# Slow Arena

A Gauntlet-style RPG game engine built with Elixir/OTP. Slow, tactical combat with cooldown-based abilities, AI-driven enemies, party dungeons, and loot.

## Tech Stack

- **Elixir 1.19 / OTP 28** - game engine as OTP supervision tree
- **Phoenix + LiveView** - web client (WIP)
- **Mnesia** - in-memory real-time game state (9 tables)
- **SurrealDB** - persistent storage via Docker (WIP)

## Quick Start

```bash
# Install deps and start SurrealDB
make setup

# Run tests
make test

# Interactive game CLI
make cli

# Start Phoenix server
make server
```

Requires Elixir 1.15+, Docker.

## Game Engine

7 GenServers under a supervision tree, ticked at 10Hz:

| System | Description |
|--------|-------------|
| **GameLoop** | 100ms tick orchestrating all systems |
| **Movement** | WASD input, velocity-based, diagonal normalization |
| **CombatServer** | 6 abilities, auto-attacks, stat scaling, crits |
| **AIServer** | NPC state machine: idle/chase/attack/flee |
| **LootServer** | Template-based drops, 60s expiry, pickup |
| **PartyServer** | Up to 8 players, leader succession, loot modes |
| **DungeonServer** | Instanced dungeons with difficulty scaling |

## CLI

All systems are testable without a frontend:

```
arena> spawn hero warrior
arena> dungeon crypt_of_bones nightmare
arena> npcs
arena> cast hero slash 200.0 150.0
arena> stats hero
arena> loot
arena> status
```

## Project Structure

```
lib/
├── slow_arena/
│   ├── application.ex          # OTP application
│   └── game_engine/
│       ├── supervisor.ex       # Engine supervisor
│       ├── mnesia_setup.ex     # Table initialization
│       ├── game_loop.ex        # 10Hz tick loop
│       ├── movement.ex         # Player movement
│       ├── combat_server.ex    # Abilities & damage
│       ├── ai_server.ex        # NPC behavior
│       ├── loot_server.ex      # Loot generation
│       ├── party_server.ex     # Party management
│       └── dungeon_server.ex   # Instance management
├── slow_arena_web/             # Phoenix web layer
└── mix/tasks/
    ├── game.cli.ex             # Interactive CLI
    └── game.status.ex          # Status command
```

## Make Targets

```
make help        # Show all commands
make setup       # Full project setup
make test        # Run tests
make cli         # Interactive game CLI
make server      # Phoenix server
make iex         # IEx with app
make db          # Start SurrealDB
make db.reset    # Reset database
```

## License

MIT
