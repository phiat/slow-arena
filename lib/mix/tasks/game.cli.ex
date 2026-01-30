defmodule Mix.Tasks.Game.Cli do
  @moduledoc "Interactive game engine CLI"
  @shortdoc "Open game CLI"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    IO.puts("\n=== Slow Arena Game CLI ===")
    IO.puts("Type 'help' for commands\n")
    loop()
  end

  defp loop do
    case IO.gets("arena> ") do
      :eof ->
        IO.puts("Goodbye!")

      input ->
        case parse_command(String.trim(input)) do
          :quit -> IO.puts("Goodbye!")
          :continue -> loop()
        end
    end
  end

  defp parse_command(""), do: :continue
  defp parse_command("quit"), do: :quit
  defp parse_command("exit"), do: :quit

  defp parse_command("help") do
    IO.puts("""

    === Commands ===

    Player:
      spawn <name> <class>     - Spawn a player (warrior/mage/ranger/rogue)
      move <name> <dir>        - Move player (up/down/left/right/stop)
      pos <name>               - Show player position
      stats <name>             - Show player stats
      attack <name> <target>   - Auto-attack target NPC
      cast <name> <ability> <x> <y> - Cast ability at position

    World:
      dungeon <template> [difficulty] - Create dungeon instance (default: normal)
      npcs [instance]          - List NPCs
      loot [instance]          - List loot piles
      pickup <name> <loot_id>  - Pick up loot

    Party:
      party.create <name>      - Create party
      party.join <party_id> <name> - Join party
      party.list               - List parties

    System:
      status                   - Game engine status
      tick                     - Show tick stats
      tables                   - Show Mnesia table info
      reset                    - Clear all game state

    Diagrams:
      diagram                  - Show available diagrams
      diagram <name>           - Render diagram (arch, loop, ai, combat, data)

    help                       - Show this help
    quit                       - Exit CLI
    """)

    :continue
  end

  # === Player Commands ===

  defp parse_command("spawn " <> args) do
    case String.split(args) do
      [name, class] when class in ["warrior", "mage", "ranger", "rogue"] ->
        spawn_player(name, String.to_atom(class))

      [name] ->
        spawn_player(name, :warrior)

      _ ->
        IO.puts("Usage: spawn <name> <class>")
    end

    :continue
  end

  defp parse_command("move " <> args) do
    case String.split(args) do
      [name, dir] ->
        input =
          case dir do
            "up" -> %{up: true, down: false, left: false, right: false}
            "down" -> %{up: false, down: true, left: false, right: false}
            "left" -> %{up: false, down: false, left: true, right: false}
            "right" -> %{up: false, down: false, left: false, right: true}
            "stop" -> %{up: false, down: false, left: false, right: false}
            _ -> nil
          end

        if input do
          case SlowArena.GameEngine.Movement.set_input(name, input) do
            :ok -> IO.puts("#{name} moving #{dir}")
            {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
          end
        else
          IO.puts("Directions: up, down, left, right, stop")
        end

      _ ->
        IO.puts("Usage: move <name> <direction>")
    end

    :continue
  end

  defp parse_command("pos " <> name) do
    name = String.trim(name)

    case SlowArena.GameEngine.Movement.get_position(name) do
      {:ok, pos} ->
        IO.puts(
          "#{name}: x=#{Float.round(pos.x, 1)} y=#{Float.round(pos.y, 1)} facing=#{Float.round(pos.facing, 2)} vx=#{pos.vx} vy=#{pos.vy}"
        )

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end

    :continue
  end

  defp parse_command("stats " <> name) do
    name = String.trim(name)

    case :mnesia.dirty_read(:player_stats, name) do
      [{:player_stats, _, class, level, hp, max_hp, mana, max_mana, str, int, agi, armor}] ->
        IO.puts("""
        #{name} [#{class}] Lv.#{level}
          HP: #{hp}/#{max_hp}  Mana: #{mana}/#{max_mana}
          STR: #{str}  INT: #{int}  AGI: #{agi}  Armor: #{armor}
        """)

      [] ->
        IO.puts("Player not found: #{name}")
    end

    :continue
  end

  defp parse_command("attack " <> args) do
    case String.split(args) do
      [name, target] ->
        SlowArena.GameEngine.CombatServer.set_auto_attack_target(name, target)
        IO.puts("#{name} auto-attacking #{target}")

      _ ->
        IO.puts("Usage: attack <name> <target_npc_id>")
    end

    :continue
  end

  defp parse_command("cast " <> args) do
    case String.split(args) do
      [name, ability, x_str, y_str] ->
        {x, _} = Float.parse(x_str)
        {y, _} = Float.parse(y_str)

        case SlowArena.GameEngine.CombatServer.cast_ability(name, ability, x, y) do
          {:ok, result} -> IO.puts("Cast #{ability}: #{inspect(result)}")
          {:error, reason} -> IO.puts("Failed: #{inspect(reason)}")
        end

      _ ->
        IO.puts("Usage: cast <name> <ability> <x> <y>")
    end

    :continue
  end

  # === World Commands ===

  defp parse_command("dungeon " <> args) do
    case String.split(args) do
      [template] ->
        create_dungeon(template, :normal)

      [template, difficulty] ->
        create_dungeon(template, String.to_atom(difficulty))

      _ ->
        IO.puts("Usage: dungeon <template> [difficulty]")
        IO.puts("Templates: #{inspect(SlowArena.GameEngine.DungeonServer.list_templates())}")
    end

    :continue
  end

  defp parse_command("npcs" <> _args) do
    npcs =
      :mnesia.dirty_all_keys(:npc_state)
      |> Enum.flat_map(fn npc_id ->
        case :mnesia.dirty_read(:npc_state, npc_id) do
          [{:npc_state, id, template, instance, x, y, hp, max_hp, ai, target, _, _}] ->
            [
              %{
                id: id,
                template: template,
                instance: instance,
                x: Float.round(x, 1),
                y: Float.round(y, 1),
                hp: hp,
                max_hp: max_hp,
                ai: ai,
                target: target
              }
            ]

          _ ->
            []
        end
      end)

    if npcs == [] do
      IO.puts("No NPCs alive")
    else
      IO.puts("\n  NPCs (#{length(npcs)}):")

      Enum.each(npcs, fn npc ->
        IO.puts(
          "    #{npc.id} [#{npc.template}] HP:#{npc.hp}/#{npc.max_hp} AI:#{npc.ai} @ (#{npc.x}, #{npc.y}) inst:#{npc.instance}"
        )
      end)

      IO.puts("")
    end

    :continue
  end

  defp parse_command("loot" <> _args) do
    loot =
      :mnesia.dirty_all_keys(:loot_piles)
      |> Enum.flat_map(fn lid ->
        case :mnesia.dirty_read(:loot_piles, lid) do
          [{:loot_piles, id, instance, x, y, items, gold, _, _, _}] ->
            [
              %{
                id: id,
                instance: instance,
                x: Float.round(x, 1),
                y: Float.round(y, 1),
                items: items,
                gold: gold
              }
            ]

          _ ->
            []
        end
      end)

    if loot == [] do
      IO.puts("No loot piles")
    else
      IO.puts("\n  Loot piles (#{length(loot)}):")

      Enum.each(loot, fn l ->
        items_str =
          Enum.map(l.items, fn i -> "#{i.item_id}x#{i.quantity}" end) |> Enum.join(", ")

        IO.puts("    #{l.id} @ (#{l.x}, #{l.y}) - #{items_str} #{l.gold}g")
      end)

      IO.puts("")
    end

    :continue
  end

  defp parse_command("pickup " <> args) do
    case String.split(args) do
      [name, loot_id] ->
        case SlowArena.GameEngine.LootServer.pickup_loot(name, loot_id) do
          {:ok, loot} -> IO.puts("#{name} picked up: #{inspect(loot)}")
          {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
        end

      _ ->
        IO.puts("Usage: pickup <name> <loot_id>")
    end

    :continue
  end

  # === Party Commands ===

  defp parse_command("party.create " <> name) do
    case SlowArena.GameEngine.PartyServer.create_party(String.trim(name)) do
      {:ok, party_id} -> IO.puts("Party created: #{party_id}")
    end

    :continue
  end

  defp parse_command("party.join " <> args) do
    case String.split(args) do
      [party_id, name] ->
        case SlowArena.GameEngine.PartyServer.join_party(party_id, name) do
          {:ok, _} -> IO.puts("#{name} joined #{party_id}")
          {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
        end

      _ ->
        IO.puts("Usage: party.join <party_id> <name>")
    end

    :continue
  end

  defp parse_command("party.list") do
    parties = SlowArena.GameEngine.PartyServer.list_parties()

    if parties == [] do
      IO.puts("No parties")
    else
      Enum.each(parties, fn p ->
        IO.puts(
          "  #{p.party_id} leader:#{p.leader} members:#{inspect(p.members)} loot:#{p.loot_mode}"
        )
      end)
    end

    :continue
  end

  # === System Commands ===

  defp parse_command("status") do
    tick = SlowArena.GameEngine.GameLoop.get_stats()
    players = length(:mnesia.dirty_all_keys(:player_positions))
    npcs = length(:mnesia.dirty_all_keys(:npc_state))
    loot = length(:mnesia.dirty_all_keys(:loot_piles))
    parties = length(:mnesia.dirty_all_keys(:party_state))
    instances = length(:mnesia.dirty_all_keys(:dungeon_instances))

    IO.puts("""

    === Game Engine Status ===
    Tick: ##{tick.tick_count} (#{tick.tick_rate}ms rate, #{tick.avg_elapsed_ms}ms avg)
    Players: #{players}
    NPCs: #{npcs}
    Loot piles: #{loot}
    Parties: #{parties}
    Dungeon instances: #{instances}
    """)

    :continue
  end

  defp parse_command("tick") do
    stats = SlowArena.GameEngine.GameLoop.get_stats()

    IO.puts(
      "Tick ##{stats.tick_count} | Rate: #{stats.tick_rate}ms | Avg: #{stats.avg_elapsed_ms}ms"
    )

    :continue
  end

  defp parse_command("tables") do
    tables = [
      :player_positions,
      :player_stats,
      :player_cooldowns,
      :player_auto_attack,
      :npc_state,
      :loot_piles,
      :party_state,
      :dungeon_instances,
      :combat_events
    ]

    IO.puts("\n  Mnesia Tables:")

    Enum.each(tables, fn t ->
      size = :mnesia.table_info(t, :size)
      IO.puts("    #{t}: #{size} records")
    end)

    IO.puts("")
    :continue
  end

  defp parse_command("reset") do
    tables = [
      :player_positions,
      :player_stats,
      :player_cooldowns,
      :player_auto_attack,
      :npc_state,
      :loot_piles,
      :party_state,
      :dungeon_instances,
      :combat_events
    ]

    Enum.each(tables, &:mnesia.clear_table/1)
    IO.puts("All game state cleared")
    :continue
  end

  # === Diagram Commands ===

  defp parse_command("diagram") do
    IO.puts("""

    Available diagrams:
      arch     - System architecture / supervision tree
      loop     - Game loop tick sequence
      ai       - NPC AI state machine
      combat   - Combat ability flow
      data     - Data layer (Mnesia tables)

    Usage: diagram <name>
    Requires: mermaid-ascii (install: uv tool install mermaid-ascii)
    """)

    :continue
  end

  defp parse_command("diagram " <> name) do
    diagram =
      case String.trim(name) do
        "arch" ->
          """
          graph LR
            App[Application] --> Sup[GameEngine.Supervisor]
            Sup --> Mnesia[MnesiaSetup]
            Sup --> Loop[GameLoop]
            Sup --> Combat[CombatServer]
            Sup --> AI[AIServer]
            Sup --> Loot[LootServer]
            Sup --> Party[PartyServer]
            Sup --> Dungeon[DungeonServer]
          """

        "loop" ->
          """
          graph LR
            Move[Movement] --> AI[AI Tick]
            AI --> Combat[Combat]
            Combat --> Loot[Loot Cleanup]
            Loot --> Broadcast[Broadcast]
          """

        "ai" ->
          """
          graph LR
            Idle --> |aggro| Chase
            Chase --> |in range| Attack
            Chase --> |lost| Idle
            Attack --> |out of range| Chase
            Attack --> |low hp| Flee
            Flee --> |at spawn| Idle
          """

        "combat" ->
          """
          graph LR
            Cast[Cast Ability] --> CD[Check Cooldown]
            CD --> Mana[Check Mana]
            Mana --> Range[Check Range]
            Range --> Exec[Execute]
            Exec --> Dmg[Apply Damage]
            Dmg --> Event[Record Event]
          """

        "data" ->
          """
          graph LR
            Mnesia[Mnesia RAM] --> Pos[player_positions]
            Mnesia --> Stats[player_stats]
            Mnesia --> CD[player_cooldowns]
            Mnesia --> NPC[npc_state]
            Mnesia --> LP[loot_piles]
            Mnesia --> PS[party_state]
            Mnesia --> DI[dungeon_instances]
            Mnesia --> CE[combat_events]
          """

        other ->
          IO.puts("Unknown diagram: #{other}")
          IO.puts("Available: arch, loop, ai, combat, data")
          nil
      end

    if diagram do
      render_mermaid(diagram)
    end

    :continue
  end

  defp parse_command(unknown) do
    IO.puts("Unknown command: #{unknown}")
    IO.puts("Type 'help' for available commands")
    :continue
  end

  # === Diagram Rendering ===

  defp render_mermaid(mermaid_string) do
    case System.find_executable("mermaid-ascii") do
      nil ->
        IO.puts("mermaid-ascii not found. Install with: uv tool install mermaid-ascii")

      _exe ->
        tmp = Path.join(System.tmp_dir!(), "slow_arena_diagram.mmd")
        File.write!(tmp, mermaid_string)

        case System.cmd("mermaid-ascii", ["-f", tmp], stderr_to_stdout: true) do
          {output, 0} ->
            IO.puts("")
            IO.puts(output)

          {error, _code} ->
            IO.puts("Error rendering diagram: #{String.trim(error)}")
        end

        File.rm(tmp)
    end
  end

  # === Helpers ===

  defp spawn_player(name, class) do
    {hp, mana, str, int, agi, armor} =
      case class do
        :warrior -> {100, 30, 15, 5, 8, 20}
        :mage -> {60, 100, 5, 15, 8, 5}
        :ranger -> {80, 50, 8, 8, 15, 10}
        :rogue -> {70, 40, 10, 5, 15, 8}
      end

    :mnesia.dirty_write(
      {:player_positions, name, 100.0, 100.0, 0.0, 0.0, 0.0, "lobby", "lobby",
       System.monotonic_time(:millisecond)}
    )

    :mnesia.dirty_write({:player_stats, name, class, 1, hp, hp, mana, mana, str, int, agi, armor})

    IO.puts(
      "Spawned #{name} [#{class}] HP:#{hp} Mana:#{mana} STR:#{str} INT:#{int} AGI:#{agi} Armor:#{armor}"
    )
  end

  defp create_dungeon(template, difficulty) do
    case SlowArena.GameEngine.DungeonServer.create_instance(template, "cli_party", difficulty) do
      {:ok, instance_id} -> IO.puts("Dungeon created: #{instance_id}")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end
end
