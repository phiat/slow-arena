# CLAUDE.md - Project Directives

If a tool is needed and not installed, ask the user before installing it.

## Project: Slow Arena - Gauntlet-style RPG Game Engine

### Tech Stack
- **Language:** Elixir 1.19.5 / OTP 28
- **Web:** Phoenix Framework + LiveView
- **Real-time state:** Mnesia (in-memory, OTP-native)
- **Persistence:** SurrealDB (via Docker)
- **Frontend:** Phoenix LiveView (server-rendered)
- **Infrastructure:** Docker Compose for services

### Development Commands
```
make help       # Show all commands
make setup      # Full setup (deps + db)
make server     # Start Phoenix
make iex        # Start IEx + Phoenix
make test       # Run tests
make cli        # Game CLI
make db         # Start SurrealDB
make db.reset   # Reset database
```

### Architecture
- **GameEngine** - OTP app with GenServers for game loop, combat, AI
- **Mnesia** - Real-time game state (positions, cooldowns, NPC state, loot piles)
- **SurrealDB** - Persistent data (accounts, characters, inventory, dungeon templates)
- **Phoenix Channels** - WebSocket communication to clients
- **LiveView** - Browser-based game client
- **Mix Tasks** - CLI for testing and management

### Code Guidelines
- Create focused, concise high-ROI tests (not exhaustive unit tests)
- Use newest versions of libraries
- CLI-first: all features should be testable without frontend
- Use Makefile for common commands
- Use Docker Compose for external services
- Ask user to run sudo if needed
- Offer design critique and options when appropriate

### Game Design
- Slow, tactical combat (NOT twitch-based)
- 10Hz game loop (100ms ticks)
- Cooldown-based abilities
- AI state machines (idle/patrol/chase/attack/flee)
- Party-based dungeon instances
- Loot generation and distribution
