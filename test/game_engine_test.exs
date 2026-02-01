defmodule SlowArena.GameEngineTest do
  use ExUnit.Case, async: false

  @moduletag :game_engine

  setup do
    # Clear all tables before each test
    tables = [
      :player_positions,
      :player_stats,
      :player_cooldowns,
      :player_auto_attack,
      :player_equipment,
      :npc_state,
      :loot_piles,
      :party_state,
      :dungeon_instances,
      :combat_events
    ]

    Enum.each(tables, &:mnesia.clear_table/1)
    :ok
  end

  defp spawn_warrior(name) do
    :mnesia.dirty_write(
      {:player_positions, name, 100.0, 100.0, 0.0, 0.0, 0.0, "lobby", "lobby",
       System.monotonic_time(:millisecond)}
    )

    :mnesia.dirty_write({:player_stats, name, :warrior, 1, 100, 100, 30, 30, 15, 5, 8, 20})
  end

  describe "Movement" do
    test "set_input updates velocity" do
      spawn_warrior("hero")

      assert :ok =
               SlowArena.GameEngine.Movement.set_input("hero", %{
                 up: false,
                 down: false,
                 left: false,
                 right: true
               })

      {:ok, pos} = SlowArena.GameEngine.Movement.get_position("hero")
      assert pos.vx == 1.0
      assert pos.vy == 0.0
    end

    test "update_all moves players with velocity" do
      spawn_warrior("hero")

      SlowArena.GameEngine.Movement.set_input("hero", %{
        up: false,
        down: false,
        left: false,
        right: true
      })

      {:ok, before} = SlowArena.GameEngine.Movement.get_position("hero")
      SlowArena.GameEngine.Movement.update_all()
      {:ok, after_move} = SlowArena.GameEngine.Movement.get_position("hero")

      assert after_move.x > before.x
    end

    test "diagonal movement is normalized" do
      spawn_warrior("hero")

      SlowArena.GameEngine.Movement.set_input("hero", %{
        up: true,
        down: false,
        left: false,
        right: true
      })

      {:ok, pos} = SlowArena.GameEngine.Movement.get_position("hero")
      magnitude = :math.sqrt(pos.vx * pos.vx + pos.vy * pos.vy)
      assert_in_delta magnitude, 1.0, 0.01
    end
  end

  describe "Combat" do
    test "cast ability deals damage to NPC" do
      spawn_warrior("hero")

      {:ok, npc_id} =
        SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 120, 100, 500)

      result = SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)
      assert {:ok, %{ability: "slash", targets: targets}} = result
      assert targets != []

      [{:npc_state, _, _, _, _, _, hp, _, _, _, _, _}] = :mnesia.dirty_read(:npc_state, npc_id)
      assert hp < 500
    end

    test "ability respects cooldown" do
      spawn_warrior("hero")
      SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 120, 100, 500)

      assert {:ok, _} =
               SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)

      assert {:error, {:on_cooldown, _}} =
               SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)
    end

    test "ability consumes mana" do
      spawn_warrior("hero")
      SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 120, 100, 500)

      [{:player_stats, _, _, _, _, _, mana_before, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)

      [{:player_stats, _, _, _, _, _, mana_after, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      assert mana_after == mana_before - 10
    end
  end

  describe "AI" do
    test "NPC aggros on nearby player" do
      spawn_warrior("hero")
      {:ok, npc_id} = SlowArena.GameEngine.AIServer.spawn_npc("goblin", "lobby", 150, 100, 30)

      SlowArena.GameEngine.AIServer.tick()

      [{:npc_state, _, _, _, _, _, _, _, ai_state, target, _, _}] =
        :mnesia.dirty_read(:npc_state, npc_id)

      assert ai_state == :chase
      assert target == "hero"
    end

    test "NPC stays idle when no players nearby" do
      {:ok, npc_id} = SlowArena.GameEngine.AIServer.spawn_npc("goblin", "empty", 500, 500, 30)

      SlowArena.GameEngine.AIServer.tick()

      [{:npc_state, _, _, _, _, _, _, _, ai_state, _, _, _}] =
        :mnesia.dirty_read(:npc_state, npc_id)

      assert ai_state == :idle
    end
  end

  describe "Loot" do
    test "spawns and picks up loot" do
      # Use boss_ogre which has 100% gold chance to avoid flaky random misses
      {:ok, loot_id} =
        SlowArena.GameEngine.LootServer.spawn_loot("boss_ogre", "test", 100.0, 100.0, "hero")

      assert {:ok, %{items: _, gold: _}} =
               SlowArena.GameEngine.LootServer.pickup_loot("hero", loot_id)

      assert {:error, :not_found} = SlowArena.GameEngine.LootServer.pickup_loot("hero", loot_id)
    end
  end

  describe "Party" do
    test "create and join party" do
      {:ok, party_id} = SlowArena.GameEngine.PartyServer.create_party("leader")
      {:ok, _} = SlowArena.GameEngine.PartyServer.join_party(party_id, "member1")

      {:ok, party} = SlowArena.GameEngine.PartyServer.get_party(party_id)
      assert party.leader == "leader"
      assert "member1" in party.members
      assert length(party.members) == 2
    end

    test "leave party promotes new leader" do
      {:ok, party_id} = SlowArena.GameEngine.PartyServer.create_party("leader")
      SlowArena.GameEngine.PartyServer.join_party(party_id, "member1")
      SlowArena.GameEngine.PartyServer.leave_party(party_id, "leader")

      {:ok, party} = SlowArena.GameEngine.PartyServer.get_party(party_id)
      assert party.leader == "member1"
    end
  end

  describe "Dungeon" do
    test "creates instance with NPCs" do
      {:ok, instance_id} =
        SlowArena.GameEngine.DungeonServer.create_instance(
          "crypt_of_bones",
          "test_party",
          :normal
        )

      {:ok, inst} = SlowArena.GameEngine.DungeonServer.get_instance(instance_id)
      assert inst.template_id == "crypt_of_bones"
      assert inst.difficulty == :normal

      # Should have spawned 6 NPCs
      npc_count = :mnesia.dirty_all_keys(:npc_state) |> length()
      assert npc_count == 6
    end

    test "difficulty scales NPC health" do
      {:ok, _} =
        SlowArena.GameEngine.DungeonServer.create_instance(
          "crypt_of_bones",
          "test_party",
          :nightmare
        )

      # Boss ogre base HP is 200, nightmare multiplier is 2.5 = 500
      npcs =
        :mnesia.dirty_all_keys(:npc_state)
        |> Enum.flat_map(fn npc_id ->
          case :mnesia.dirty_read(:npc_state, npc_id) do
            [{:npc_state, _, "boss_ogre", _, _, _, hp, _, _, _, _, _}] -> [hp]
            _ -> []
          end
        end)

      assert hd(npcs) == 500
    end
  end

  describe "Full combat loop" do
    test "spawn dungeon, fight NPC, collect loot" do
      spawn_warrior("hero")

      # Create dungeon
      {:ok, instance_id} =
        SlowArena.GameEngine.DungeonServer.create_instance(
          "crypt_of_bones",
          "test_party",
          :normal
        )

      # Find a goblin (30 HP)
      goblin =
        :mnesia.dirty_all_keys(:npc_state)
        |> Enum.find(fn npc_id ->
          case :mnesia.dirty_read(:npc_state, npc_id) do
            [{:npc_state, _, "goblin", ^instance_id, _, _, _, _, _, _, _, _}] -> true
            _ -> false
          end
        end)

      assert goblin != nil

      # Get goblin position
      [{:npc_state, _, _, _, gx, gy, _, _, _, _, _, _}] = :mnesia.dirty_read(:npc_state, goblin)

      # Move hero to goblin position
      :mnesia.dirty_write(
        {:player_positions, "hero", gx, gy, 0.0, 0.0, 0.0, "crypt_of_bones", instance_id,
         System.monotonic_time(:millisecond)}
      )

      # Cast slash repeatedly until dead
      for _ <- 1..10 do
        SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", gx, gy)
        # Reset cooldown for test
        :mnesia.dirty_delete(:player_cooldowns, {"hero", "slash"})
        # Restore mana
        case :mnesia.dirty_read(:player_stats, "hero") do
          [{:player_stats, cid, c, l, hp, mhp, _, mm, s, i, a, ar}] ->
            :mnesia.dirty_write({:player_stats, cid, c, l, hp, mhp, mm, mm, s, i, a, ar})

          _ ->
            :ok
        end
      end

      # Goblin should be dead (removed from table)
      assert :mnesia.dirty_read(:npc_state, goblin) == []

      # Loot should have spawned
      loot_count = :mnesia.dirty_all_keys(:loot_piles) |> length()
      assert loot_count >= 1
    end
  end

  describe "Mana regeneration" do
    test "mana regens each tick" do
      spawn_warrior("hero")

      # Drain some mana
      :mnesia.dirty_write({:player_stats, "hero", :warrior, 1, 100, 100, 20, 30, 15, 5, 8, 20})

      [{:player_stats, _, _, _, _, _, mana_before, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      assert mana_before == 20

      # Run several ticks (10 ticks = 1 second = 1 mana)
      for _ <- 1..10 do
        SlowArena.GameEngine.CombatServer.tick()
      end

      [{:player_stats, _, _, _, _, _, mana_after, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      # Should have gained ~1.0 mana (10 ticks * 0.1 per tick)
      assert mana_after > mana_before
      assert_in_delta mana_after, 21.0, 0.5
    end

    test "mana does not exceed max" do
      spawn_warrior("hero")

      # Already at max mana (30/30)
      for _ <- 1..20 do
        SlowArena.GameEngine.CombatServer.tick()
      end

      [{:player_stats, _, _, _, _, _, mana, max_mana, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      assert mana <= max_mana
    end
  end

  describe "HP regeneration" do
    test "HP regens when out of combat" do
      spawn_warrior("regen_hero")

      # Reduce HP
      :mnesia.dirty_write({:player_stats, "regen_hero", :warrior, 1, 90, 100, 30, 30, 15, 5, 8, 20})

      # No combat events for this player, so they are "out of combat"
      for _ <- 1..20 do
        SlowArena.GameEngine.CombatServer.tick()
      end

      [{:player_stats, _, _, _, hp, _, _, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "regen_hero")

      # Should have regenerated some HP (20 ticks * 0.05 = 1.0 HP)
      assert hp > 90
    end

    test "HP does not regen when recently hit" do
      spawn_warrior("hero")

      # Reduce HP and add a recent combat event targeting this player
      :mnesia.dirty_write({:player_stats, "hero", :warrior, 1, 90, 100, 30, 30, 15, 5, 8, 20})

      event_id = :erlang.unique_integer([:positive])

      :mnesia.dirty_write(
        {:combat_events, event_id, :npc_attack, "some_npc", "hero", 10,
         System.monotonic_time(:millisecond)}
      )

      # Tick a few times
      for _ <- 1..5 do
        SlowArena.GameEngine.CombatServer.tick()
      end

      [{:player_stats, _, _, _, hp, _, _, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      # HP should not have increased (still in combat)
      assert hp == 90
    end
  end

  describe "NPC damage scaling" do
    test "goblin damage is in expected range" do
      {min_dmg, max_dmg} = SlowArena.GameEngine.CombatServer.npc_damage_range("goblin")
      assert min_dmg == 8
      assert max_dmg == 12
    end

    test "boss_ogre damage is in expected range" do
      {min_dmg, max_dmg} = SlowArena.GameEngine.CombatServer.npc_damage_range("boss_ogre")
      assert min_dmg == 25
      assert max_dmg == 40
    end

    test "NPC attack deals scaled damage to player" do
      spawn_warrior("hero")

      {:ok, npc_id} =
        SlowArena.GameEngine.AIServer.spawn_npc("boss_ogre", "test_inst", 100, 100, 200)

      SlowArena.GameEngine.CombatServer.apply_npc_damage(npc_id, "hero", "boss_ogre")

      [{:player_stats, _, _, _, hp, _, _, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      # Boss ogre does 25-40 raw, warrior has 20 armor (10% reduction), so ~22-36 damage
      assert hp < 100
      assert hp >= 60
    end

    test "NPC attack creates combat event" do
      spawn_warrior("hero")

      {:ok, npc_id} =
        SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 100, 100, 30)

      SlowArena.GameEngine.CombatServer.apply_npc_damage(npc_id, "hero", "goblin")

      # Should have a combat event for the NPC attack
      events =
        :mnesia.dirty_all_keys(:combat_events)
        |> Enum.flat_map(fn eid ->
          case :mnesia.dirty_read(:combat_events, eid) do
            [{:combat_events, _, :npc_attack, ^npc_id, "hero", damage, _}] -> [damage]
            _ -> []
          end
        end)

      assert length(events) == 1
      assert hd(events) > 0
    end
  end

  describe "Armor reduction" do
    test "armor reduces NPC damage" do
      # Spawn a high-armor player
      :mnesia.dirty_write(
        {:player_positions, "tank", 100.0, 100.0, 0.0, 0.0, 0.0, "lobby", "lobby",
         System.monotonic_time(:millisecond)}
      )

      # 100 armor = 50% reduction
      :mnesia.dirty_write(
        {:player_stats, "tank", :warrior, 1, 100, 100, 30, 30, 15, 5, 8, 100}
      )

      {:ok, npc_id} =
        SlowArena.GameEngine.AIServer.spawn_npc("boss_ogre", "test_inst", 100, 100, 200)

      # Apply damage multiple times and average
      damages =
        for _ <- 1..20 do
          # Reset HP each time
          :mnesia.dirty_write(
            {:player_stats, "tank", :warrior, 1, 100, 100, 30, 30, 15, 5, 8, 100}
          )

          {:ok, dmg} =
            SlowArena.GameEngine.CombatServer.apply_npc_damage(npc_id, "tank", "boss_ogre")

          dmg
        end

      avg_damage = Enum.sum(damages) / length(damages)

      # Boss ogre raw: 25-40, 50% reduction = 12-20 expected
      assert avg_damage >= 10
      assert avg_damage <= 22
    end
  end

  describe "Player death and respawn" do
    test "dead player cannot cast abilities" do
      spawn_warrior("hero")
      SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 120, 100, 500)

      # Kill the player
      :mnesia.dirty_write({:player_stats, "hero", :warrior, 1, 0, 100, 30, 30, 15, 5, 8, 20})

      result =
        SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)

      assert {:error, :dead} = result
    end

    test "player respawns after death with full HP/mana" do
      spawn_warrior("hero")

      # Kill the player
      :mnesia.dirty_write({:player_stats, "hero", :warrior, 1, 0, 100, 0, 30, 15, 5, 8, 20})

      # Record death event in the past (beyond respawn delay)
      death_time = System.monotonic_time(:millisecond) - 6000
      event_id = :erlang.unique_integer([:positive])

      :mnesia.dirty_write(
        {:combat_events, event_id, :player_death, "hero", "hero", 0, death_time}
      )

      # Tick should trigger respawn
      SlowArena.GameEngine.CombatServer.tick()

      [{:player_stats, _, _, _, hp, max_hp, mana, max_mana, _, _, _, _}] =
        :mnesia.dirty_read(:player_stats, "hero")

      assert hp == max_hp
      assert mana == max_mana

      # Should be at respawn position
      [{:player_positions, _, x, y, _, _, _, _, _, _}] =
        :mnesia.dirty_read(:player_positions, "hero")

      assert_in_delta x, 50.0, 0.1
      assert_in_delta y, 300.0, 0.1
    end

    test "player death broadcasts as combat event" do
      spawn_warrior("hero")

      {:ok, npc_id} =
        SlowArena.GameEngine.AIServer.spawn_npc("boss_ogre", "test_inst", 100, 100, 200)

      # Set HP to 1 so next hit kills
      :mnesia.dirty_write({:player_stats, "hero", :warrior, 1, 1, 100, 30, 30, 15, 5, 8, 20})

      SlowArena.GameEngine.CombatServer.apply_npc_damage(npc_id, "hero", "boss_ogre")

      # Should have death event
      death_events =
        :mnesia.dirty_all_keys(:combat_events)
        |> Enum.flat_map(fn eid ->
          case :mnesia.dirty_read(:combat_events, eid) do
            [{:combat_events, _, :player_death, "hero", "hero", _, _}] -> [:found]
            _ -> []
          end
        end)

      assert death_events != []
    end
  end
end
