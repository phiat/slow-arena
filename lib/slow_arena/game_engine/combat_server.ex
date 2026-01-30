defmodule SlowArena.GameEngine.CombatServer do
  use GenServer
  require Logger

  # 1 second
  @auto_attack_cooldown 1000
  @auto_attack_range 50.0

  # Ability definitions
  @abilities %{
    "slash" => %{
      cooldown: 2000,
      mana: 10,
      damage: 25,
      scaling: :strength,
      factor: 1.5,
      range: 60.0,
      type: :instant
    },
    "shield_bash" => %{
      cooldown: 5000,
      mana: 15,
      damage: 15,
      scaling: :strength,
      factor: 1.0,
      range: 50.0,
      type: :instant,
      stun: 1500
    },
    "fireball" => %{
      cooldown: 3000,
      mana: 20,
      damage: 40,
      scaling: :intelligence,
      factor: 2.0,
      range: 200.0,
      type: :projectile
    },
    "ice_lance" => %{
      cooldown: 2000,
      mana: 15,
      damage: 30,
      scaling: :intelligence,
      factor: 1.5,
      range: 180.0,
      type: :projectile
    },
    "arrow_volley" => %{
      cooldown: 4000,
      mana: 20,
      damage: 35,
      scaling: :agility,
      factor: 1.8,
      range: 250.0,
      type: :aoe,
      radius: 80.0
    },
    "backstab" => %{
      cooldown: 3000,
      mana: 15,
      damage: 50,
      scaling: :agility,
      factor: 2.5,
      range: 40.0,
      type: :instant
    }
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_), do: {:ok, %{}}

  # Called each game tick
  def tick do
    process_auto_attacks()
    process_effects()
  end

  def cast_ability(character_id, ability_id, target_x, target_y) do
    GenServer.call(__MODULE__, {:cast_ability, character_id, ability_id, target_x, target_y})
  end

  def set_auto_attack_target(character_id, target_id) do
    :mnesia.dirty_write({:player_auto_attack, character_id, target_id, 0})
    :ok
  end

  def get_abilities, do: @abilities

  def handle_call({:cast_ability, character_id, ability_id, target_x, target_y}, _from, state) do
    result = do_cast_ability(character_id, ability_id, target_x, target_y)
    {:reply, result, state}
  end

  defp do_cast_ability(character_id, ability_id, target_x, target_y) do
    ability = Map.get(@abilities, ability_id)

    with {:ok, ability} <- validate_ability(ability, ability_id),
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
        record_combat_event(:ability, character_id, target_id, damage)
      end)

      {:ok, %{ability: ability_id, targets: damages}}
    end
  end

  defp validate_ability(nil, id), do: {:error, {:unknown_ability, id}}
  defp validate_ability(ability, _id), do: {:ok, ability}

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

  defp calculate_damage(attacker_id, _target_id, ability) do
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
        trunc(base * variance * crit)

      _ ->
        ability.damage
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
      [{:npc_state, _, template_id, instance_id, x, y, _, _, _, _, _, _}] ->
        # Update AI state to dead
        :mnesia.dirty_delete(:npc_state, npc_id)

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
          if target_alive?(target_id) and in_range?(char_id, target_id) do
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
        base = str * 2
        variance = 0.9 + :rand.uniform() * 0.2
        trunc(base * variance)

      _ ->
        5
    end
  end

  defp record_combat_event(type, attacker, target, damage) do
    event_id = :erlang.unique_integer([:positive])

    :mnesia.dirty_write(
      {:combat_events, event_id, type, attacker, target, damage,
       System.monotonic_time(:millisecond)}
    )
  end
end
