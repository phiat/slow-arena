// GameCanvas hook — renders game state to a <canvas> element
// Color palette:
//   Chocolate Plum: #563635  |  Ebony: #5b6057  |  Dusty Olive: #6e9075
//   Mint Leaf: #78c091       |  Neon Ice: #81f0e5
const COLORS = {
  chocolatePlum: "#563635",
  ebony: "#5b6057",
  dustyOlive: "#6e9075",
  mintLeaf: "#78c091",
  neonIce: "#81f0e5",
}

const GameCanvas = {
  mounted() {
    this.canvas = this.el
    this.ctx = this.canvas.getContext("2d")
    this.state = { players: [], npcs: [], loot: [], combat_events: [], local_player_id: null }
    this.damageFloaters = []
    this.lootFloaters = []    // gold/item pickup floaters
    this.deathEffects = []    // dissolve particle bursts
    this.hitFlashes = {}      // entity_id -> frames remaining
    this.screenShake = 0      // frames remaining for screen shake
    this.killFlash = null     // { text, life } for +KILL popups
    this.castFlash = 0        // frames remaining for border flash on ability cast
    this._prevNpcCount = null // track NPC count changes for kill detection
    this._prevPlayerHp = null // track player HP for damage screen shake

    this.handleEvent("game_state", (state) => {
      const localPlayer = state.players?.find(p => p.id === state.local_player_id)

      // Detect player taking damage -> screen shake
      if (localPlayer && this._prevPlayerHp !== null && localPlayer.hp < this._prevPlayerHp) {
        this.screenShake = 4
      }
      if (localPlayer) this._prevPlayerHp = localPlayer.hp

      // Detect NPC count drop -> kill celebration
      const npcAlive = (state.npcs || []).filter(n => n.hp > 0).length
      if (this._prevNpcCount !== null && npcAlive < this._prevNpcCount) {
        this.killFlash = { text: "+KILL", life: 40 }
      }
      this._prevNpcCount = npcAlive

      // Spawn damage floaters for new combat events
      for (const evt of (state.combat_events || [])) {
        if (!this._seenEvents) this._seenEvents = new Set()
        if (!this._seenEvents.has(evt.id)) {
          this._seenEvents.add(evt.id)
          // Find target position
          const target = [...state.npcs, ...state.players].find(e => e.id === evt.target)
          if (target) {
            // Determine if damage is to player or NPC
            const isPlayerTarget = state.players.some(p => p.id === evt.target)
            this.damageFloaters.push({
              x: target.x, y: target.y - 20,
              text: `-${evt.damage}`,
              life: 60,
              color: isPlayerTarget ? COLORS.chocolatePlum : COLORS.neonIce,
              outline: isPlayerTarget // NPC damage to player gets white outline
            })
            // Hit flash on target
            this.hitFlashes[evt.target] = 3
          }
          if (this._seenEvents.size > 200) {
            const arr = [...this._seenEvents]
            this._seenEvents = new Set(arr.slice(-100))
          }
        }
      }

      // Detect NPC deaths -> death dissolve effect
      if (this._prevNpcs) {
        for (const prev of this._prevNpcs) {
          const curr = (state.npcs || []).find(n => n.id === prev.id)
          if (prev.hp > 0 && (!curr || curr.hp <= 0)) {
            this.spawnDeathEffect(prev.x, prev.y)
          }
        }
      }
      this._prevNpcs = (state.npcs || []).map(n => ({ id: n.id, x: n.x, y: n.y, hp: n.hp }))

      this.state = state
    })

    this.handleEvent("loot_pickup", (data) => {
      const localPlayer = this.state.players?.find(p => p.id === this.state.local_player_id)
      if (!localPlayer) return
      const baseX = localPlayer.x
      let baseY = localPlayer.y - 30
      if (data.gold > 0) {
        this.lootFloaters.push({
          x: baseX, y: baseY,
          text: `+${data.gold}g`,
          life: 60,
          color: "#fbbf24" // gold color
        })
        baseY -= 14
      }
      for (const item of (data.items || [])) {
        this.lootFloaters.push({
          x: baseX, y: baseY,
          text: `+${item.quantity} ${item.item_id.replace(/_/g, " ")}`,
          life: 60,
          color: COLORS.mintLeaf
        })
        baseY -= 14
      }
    })

    // Detect ability cast via keyboard (border flash)
    this._castListener = (e) => {
      if (["1", "2", "3", "4", "5", "6"].includes(e.key)) {
        this.castFlash = 6
      }
    }
    window.addEventListener("keydown", this._castListener)

    // Render loop at 30fps
    this._raf = requestAnimationFrame(() => this.renderLoop())
  },

  destroyed() {
    if (this._raf) cancelAnimationFrame(this._raf)
    if (this._castListener) window.removeEventListener("keydown", this._castListener)
  },

  spawnDeathEffect(x, y) {
    const particles = []
    for (let i = 0; i < 12; i++) {
      const angle = (Math.PI * 2 / 12) * i + Math.random() * 0.3
      const speed = 1.5 + Math.random() * 2
      particles.push({
        x, y,
        vx: Math.cos(angle) * speed,
        vy: Math.sin(angle) * speed,
        life: 20 + Math.floor(Math.random() * 8),
        size: 2 + Math.random() * 2
      })
    }
    this.deathEffects.push({ particles })
  },

  renderLoop() {
    this.draw()
    this._raf = requestAnimationFrame(() => this.renderLoop())
  },

  draw() {
    const ctx = this.ctx
    const W = this.canvas.width
    const H = this.canvas.height

    // Apply screen shake
    ctx.save()
    if (this.screenShake > 0) {
      const shakeX = (Math.random() - 0.5) * 5
      const shakeY = (Math.random() - 0.5) * 5
      ctx.translate(shakeX, shakeY)
      this.screenShake--
    }

    // Background - Chocolate Plum
    ctx.fillStyle = COLORS.chocolatePlum
    ctx.fillRect(0, 0, W, H)

    // Grid - Ebony with low opacity
    ctx.strokeStyle = "rgba(91, 96, 87, 0.12)"
    ctx.lineWidth = 1
    for (let x = 0; x < W; x += 40) {
      ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke()
    }
    for (let y = 0; y < H; y += 40) {
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke()
    }

    // Loot piles - Mint Leaf with glow
    for (const loot of this.state.loot) {
      ctx.save()
      ctx.shadowColor = COLORS.mintLeaf
      ctx.shadowBlur = 12
      ctx.fillStyle = COLORS.mintLeaf
      ctx.beginPath()
      ctx.arc(loot.x, loot.y, 6, 0, Math.PI * 2)
      ctx.fill()
      ctx.restore()

      ctx.strokeStyle = COLORS.dustyOlive
      ctx.lineWidth = 1.5
      ctx.beginPath()
      ctx.arc(loot.x, loot.y, 6, 0, Math.PI * 2)
      ctx.stroke()

      if (loot.gold > 0) {
        ctx.fillStyle = COLORS.mintLeaf
        ctx.font = "9px monospace"
        ctx.textAlign = "center"
        ctx.fillText(`${loot.gold}g`, loot.x, loot.y + 16)
      }

      // [E] Pickup hint when local player is near
      const lp = this.state.players?.find(p => p.id === this.state.local_player_id)
      if (lp) {
        const dx = lp.x - loot.x, dy = lp.y - loot.y
        if (Math.sqrt(dx * dx + dy * dy) <= 50) {
          ctx.fillStyle = "#fbbf24"
          ctx.font = "bold 10px monospace"
          ctx.textAlign = "center"
          ctx.fillText("[E] Pickup", loot.x, loot.y - 12)
        }
      }
    }

    // NPCs
    if (!this._frameCount) this._frameCount = 0
    this._frameCount++
    for (const npc of this.state.npcs) {
      if (npc.hp <= 0) continue
      this.drawNpc(ctx, npc, this._frameCount)
    }

    // Players
    for (const player of this.state.players) {
      const isLocal = player.id === this.state.local_player_id
      const size = 14
      const flashing = this.hitFlashes[player.id] && this.hitFlashes[player.id] > 0

      // Shadow
      ctx.fillStyle = "rgba(0,0,0,0.3)"
      ctx.beginPath()
      ctx.ellipse(player.x, player.y + size + 2, size * 0.7, 4, 0, 0, Math.PI * 2)
      ctx.fill()

      // Glow for local player
      if (isLocal) {
        ctx.save()
        ctx.shadowColor = COLORS.neonIce
        ctx.shadowBlur = 16
      }

      // Body
      if (flashing) {
        ctx.fillStyle = "#ffffff"
        ctx.strokeStyle = "#dddddd"
      } else if (isLocal) {
        ctx.fillStyle = COLORS.neonIce
        ctx.strokeStyle = COLORS.mintLeaf
      } else {
        ctx.fillStyle = COLORS.mintLeaf
        ctx.strokeStyle = COLORS.dustyOlive
      }
      ctx.lineWidth = 2
      ctx.fillRect(player.x - size / 2, player.y - size / 2, size, size)
      ctx.strokeRect(player.x - size / 2, player.y - size / 2, size, size)

      if (isLocal) ctx.restore()

      // Facing indicator
      const fx = player.x + Math.cos(player.facing) * (size + 4)
      const fy = player.y + Math.sin(player.facing) * (size + 4)
      ctx.fillStyle = COLORS.neonIce
      ctx.beginPath()
      ctx.arc(fx, fy, 3, 0, Math.PI * 2)
      ctx.fill()

      // HP bar - gradient Mint Leaf to Chocolate Plum
      const barW = 30
      const barH = 4
      const barX = player.x - barW / 2
      const barY = player.y - size - 8

      ctx.fillStyle = "rgba(86, 54, 53, 0.5)"
      ctx.fillRect(barX, barY, barW, barH)

      const hpPct = player.hp / player.max_hp
      if (hpPct > 0.5) {
        ctx.fillStyle = COLORS.mintLeaf
      } else if (hpPct > 0.25) {
        ctx.fillStyle = COLORS.dustyOlive
      } else {
        ctx.fillStyle = COLORS.chocolatePlum
      }
      ctx.fillRect(barX, barY, barW * hpPct, barH)

      // Mana bar - Neon Ice
      ctx.fillStyle = "rgba(86, 54, 53, 0.4)"
      ctx.fillRect(barX, barY + barH + 1, barW, 3)
      ctx.fillStyle = COLORS.neonIce
      ctx.fillRect(barX, barY + barH + 1, barW * (player.mana / player.max_mana), 3)

      // Name
      ctx.fillStyle = isLocal ? COLORS.neonIce : "rgba(120, 192, 145, 0.6)"
      ctx.font = isLocal ? "bold 10px monospace" : "10px monospace"
      ctx.textAlign = "center"
      ctx.fillText(isLocal ? "YOU" : player.id, player.x, barY - 4)
    }

    // Death dissolve effects
    this.deathEffects = this.deathEffects.filter(effect => {
      effect.particles = effect.particles.filter(p => p.life > 0)
      return effect.particles.length > 0
    })
    for (const effect of this.deathEffects) {
      for (const p of effect.particles) {
        const alpha = p.life / 28
        ctx.fillStyle = `rgba(129, 240, 229, ${alpha.toFixed(2)})`
        ctx.beginPath()
        ctx.arc(p.x, p.y, p.size * (1 - alpha * 0.3), 0, Math.PI * 2)
        ctx.fill()
        p.x += p.vx
        p.y += p.vy
        p.vx *= 0.96
        p.vy *= 0.96
        p.life--
      }
    }

    // Tick down hit flashes
    for (const id of Object.keys(this.hitFlashes)) {
      if (this.hitFlashes[id] > 0) this.hitFlashes[id]--
      else delete this.hitFlashes[id]
    }

    // Damage floaters
    this.damageFloaters = this.damageFloaters.filter(f => f.life > 0)
    for (const f of this.damageFloaters) {
      const alpha = Math.min(1, f.life / 20)
      if (f.outline) {
        // NPC damage to player: Chocolate Plum with white outline
        ctx.font = "bold 12px monospace"
        ctx.textAlign = "center"
        ctx.strokeStyle = `rgba(255, 255, 255, ${alpha.toFixed(2)})`
        ctx.lineWidth = 3
        ctx.strokeText(f.text, f.x, f.y)
        ctx.fillStyle = `rgba(86, 54, 53, ${alpha.toFixed(2)})`
        ctx.fillText(f.text, f.x, f.y)
      } else {
        // Player damage to NPC: Neon Ice
        ctx.fillStyle = COLORS.neonIce + Math.round(alpha * 255).toString(16).padStart(2, "0")
        ctx.font = "bold 12px monospace"
        ctx.textAlign = "center"
        ctx.fillText(f.text, f.x, f.y)
      }
      f.y -= 0.8
      f.life--
    }

    // Loot pickup floaters
    this.lootFloaters = this.lootFloaters.filter(f => f.life > 0)
    for (const f of this.lootFloaters) {
      const alpha = Math.min(1, f.life / 20)
      ctx.font = "bold 11px monospace"
      ctx.textAlign = "center"
      ctx.strokeStyle = `rgba(0, 0, 0, ${(alpha * 0.6).toFixed(2)})`
      ctx.lineWidth = 3
      ctx.strokeText(f.text, f.x, f.y)
      // Parse hex color to rgba
      const r = parseInt(f.color.slice(1, 3), 16)
      const g = parseInt(f.color.slice(3, 5), 16)
      const b = parseInt(f.color.slice(5, 7), 16)
      ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${alpha.toFixed(2)})`
      ctx.fillText(f.text, f.x, f.y)
      f.y -= 0.6
      f.life--
    }

    // Kill celebration flash
    if (this.killFlash && this.killFlash.life > 0) {
      const alpha = Math.min(1, this.killFlash.life / 15)
      ctx.save()
      ctx.fillStyle = `rgba(129, 240, 229, ${alpha.toFixed(2)})`
      ctx.font = "bold 20px monospace"
      ctx.textAlign = "center"
      ctx.fillText(this.killFlash.text, W / 2, 40)
      ctx.restore()
      this.killFlash.life--
    }

    // Ability bar hint - Dusty Olive
    ctx.fillStyle = COLORS.dustyOlive + "55"
    ctx.font = "11px monospace"
    ctx.textAlign = "center"
    ctx.fillText("[1] slash  [2] shield bash  [3] fireball  [4] ice lance  [5] arrow volley  [6] backstab", W / 2, H - 10)

    // --- Retro CRT effects ---

    // Scanlines (very faint)
    ctx.fillStyle = "rgba(0, 0, 0, 0.04)"
    for (let y = 0; y < H; y += 3) {
      ctx.fillRect(0, y, W, 1)
    }

    // Vignette (darken edges)
    const vigGrad = ctx.createRadialGradient(W / 2, H / 2, W * 0.3, W / 2, H / 2, W * 0.75)
    vigGrad.addColorStop(0, "rgba(0, 0, 0, 0)")
    vigGrad.addColorStop(1, "rgba(0, 0, 0, 0.35)")
    ctx.fillStyle = vigGrad
    ctx.fillRect(0, 0, W, H)

    ctx.restore() // end screen shake transform

    // Canvas border flash for ability cast (applied to DOM element)
    if (this.castFlash > 0) {
      this.canvas.style.borderColor = COLORS.neonIce
      this.canvas.style.boxShadow = `0 0 12px ${COLORS.neonIce}55`
      this.castFlash--
    } else {
      this.canvas.style.borderColor = ""
      this.canvas.style.boxShadow = ""
    }
  },

  // --- NPC color map: all monster colors in one place for easy swapping ---
  npcColors: {
    "skeleton_warrior": { fill: COLORS.ebony, stroke: "#8a8f85", aura: null },
    "goblin":           { fill: COLORS.dustyOlive, stroke: COLORS.mintLeaf, aura: null },
    "boss_ogre":        { fill: COLORS.neonIce, stroke: COLORS.chocolatePlum, aura: COLORS.neonIce },
    "ghost":            { fill: "#a5b4fc", stroke: "#818cf8", aura: null },
    "spider":           { fill: "#78716c", stroke: "#57534e", aura: null },
    "necromancer":      { fill: "#7c3aed", stroke: "#5b21b6", aura: "#4c1d95" },
    "slime":            { fill: COLORS.mintLeaf, stroke: COLORS.dustyOlive, aura: null },
  },

  // NPC base sizes
  npcSizes: {
    "boss_ogre": 20,
    "ghost": 14,
    "spider": 8,
    "necromancer": 14,
    "slime": 11,
    "goblin": 10,
    "skeleton_warrior": 12,
  },

  drawNpc(ctx, npc, t) {
    const c = this.npcColors[npc.template] || { fill: COLORS.ebony, stroke: COLORS.dustyOlive, aura: null }
    const baseSize = this.npcSizes[npc.template] || 12
    const flashing = this.hitFlashes[npc.id] && this.hitFlashes[npc.id] > 0

    // AI state tinting
    let alpha = 1.0
    let tintColor = null
    if (npc.ai_state === "chase") tintColor = "rgba(239,68,68,0.2)"
    else if (npc.ai_state === "flee") tintColor = "rgba(251,191,36,0.25)"
    else if (npc.ai_state === "idle" || npc.ai_state === "patrol") alpha = 0.85

    ctx.save()
    ctx.globalAlpha = alpha

    // If hit flashing, override colors
    const fc = flashing ? { fill: "#ffffff", stroke: "#dddddd", aura: null } : c

    // Dispatch to per-template draw
    switch (npc.template) {
      case "skeleton_warrior": this.drawSkeleton(ctx, npc, fc, baseSize, t); break
      case "goblin":           this.drawGoblin(ctx, npc, fc, baseSize, t); break
      case "boss_ogre":        this.drawBossOgre(ctx, npc, fc, baseSize, t); break
      case "ghost":            this.drawGhost(ctx, npc, fc, baseSize, t); break
      case "spider":           this.drawSpider(ctx, npc, fc, baseSize, t); break
      case "necromancer":      this.drawNecromancer(ctx, npc, fc, baseSize, t); break
      case "slime":            this.drawSlime(ctx, npc, fc, baseSize, t); break
      default:                 this.drawDefaultNpc(ctx, npc, fc, baseSize, t); break
    }

    // AI state tint overlay
    if (tintColor) {
      ctx.fillStyle = tintColor
      ctx.beginPath()
      ctx.arc(npc.x, npc.y, baseSize + 4, 0, Math.PI * 2)
      ctx.fill()
    }

    ctx.restore()

    // HP bar (always full alpha)
    const barW = baseSize * 2.5
    const barH = 4
    const barX = npc.x - barW / 2
    const barY = npc.y - baseSize - 10

    ctx.fillStyle = "rgba(86, 54, 53, 0.5)"
    ctx.fillRect(barX, barY, barW, barH)

    const hpPct = npc.hp / npc.max_hp
    if (hpPct > 0.5) {
      ctx.fillStyle = COLORS.mintLeaf
    } else if (hpPct > 0.25) {
      ctx.fillStyle = COLORS.dustyOlive
    } else {
      ctx.fillStyle = COLORS.chocolatePlum
    }
    ctx.fillRect(barX, barY, barW * hpPct, barH)

    // Name
    ctx.fillStyle = "rgba(129, 240, 229, 0.6)"
    ctx.font = "9px monospace"
    ctx.textAlign = "center"
    ctx.fillText(npc.template.replace(/_/g, " "), npc.x, barY - 3)
  },

  // --- Per-template NPC draw functions ---

  drawSkeleton(ctx, npc, c, size, _t) {
    const x = npc.x, y = npc.y
    // Shadow
    ctx.fillStyle = "rgba(0,0,0,0.3)"
    ctx.beginPath()
    ctx.ellipse(x, y + size + 2, size * 0.6, 3, 0, 0, Math.PI * 2)
    ctx.fill()
    // Body (rectangle torso)
    ctx.fillStyle = c.fill
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 2
    ctx.fillRect(x - size * 0.4, y - size * 0.2, size * 0.8, size * 1.2)
    ctx.strokeRect(x - size * 0.4, y - size * 0.2, size * 0.8, size * 1.2)
    // Head (circle on top)
    ctx.beginPath()
    ctx.arc(x, y - size * 0.5, size * 0.4, 0, Math.PI * 2)
    ctx.fill()
    ctx.stroke()
    // Eye sockets
    ctx.fillStyle = COLORS.chocolatePlum
    ctx.fillRect(x - 3, y - size * 0.55, 2, 2)
    ctx.fillRect(x + 1, y - size * 0.55, 2, 2)
  },

  drawGoblin(ctx, npc, c, size, t) {
    const jitter = Math.sin(t * 0.25) * 1.5
    const x = npc.x + jitter, y = npc.y
    // Shadow
    ctx.fillStyle = "rgba(0,0,0,0.3)"
    ctx.beginPath()
    ctx.ellipse(npc.x, y + size + 2, size * 0.6, 3, 0, 0, Math.PI * 2)
    ctx.fill()
    // Diamond body
    ctx.fillStyle = c.fill
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(x, y - size)
    ctx.lineTo(x + size * 0.7, y)
    ctx.lineTo(x, y + size * 0.8)
    ctx.lineTo(x - size * 0.7, y)
    ctx.closePath()
    ctx.fill()
    ctx.stroke()
    // Eyes
    ctx.fillStyle = COLORS.neonIce
    ctx.beginPath()
    ctx.arc(x - 2, y - size * 0.3, 1.5, 0, Math.PI * 2)
    ctx.arc(x + 2, y - size * 0.3, 1.5, 0, Math.PI * 2)
    ctx.fill()
  },

  drawBossOgre(ctx, npc, c, size, t) {
    const x = npc.x, y = npc.y
    // Pulsing glow
    const pulse = 0.6 + Math.sin(t * 0.08) * 0.4
    if (c.aura) {
      ctx.fillStyle = c.aura
      ctx.globalAlpha = pulse * 0.3
      ctx.beginPath()
      ctx.arc(x, y, size + 8, 0, Math.PI * 2)
      ctx.fill()
      ctx.globalAlpha = 1.0
    }
    // Shadow
    ctx.fillStyle = "rgba(0,0,0,0.3)"
    ctx.beginPath()
    ctx.ellipse(x, y + size + 2, size * 0.8, 4, 0, 0, Math.PI * 2)
    ctx.fill()
    // Large body circle
    ctx.fillStyle = c.fill
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 3
    ctx.beginPath()
    ctx.arc(x, y, size, 0, Math.PI * 2)
    ctx.fill()
    ctx.stroke()
    // Inner detail circle
    ctx.fillStyle = c.stroke
    ctx.beginPath()
    ctx.arc(x, y, size * 0.5, 0, Math.PI * 2)
    ctx.fill()
    // Eyes
    ctx.fillStyle = COLORS.chocolatePlum
    ctx.beginPath()
    ctx.arc(x - size * 0.3, y - size * 0.2, 3, 0, Math.PI * 2)
    ctx.arc(x + size * 0.3, y - size * 0.2, 3, 0, Math.PI * 2)
    ctx.fill()
  },

  drawGhost(ctx, npc, c, size, t) {
    const x = npc.x, y = npc.y
    // Oscillating alpha (0.5 to 0.8) - ghost is translucent
    const ghostAlpha = 0.5 + Math.sin(t * 0.1) * 0.15
    ctx.globalAlpha = ghostAlpha
    // No shadow for ghost (floating)
    // Wavy body
    ctx.fillStyle = c.fill
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 1.5
    ctx.beginPath()
    ctx.arc(x, y - size * 0.2, size, Math.PI, 0) // top dome
    // Wavy bottom
    const wave = Math.sin(t * 0.15) * 2
    ctx.lineTo(x + size, y + size * 0.6)
    ctx.quadraticCurveTo(x + size * 0.5, y + size * 0.4 + wave, x, y + size * 0.7)
    ctx.quadraticCurveTo(x - size * 0.5, y + size * 0.4 - wave, x - size, y + size * 0.6)
    ctx.closePath()
    ctx.fill()
    ctx.stroke()
    // Hollow eyes
    ctx.fillStyle = COLORS.chocolatePlum
    ctx.beginPath()
    ctx.arc(x - size * 0.3, y - size * 0.3, size * 0.2, 0, Math.PI * 2)
    ctx.arc(x + size * 0.3, y - size * 0.3, size * 0.2, 0, Math.PI * 2)
    ctx.fill()
    ctx.globalAlpha = 1.0
  },

  drawSpider(ctx, npc, c, size, t) {
    const x = npc.x, y = npc.y
    // Shadow
    ctx.fillStyle = "rgba(0,0,0,0.2)"
    ctx.beginPath()
    ctx.ellipse(x, y + size + 1, size * 0.8, 2, 0, 0, Math.PI * 2)
    ctx.fill()
    // Legs (4 pairs radiating from center)
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 1.5
    const legLen = size * 1.8
    const legWiggle = Math.sin(t * 0.3) * 3
    for (let i = 0; i < 4; i++) {
      const baseAngle = (i * Math.PI / 3) - Math.PI / 3
      // Left leg
      const lx = x + Math.cos(Math.PI + baseAngle) * legLen
      const ly = y + Math.sin(Math.PI + baseAngle) * legLen + (i % 2 === 0 ? legWiggle : -legWiggle)
      ctx.beginPath()
      ctx.moveTo(x, y)
      ctx.quadraticCurveTo(x + Math.cos(Math.PI + baseAngle) * size, y - size * 0.5, lx, ly)
      ctx.stroke()
      // Right leg
      const rx = x + Math.cos(baseAngle) * legLen
      const ry = y + Math.sin(baseAngle) * legLen + (i % 2 === 0 ? -legWiggle : legWiggle)
      ctx.beginPath()
      ctx.moveTo(x, y)
      ctx.quadraticCurveTo(x + Math.cos(baseAngle) * size, y - size * 0.5, rx, ry)
      ctx.stroke()
    }
    // Body (small oval)
    ctx.fillStyle = c.fill
    ctx.beginPath()
    ctx.ellipse(x, y, size, size * 0.7, 0, 0, Math.PI * 2)
    ctx.fill()
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 1
    ctx.stroke()
    // Eyes (two red dots)
    ctx.fillStyle = "#ef4444"
    ctx.beginPath()
    ctx.arc(x - 2, y - 2, 1.5, 0, Math.PI * 2)
    ctx.arc(x + 2, y - 2, 1.5, 0, Math.PI * 2)
    ctx.fill()
  },

  drawNecromancer(ctx, npc, c, size, t) {
    const x = npc.x, y = npc.y
    // Dark aura ring
    if (c.aura) {
      const auraSize = size + 10 + Math.sin(t * 0.06) * 3
      ctx.strokeStyle = c.aura
      ctx.lineWidth = 2
      ctx.globalAlpha = 0.4 + Math.sin(t * 0.08) * 0.15
      ctx.beginPath()
      ctx.arc(x, y, auraSize, 0, Math.PI * 2)
      ctx.stroke()
      ctx.globalAlpha = 1.0
    }
    // Shadow
    ctx.fillStyle = "rgba(0,0,0,0.3)"
    ctx.beginPath()
    ctx.ellipse(x, y + size + 2, size * 0.6, 3, 0, 0, Math.PI * 2)
    ctx.fill()
    // Hooded triangle body (robe)
    ctx.fillStyle = c.fill
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(x, y - size * 1.1)    // hood tip
    ctx.lineTo(x + size * 0.8, y + size * 0.8)
    ctx.lineTo(x - size * 0.8, y + size * 0.8)
    ctx.closePath()
    ctx.fill()
    ctx.stroke()
    // Hood face shadow
    ctx.fillStyle = COLORS.chocolatePlum
    ctx.beginPath()
    ctx.arc(x, y - size * 0.3, size * 0.35, 0, Math.PI * 2)
    ctx.fill()
    // Glowing eyes
    ctx.fillStyle = "#a855f7"
    ctx.beginPath()
    ctx.arc(x - 3, y - size * 0.35, 1.5, 0, Math.PI * 2)
    ctx.arc(x + 3, y - size * 0.35, 1.5, 0, Math.PI * 2)
    ctx.fill()
    // Staff line (right side)
    ctx.strokeStyle = "#a78bfa"
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(x + size * 0.6, y - size * 0.8)
    ctx.lineTo(x + size * 0.6, y + size)
    ctx.stroke()
    // Staff orb
    ctx.fillStyle = "#c084fc"
    ctx.beginPath()
    ctx.arc(x + size * 0.6, y - size * 0.8, 3, 0, Math.PI * 2)
    ctx.fill()
  },

  drawSlime(ctx, npc, c, size, t) {
    const x = npc.x, y = npc.y
    // Wobbly radius oscillation
    const wobble = size + Math.sin(t * 0.12) * 2
    const squash = 1.0 + Math.sin(t * 0.15) * 0.1
    // Shadow
    ctx.fillStyle = "rgba(0,0,0,0.25)"
    ctx.beginPath()
    ctx.ellipse(x, y + wobble + 1, wobble * 0.9, 3, 0, 0, Math.PI * 2)
    ctx.fill()
    // Blob body (squashed circle)
    ctx.fillStyle = c.fill
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.ellipse(x, y + (squash - 1) * size * 0.5, wobble, wobble * squash, 0, 0, Math.PI * 2)
    ctx.fill()
    ctx.stroke()
    // Glossy highlight
    ctx.fillStyle = "rgba(255,255,255,0.25)"
    ctx.beginPath()
    ctx.ellipse(x - size * 0.25, y - size * 0.25, size * 0.3, size * 0.2, -0.3, 0, Math.PI * 2)
    ctx.fill()
    // Eyes (simple dots)
    ctx.fillStyle = COLORS.chocolatePlum
    ctx.beginPath()
    ctx.arc(x - 3, y - 2, 2, 0, Math.PI * 2)
    ctx.arc(x + 3, y - 2, 2, 0, Math.PI * 2)
    ctx.fill()
  },

  drawDefaultNpc(ctx, npc, c, size, _t) {
    const x = npc.x, y = npc.y
    // Shadow
    ctx.fillStyle = "rgba(0,0,0,0.3)"
    ctx.beginPath()
    ctx.ellipse(x, y + size + 2, size * 0.8, 4, 0, 0, Math.PI * 2)
    ctx.fill()
    // Simple circle fallback
    ctx.fillStyle = c.fill
    ctx.strokeStyle = c.stroke
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.arc(x, y, size, 0, Math.PI * 2)
    ctx.fill()
    ctx.stroke()
  },
}


export default GameCanvas
