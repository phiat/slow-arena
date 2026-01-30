# Initial Design & Setup - Technical Summary

## Current State

The project has a working Elixir/Phoenix game engine skeleton with all core systems
operational. The engine compiles cleanly, passes 14 integration tests, and can be
interacted with via CLI or IEx.

**Stack:** Elixir 1.19.5 / OTP 28 / Phoenix 1.8 / Mnesia / SurrealDB (Docker)

---

## Architecture

### OTP Supervision Tree

```
SlowArena.Application
├── SlowArenaWeb.Telemetry
├── DNSCluster
├── Phoenix.PubSub
├── SlowArena.GameEngine.Supervisor
│   ├── MnesiaSetup         (initializes 9 RAM tables on boot)
│   ├── GameLoop            (10Hz tick - orchestrates all systems)
│   ├── CombatServer        (abilities, auto-attacks, damage calc)
│   ├── AIServer            (NPC state machines)
│   ├── LootServer          (drop generation, expiry cleanup)
│   ├── PartyServer         (party CRUD, leader succession)
│   └── DungeonServer       (instance creation, difficulty scaling)
└── SlowArenaWeb.Endpoint
```

### Data Layer

**Mnesia (in-memory, ephemeral)** - 9 tables for real-time game state:
- `player_positions` - x/y/facing/velocity per character
- `player_stats` - class/level/hp/mana/attributes
- `player_cooldowns` - ability cooldown expiry timestamps
- `player_auto_attack` - current auto-attack target + timing
- `npc_state` - position/hp/ai_state/target/spawn_point per NPC
- `loot_piles` - items/gold/location/expiry per drop
- `party_state` - members/leader/loot_mode per party
- `dungeon_instances` - template/difficulty/status per instance
- `combat_events` - damage log for replay/UI

**SurrealDB (persistent, Docker)** - Not yet wired. Will hold:
- Account/character persistence
- Inventory
- Dungeon templates (when they outgrow hardcoded maps)

### Game Loop (10Hz)

Each tick (100ms) processes in order:
1. Movement - apply velocity * speed * delta to all moving players
2. AI - run state machine for every living NPC
3. Combat - process auto-attacks on cooldown, apply DoT effects
4. Loot - clean up expired piles (60s TTL)

Performance is tracked via exponential moving average (`avg_elapsed`).

---

## Systems Implemented

### Movement
- WASD input sets velocity vector on player
- Diagonal movement normalized to unit length
- 150 px/s base speed, 0.1s delta per tick
- Bounds clamping (800x600 default zone)

### Combat
- **6 abilities** defined with cooldown/mana/damage/scaling/range/type:
  - `slash` (2s CD, STR scaling, melee instant)
  - `shield_bash` (5s CD, STR, stun 1.5s)
  - `fireball` (3s CD, INT, projectile)
  - `ice_lance` (2s CD, INT, projectile)
  - `arrow_volley` (4s CD, AGI, AoE r=80)
  - `backstab` (3s CD, AGI, melee)
- Cast validation: cooldown -> mana -> range -> line of sight
- Damage formula: `(base + stat * factor) * variance(±10%) * crit(15% chance, 2x)`
- Auto-attacks: 1/s, STR*2 base, range 50px

### AI State Machine
- **States:** idle, chase, attack, flee
- **Aggro:** 200px detection range
- **Chase:** move toward target at 80px/s, drop aggro at 400px
- **Attack:** 50px range, 1.5s cooldown, flat damage reduced by armor
- **Flee:** return to spawn point (unused for current templates)

### Loot
- Per-template loot tables (goblin, skeleton_warrior, boss_ogre)
- Probabilistic item drops with quantity ranges
- Gold rolls with chance + max
- 60s expiry with tick-based cleanup
- Pickup with reservation support

### Party
- Create/join/leave with 8-player max
- Leader succession on leave
- Loot modes: free_for_all, round_robin, master_looter (skeleton)

### Dungeon Instancing
- Template: `crypt_of_bones` (3 skeletons, 2 goblins, 1 boss ogre)
- Difficulty multipliers: normal(1x), hard(1.5x), nightmare(2.5x)
- NPCs spawned at template-defined positions
- Players teleported to entrance on instance creation
- Instance cleanup deletes all associated NPCs and loot

---

## CLI

Interactive CLI via `make cli` (or `mix game.cli`):

```
arena> spawn hero warrior
arena> dungeon crypt_of_bones nightmare
arena> npcs
arena> cast hero slash 200.0 150.0
arena> loot
arena> pickup hero loot_12345
arena> status
arena> tables
arena> reset
```

All game systems are testable without a frontend.

---

## Project Stats

| Metric | Value |
|--------|-------|
| Game engine LOC | ~1,200 |
| CLI LOC | ~470 |
| Test count | 14 |
| Mnesia tables | 9 |
| GenServers | 7 |
| Abilities | 6 |
| NPC templates | 3 |
| Dungeon templates | 1 |
| Character classes | 4 |

---

## What's Not Done Yet

- **SurrealDB integration** - Docker compose is ready, no Elixir client wired
- **Phoenix LiveView UI** - endpoint is running, no game-specific views
- **WebSocket broadcasts** - PubSub is set up, broadcast calls are commented stubs
- **Collision detection** - only bounds clamping, no wall/NPC collision
- **Projectile system** - abilities flagged as `:projectile` resolve instantly
- **Buff/debuff system** - `process_effects()` is a stub
- **Player-vs-player** - damage only targets NPCs
- **Death/respawn** - player death is logged but not handled
- **Inventory persistence** - loot pickup has no inventory storage
- **More dungeon templates** - only `crypt_of_bones` exists
- **Spatial partitioning** - all queries scan full table (fine for small scale)

---

## Dev Workflow

```bash
make help       # all available commands
make setup      # deps + start SurrealDB
make test       # run tests
make cli        # interactive game CLI
make iex        # IEx with full app
make server     # Phoenix server (http://localhost:4000)
make db         # start SurrealDB container
make db.reset   # wipe and restart SurrealDB
```
