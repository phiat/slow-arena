defmodule Mix.Tasks.Game.Status do
  @moduledoc "Show game engine status"
  @shortdoc "Show game engine status"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    tick = SlowArena.GameEngine.GameLoop.get_stats()
    players = length(:mnesia.dirty_all_keys(:player_positions))
    npcs = length(:mnesia.dirty_all_keys(:npc_state))
    loot = length(:mnesia.dirty_all_keys(:loot_piles))
    parties = length(:mnesia.dirty_all_keys(:party_state))
    instances = length(:mnesia.dirty_all_keys(:dungeon_instances))

    IO.puts("""
    === Slow Arena Status ===
    Tick: ##{tick.tick_count} (#{tick.tick_rate}ms rate, #{tick.avg_elapsed_ms}ms avg)
    Players: #{players}
    NPCs: #{npcs}
    Loot piles: #{loot}
    Parties: #{parties}
    Dungeon instances: #{instances}
    """)
  end
end
