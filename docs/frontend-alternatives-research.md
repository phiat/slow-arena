# Frontend Rendering Alternatives to Phoenix LiveView

> Research for Slow Arena -- Gauntlet-style RPG Game Engine
> Date: 2026-02-01

## Context

Slow Arena is an Elixir/OTP game engine with:
- 10Hz game loop (100ms ticks) in a GenServer
- Mnesia for real-time state (positions, cooldowns, NPC state, loot)
- GenServer-based subsystems (combat, AI, loot, parties, dungeons)
- Currently uses Phoenix LiveView for the web frontend

The question: **Can we render the game natively instead of in a browser?**

---

## Summary Table

| Option | Status | Rendering | FPS | Integration | Complexity | Verdict |
|--------|--------|-----------|-----|-------------|------------|---------|
| **Scenic** | Maintained (v0.11+) | OpenGL via driver | 30-60 | Native OTP | Low | **Top Pick for Native** |
| **Rayex** | Abandoned (~2022) | Raylib/OpenGL | 60+ | NIF (risky) | Medium | Not viable |
| **ex_raylib** | Experimental | Raylib/OpenGL | 60+ | NIF | Medium | Not viable |
| **:wx (wxWidgets)** | Ships with OTP | wxWidgets/native | 30 | Native OTP | Medium | Viable fallback |
| **Port to Rust** | Custom build | wgpu/SDL2/etc | 60+ | Port/stdio | High | Best perf path |
| **Godot client** | Custom build | Godot engine | 60+ | WebSocket/TCP | High | Overkill |
| **LiveView+Canvas** | Current stack | HTML5 Canvas/WebGL | 60 | Phoenix Channel | Low | **Solid baseline** |
| **LiveView+PixiJS** | Current stack | WebGL (PixiJS) | 60+ | Phoenix Channel | Low-Med | **Best hybrid** |
| **Membrane** | Active | Media pipelines | N/A | OTP | N/A | Not relevant |
| **SDL2 NIF** | None exists | SDL2 | 60+ | Would need NIF | Very High | DIY only |

---

## 1. Scenic Framework

**Repo:** https://github.com/ScenicFramework/scenic
**Author:** Boyd Multerer (Erlang/Elixir veteran, ex-Microsoft Xbox)
**Hex:** `scenic` (~1,900+ GitHub stars)
**Version:** v0.11.x (major rewrite from v0.10)
**Status:** Maintained, slow release cadence, solo maintainer with periodic activity bursts

### What It Is

OTP-native framework for fixed-screen UIs. Designed for IoT/embedded/kiosk.

- **Pure OTP** -- scenes are GenServers, the graph is a data structure
- **Retained-mode** -- build a `Scenic.Graph` of primitives, push to a driver
- **Driver-based** -- `scenic_driver_local` uses GLFW + OpenGL via NIF for desktop rendering
- **Input handling** -- keyboard, mouse, touch events flow through the scene tree
- **No browser** -- runs as a native window

### Rendering Capabilities

Primitives: `rect`, `rounded_rect`, `circle`, `ellipse`, `arc`, `sector`, `line`, `path`, `triangle`, `quad`, `text` (TrueType), `sprites` (sprite sheets with source rectangles), `group` (for transforms -- translate, rotate, scale). Fill/stroke styles, colors, opacity.

Can it draw a 2D game? **Yes**, with caveats:
- Sprite sheet support exists (`Scenic.Primitive.Sprites`)
- Graph can be updated at any frame rate by pushing new graphs
- Transforms (translate/rotate/scale) work on groups and individual primitives
- NOT designed for thousands of independently moving sprites -- it is a UI framework
- For Slow Arena's scale (dozens of entities, not thousands), it works fine

### Input Handling

```elixir
handle_input({:key, {"w", :press, _mods}}, _context, scene)
handle_input({:key, {"w", :release, _mods}}, _context, scene)
handle_input({:cursor_pos, {x, y}}, _context, scene)
handle_input({:cursor_button, {:left, :press, _mods, {x, y}}}, _context, scene)
```

Maps cleanly to `Movement.set_input/2`.

### Install Requirements

- GLFW3 (`libglfw3-dev` on Ubuntu/Debian), OpenGL ES 2.0+ (mesa), C compiler
- Linux: `sudo apt install libglfw3-dev libgl1-mesa-dev`
- macOS: works out of the box (Xcode CLI tools)

### Integration Architecture

```
+-----------------------------------------------------------+
|                    BEAM VM (single node)                   |
|                                                           |
|  +------------------+       +------------------------+    |
|  | GameEngine       |       | Scenic Application     |    |
|  | Supervisor       |       |                        |    |
|  |                  |       |  +------------------+  |    |
|  | GameLoop --------+------>|  | GameScene        |  |    |
|  |   (10Hz tick)    | state |  | (GenServer)      |  |    |
|  |                  | push  |  |                  |  |    |
|  | CombatServer     |       |  | - Builds Graph   |  |    |
|  | AIServer         |       |  | - Pushes to      |  |    |
|  | MovementServer   |       |  |   ViewPort       |  |    |
|  | LootServer       |       |  +--------+---------+  |    |
|  +------------------+       |           |             |    |
|         ^                   |  +--------v---------+   |    |
|         |                   |  | scenic_driver_   |   |    |
|         | input events      |  | local (GLFW+GL)  |   |    |
|         | (GenServer.cast)  |  +--------+---------+   |    |
|         |                   +-----------|-------------+    |
|         |                               |                  |
+---------|-------------------------------|------------------+
          |                               |
     [keyboard/mouse]               [native window]
```

**Key advantage:** Everything runs in the same BEAM VM. The GameScene GenServer can directly call `Movement.set_input/2` and read Mnesia tables. Zero serialization overhead.

### Code Sketch

```elixir
defmodule SlowArena.Scenic.GameScene do
  use Scenic.Scene
  import Scenic.Primitives

  @frame_rate 16  # ~60fps rendering (independent of 10Hz game tick)

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    schedule_frame()
    scene =
      scene
      |> assign(input_state: %{up: false, down: false, left: false, right: false})
      |> push_graph(build_graph(%{}, %{}))
    {:ok, scene}
  end

  @impl Scenic.Scene
  def handle_info(:frame, scene) do
    players = read_all_positions(:player_positions)
    npcs = read_all_positions(:npc_state)
    schedule_frame()
    {:noreply, scene |> push_graph(build_graph(players, npcs))}
  end

  @impl Scenic.Scene
  def handle_input({:key, {key, :press, _}}, _ctx, scene) do
    input = update_input(scene.assigns.input_state, key, true)
    SlowArena.GameEngine.Movement.set_input("player_1", input)
    {:noreply, assign(scene, input_state: input)}
  end

  def handle_input({:key, {key, :release, _}}, _ctx, scene) do
    input = update_input(scene.assigns.input_state, key, false)
    SlowArena.GameEngine.Movement.set_input("player_1", input)
    {:noreply, assign(scene, input_state: input)}
  end

  def handle_input(_, _, scene), do: {:noreply, scene}

  defp build_graph(players, npcs) do
    Scenic.Graph.build(font: :roboto, font_size: 16)
    |> rect({800, 600}, fill: {20, 20, 30})
    |> draw_entities(players, :blue)
    |> draw_entities(npcs, :red)
    |> text("Slow Arena", translate: {10, 20}, fill: :white)
  end

  defp draw_entities(graph, entities, color) do
    Enum.reduce(entities, graph, fn {_id, pos}, g ->
      g |> circle(12, fill: color, translate: {pos.x, pos.y})
    end)
  end

  defp update_input(state, "w", v), do: %{state | up: v}
  defp update_input(state, "s", v), do: %{state | down: v}
  defp update_input(state, "a", v), do: %{state | left: v}
  defp update_input(state, "d", v), do: %{state | right: v}
  defp update_input(state, _, _), do: state

  defp schedule_frame, do: Process.send_after(self(), :frame, @frame_rate)
end
```

### Verdict: RECOMMENDED (Top Pick for Native)

**Pros:** Pure OTP, same BEAM node, zero serialization, mature primitives, clean input handling, supervision tree integration, credible maintainer.

**Cons:** Not a game engine (minimal sprite animation tooling), v0.11 ecosystem catching up, limited community, requires OpenGL+GLFW, no particle systems or camera/viewport scrolling, single maintainer risk.

---

## 2. Rayex (Raylib NIF Bindings)

**Repo:** https://github.com/shiryel/rayex
**Status:** Abandoned (~2022). No Hex package. ~50 stars.

**Problems:**
1. **NIF safety** -- Raylib owns the main thread. NIF crash = VM crash.
2. **Unmaintained** -- No activity, incomplete API coverage.
3. **Build complexity** -- System Raylib install + C compiler + NIF.
4. **Loop conflict** -- Raylib's BeginDrawing/EndDrawing vs BEAM scheduler.

**Verdict: NOT VIABLE.** If Raylib is desired, use a Port-based approach instead.

---

## 3. ex_raylib and Other Raylib Bindings

- **ex_raylib** -- No published package. Various forks exist, none maintained.
- **raylib_server** -- Concept only (separate process via TCP).

**Verdict:** Nothing viable exists. Build a custom Port if Raylib is desired.

---

## 4. :wx (wxWidgets, built into OTP)

**Status:** Ships with Erlang/OTP. Always available. Maintained by the OTP team.

`:wx` is the Erlang binding to wxWidgets. Desktop app toolkit with `wxGLCanvas` for OpenGL.

- `wxDC`: 2D drawing (adequate but slow, ~30fps max for complex scenes)
- `wxGLCanvas`: OpenGL surface (fast but requires raw OpenGL code)
- `wxImage`/`wxBitmap`: image loading and blitting

**Verdict: VIABLE FALLBACK.**
**Pros:** Zero external deps, ships with OTP, all platforms, same BEAM node.
**Cons:** Verbose Erlang-flavored API, slow wxDC rendering, no sprite support, looks like a desktop app, raw OpenGL for any real performance.

---

## 5. Port to External Renderer (Rust/C/Zig)

Run the renderer as a **separate OS process** communicating with the BEAM via Erlang Ports (stdin/stdout with length-prefixed binary) or TCP sockets.

```
+---------------------------+          +---------------------------+
|       BEAM VM             |   Port   |    Renderer Process       |
| GameLoop (10Hz) --------->| =======> | receive_state()          |
|   serialize state         | binary   |   update render state     |
| InputHandler <------------|<======== | poll_input()              |
|   call Movement.set_input | events   |   send key/mouse          |
| Supervision: auto-restart |          | render_loop (60fps)       |
+---------------------------+          +---------------------------+
```

```elixir
defmodule SlowArena.Renderer.Port do
  use GenServer

  def init(_) do
    port = Port.open({:spawn_executable, renderer_path()}, [
      :binary, :exit_status, {:packet, 4}
    ])
    schedule_push()
    {:ok, %{port: port}}
  end

  def handle_info(:push, %{port: port} = state) do
    Port.command(port, :erlang.term_to_binary(gather_state()))
    schedule_push()
    {:noreply, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case :erlang.binary_to_term(data) do
      {:input, id, input} -> Movement.set_input(id, input)
      {:ability, id, ab, tgt} -> CombatServer.cast_ability(id, ab, tgt)
    end
    {:noreply, state}
  end
end
```

**Verdict: BEST PERFORMANCE PATH (high effort).**
**Pros:** 60fps+, crash isolation, any language/renderer, clean separation.
**Cons:** Two codebases/languages/build systems, serialization overhead, fully custom.

---

## 6. Godot with Elixir Backend

Godot as thick client, Elixir as authoritative server, connected via WebSocket/TCP.

**Verdict: OVERKILL** for current scope.

---

## 7. LiveView + Canvas/PixiJS (Enhanced Current Approach)

Keep Phoenix, add Canvas/PixiJS renderer driven by PubSub pushes.

**Verdict: BEST HYBRID APPROACH.**
**Pros:** Existing stack, PixiJS is extremely capable (sprites, particles, tilemaps), client-side interpolation gives smooth 60fps from 10Hz server, multiplayer-ready.
**Cons:** Browser overhead vs native, JavaScript for renderer (standard for Phoenix apps).

---

## Recommendation Ranking

### Tier 1: Recommended

| Rank | Option | Why |
|------|--------|-----|
| **1** | **LiveView + PixiJS/Canvas** | Lowest effort, highest capability, existing stack, multiplayer-ready |
| **2** | **Scenic** | Best native option, pure OTP, zero serialization, same BEAM node |

### Tier 2: Viable but Higher Effort

| Rank | Option | Why |
|------|--------|-----|
| **3** | **Port to Rust renderer** | Best performance ceiling, crash isolation, clean separation |
| **4** | **:wx** | Zero deps, good for debug/admin view |

### Tier 3: Not Recommended

| Rank | Option | Why |
|------|--------|-----|
| **5** | Godot client | Overkill |
| **6** | Rayex / NIF bindings | Unmaintained, unsafe |
| **7** | SDL2 / OpenGL bindings | Do not exist |

---

## Recommended Strategy

**Phase 1 (Now):** LiveView + Canvas. Already implemented. Minimal deps, working visual client.

**Phase 2 (Optional):** Scenic native client. Same BEAM node, fastest dev feedback loop. Can coexist alongside the Phoenix web endpoint.

**Phase 3 (If needed):** Rust Port renderer. Only if native performance becomes a requirement (unlikely for "slow, tactical" combat at 10Hz).

**Key insight:** The game engine architecture does not need to change for any of these options. The GenServer/Mnesia core stays identical. Only the "last mile" -- how state reaches pixels -- varies.
