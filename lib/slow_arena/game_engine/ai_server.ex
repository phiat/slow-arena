defmodule SlowArena.GameEngine.AIServer do
  @moduledoc "NPC AI state machines with template-driven behaviors."
  use GenServer
  require Logger

  @delta_time 0.1

  # Template-driven behavior configs
  @behavior_configs %{
    "goblin" => %{
      aggro_range: 200.0,
      chase_range: 400.0,
      attack_range: 50.0,
      speed: 80.0,
      attack_cooldown: 1500,
      flee_threshold: 0.2,
      behavior: :standard,
      damage: 10
    },
    "skeleton_warrior" => %{
      aggro_range: 200.0,
      chase_range: 400.0,
      attack_range: 50.0,
      speed: 80.0,
      attack_cooldown: 1500,
      flee_threshold: 0.0,
      behavior: :standard,
      damage: 12
    },
    "boss_ogre" => %{
      aggro_range: 250.0,
      chase_range: 500.0,
      attack_range: 60.0,
      speed: 60.0,
      attack_cooldown: 2000,
      flee_threshold: 0.0,
      behavior: :standard,
      damage: 25
    },
    "ghost" => %{
      aggro_range: 150.0,
      chase_range: 400.0,
      attack_range: 60.0,
      speed: 120.0,
      attack_cooldown: 2000,
      flee_threshold: 0.3,
      behavior: :erratic,
      damage: 8,
      ignores_collision: true
    },
    "spider" => %{
      aggro_range: 100.0,
      chase_range: 300.0,
      attack_range: 30.0,
      speed: 140.0,
      attack_cooldown: 800,
      flee_threshold: 0.0,
      behavior: :pack,
      damage: 6,
      patrol_radius: 100.0,
      pack_alert_range: 150.0
    },
    "necromancer" => %{
      aggro_range: 300.0,
      chase_range: 500.0,
      attack_range: 200.0,
      speed: 60.0,
      attack_cooldown: 3000,
      flee_threshold: 0.4,
      behavior: :keep_distance,
      damage: 30,
      min_range: 150.0
    },
    "slime" => %{
      aggro_range: 80.0,
      chase_range: 200.0,
      attack_range: 40.0,
      speed: 40.0,
      attack_cooldown: 2000,
      flee_threshold: 0.0,
      behavior: :standard,
      damage: 8,
      splits_on_death: true
    }
  }

  @default_behavior %{
    aggro_range: 200.0,
    chase_range: 400.0,
    attack_range: 50.0,
    speed: 80.0,
    attack_cooldown: 1500,
    flee_threshold: 0.0,
    behavior: :standard,
    damage: 10
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_), do: {:ok, %{}}

  def get_behavior(template_id) do
    Map.get(@behavior_configs, to_string(template_id), @default_behavior)
  end

  def behavior_configs, do: @behavior_configs

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
        cfg = get_behavior(tid)

        cond do
          cfg.flee_threshold > 0 and hp / max_hp <= cfg.flee_threshold and ai_state != :flee ->
            :mnesia.dirty_write(
              {:npc_state, npc_id, tid, iid, x, y, hp, max_hp, :flee, nil, last_attack, spawn}
            )

          ai_state in [:attack, :keep_distance] ->
            run_combat_behavior(npc_id, tid, iid, x, y, hp, max_hp, ai_state, target_id, last_attack, spawn, cfg)

          true ->
            run_movement_behavior(npc_id, tid, iid, x, y, hp, max_hp, ai_state, target_id, last_attack, spawn, cfg)
        end

      # Dead or missing
      _ ->
        :ok
    end
  end

  defp run_combat_behavior(npc_id, tid, iid, x, y, hp, max_hp, ai_state, target_id, last_attack, spawn, cfg) do
    {new_state, new_target, new_x, new_y} =
      case ai_state do
        :attack -> attack_behavior(npc_id, x, y, target_id, last_attack, cfg, tid)
        :keep_distance -> keep_distance_behavior(npc_id, x, y, target_id, last_attack, cfg)
      end

    # Re-read last_attack from Mnesia (attack may have stamped a new value)
    current_la =
      case :mnesia.dirty_read(:npc_state, npc_id) do
        [{:npc_state, _, _, _, _, _, _, _, _, _, la, _}] -> la
        _ -> last_attack
      end

    {cx, cy} = resolve_collision(npc_id, new_x, new_y, tid, cfg)

    :mnesia.dirty_write(
      {:npc_state, npc_id, tid, iid, cx, cy, hp, max_hp, new_state, new_target, current_la, spawn}
    )
  end

  defp run_movement_behavior(npc_id, tid, iid, x, y, hp, max_hp, ai_state, target_id, last_attack, spawn, cfg) do
    {new_state, new_target, new_x, new_y} =
      case ai_state do
        :idle -> idle_behavior(x, y, iid, cfg, tid, npc_id)
        :patrol -> patrol_behavior(x, y, iid, cfg, spawn)
        :chase -> chase_behavior(x, y, target_id, cfg)
        :flee -> flee_behavior(x, y, spawn, cfg)
        _ -> {:idle, nil, x, y}
      end

    # Reset last_attack when first entering attack state
    new_last_attack = if new_state == :attack and ai_state != :attack, do: 0, else: last_attack
    {cx, cy} = resolve_collision(npc_id, new_x, new_y, tid, cfg)

    :mnesia.dirty_write(
      {:npc_state, npc_id, tid, iid, cx, cy, hp, max_hp, new_state, new_target, new_last_attack, spawn}
    )
  end

  defp idle_behavior(x, y, instance_id, cfg, _tid, npc_id) do
    case find_nearest_player(x, y, instance_id, cfg.aggro_range) do
      nil ->
        # Spiders patrol when idle
        if cfg.behavior == :pack do
          {:patrol, nil, x, y}
        else
          {:idle, nil, x, y}
        end

      player_id ->
        # Pack behavior: alert nearby spiders
        if cfg.behavior == :pack do
          alert_pack(npc_id, x, y, instance_id, player_id, cfg)
        end

        {:chase, player_id, x, y}
    end
  end

  defp patrol_behavior(x, y, instance_id, cfg, {sx, sy}) do
    # Check for players first
    case find_nearest_player(x, y, instance_id, cfg.aggro_range) do
      nil ->
        # Wander randomly within patrol_radius of spawn
        patrol_radius = Map.get(cfg, :patrol_radius, 100.0)
        # Pick a random point near spawn if close to current position or no target
        angle = :rand.uniform() * 2 * :math.pi()
        dist = :rand.uniform() * patrol_radius
        tx = sx + :math.cos(angle) * dist
        ty = sy + :math.sin(angle) * dist

        # Move slowly toward random point
        speed = cfg.speed * 0.3
        {nx, ny} = move_toward_speed(x, y, tx, ty, speed)
        {:patrol, nil, nx, ny}

      player_id ->
        # Alert pack and chase
        if cfg.behavior == :pack do
          alert_pack(nil, x, y, instance_id, player_id, cfg)
        end

        {:chase, player_id, x, y}
    end
  end

  defp chase_behavior(x, y, target_id, cfg) do
    case get_player_pos(target_id) do
      nil ->
        {:idle, nil, x, y}

      {px, py} ->
        dist = distance(x, y, px, py)

        cond do
          dist <= cfg.attack_range ->
            # Ranged keep_distance NPCs should transition to keep_distance state
            if cfg.behavior == :keep_distance do
              {:keep_distance, target_id, x, y}
            else
              {:attack, target_id, x, y}
            end

          dist > cfg.chase_range ->
            {:idle, nil, x, y}

          true ->
            {nx, ny} =
              if cfg.behavior == :erratic do
                # Ghost: erratic movement (add random offset)
                move_erratic(x, y, px, py, cfg.speed)
              else
                move_toward_speed(x, y, px, py, cfg.speed)
              end

            {:chase, target_id, nx, ny}
        end
    end
  end

  defp attack_behavior(npc_id, x, y, target_id, last_attack, cfg, _tid) do
    now = System.monotonic_time(:millisecond)
    ready = now - last_attack >= cfg.attack_cooldown

    case get_player_pos(target_id) do
      nil ->
        {:idle, nil, x, y}

      {px, py} ->
        in_range = distance(x, y, px, py) <= cfg.attack_range
        do_attack(in_range, ready, npc_id, x, y, target_id, now, cfg)
    end
  end

  defp do_attack(true, true, npc_id, x, y, target_id, now, cfg) do
    execute_npc_attack(npc_id, target_id, cfg)
    stamp_last_attack(npc_id, target_id, now)
    {:attack, target_id, x, y}
  end

  defp do_attack(true, false, _npc_id, x, y, target_id, _now, _cfg) do
    {:attack, target_id, x, y}
  end

  defp do_attack(false, _, _npc_id, x, y, target_id, _now, _cfg) do
    {:chase, target_id, x, y}
  end

  defp stamp_last_attack(npc_id, target_id, now),
    do: stamp_last_attack_state(npc_id, target_id, now, :attack)

  defp stamp_last_attack_state(npc_id, target_id, now, ai_state) do
    case :mnesia.dirty_read(:npc_state, npc_id) do
      [{:npc_state, nid, tid, iid, nx, ny, hp, mhp, _, _, _, sp}] ->
        :mnesia.dirty_write(
          {:npc_state, nid, tid, iid, nx, ny, hp, mhp, ai_state, target_id, now, sp}
        )

      _ ->
        :ok
    end
  end

  defp keep_distance_behavior(npc_id, x, y, target_id, last_attack, cfg) do
    min_range = Map.get(cfg, :min_range, 150.0)
    now = System.monotonic_time(:millisecond)

    case get_player_pos(target_id) do
      nil ->
        {:idle, nil, x, y}

      {px, py} ->
        dist = distance(x, y, px, py)

        cond do
          dist > cfg.chase_range ->
            {:idle, nil, x, y}

          dist < min_range ->
            {nx, ny} = move_away_from(x, y, px, py, cfg.speed)
            {:keep_distance, target_id, nx, ny}

          dist <= cfg.attack_range and now - last_attack >= cfg.attack_cooldown ->
            execute_npc_attack(npc_id, target_id, cfg)
            stamp_last_attack_state(npc_id, target_id, now, :keep_distance)
            {:keep_distance, target_id, x, y}

          true ->
            {:keep_distance, target_id, x, y}
        end
    end
  end

  defp flee_behavior(x, y, {sx, sy}, cfg) do
    if distance(x, y, sx, sy) < 5.0 do
      {:idle, nil, x, y}
    else
      speed = Map.get(cfg, :speed, 80.0)
      {nx, ny} = move_toward_speed(x, y, sx, sy, speed)
      {:flee, nil, nx, ny}
    end
  end

  defp execute_npc_attack(npc_id, target_id, _cfg) do
    # Look up NPC template for damage scaling, delegate to CombatServer
    template_id =
      case :mnesia.dirty_read(:npc_state, npc_id) do
        [{:npc_state, _, tid, _, _, _, _, _, _, _, _, _}] -> tid
        _ -> "unknown"
      end

    SlowArena.GameEngine.CombatServer.apply_npc_damage(npc_id, target_id, template_id)
  end

  # Pack alert: when one spider aggros, nearby spiders also aggro
  defp alert_pack(alerter_id, x, y, instance_id, player_id, cfg) do
    pack_range = Map.get(cfg, :pack_alert_range, 150.0)

    :mnesia.dirty_all_keys(:npc_state)
    |> Enum.each(fn npc_id ->
      if npc_id != alerter_id do
        maybe_alert_peer(npc_id, x, y, instance_id, player_id, pack_range)
      end
    end)
  end

  defp maybe_alert_peer(npc_id, x, y, instance_id, player_id, pack_range) do
    case :mnesia.dirty_read(:npc_state, npc_id) do
      [{:npc_state, ^npc_id, tid, ^instance_id, nx, ny, hp, max_hp, ai_state, _tgt, la, sp}]
      when hp > 0 and ai_state in [:idle, :patrol] ->
        peer_cfg = get_behavior(tid)

        if peer_cfg.behavior == :pack and distance(x, y, nx, ny) <= pack_range do
          :mnesia.dirty_write(
            {:npc_state, npc_id, tid, instance_id, nx, ny, hp, max_hp, :chase, player_id, la, sp}
          )
        end

      _ ->
        :ok
    end
  end

  # Slime split on death: called from combat_server handle_npc_death
  def on_npc_death(template_id, instance_id, x, y, _hp_at_death, max_hp) do
    cfg = get_behavior(template_id)

    if Map.get(cfg, :splits_on_death, false) and max_hp >= 10 do
      split_hp = div(max_hp, 2)
      offset = 20.0

      spawn_npc(template_id, instance_id, x - offset, y, split_hp, max_health: split_hp)
      spawn_npc(template_id, instance_id, x + offset, y, split_hp, max_health: split_hp)

      Logger.info("Slime split into 2 at (#{x}, #{y}) with #{split_hp} HP each")
      :split
    else
      :no_split
    end
  end

  defp find_nearest_player(x, y, instance_id, range) do
    :mnesia.dirty_all_keys(:player_positions)
    |> Enum.flat_map(fn pid ->
      case :mnesia.dirty_read(:player_positions, pid) do
        [{:player_positions, ^pid, px, py, _, _, _, _, ^instance_id, _}] ->
          dist = distance(x, y, px, py)
          if dist <= range, do: [{pid, dist}], else: []

        _ ->
          []
      end
    end)
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

  defp move_toward_speed(x, y, tx, ty, speed) do
    dx = tx - x
    dy = ty - y
    dist = max(distance(x, y, tx, ty), 0.001)
    {x + dx / dist * speed * @delta_time, y + dy / dist * speed * @delta_time}
  end

  defp move_away_from(x, y, tx, ty, speed) do
    dx = x - tx
    dy = y - ty
    dist = max(:math.sqrt(dx * dx + dy * dy), 0.001)
    new_x = x + dx / dist * speed * @delta_time
    new_y = y + dy / dist * speed * @delta_time
    # Clamp to bounds (800x600)
    {max(10.0, min(790.0, new_x)), max(10.0, min(590.0, new_y))}
  end

  defp move_erratic(x, y, tx, ty, speed) do
    dx = tx - x
    dy = ty - y
    angle = :math.atan2(dy, dx) + (:rand.uniform() - 0.5) * :math.pi() * 0.8
    nx = x + :math.cos(angle) * speed * @delta_time
    ny = y + :math.sin(angle) * speed * @delta_time
    {nx, ny}
  end

  # Ghosts ignore collision (ethereal), others get soft repulsion
  defp resolve_collision(_npc_id, x, y, _tid, %{ignores_collision: true}), do: {x, y}

  defp resolve_collision(npc_id, x, y, tid, _cfg) do
    SlowArena.GameEngine.Collision.resolve_npc(npc_id, x, y, tid)
  end

  defp distance(x1, y1, x2, y2) do
    :math.sqrt(:math.pow(x2 - x1, 2) + :math.pow(y2 - y1, 2))
  end
end
