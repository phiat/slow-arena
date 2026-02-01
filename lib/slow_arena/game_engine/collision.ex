defmodule SlowArena.GameEngine.Collision do
  @moduledoc "Soft-repulsion collision between all entities (players + NPCs)."

  # Collision radii by NPC template
  @npc_radii %{
    "boss_ogre" => 20.0,
    "necromancer" => 14.0,
    "ghost" => 14.0,
    "skeleton_warrior" => 12.0,
    "slime" => 11.0,
    "goblin" => 10.0,
    "spider" => 8.0
  }
  @default_npc_radius 10.0
  @player_radius 12.0

  # How strongly entities push apart per tick (pixels)
  @repulsion_strength 4.0

  @doc """
  Apply soft repulsion to a proposed position {x, y} for the given entity_id.
  Returns adjusted {x, y} pushed away from any overlapping entities.
  """
  def resolve(entity_id, x, y, radius) do
    others = collect_all_entities(entity_id)

    Enum.reduce(others, {x, y}, fn {_id, ox, oy, or_radius}, {ax, ay} ->
      push_apart(ax, ay, radius, ox, oy, or_radius)
    end)
  end

  @doc "Resolve collision for a player entity."
  def resolve_player(player_id, x, y) do
    resolve(player_id, x, y, @player_radius)
  end

  @doc "Resolve collision for an NPC entity."
  def resolve_npc(npc_id, x, y, template_id) do
    radius = Map.get(@npc_radii, template_id, @default_npc_radius)
    resolve(npc_id, x, y, radius)
  end

  def npc_radius(template_id), do: Map.get(@npc_radii, template_id, @default_npc_radius)
  def player_radius, do: @player_radius

  # Collect all entity positions except the given entity
  defp collect_all_entities(exclude_id) do
    players =
      :mnesia.dirty_all_keys(:player_positions)
      |> Enum.flat_map(fn pid ->
        if pid == exclude_id do
          []
        else
          case :mnesia.dirty_read(:player_positions, pid) do
            [{:player_positions, ^pid, px, py, _, _, _, _, _, _}] ->
              [{pid, px, py, @player_radius}]
            _ -> []
          end
        end
      end)

    npcs =
      :mnesia.dirty_all_keys(:npc_state)
      |> Enum.flat_map(fn nid ->
        if nid == exclude_id do
          []
        else
          case :mnesia.dirty_read(:npc_state, nid) do
            [{:npc_state, ^nid, tid, _, nx, ny, hp, _, _, _, _, _}] when hp > 0 ->
              [{nid, nx, ny, Map.get(@npc_radii, tid, @default_npc_radius)}]
            _ -> []
          end
        end
      end)

    players ++ npcs
  end

  # Push {ax, ay} away from {bx, by} if their radii overlap
  defp push_apart(ax, ay, ar, bx, by, br) do
    dx = ax - bx
    dy = ay - by
    dist = :math.sqrt(dx * dx + dy * dy)
    min_dist = ar + br

    if dist < min_dist and dist > 0.001 do
      # Overlap amount determines push strength
      overlap = min_dist - dist
      push = min(overlap, @repulsion_strength)
      nx = dx / dist
      ny = dy / dist
      {ax + nx * push, ay + ny * push}
    else
      {ax, ay}
    end
  end
end
