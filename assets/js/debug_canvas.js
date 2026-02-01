// DebugCanvas hook — dense debug/server stats with scroll support
const COLORS = {
  chocolatePlum: "#563635",
  ebony: "#5b6057",
  dustyOlive: "#6e9075",
  mintLeaf: "#78c091",
  neonIce: "#81f0e5",
}

const DebugCanvas = {
  mounted() {
    this.canvas = this.el
    this.ctx = this.canvas.getContext("2d")
    this.state = { players: [], npcs: [], loot: [], debug: null, local_player_id: null }
    this._fpsFrames = []
    this._scrollY = 0

    this.handleEvent("game_state", (state) => {
      this.state = state
    })

    // Scroll support
    this.canvas.addEventListener("wheel", (e) => {
      e.preventDefault()
      this._scrollY = Math.max(0, this._scrollY + e.deltaY * 0.5)
    })

    this._raf = requestAnimationFrame(() => this.renderLoop())
  },

  destroyed() {
    if (this._raf) cancelAnimationFrame(this._raf)
  },

  renderLoop() {
    this.draw()
    this._raf = requestAnimationFrame(() => this.renderLoop())
  },

  draw() {
    const ctx = this.ctx
    const W = this.canvas.width
    const H = this.canvas.height
    const d = this.state.debug

    ctx.fillStyle = COLORS.chocolatePlum
    ctx.fillRect(0, 0, W, H)
    ctx.strokeStyle = "rgba(129, 240, 229, 0.15)"
    ctx.lineWidth = 1
    ctx.strokeRect(0, 0, W, H)

    const pad = 6
    const lh = 11 // line height
    const lines = []

    if (!d || !d.tick_count) {
      lines.push({t: "DEBUG (` toggle)", h: true})
      lines.push({t: "Waiting..."})
      this.drawLines(ctx, lines, pad, lh, W, H)
      return
    }

    // FPS tracking
    this._fpsFrames.push(performance.now())
    while (this._fpsFrames.length > 0 && this._fpsFrames[0] < performance.now() - 1000)
      this._fpsFrames.shift()

    const L = (t, h) => lines.push({t, h: !!h})
    const S = () => lines.push({t: "", sep: true}) // half-height spacer

    L("DEBUG", true)
    S()
    L("LOOP", true)
    L(`tick #${d.tick_count}  ${d.avg_tick_ms}ms  ${1000/d.tick_rate}Hz`)
    S()
    L("BEAM", true)
    L(`${d.otp_release} ${d.scheduler_count}sched ${d.process_count}proc`)
    L(`mem ${d.beam_memory_mb}MB  mnesia ${(d.mnesia_memory_bytes/1024).toFixed(1)}KB`)
    S()
    L("TABLES", true)
    if (d.table_sizes) {
      const abbr = {player_positions:"pos",player_stats:"stats",player_cooldowns:"cd",
        player_auto_attack:"aa",player_equipment:"eq",npc_state:"npc",loot_piles:"loot",
        party_state:"party",dungeon_instances:"dng",combat_events:"evt"}
      const parts = []
      for (const [t, sz] of Object.entries(d.table_sizes)) {
        parts.push(`${abbr[t]||t}:${sz}`)
      }
      // Pack 3 per line
      for (let i = 0; i < parts.length; i += 3) {
        L(parts.slice(i, i+3).join("  "))
      }
    }
    S()
    L("WORLD", true)
    L(`p:${this.state.players.length} npc:${this.state.npcs.length} loot:${this.state.loot.length} fps:${this._fpsFrames.length}`)

    // AI state breakdown - compact
    const ai = {}
    for (const npc of this.state.npcs) ai[npc.ai_state] = (ai[npc.ai_state]||0) + 1
    if (Object.keys(ai).length > 0) {
      const parts = Object.entries(ai).map(([s,c]) => `${s}:${c}`)
      L(`ai ${parts.join(" ")}`)
    }

    // Local player
    const local = this.state.players.find(p => p.id === this.state.local_player_id)
    if (local) {
      S()
      L("PLAYER", true)
      L(`hp:${local.hp}/${local.max_hp} mp:${local.mana}/${local.max_mana}`)
      L(`pos:(${local.x.toFixed(0)},${local.y.toFixed(0)}) ${(local.facing*180/Math.PI).toFixed(0)}°`)
    }

    // NPC list - compact
    if (this.state.npcs.length > 0) {
      S()
      L("NPCS", true)
      for (const npc of this.state.npcs) {
        const hp = npc.max_hp > 0 ? Math.round(npc.hp/npc.max_hp*100) : 0
        const name = npc.template.replace(/_/g," ").substring(0,10)
        L(`${name} ${npc.ai_state} ${hp}%`)
      }
    }

    // Combat events count
    const evts = this.state.combat_events || []
    if (evts.length > 0) {
      S()
      L("EVENTS", true)
      L(`${evts.length} recent`)
    }

    this.drawLines(ctx, lines, pad, lh, W, H)
  },

  drawLines(ctx, lines, pad, lh, W, H) {
    ctx.save()
    ctx.beginPath()
    ctx.rect(0, 0, W, H)
    ctx.clip()

    ctx.font = "9px monospace"
    ctx.textAlign = "left"

    // Clamp scroll to content
    const totalH = lines.reduce((a, l) => a + (l.sep ? lh * 0.4 : lh), 0)
    this._scrollY = Math.min(this._scrollY, Math.max(0, totalH - H + pad * 2))

    let y = pad - this._scrollY
    for (const line of lines) {
      if (line.sep) { y += lh * 0.4; continue }
      y += lh
      if (y < -lh || y > H + lh) continue // skip offscreen
      ctx.fillStyle = line.h ? COLORS.neonIce : "rgba(120,192,145,0.85)"
      ctx.fillText(line.t, pad, y)
    }

    // Scroll indicator
    if (totalH > H) {
      const barH = Math.max(20, H * H / totalH)
      const barY = (this._scrollY / totalH) * H
      ctx.fillStyle = "rgba(129,240,229,0.2)"
      ctx.fillRect(W - 3, barY, 2, barH)
    }

    ctx.restore()
  }
}

export default DebugCanvas
