defmodule SlowArena.GameEngine.MnesiaSetup do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    setup_mnesia()
    {:ok, %{}}
  end

  defp setup_mnesia do
    # Stop mnesia if running, create schema, start
    :mnesia.stop()
    :mnesia.create_schema([node()])
    :mnesia.start()

    tables = [
      {:player_positions,
       [:character_id, :x, :y, :facing, :vx, :vy, :zone_id, :instance_id, :updated_at]},
      {:player_stats,
       [
         :character_id,
         :class,
         :level,
         :health,
         :max_health,
         :mana,
         :max_mana,
         :strength,
         :intelligence,
         :agility,
         :armor
       ]},
      {:player_cooldowns, [:key, :expires_at, :cooldown_ms]},
      {:player_auto_attack, [:character_id, :target_id, :last_attack_time]},
      {:npc_state,
       [
         :npc_id,
         :template_id,
         :instance_id,
         :x,
         :y,
         :health,
         :max_health,
         :ai_state,
         :target_id,
         :last_attack,
         :spawn_point
       ]},
      {:loot_piles,
       [:loot_id, :instance_id, :x, :y, :items, :gold, :spawned_at, :expires_at, :reserved_by]},
      {:party_state,
       [:party_id, :leader_id, :members, :max_size, :loot_mode, :instance_id, :created_at]},
      {:dungeon_instances,
       [
         :instance_id,
         :template_id,
         :party_id,
         :members,
         :created_at,
         :difficulty,
         :status,
         :boss_defeated,
         :loot_spawned
       ]},
      {:combat_events, [:event_id, :type, :attacker_id, :target_id, :damage, :timestamp]}
    ]

    Enum.each(tables, fn {name, attributes} ->
      case :mnesia.create_table(name, attributes: attributes, ram_copies: [node()]) do
        {:atomic, :ok} -> Logger.info("Created Mnesia table: #{name}")
        {:aborted, {:already_exists, _}} -> Logger.debug("Mnesia table already exists: #{name}")
      end
    end)

    # Wait for tables
    :mnesia.wait_for_tables(Enum.map(tables, &elem(&1, 0)), 5000)
    Logger.info("Mnesia setup complete - #{length(tables)} tables ready")
  end
end
