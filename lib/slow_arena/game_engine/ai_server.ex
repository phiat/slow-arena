defmodule SlowArena.GameEngine.AIServer do
  use GenServer
  require Logger

  @aggro_range 200.0
  @chase_range 400.0
  @attack_range 50.0
  @npc_speed 80.0
  @delta_time 0.1
  @attack_cooldown 1500

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_), do: {:ok, %{}}

  def tick do
    :mnesia.dirty_all_keys(:npc_state)
    |> Enum.each(&update_npc/1)
  end

  def spawn_npc(template_id, instance_id, x, y, health, opts \\ []) do
    npc_id = "npc_#{:erlang.unique_integer([:positive])}"
    max_health = Keyword.get(opts, :max_health, health)

    :mnesia.dirty_write({
      :npc_state,
      npc_id,
      template_id,
      instance_id,
      x * 1.0,
      y * 1.0,
      health,
      max_health,
      :idle,
      nil,
      0,
      {x * 1.0, y * 1.0}
    })

    {:ok, npc_id}
  end

  defp update_npc(npc_id) do
    case :mnesia.dirty_read(:npc_state, npc_id) do
      [{:npc_state, ^npc_id, tid, iid, x, y, hp, max_hp, ai_state, target_id, last_attack, spawn}]
      when hp > 0 ->
        {new_state, new_target, new_x, new_y} =
          case ai_state do
            :idle -> idle_behavior(x, y, iid)
            :chase -> chase_behavior(x, y, target_id)
            :attack -> attack_behavior(npc_id, x, y, target_id, last_attack)
            :flee -> flee_behavior(x, y, spawn)
            _ -> {:idle, nil, x, y}
          end

        new_last_attack =
          if new_state == :attack and ai_state != :attack, do: 0, else: last_attack

        :mnesia.dirty_write(
          {:npc_state, npc_id, tid, iid, new_x, new_y, hp, max_hp, new_state, new_target,
           new_last_attack, spawn}
        )

      # Dead or missing
      _ ->
        :ok
    end
  end

  defp idle_behavior(x, y, instance_id) do
    case find_nearest_player(x, y, instance_id, @aggro_range) do
      nil -> {:idle, nil, x, y}
      player_id -> {:chase, player_id, x, y}
    end
  end

  defp chase_behavior(x, y, target_id) do
    case get_player_pos(target_id) do
      nil ->
        {:idle, nil, x, y}

      {px, py} ->
        dist = distance(x, y, px, py)

        cond do
          dist <= @attack_range ->
            {:attack, target_id, x, y}

          dist > @chase_range ->
            {:idle, nil, x, y}

          true ->
            {nx, ny} = move_toward(x, y, px, py)
            {:chase, target_id, nx, ny}
        end
    end
  end

  defp attack_behavior(npc_id, x, y, target_id, last_attack) do
    now = System.monotonic_time(:millisecond)

    if now - last_attack >= @attack_cooldown do
      # Execute attack
      case get_player_pos(target_id) do
        nil ->
          {:idle, nil, x, y}

        {px, py} ->
          if distance(x, y, px, py) <= @attack_range do
            execute_npc_attack(npc_id, target_id)
            # Update last_attack via direct write
            case :mnesia.dirty_read(:npc_state, npc_id) do
              [{:npc_state, nid, tid, iid, nx, ny, hp, mhp, _, _, _, sp}] ->
                :mnesia.dirty_write(
                  {:npc_state, nid, tid, iid, nx, ny, hp, mhp, :attack, target_id, now, sp}
                )

              _ ->
                :ok
            end

            {:attack, target_id, x, y}
          else
            {:chase, target_id, x, y}
          end
      end
    else
      # Still on cooldown, check range
      case get_player_pos(target_id) do
        nil ->
          {:idle, nil, x, y}

        {px, py} ->
          if distance(x, y, px, py) <= @attack_range do
            {:attack, target_id, x, y}
          else
            {:chase, target_id, x, y}
          end
      end
    end
  end

  defp flee_behavior(x, y, {sx, sy}) do
    if distance(x, y, sx, sy) < 5.0 do
      {:idle, nil, x, y}
    else
      {nx, ny} = move_toward(x, y, sx, sy)
      {:flee, nil, nx, ny}
    end
  end

  defp execute_npc_attack(_npc_id, target_id) do
    # Simple damage to player
    case :mnesia.dirty_read(:player_stats, target_id) do
      [{:player_stats, cid, class, level, hp, max_hp, mana, max_mana, str, int, agi, armor}] ->
        damage = max(1, 10 - div(armor, 10))
        new_hp = max(0, hp - damage)

        :mnesia.dirty_write(
          {:player_stats, cid, class, level, new_hp, max_hp, mana, max_mana, str, int, agi, armor}
        )

        if new_hp == 0 do
          Logger.info("Player #{target_id} was killed!")
        end

      _ ->
        :ok
    end
  end

  defp find_nearest_player(x, y, _instance_id, range) do
    :mnesia.dirty_all_keys(:player_positions)
    |> Enum.map(fn pid ->
      case :mnesia.dirty_read(:player_positions, pid) do
        [{:player_positions, ^pid, px, py, _, _, _, _, _, _}] ->
          {pid, distance(x, y, px, py)}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn {_, d} -> d <= range end)
    |> Enum.sort_by(&elem(&1, 1))
    |> List.first()
    |> case do
      {pid, _} -> pid
      nil -> nil
    end
  end

  defp get_player_pos(player_id) do
    case :mnesia.dirty_read(:player_positions, player_id) do
      [{:player_positions, _, x, y, _, _, _, _, _, _}] -> {x, y}
      _ -> nil
    end
  end

  defp move_toward(x, y, tx, ty) do
    dx = tx - x
    dy = ty - y
    dist = max(distance(x, y, tx, ty), 0.001)
    {x + dx / dist * @npc_speed * @delta_time, y + dy / dist * @npc_speed * @delta_time}
  end

  defp distance(x1, y1, x2, y2) do
    :math.sqrt(:math.pow(x2 - x1, 2) + :math.pow(y2 - y1, 2))
  end
end
