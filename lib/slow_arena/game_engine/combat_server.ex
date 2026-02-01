defmodule SlowArena.GameEngine.CombatServer do
  @moduledoc "Ability casting, auto-attacks, damage, death/respawn, and regen."
  use GenServer
  require Logger

  # 1 second
  @auto_attack_cooldown 1000
  @auto_attack_range 50.0

  # Regen rates (per tick at 10Hz = 100ms)
  # 1 mana/s = 0.1 per tick
  @mana_regen_per_tick 0.1
  # 0.5 HP/s = 0.05 per tick, only out of combat
  @hp_regen_per_tick 0.05
  # 5 seconds out of combat before HP regen kicks in
  @hp_regen_ooc_ms 5000

  # Respawn delay in ms
  @respawn_delay_ms 5000
  @respawn_x 50.0
  @respawn_y 300.0

  # NPC damage ranges by template
  @npc_damage_ranges %{
    "goblin" => {8, 12},
    "skeleton_warrior" => {12, 18},
    "boss_ogre" => {25, 40},
    "ghost" => {6, 10},
    "spider" => {4, 8},
    "necromancer" => {25, 35},
    "slime" => {5, 10}
  }

  # Default NPC damage for unknown templates
  @npc_damage_default {6, 10}

  # Ability definitions
  @abilities %{
    "slash" => %{
      cooldown: 2000,
      mana: 10,
      damage: 25,
      scaling: :strength,
      factor: 1.5,
      range: 60.0,
      type: :instant,
      description: "A powerful melee strike that scales with Strength."
    },
    "shield_bash" => %{
      cooldown: 5000,
      mana: 15,
      damage: 15,
      scaling: :strength,
      factor: 1.0,
      range: 50.0,
      type: :instant,
      stun: 1500,
      description: "Bash your shield into the target, dealing damage and stunning for 1.5s."
    },
    "fireball" => %{
      cooldown: 3000,
      mana: 20,
      damage: 40,
      scaling: :intelligence,
      factor: 2.0,
      range: 200.0,
      type: :projectile,
      description: "Hurl a ball of fire at the target. High Intelligence scaling."
    },
    "ice_lance" => %{
      cooldown: 2000,
      mana: 15,
      damage: 30,
      scaling: :intelligence,
      factor: 1.5,
      range: 180.0,
      type: :projectile,
      description: "Launch a shard of ice. Fast cooldown, moderate damage."
    },
    "arrow_volley" => %{
      cooldown: 4000,
      mana: 20,
      damage: 35,
      scaling: :agility,
      factor: 1.8,
      range: 250.0,
      type: :aoe,
      radius: 80.0,
      description: "Rain arrows in an 80-unit radius AoE. Scales with Agility."
    },
    "backstab" => %{
      cooldown: 3000,
      mana: 15,
      damage: 50,
      scaling: :agility,
      factor: 2.5,
      range: 40.0,
      type: :instant,
      backstab: true,
      description: "Strike from behind for massive damage. 50% bonus if behind the target."
    }
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    :ets.new(:player_last_hit, [:named_table, :public, :set])
    {:ok, %{}}
  end

  # Called each game tick
  def tick do
    process_auto_attacks()
    process_effects()
    process_regen()
    process_respawns()
    cleanup_old_events()
  end

  def cast_ability(character_id, ability_id, target_x, target_y) do
    GenServer.call(__MODULE__, {:cast_ability, character_id, ability_id, target_x, target_y})
  end

  def set_auto_attack_target(character_id, target_id) do
    :mnesia.dirty_write({:player_auto_attack, character_id, target_id, 0})
    :ok
  end

  def get_abilities, do: @abilities

  @doc "Returns the NPC damage range for a given template_id"
  def npc_damage_range(template_id) do
    Map.get(@npc_damage_ranges, to_string(template_id), @npc_damage_default)
  end

  def handle_call({:cast_ability, character_id, ability_id, target_x, target_y}, _from, state) do
    result = do_cast_ability(character_id, ability_id, target_x, target_y)
    {:reply, result, state}
  end

  defp do_cast_ability(character_id, ability_id, target_x, target_y) do
    ability = Map.get(@abilities, ability_id)

    with {:ok, ability} <- validate_ability(ability, ability_id),
         :ok <- check_alive(character_id),
         :ok <- check_cooldown(character_id, ability_id),
         :ok <- check_mana(character_id, ability.mana),
         :ok <- check_range(character_id, target_x, target_y, ability.range) do
      # Apply cooldown
      now = System.monotonic_time(:millisecond)

      :mnesia.dirty_write(
        {:player_cooldowns, {character_id, ability_id}, now + ability.cooldown, ability.cooldown}
      )

      # Consume mana
      consume_mana(character_id, ability.mana)

      # Find targets and apply damage
      targets = find_targets(character_id, target_x, target_y, ability)

      damages =
        Enum.map(targets, fn target_id ->
          damage = calculate_damage(character_id, target_id, ability)
          apply_damage(target_id, damage, character_id)
          {target_id, damage}
        end)

      # Record event
      Enum.each(damages, fn {target_id, damage} ->
        event_data =
          case ability do
            %{type: :aoe, radius: radius} ->
              %{radius: radius, target_x: target_x, target_y: target_y}

            _ ->
              nil
          end

        record_combat_event(:ability, character_id, target_id, damage, event_data)
      end)

      {:ok, %{ability: ability_id, targets: damages}}
    end
  end

  defp validate_ability(nil, id), do: {:error, {:unknown_ability, id}}
  defp validate_ability(ability, _id), do: {:ok, ability}

  defp check_alive(character_id) do
    case :mnesia.dirty_read(:player_stats, character_id) do
      [{:player_stats, _, _, _, hp, _, _, _, _, _, _, _}] when hp <= 0 ->
        {:error, :dead}

      [{:player_stats, _, _, _, _, _, _, _, _, _, _, _}] ->
        :ok

      [] ->
        {:error, :character_not_found}
    end
  end

  defp check_cooldown(character_id, ability_id) do
    now = System.monotonic_time(:millisecond)

    case :mnesia.dirty_read(:player_cooldowns, {character_id, ability_id}) do
      [{:player_cooldowns, _, expires_at, _}] when expires_at > now ->
        {:error, {:on_cooldown, expires_at - now}}

      _ ->
        :ok
    end
  end

  defp check_mana(character_id, cost) do
    case :mnesia.dirty_read(:player_stats, character_id) do
      [{:player_stats, _, _, _, _, _, mana, _, _, _, _, _}] when mana >= cost ->
        :ok

      [{:player_stats, _, _, _, _, _, mana, _, _, _, _, _}] ->
        {:error, {:not_enough_mana, mana, cost}}

      [] ->
        {:error, :character_not_found}
    end
  end

  defp check_range(character_id, target_x, target_y, range) do
    case :mnesia.dirty_read(:player_positions, character_id) do
      [{:player_positions, _, x, y, _, _, _, _, _, _}] ->
        dist = :math.sqrt(:math.pow(target_x - x, 2) + :math.pow(target_y - y, 2))
        if dist <= range, do: :ok, else: {:error, :out_of_range}

      [] ->
        {:error, :character_not_found}
    end
  end

  defp consume_mana(character_id, cost) do
    case :mnesia.dirty_read(:player_stats, character_id) do
      [{:player_stats, cid, class, level, hp, max_hp, mana, max_mana, str, int, agi, armor}] ->
        :mnesia.dirty_write(
          {:player_stats, cid, class, level, hp, max_hp, max(0, mana - cost), max_mana, str, int,
           agi, armor}
        )

      _ ->
        :ok
    end
  end

  defp find_targets(_caster_id, target_x, target_y, %{type: :aoe, radius: radius}) do
    # Find all NPCs in radius
    :mnesia.dirty_all_keys(:npc_state)
    |> Enum.filter(fn npc_id ->
      case :mnesia.dirty_read(:npc_state, npc_id) do
        [{:npc_state, _, _, _, x, y, hp, _, _, _, _, _}] when hp > 0 ->
          :math.sqrt(:math.pow(target_x - x, 2) + :math.pow(target_y - y, 2)) <= radius

        _ ->
          false
      end
    end)
  end

  defp find_targets(_caster_id, target_x, target_y, _ability) do
    # Find closest NPC to target point
    :mnesia.dirty_all_keys(:npc_state)
    |> Enum.map(fn npc_id ->
      case :mnesia.dirty_read(:npc_state, npc_id) do
        [{:npc_state, _, _, _, x, y, hp, _, _, _, _, _}] when hp > 0 ->
          dist = :math.sqrt(:math.pow(target_x - x, 2) + :math.pow(target_y - y, 2))
          {npc_id, dist}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.take(1)
    |> Enum.filter(fn {_, dist} -> dist <= 50.0 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp calculate_damage(attacker_id, target_id, ability) do
    case :mnesia.dirty_read(:player_stats, attacker_id) do
      [{:player_stats, _, _, _, _, _, _, _, str, int, agi, _}] ->
        stat_value =
          case ability.scaling do
            :strength -> str
            :intelligence -> int
            :agility -> agi
          end

        base = ability.damage + stat_value * ability.factor
        # ±10% variance
        variance = 0.9 + :rand.uniform() * 0.2
        # 15% crit chance, 2x damage
        crit = if :rand.uniform() < 0.15, do: 2.0, else: 1.0

        # Backstab behind-target bonus: 50% extra if attacker is behind NPC
        backstab_bonus = backstab_bonus(attacker_id, target_id, ability)

        trunc(base * variance * crit * backstab_bonus)

      _ ->
        ability.damage
    end
  end

  defp backstab_bonus(attacker_id, target_id, %{type: :instant} = ability) do
    # Only backstab gets the bonus
    if Map.get(ability, :backstab, false) do
      case {get_entity_pos(attacker_id, :player), get_npc_pos(target_id)} do
        {{px, py}, {nx, ny, npc_facing}} ->
          # Angle from NPC to player
          angle_to_player = :math.atan2(py - ny, px - nx)
          # NPC facing direction (using spawn point as rough facing estimate)
          # If the player is within 90 degrees of behind the NPC, bonus applies
          angle_diff = abs(angle_to_player - npc_facing)
          angle_diff = if angle_diff > :math.pi(), do: 2 * :math.pi() - angle_diff, else: angle_diff

          # Behind = angle_diff > 90 degrees (pi/2)
          if angle_diff > :math.pi() / 2, do: 1.5, else: 1.0

        _ ->
          1.0
      end
    else
      1.0
    end
  end

  defp backstab_bonus(_attacker_id, _target_id, _ability), do: 1.0

  defp get_entity_pos(id, :player) do
    case :mnesia.dirty_read(:player_positions, id) do
      [{:player_positions, _, x, y, _, _, _, _, _, _}] -> {x, y}
      _ -> nil
    end
  end

  defp get_npc_pos(npc_id) do
    case :mnesia.dirty_read(:npc_state, npc_id) do
      [{:npc_state, _, _, _, x, y, _, _, _, target_id, _, {sx, sy}}] ->
        # Estimate NPC facing: toward their current target, or toward spawn
        facing =
          case target_id do
            nil ->
              :math.atan2(sy - y, sx - x)

            tid ->
              case :mnesia.dirty_read(:player_positions, tid) do
                [{:player_positions, _, px, py, _, _, _, _, _, _}] ->
                  :math.atan2(py - y, px - x)

                _ ->
                  :math.atan2(sy - y, sx - x)
              end
          end

        {x, y, facing}

      _ ->
        nil
    end
  end

  defp apply_damage(target_id, damage, attacker_id) do
    case :mnesia.dirty_read(:npc_state, target_id) do
      [{:npc_state, nid, tid, iid, x, y, hp, max_hp, ai, _tgt, la, sp}] ->
        new_hp = max(0, hp - damage)
        new_ai = if ai == :idle or ai == :patrol, do: :chase, else: ai

        :mnesia.dirty_write(
          {:npc_state, nid, tid, iid, x, y, new_hp, max_hp, new_ai, attacker_id, la, sp}
        )

        if new_hp == 0 do
          handle_npc_death(target_id, attacker_id)
        end

      _ ->
        :ok
    end
  end

  defp handle_npc_death(npc_id, killer_id) do
    case :mnesia.dirty_read(:npc_state, npc_id) do
      [{:npc_state, _, template_id, instance_id, x, y, _hp, max_hp, _, _, _, _}] ->
        # Update AI state to dead
        :mnesia.dirty_delete(:npc_state, npc_id)

        # Check for split-on-death behavior (slimes)
        SlowArena.GameEngine.AIServer.on_npc_death(template_id, instance_id, x, y, 0, max_hp)

        # Generate and spawn loot
        SlowArena.GameEngine.LootServer.spawn_loot(template_id, instance_id, x, y, killer_id)

        Logger.info("NPC #{npc_id} (#{template_id}) killed by #{killer_id}")

      _ ->
        :ok
    end
  end

  defp process_auto_attacks do
    now = System.monotonic_time(:millisecond)

    :mnesia.dirty_all_keys(:player_auto_attack)
    |> Enum.each(fn char_id ->
      case :mnesia.dirty_read(:player_auto_attack, char_id) do
        [{:player_auto_attack, ^char_id, target_id, last_attack}]
        when target_id != nil and now - last_attack >= @auto_attack_cooldown ->
          if target_alive?(target_id) and in_range?(char_id, target_id) and player_alive?(char_id) do
            damage = calculate_auto_damage(char_id)
            apply_damage(target_id, damage, char_id)
            :mnesia.dirty_write({:player_auto_attack, char_id, target_id, now})
            record_combat_event(:auto_attack, char_id, target_id, damage)
          end

        _ ->
          :ok
      end
    end)
  end

  defp process_effects do
    # TODO: DoT effects, buffs, debuffs
    :ok
  end

  defp process_regen do
    now = System.monotonic_time(:millisecond)

    :mnesia.dirty_all_keys(:player_stats)
    |> Enum.each(fn char_id ->
      case :mnesia.dirty_read(:player_stats, char_id) do
        [{:player_stats, cid, class, level, hp, max_hp, mana, max_mana, str, int, agi, armor}]
        when hp > 0 ->
          # Mana regen: always ticking
          new_mana = min(max_mana, mana + @mana_regen_per_tick)

          # HP regen: only out of combat (no damage received for @hp_regen_ooc_ms)
          new_hp =
            if out_of_combat?(char_id, now) do
              min(max_hp, hp + @hp_regen_per_tick)
            else
              hp
            end

          if new_mana != mana or new_hp != hp do
            :mnesia.dirty_write(
              {:player_stats, cid, class, level, new_hp, max_hp, new_mana, max_mana, str, int,
               agi, armor}
            )
          end

        _ ->
          :ok
      end
    end)
  end

  defp out_of_combat?(character_id, now) do
    case :ets.lookup(:player_last_hit, character_id) do
      [{_, ts}] -> now - ts >= @hp_regen_ooc_ms
      [] ->
        # Fallback: scan recent events (only needed if mark_player_hit wasn't called)
        cutoff = now - @hp_regen_ooc_ms

        :mnesia.dirty_all_keys(:combat_events)
        |> Enum.all?(fn eid ->
          case :mnesia.dirty_read(:combat_events, eid) do
            [{:combat_events, _, _, _, target, _, ts}]
            when target == character_id and ts > cutoff ->
              false

            _ ->
              true
          end
        end)
    end
  end

  defp mark_player_hit(player_id) do
    :ets.insert(:player_last_hit, {player_id, System.monotonic_time(:millisecond)})
  end

  defp process_respawns do
    now = System.monotonic_time(:millisecond)

    :mnesia.dirty_all_keys(:player_stats)
    |> Enum.each(fn char_id ->
      case :mnesia.dirty_read(:player_stats, char_id) do
        [{:player_stats, _, _, _, hp, _, _, _, _, _, _, _}] when hp <= 0 ->
          # Check if enough time has passed since death
          case get_death_time(char_id) do
            nil ->
              # Record death time
              record_combat_event(:player_death, char_id, char_id, 0)

            death_time when now - death_time >= @respawn_delay_ms ->
              respawn_player(char_id)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end)
  end

  defp get_death_time(character_id) do
    # Find the most recent death event for this character
    :mnesia.dirty_all_keys(:combat_events)
    |> Enum.flat_map(fn eid ->
      case :mnesia.dirty_read(:combat_events, eid) do
        [{:combat_events, _, :player_death, ^character_id, ^character_id, _, ts}] ->
          [ts]

        _ ->
          []
      end
    end)
    |> Enum.max(fn -> nil end)
  end

  defp respawn_player(character_id) do
    case :mnesia.dirty_read(:player_stats, character_id) do
      [{:player_stats, cid, class, level, _hp, max_hp, _mana, max_mana, str, int, agi, armor}] ->
        # Restore full HP and mana
        :mnesia.dirty_write(
          {:player_stats, cid, class, level, max_hp, max_hp, max_mana, max_mana, str, int, agi,
           armor}
        )

        # Move to dungeon entrance
        case :mnesia.dirty_read(:player_positions, character_id) do
          [{:player_positions, pid, _x, _y, _f, _vx, _vy, zone, inst, _t}] ->
            :mnesia.dirty_write(
              {:player_positions, pid, @respawn_x, @respawn_y, 0.0, 0.0, 0.0, zone, inst,
               System.monotonic_time(:millisecond)}
            )

          _ ->
            :ok
        end

        record_combat_event(:player_respawn, character_id, character_id, 0)
        Logger.info("Player #{character_id} respawned at (#{@respawn_x}, #{@respawn_y})")

      _ ->
        :ok
    end
  end

  @doc "Apply NPC damage to a player. Called from AIServer."
  def apply_npc_damage(npc_id, target_id, template_id) do
    case :mnesia.dirty_read(:player_stats, target_id) do
      [{:player_stats, cid, class, level, hp, max_hp, mana, max_mana, str, int, agi, armor}]
      when hp > 0 ->
        {min_dmg, max_dmg} = npc_damage_range(template_id)
        raw_damage = min_dmg + :rand.uniform(max(1, max_dmg - min_dmg + 1)) - 1

        # Apply armor reduction: each point of armor reduces damage by 0.5%
        # Capped at 75% reduction
        reduction = min(0.75, armor * 0.005)
        damage = max(1, trunc(raw_damage * (1.0 - reduction)))

        new_hp = max(0, hp - damage)

        :mnesia.dirty_write(
          {:player_stats, cid, class, level, new_hp, max_hp, mana, max_mana, str, int, agi,
           armor}
        )

        # Track last-hit for regen gating
        mark_player_hit(target_id)

        # Record as combat event so it shows as damage floater
        record_combat_event(:npc_attack, npc_id, target_id, damage)

        if new_hp == 0 do
          Logger.info("Player #{target_id} was killed by #{npc_id}!")
          record_combat_event(:player_death, target_id, target_id, 0)
        end

        {:ok, damage}

      _ ->
        :ok
    end
  end

  defp player_alive?(char_id) do
    case :mnesia.dirty_read(:player_stats, char_id) do
      [{:player_stats, _, _, _, hp, _, _, _, _, _, _, _}] when hp > 0 -> true
      _ -> false
    end
  end

  defp target_alive?(target_id) do
    case :mnesia.dirty_read(:npc_state, target_id) do
      [{:npc_state, _, _, _, _, _, hp, _, _, _, _, _}] when hp > 0 -> true
      _ -> false
    end
  end

  defp in_range?(char_id, target_id) do
    with [{:player_positions, _, px, py, _, _, _, _, _, _}] <-
           :mnesia.dirty_read(:player_positions, char_id),
         [{:npc_state, _, _, _, nx, ny, _, _, _, _, _, _}] <-
           :mnesia.dirty_read(:npc_state, target_id) do
      :math.sqrt(:math.pow(px - nx, 2) + :math.pow(py - ny, 2)) <= @auto_attack_range
    else
      _ -> false
    end
  end

  defp calculate_auto_damage(char_id) do
    case :mnesia.dirty_read(:player_stats, char_id) do
      [{:player_stats, _, _, _, _, _, _, _, str, _, _, _}] ->
        # Check for equipped weapon
        weapon_multiplier =
          case :mnesia.dirty_read(:player_equipment, char_id) do
            [{:player_equipment, _, weapon, _, _, _}] when weapon != nil ->
              weapon_damage_multiplier(weapon)

            _ ->
              # Fists: STR * 1.5
              1.5
          end

        base = str * weapon_multiplier
        variance = 0.9 + :rand.uniform() * 0.2
        trunc(base * variance)

      _ ->
        5
    end
  end

  defp weapon_damage_multiplier(weapon) do
    case weapon do
      "rusty_sword" -> 2.0
      "ogre_club" -> 2.5
      "short_sword" -> 1.8
      "great_axe" -> 3.0
      "dagger" -> 1.6
      "staff" -> 1.7
      _ -> 1.5
    end
  end

  # Purge combat events older than 10 seconds to prevent unbounded growth
  defp cleanup_old_events do
    cutoff = System.monotonic_time(:millisecond) - 10_000

    :mnesia.dirty_all_keys(:combat_events)
    |> Enum.each(fn eid ->
      case :mnesia.dirty_read(:combat_events, eid) do
        [{:combat_events, ^eid, _, _, _, _, ts}] when ts < cutoff ->
          :mnesia.dirty_delete(:combat_events, eid)

        _ ->
          :ok
      end
    end)
  end

  defp record_combat_event(type, attacker, target, damage, extra \\ nil) do
    event_id = :erlang.unique_integer([:positive])

    :mnesia.dirty_write(
      {:combat_events, event_id, type, attacker, target, damage,
       System.monotonic_time(:millisecond)}
    )

    # If there's extra data (like AoE radius), we log it for now
    # The broadcast system picks up the base event from combat_events table
    if extra do
      Logger.debug("Combat event extra: #{inspect(extra)}")
    end
  end
end
