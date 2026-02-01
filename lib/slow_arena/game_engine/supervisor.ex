defmodule SlowArena.GameEngine.Supervisor do
  @moduledoc "Supervision tree for all game engine GenServers."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      SlowArena.GameEngine.MnesiaSetup,
      SlowArena.GameEngine.GameLoop,
      SlowArena.GameEngine.CombatServer,
      SlowArena.GameEngine.AIServer,
      SlowArena.GameEngine.LootServer,
      SlowArena.GameEngine.PartyServer,
      SlowArena.GameEngine.DungeonServer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
