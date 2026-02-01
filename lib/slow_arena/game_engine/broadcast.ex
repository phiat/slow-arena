defmodule SlowArena.GameEngine.Broadcast do
  @moduledoc """
  Collects game state from Mnesia and broadcasts via PubSub each tick.
  """

  @topic "game:state"

  def send_updates(loop_stats \\ nil) do
    state = %{
      players: collect_players(),
      npcs: collect_npcs(),
      loot: collect_loot(),
      combat_events: collect_recent_events(),
      debug: collect_debug(loop_stats)
    }

    Phoenix.PubSub.broadcast(SlowArena.PubSub, @topic, {:game_state, state})
  end

  def topic, do: @topic

  defp collect_players do
    :mnesia.dirty_all_keys(:player_positions)
    |> Enum.flat_map(fn char_id ->
      with [{:player_positions, ^char_id, x, y, facing, vx, vy, _zone, _inst, _t}] <-
             :mnesia.dirty_read(:player_positions, char_id),
           [{:player_stats, ^char_id, class, _level, hp, max_hp, mana, max_mana, _str, _int, _agi, _armor}] <-
             :mnesia.dirty_read(:player_stats, char_id) do
        gold =
          case :mnesia.dirty_read(:player_gold, char_id) do
            [{:player_gold, _, amount}] -> amount
            [] -> 0
          end

        [
          %{
            id: char_id,
            x: x,
            y: y,
            facing: facing,
            vx: vx,
            vy: vy,
            class: class,
            hp: round_stat(hp),
            max_hp: max_hp,
            mana: round_stat(mana),
            max_mana: max_mana,
            dead: hp <= 0,
            gold: gold
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp collect_npcs do
    :mnesia.dirty_all_keys(:npc_state)
    |> Enum.flat_map(fn npc_id ->
      case :mnesia.dirty_read(:npc_state, npc_id) do
        [{:npc_state, ^npc_id, template_id, _inst, x, y, hp, max_hp, ai_state, _target, _la, _sp}] ->
          [
            %{
              id: npc_id,
              template: template_id,
              x: x,
              y: y,
              hp: hp,
              max_hp: max_hp,
              ai_state: ai_state
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp collect_loot do
    :mnesia.dirty_all_keys(:loot_piles)
    |> Enum.flat_map(fn lid ->
      case :mnesia.dirty_read(:loot_piles, lid) do
        [{:loot_piles, ^lid, _inst, x, y, items, gold, _spawned, _expires, _reserved}] ->
          [%{id: lid, x: x, y: y, item_count: length(items), gold: gold}]

        _ ->
          []
      end
    end)
  end

  defp collect_debug(nil), do: %{}

  defp collect_debug(loop_stats) do
    # Mnesia table sizes
    tables = [:player_positions, :player_stats, :player_cooldowns, :player_auto_attack,
              :npc_state, :loot_piles, :party_state, :dungeon_instances, :combat_events,
              :player_equipment]

    table_sizes =
      Enum.map(tables, fn t ->
        size = try do :mnesia.table_info(t, :size) rescue _ -> 0 end
        {t, size}
      end)
      |> Map.new()

    memory =
      Enum.map(tables, fn t ->
        try do :mnesia.table_info(t, :memory) * :erlang.system_info(:wordsize) rescue _ -> 0 end
      end)
      |> Enum.sum()

    %{
      tick_count: loop_stats.tick_count,
      avg_tick_ms: loop_stats.avg_elapsed_ms,
      tick_rate: loop_stats.tick_rate,
      table_sizes: table_sizes,
      mnesia_memory_bytes: memory,
      process_count: :erlang.system_info(:process_count),
      beam_memory_mb: Float.round(:erlang.memory(:total) / 1_048_576, 1),
      uptime_s: div(System.monotonic_time(:millisecond), 1000),
      node: node(),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      scheduler_count: :erlang.system_info(:schedulers_online)
    }
  end

  defp collect_recent_events do
    now = System.monotonic_time(:millisecond)
    cutoff = now - 2000

    :mnesia.dirty_all_keys(:combat_events)
    |> Enum.flat_map(fn eid ->
      case :mnesia.dirty_read(:combat_events, eid) do
        [{:combat_events, ^eid, type, attacker, target, damage, ts}] when ts > cutoff ->
          [%{id: eid, type: type, attacker: attacker, target: target, damage: damage, ts: ts}]

        _ ->
          []
      end
    end)
  end

  # Round HP/mana to integers for display (they can be floats from regen)
  defp round_stat(value) when is_float(value), do: trunc(value)
  defp round_stat(value), do: value
end
