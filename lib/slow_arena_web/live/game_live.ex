defmodule SlowArenaWeb.GameLive do
  use SlowArenaWeb, :live_view
  require Logger

  alias SlowArena.GameEngine.{Movement, CombatServer, DungeonServer, LootServer, Broadcast, Classes}

  @ability_keys %{
    "1" => "slash",
    "2" => "shield_bash",
    "3" => "fireball",
    "4" => "ice_lance",
    "5" => "arrow_volley",
    "6" => "backstab"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Generate a unique player ID
      player_id = "player_#{:erlang.unique_integer([:positive])}"
      class = "warrior"

      # Spawn the player
      spawn_player(player_id, class)

      # Create a dungeon with monsters
      {:ok, instance_id} = DungeonServer.create_instance("crypt_of_bones", "solo", :normal)

      # Place player at entrance
      :mnesia.dirty_write(
        {:player_positions, player_id, 50.0, 300.0, 0.0, 0.0, 0.0, "crypt_of_bones", instance_id,
         System.monotonic_time(:millisecond)}
      )

      # Subscribe to game state broadcasts
      Phoenix.PubSub.subscribe(SlowArena.PubSub, Broadcast.topic())


      {:ok,
       assign(socket,
         player_id: player_id,
         instance_id: instance_id,
         keys: %{up: false, down: false, left: false, right: false},
         debug_open: false,
         game_state: %{players: [], npcs: [], loot: [], combat_events: [], debug: %{}}
       )}
    else
      {:ok,
       assign(socket,
         player_id: nil,
         instance_id: nil,
         keys: %{up: false, down: false, left: false, right: false},
         debug_open: false,
         game_state: %{players: [], npcs: [], loot: [], combat_events: [], debug: %{}}
       )}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if player_id = socket.assigns[:player_id] do
      cleanup_player(player_id)
    end

    if instance_id = socket.assigns[:instance_id] do
      DungeonServer.cleanup_instance(instance_id)
    end
  end

  @impl true
  def handle_event("keydown", %{"key" => key}, socket) do
    socket = handle_key(socket, key, true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("keyup", %{"key" => key}, socket) do
    socket = handle_key(socket, key, false)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:game_state, state}, socket) do
    socket =
      socket
      |> assign(:game_state, state)
      |> push_event("game_state", %{
        players: state.players,
        npcs: state.npcs,
        loot: state.loot,
        combat_events: state.combat_events,
        debug: if(socket.assigns.debug_open, do: state.debug, else: nil),
        local_player_id: socket.assigns.player_id
      })

    {:noreply, socket}
  end

  defp handle_key(socket, key, pressed) when key in ["w", "W", "ArrowUp"] do
    update_movement(socket, :up, pressed)
  end

  defp handle_key(socket, key, pressed) when key in ["s", "S", "ArrowDown"] do
    update_movement(socket, :down, pressed)
  end

  defp handle_key(socket, key, pressed) when key in ["a", "A", "ArrowLeft"] do
    update_movement(socket, :left, pressed)
  end

  defp handle_key(socket, key, pressed) when key in ["d", "D", "ArrowRight"] do
    update_movement(socket, :right, pressed)
  end

  defp handle_key(socket, key, true) when is_map_key(@ability_keys, key) do
    ability_id = @ability_keys[key]
    player_id = socket.assigns.player_id

    if player_id do
      # Cast toward nearest NPC
      case find_nearest_npc(player_id) do
        {target_x, target_y} ->
          case CombatServer.cast_ability(player_id, ability_id, target_x, target_y) do
            {:ok, result} ->
              Logger.debug("Cast #{ability_id}: #{inspect(result)}")

            {:error, reason} ->
              Logger.debug("Cast failed: #{inspect(reason)}")
          end

        nil ->
          # Cast in facing direction
          case :mnesia.dirty_read(:player_positions, player_id) do
            [{:player_positions, _, x, y, facing, _, _, _, _, _}] ->
              tx = x + :math.cos(facing) * 100
              ty = y + :math.sin(facing) * 100
              CombatServer.cast_ability(player_id, ability_id, tx, ty)

            _ ->
              :ok
          end
      end
    end

    socket
  end

  defp handle_key(socket, key, true) when key in ["e", "E"] do
    try_pickup_loot(socket)
  end

  defp handle_key(socket, "`", true) do
    assign(socket, :debug_open, !socket.assigns.debug_open)
  end

  defp handle_key(socket, "~", true) do
    assign(socket, :debug_open, !socket.assigns.debug_open)
  end

  defp handle_key(socket, _key, _pressed), do: socket

  defp update_movement(socket, direction, pressed) do
    keys = Map.put(socket.assigns.keys, direction, pressed)
    player_id = socket.assigns.player_id

    if player_id do
      Movement.set_input(player_id, keys)
    end

    assign(socket, :keys, keys)
  end

  defp spawn_player(player_id, class_name) do
    stats = Classes.stats(class_name)

    :mnesia.dirty_write(
      {:player_positions, player_id, 50.0, 300.0, 0.0, 0.0, 0.0, "lobby", nil,
       System.monotonic_time(:millisecond)}
    )

    :mnesia.dirty_write(
      {:player_stats, player_id, stats.class, 1, stats.hp, stats.max_hp, stats.mana,
       stats.max_mana, stats.str, stats.int, stats.agi, stats.armor}
    )

    :mnesia.dirty_write({:player_gold, player_id, 0})
  end

  defp cleanup_player(player_id) do
    :mnesia.dirty_delete(:player_positions, player_id)
    :mnesia.dirty_delete(:player_stats, player_id)
    :mnesia.dirty_delete(:player_auto_attack, player_id)
    :mnesia.dirty_delete(:player_equipment, player_id)
    :mnesia.dirty_delete(:player_gold, player_id)

    # Clean up cooldowns (composite keys)
    :mnesia.dirty_all_keys(:player_cooldowns)
    |> Enum.each(fn {cid, _ability} = key when cid == player_id ->
      :mnesia.dirty_delete(:player_cooldowns, key)
    _ -> :ok
    end)

    # Clean up inventory (composite keys)
    :mnesia.dirty_all_keys(:player_inventory)
    |> Enum.each(fn {cid, _item} = key when cid == player_id ->
      :mnesia.dirty_delete(:player_inventory, key)
    _ -> :ok
    end)

    Logger.info("Cleaned up player #{player_id}")
  end

  defp find_nearest_npc(player_id) do
    case :mnesia.dirty_read(:player_positions, player_id) do
      [{:player_positions, _, px, py, _, _, _, _, _, _}] ->
        :mnesia.dirty_all_keys(:npc_state)
        |> Enum.flat_map(fn npc_id ->
          case :mnesia.dirty_read(:npc_state, npc_id) do
            [{:npc_state, _, _, _, x, y, hp, _, _, _, _, _}] when hp > 0 ->
              [{npc_id, x, y, :math.sqrt(:math.pow(px - x, 2) + :math.pow(py - y, 2))}]

            _ ->
              []
          end
        end)
        |> Enum.sort_by(&elem(&1, 3))
        |> case do
          [{_, x, y, _} | _] -> {x, y}
          [] -> nil
        end

      _ ->
        nil
    end
  end

  defp try_pickup_loot(%{assigns: %{player_id: nil}} = socket), do: socket

  defp try_pickup_loot(socket) do
    %{player_id: player_id, instance_id: instance_id} = socket.assigns

    with [{:player_positions, _, px, py, _, _, _, _, _, _}] <-
           :mnesia.dirty_read(:player_positions, player_id),
         {loot_id, _lx, _ly} <- find_nearest_loot(px, py, instance_id),
         {:ok, loot} <- LootServer.pickup_loot(player_id, loot_id, px, py, instance_id) do
      push_event(socket, "loot_pickup", %{gold: loot.gold, items: loot.items})
    else
      _ -> socket
    end
  end

  defp find_nearest_loot(px, py, instance_id) do
    :mnesia.dirty_all_keys(:loot_piles)
    |> Enum.flat_map(fn lid ->
      case :mnesia.dirty_read(:loot_piles, lid) do
        [{:loot_piles, ^lid, ^instance_id, x, y, _items, _gold, _, _, _}] ->
          dist = :math.sqrt(:math.pow(px - x, 2) + :math.pow(py - y, 2))
          if dist <= 50.0, do: [{lid, x, y, dist}], else: []

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&elem(&1, 3))
    |> case do
      [{lid, x, y, _} | _] -> {lid, x, y}
      [] -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="game-container" phx-window-keydown="keydown" phx-window-keyup="keyup" class="flex flex-col items-center gap-4 p-4">
      <div class="flex gap-4 items-center text-sm">
        <span class="sa-title text-lg">Slow Arena</span>
        <span class="sa-subtitle">WASD = move | 1-6 = abilities | ` = debug</span>
      </div>

      <div class="flex gap-3 items-start">
        <canvas
          id="game-canvas"
          phx-hook="GameCanvas"
          width="800"
          height="600"
          phx-update="ignore"
        />

        <%= if @debug_open do %>
          <canvas
            id="debug-canvas"
            phx-hook="DebugCanvas"
            width="220"
            height="600"
            phx-update="ignore"
            style="border: 1px solid rgba(129, 240, 229, 0.2); border-radius: 4px;"
          />
        <% end %>
      </div>

      <div id="hud" class="sa-hud flex gap-6 text-sm">
        <%= if @player_id do %>
          <% player = Enum.find(@game_state.players, &(&1.id == @player_id)) %>
          <%= if player do %>
            <span>
              HP: <span class="sa-hud-hp"><%= player.hp %>/<%= player.max_hp %></span>
            </span>
            <span>
              Mana: <span class="sa-hud-mana"><%= player.mana %>/<%= player.max_mana %></span>
            </span>
            <span class="sa-hud-gold">
              Gold: <%= player[:gold] || 0 %>
            </span>
            <span>
              Pos: (<%= Float.round(player.x, 0) |> trunc %>, <%= Float.round(player.y, 0) |> trunc %>)
            </span>
          <% end %>
          <span class="sa-hud-dim">NPCs: <%= length(@game_state.npcs) %></span>
          <span class="sa-hud-dim">Loot: <%= length(@game_state.loot) %></span>
        <% else %>
          <span class="sa-hud-dim">Connecting...</span>
        <% end %>
      </div>
    </div>
    """
  end
end
