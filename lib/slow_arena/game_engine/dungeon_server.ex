defmodule SlowArena.GameEngine.DungeonServer do
  use GenServer
  require Logger

  @dungeon_templates %{
    "crypt_of_bones" => %{
      name: "Crypt of Bones",
      width: 800,
      height: 600,
      npc_spawns: [
        %{template_id: "skeleton_warrior", x: 200, y: 150, base_health: 50},
        %{template_id: "skeleton_warrior", x: 400, y: 300, base_health: 50},
        %{template_id: "skeleton_warrior", x: 600, y: 200, base_health: 50},
        %{template_id: "goblin", x: 300, y: 400, base_health: 30},
        %{template_id: "goblin", x: 500, y: 450, base_health: 30},
        %{template_id: "boss_ogre", x: 700, y: 500, base_health: 200}
      ]
    }
  }

  @difficulty_multipliers %{normal: 1.0, hard: 1.5, nightmare: 2.5}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_), do: {:ok, %{}}

  def create_instance(template_id, party_id, difficulty \\ :normal) do
    template = Map.get(@dungeon_templates, template_id)

    if template do
      instance_id = "inst_#{:erlang.unique_integer([:positive])}"
      members = get_party_members(party_id)
      mult = Map.get(@difficulty_multipliers, difficulty, 1.0)

      # Write instance record
      :mnesia.dirty_write(
        {:dungeon_instances, instance_id, template_id, party_id, members,
         System.monotonic_time(:millisecond), difficulty, :active, false, []}
      )

      # Spawn NPCs
      Enum.each(template.npc_spawns, fn spawn_def ->
        hp = trunc(spawn_def.base_health * mult)

        SlowArena.GameEngine.AIServer.spawn_npc(
          spawn_def.template_id,
          instance_id,
          spawn_def.x,
          spawn_def.y,
          hp
        )
      end)

      # Place players at entrance
      Enum.each(members, fn char_id ->
        case :mnesia.dirty_read(:player_positions, char_id) do
          [{:player_positions, ^char_id, _, _, facing, vx, vy, _, _, _}] ->
            :mnesia.dirty_write(
              {:player_positions, char_id, 50.0, 300.0, facing, vx, vy, template_id, instance_id,
               System.monotonic_time(:millisecond)}
            )

          _ ->
            :ok
        end
      end)

      Logger.info(
        "Dungeon instance #{instance_id} (#{template.name}, #{difficulty}) created with #{length(template.npc_spawns)} NPCs"
      )

      {:ok, instance_id}
    else
      {:error, :unknown_template}
    end
  end

  def get_instance(instance_id) do
    case :mnesia.dirty_read(:dungeon_instances, instance_id) do
      [{:dungeon_instances, ^instance_id, tid, pid, members, created, diff, status, boss, loot}] ->
        {:ok,
         %{
           instance_id: instance_id,
           template_id: tid,
           party_id: pid,
           members: members,
           created_at: created,
           difficulty: diff,
           status: status,
           boss_defeated: boss,
           loot_spawned: loot
         }}

      [] ->
        {:error, :not_found}
    end
  end

  def list_instances do
    :mnesia.dirty_all_keys(:dungeon_instances)
    |> Enum.flat_map(fn iid ->
      case get_instance(iid) do
        {:ok, inst} -> [inst]
        _ -> []
      end
    end)
  end

  def cleanup_instance(instance_id) do
    # Delete NPCs in this instance
    :mnesia.dirty_all_keys(:npc_state)
    |> Enum.each(fn npc_id ->
      case :mnesia.dirty_read(:npc_state, npc_id) do
        [{:npc_state, ^npc_id, _, ^instance_id, _, _, _, _, _, _, _, _}] ->
          :mnesia.dirty_delete(:npc_state, npc_id)

        _ ->
          :ok
      end
    end)

    # Delete loot
    :mnesia.dirty_all_keys(:loot_piles)
    |> Enum.each(fn lid ->
      case :mnesia.dirty_read(:loot_piles, lid) do
        [{:loot_piles, ^lid, ^instance_id, _, _, _, _, _, _, _}] ->
          :mnesia.dirty_delete(:loot_piles, lid)

        _ ->
          :ok
      end
    end)

    # Delete instance
    :mnesia.dirty_delete(:dungeon_instances, instance_id)
    Logger.info("Instance #{instance_id} cleaned up")
    :ok
  end

  def list_templates do
    Enum.map(@dungeon_templates, fn {id, t} ->
      %{id: id, name: t.name, npc_count: length(t.npc_spawns)}
    end)
  end

  defp get_party_members(party_id) do
    case :mnesia.dirty_read(:party_state, party_id) do
      [{:party_state, _, _, members, _, _, _, _}] -> members
      [] -> []
    end
  end
end
