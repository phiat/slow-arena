defmodule SlowArena.GameEngineTest do
  use ExUnit.Case, async: false

  @moduletag :game_engine

  setup do
    # Clear all tables before each test
    tables = [
      :player_positions, :player_stats, :player_cooldowns,
      :player_auto_attack, :npc_state, :loot_piles,
      :party_state, :dungeon_instances, :combat_events
    ]
    Enum.each(tables, &:mnesia.clear_table/1)
    :ok
  end

  defp spawn_warrior(name) do
    :mnesia.dirty_write({:player_positions, name, 100.0, 100.0, 0.0, 0.0, 0.0, "lobby", "lobby", System.monotonic_time(:millisecond)})
    :mnesia.dirty_write({:player_stats, name, :warrior, 1, 100, 100, 30, 30, 15, 5, 8, 20})
  end

  describe "Movement" do
    test "set_input updates velocity" do
      spawn_warrior("hero")
      assert :ok = SlowArena.GameEngine.Movement.set_input("hero", %{up: false, down: false, left: false, right: true})

      {:ok, pos} = SlowArena.GameEngine.Movement.get_position("hero")
      assert pos.vx == 1.0
      assert pos.vy == 0.0
    end

    test "update_all moves players with velocity" do
      spawn_warrior("hero")
      SlowArena.GameEngine.Movement.set_input("hero", %{up: false, down: false, left: false, right: true})

      {:ok, before} = SlowArena.GameEngine.Movement.get_position("hero")
      SlowArena.GameEngine.Movement.update_all()
      {:ok, after_move} = SlowArena.GameEngine.Movement.get_position("hero")

      assert after_move.x > before.x
    end

    test "diagonal movement is normalized" do
      spawn_warrior("hero")
      SlowArena.GameEngine.Movement.set_input("hero", %{up: true, down: false, left: false, right: true})

      {:ok, pos} = SlowArena.GameEngine.Movement.get_position("hero")
      magnitude = :math.sqrt(pos.vx * pos.vx + pos.vy * pos.vy)
      assert_in_delta magnitude, 1.0, 0.01
    end
  end

  describe "Combat" do
    test "cast ability deals damage to NPC" do
      spawn_warrior("hero")
      {:ok, npc_id} = SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 120, 100, 500)

      result = SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)
      assert {:ok, %{ability: "slash", targets: targets}} = result
      assert length(targets) > 0

      [{:npc_state, _, _, _, _, _, hp, _, _, _, _, _}] = :mnesia.dirty_read(:npc_state, npc_id)
      assert hp < 500
    end

    test "ability respects cooldown" do
      spawn_warrior("hero")
      SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 120, 100, 500)

      assert {:ok, _} = SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)
      assert {:error, {:on_cooldown, _}} = SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)
    end

    test "ability consumes mana" do
      spawn_warrior("hero")
      SlowArena.GameEngine.AIServer.spawn_npc("goblin", "test_inst", 120, 100, 500)

      [{:player_stats, _, _, _, _, _, mana_before, _, _, _, _, _}] = :mnesia.dirty_read(:player_stats, "hero")
      SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", 120.0, 100.0)
      [{:player_stats, _, _, _, _, _, mana_after, _, _, _, _, _}] = :mnesia.dirty_read(:player_stats, "hero")

      assert mana_after == mana_before - 10
    end
  end

  describe "AI" do
    test "NPC aggros on nearby player" do
      spawn_warrior("hero")
      {:ok, npc_id} = SlowArena.GameEngine.AIServer.spawn_npc("goblin", "lobby", 150, 100, 30)

      SlowArena.GameEngine.AIServer.tick()

      [{:npc_state, _, _, _, _, _, _, _, ai_state, target, _, _}] = :mnesia.dirty_read(:npc_state, npc_id)
      assert ai_state == :chase
      assert target == "hero"
    end

    test "NPC stays idle when no players nearby" do
      {:ok, npc_id} = SlowArena.GameEngine.AIServer.spawn_npc("goblin", "empty", 500, 500, 30)

      SlowArena.GameEngine.AIServer.tick()

      [{:npc_state, _, _, _, _, _, _, _, ai_state, _, _, _}] = :mnesia.dirty_read(:npc_state, npc_id)
      assert ai_state == :idle
    end
  end

  describe "Loot" do
    test "spawns and picks up loot" do
      {:ok, loot_id} = SlowArena.GameEngine.LootServer.spawn_loot("goblin", "test", 100.0, 100.0, "hero")

      assert {:ok, %{items: _, gold: _}} = SlowArena.GameEngine.LootServer.pickup_loot("hero", loot_id)
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
      {:ok, instance_id} = SlowArena.GameEngine.DungeonServer.create_instance("crypt_of_bones", "test_party", :normal)

      {:ok, inst} = SlowArena.GameEngine.DungeonServer.get_instance(instance_id)
      assert inst.template_id == "crypt_of_bones"
      assert inst.difficulty == :normal

      # Should have spawned 6 NPCs
      npc_count = :mnesia.dirty_all_keys(:npc_state) |> length()
      assert npc_count == 6
    end

    test "difficulty scales NPC health" do
      {:ok, _} = SlowArena.GameEngine.DungeonServer.create_instance("crypt_of_bones", "test_party", :nightmare)

      # Boss ogre base HP is 200, nightmare multiplier is 2.5 = 500
      npcs = :mnesia.dirty_all_keys(:npc_state)
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
      {:ok, instance_id} = SlowArena.GameEngine.DungeonServer.create_instance("crypt_of_bones", "test_party", :normal)

      # Find a goblin (30 HP)
      goblin = :mnesia.dirty_all_keys(:npc_state)
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
      :mnesia.dirty_write({:player_positions, "hero", gx, gy, 0.0, 0.0, 0.0, "crypt_of_bones", instance_id, System.monotonic_time(:millisecond)})

      # Cast slash repeatedly until dead
      for _ <- 1..10 do
        SlowArena.GameEngine.CombatServer.cast_ability("hero", "slash", gx, gy)
        # Reset cooldown for test
        :mnesia.dirty_delete(:player_cooldowns, {"hero", "slash"})
        # Restore mana
        case :mnesia.dirty_read(:player_stats, "hero") do
          [{:player_stats, cid, c, l, hp, mhp, _, mm, s, i, a, ar}] ->
            :mnesia.dirty_write({:player_stats, cid, c, l, hp, mhp, mm, mm, s, i, a, ar})
          _ -> :ok
        end
      end

      # Goblin should be dead (removed from table)
      assert :mnesia.dirty_read(:npc_state, goblin) == []

      # Loot should have spawned
      loot_count = :mnesia.dirty_all_keys(:loot_piles) |> length()
      assert loot_count >= 1
    end
  end
end
