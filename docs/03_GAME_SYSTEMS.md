# Game Systems - Mechanics & Implementation

## Overview

This document details the core gameplay systems for the Gauntlet-style RPG, focusing on **slow, tactical combat** rather than twitch-based gameplay.

---

## 1. Game Loop & Tick System

### Main Game Loop (10 Hz)

```elixir
defmodule GameEngine.GameLoop do
  use GenServer
  
  @tick_rate 100  # milliseconds (10 Hz)
  
  def init(_) do
    schedule_tick()
    {:ok, %{tick_count: 0, last_tick: System.monotonic_time(:millisecond)}}
  end
  
  def handle_info(:tick, state) do
    start_time = System.monotonic_time(:millisecond)
    
    # === TICK OPERATIONS (in order) ===
    
    # 1. Update player positions (movement)
    GameEngine.Movement.update_all_players()
    
    # 2. Update NPC AI and positions
    GameEngine.AI.update_all_npcs()
    
    # 3. Process combat (auto-attacks, DoT effects)
    GameEngine.Combat.process_auto_attacks()
    GameEngine.Combat.process_effects()
    
    # 4. Check ability cooldowns
    GameEngine.Combat.update_cooldowns()
    
    # 5. Check loot pile expirations
    GameEngine.Loot.cleanup_expired()
    
    # 6. Spatial queries & collision detection
    GameEngine.Spatial.update_zones()
    
    # 7. Broadcast state to clients
    GameEngine.Broadcast.send_updates()
    
    # === PERFORMANCE TRACKING ===
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    if elapsed > @tick_rate do
      Logger.warn("Tick took #{elapsed}ms (> #{@tick_rate}ms target)")
    end
    
    schedule_tick()
    {:noreply, %{state | tick_count: state.tick_count + 1, last_tick: start_time}}
  end
  
  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_rate)
  end
end
```

---

## 2. Movement System

### Player Movement (WASD + Mouse)

**Design Goals:**
- Smooth 8-directional movement
- No stuttering or rubber-banding
- Collision with walls and NPCs
- Predictive client-side movement

```elixir
defmodule GameEngine.Movement do
  @movement_speed 150.0  # pixels per second
  @delta_time 0.1        # 100ms per tick
  
  def process_movement(character_id, input) do
    # input = %{up: bool, down: bool, left: bool, right: bool}
    
    # Get current position
    [{_, _, x, y, facing, _vx, _vy, zone_id, instance_id, _time}] = 
      :mnesia.dirty_read(:player_positions, character_id)
    
    # Calculate velocity from input
    {vx, vy} = calculate_velocity(input)
    
    # Apply movement
    new_x = x + (vx * @movement_speed * @delta_time)
    new_y = y + (vy * @movement_speed * @delta_time)
    
    # Collision detection
    {final_x, final_y} = check_collisions(new_x, new_y, zone_id, instance_id)
    
    # Update facing direction if moving
    new_facing = if vx != 0 or vy != 0 do
      :math.atan2(vy, vx)
    else
      facing
    end
    
    # Write to Mnesia
    :mnesia.dirty_write({
      :player_positions,
      character_id,
      final_x,
      final_y,
      new_facing,
      vx,
      vy,
      zone_id,
      instance_id,
      System.monotonic_time(:millisecond)
    })
    
    # Return for broadcast
    %{
      character_id: character_id,
      x: final_x,
      y: final_y,
      facing: new_facing
    }
  end
  
  defp calculate_velocity(input) do
    vx = cond do
      input.left -> -1.0
      input.right -> 1.0
      true -> 0.0
    end
    
    vy = cond do
      input.up -> -1.0
      input.down -> 1.0
      true -> 0.0
    end
    
    # Normalize diagonal movement
    if vx != 0 and vy != 0 do
      magnitude = :math.sqrt(vx * vx + vy * vy)
      {vx / magnitude, vy / magnitude}
    else
      {vx, vy}
    end
  end
  
  defp check_collisions(x, y, zone_id, instance_id) do
    # 1. Check world bounds
    {x, y} = clamp_to_bounds(x, y, zone_id)
    
    # 2. Check wall collisions (from dungeon template)
    {x, y} = check_walls(x, y, zone_id)
    
    # 3. Check NPC collisions (soft collision, push away)
    {x, y} = check_npc_collisions(x, y, instance_id)
    
    {x, y}
  end
  
  # Update all players each tick
  def update_all_players do
    # Only process players with active movement
    :mnesia.dirty_match_object({
      :player_positions,
      :_,  # character_id
      :_,  # x
      :_,  # y
      :_,  # facing
      :"$1",  # vx (capture)
      :"$2",  # vy (capture)
      :_,  # zone_id
      :_,  # instance_id
      :_   # time
    })
    |> Enum.filter(fn {_, _, _, _, _, vx, vy, _, _, _} ->
      vx != 0.0 or vy != 0.0  # Player is moving
    end)
    |> Enum.each(fn {_, char_id, _, _, _, _, _, _, _, _} ->
      # Continue movement in last direction
      # (client sends input updates separately)
    end)
  end
end
```

---

## 3. Combat System (Slow-Paced)

### Design Philosophy

**NOT like:**
- Twitch shooters (Overwatch, Valorant)
- Fighting games (frame-perfect combos)
- MOBAs (last-hitting, kiting)

**More like:**
- Classic Gauntlet (deliberate actions)
- Early Diablo (click to attack, use skills)
- Path of Exile (cooldown-based builds)

### Combat Parameters

```elixir
defmodule GameEngine.Combat.Config do
  @auto_attack_cooldown 1000   # 1 attack per second
  @ability_global_cd 500       # 0.5s between any abilities
  
  # Ability cooldowns (class-specific)
  @ability_cooldowns %{
    # Warrior
    "slash" => 2000,         # 2s
    "shield_bash" => 5000,   # 5s
    "berserker_rage" => 30000, # 30s
    
    # Mage
    "fireball" => 3000,
    "ice_lance" => 2000,
    "teleport" => 8000,
    
    # Ranger
    "arrow_volley" => 4000,
    "trap" => 6000,
    "dash" => 5000,
    
    # Rogue
    "backstab" => 3000,
    "smoke_bomb" => 10000,
    "poison_dagger" => 4000
  }
  
  def ability_cooldown(ability_id), do: @ability_cooldowns[ability_id]
end
```

### Ability Cast Flow

```elixir
defmodule GameEngine.Combat do
  def cast_ability(character_id, ability_id, target_x, target_y) do
    with :ok <- check_cooldown(character_id, ability_id),
         :ok <- check_mana_cost(character_id, ability_id),
         :ok <- check_range(character_id, target_x, target_y, ability_id),
         :ok <- check_line_of_sight(character_id, target_x, target_y) do
      
      # Cast successful!
      execute_ability(character_id, ability_id, target_x, target_y)
    else
      {:error, :on_cooldown, remaining_ms} ->
        {:error, :on_cooldown, remaining_ms}
      
      {:error, :not_enough_mana} ->
        {:error, :not_enough_mana}
      
      {:error, :out_of_range} ->
        {:error, :out_of_range}
    end
  end
  
  defp check_cooldown(character_id, ability_id) do
    now = System.monotonic_time(:millisecond)
    
    case :mnesia.dirty_read(:player_cooldowns, {character_id, ability_id}) do
      [{_, _, expires_at, _}] when expires_at > now ->
        {:error, :on_cooldown, expires_at - now}
      
      _ ->
        :ok
    end
  end
  
  defp execute_ability(character_id, ability_id, target_x, target_y) do
    # 1. Start cooldown
    start_cooldown(character_id, ability_id)
    
    # 2. Consume mana
    consume_mana(character_id, ability_id)
    
    # 3. Apply ability effect
    ability_def = GameEngine.Abilities.get_definition(ability_id)
    
    case ability_def.type do
      :projectile ->
        spawn_projectile(character_id, target_x, target_y, ability_def)
      
      :instant_damage ->
        apply_instant_damage(character_id, target_x, target_y, ability_def)
      
      :aoe ->
        apply_aoe_damage(character_id, target_x, target_y, ability_def)
      
      :buff ->
        apply_buff(character_id, ability_def)
    end
    
    # 4. Broadcast to clients
    broadcast_ability_cast(character_id, ability_id, target_x, target_y)
    
    :ok
  end
  
  defp start_cooldown(character_id, ability_id) do
    cooldown_ms = GameEngine.Combat.Config.ability_cooldown(ability_id)
    expires_at = System.monotonic_time(:millisecond) + cooldown_ms
    
    :mnesia.dirty_write({
      :player_cooldowns,
      {character_id, ability_id},
      expires_at,
      cooldown_ms
    })
  end
end
```

### Auto-Attack System

```elixir
defmodule GameEngine.Combat.AutoAttack do
  @attack_range 50.0  # pixels
  @attack_cooldown 1000  # 1 second
  
  def process_auto_attacks do
    # Find all players with valid targets
    :mnesia.dirty_match_object({
      :player_auto_attack_state,
      :_,  # character_id
      :"$1",  # target_id (capture)
      :"$2"   # last_attack_time (capture)
    })
    |> Enum.filter(fn {_, _, target_id, _} ->
      target_id != nil
    end)
    |> Enum.each(&try_auto_attack/1)
  end
  
  defp try_auto_attack({_, character_id, target_id, last_attack}) do
    now = System.monotonic_time(:millisecond)
    
    if now - last_attack >= @attack_cooldown do
      # Check if target is in range
      if in_range?(character_id, target_id) do
        execute_auto_attack(character_id, target_id)
        
        # Update last attack time
        :mnesia.dirty_write({
          :player_auto_attack_state,
          character_id,
          target_id,
          now
        })
      end
    end
  end
  
  defp execute_auto_attack(attacker_id, target_id) do
    # Get attacker stats
    attacker_stats = load_character_stats(attacker_id)
    
    # Calculate damage
    base_damage = attacker_stats.strength * 2
    damage = calculate_final_damage(base_damage, target_id)
    
    # Apply damage to target
    apply_damage(target_id, damage)
    
    # Record combat event
    record_combat_event(%{
      type: :auto_attack,
      attacker: attacker_id,
      target: target_id,
      damage: damage
    })
  end
end
```

### Damage Calculation

```elixir
defmodule GameEngine.Combat.Damage do
  def calculate_damage(attacker_stats, target_stats, ability_def) do
    # Base damage from ability
    base = ability_def.base_damage
    
    # Stat scaling
    scaled = case ability_def.scaling_stat do
      :strength -> base + (attacker_stats.strength * ability_def.scaling_factor)
      :intelligence -> base + (attacker_stats.intelligence * ability_def.scaling_factor)
      :agility -> base + (attacker_stats.agility * ability_def.scaling_factor)
    end
    
    # Apply armor reduction
    armor_mitigation = target_stats.armor / (target_stats.armor + 100)
    after_armor = scaled * (1 - armor_mitigation)
    
    # Random variance ±10%
    variance = 0.9 + (:rand.uniform() * 0.2)
    final = after_armor * variance
    
    # Critical hit (15% chance, 2x damage)
    final = if :rand.uniform() < 0.15 do
      final * 2.0
    else
      final
    end
    
    trunc(final)
  end
  
  def apply_damage(target_id, damage) do
    # Update health in Mnesia (for NPCs)
    case :mnesia.dirty_read(:npc_state, target_id) do
      [{_, _, template_id, instance_id, x, y, health, max_health, ai_state, _, _, spawn}] ->
        new_health = max(0, health - damage)
        
        :mnesia.dirty_write({
          :npc_state,
          target_id,
          template_id,
          instance_id,
          x, y,
          new_health,
          max_health,
          ai_state,
          nil,
          System.monotonic_time(:millisecond),
          spawn
        })
        
        # Check for death
        if new_health == 0 do
          handle_npc_death(target_id)
        end
      
      [] ->
        # Must be a player - update in SurrealDB
        update_player_health(target_id, damage)
    end
  end
end
```

---

## 4. AI System (NPC Behavior)

### AI State Machine

```elixir
defmodule GameEngine.AI.Behavior do
  @aggro_range 200.0
  @chase_range 400.0
  @attack_range 50.0
  
  def update_npc(npc_id) do
    [{_, _, template_id, instance_id, x, y, health, max_health, 
      ai_state, target_id, last_attack, spawn_point}] = 
      :mnesia.dirty_read(:npc_state, npc_id)
    
    # State machine
    new_state = case ai_state do
      :idle ->
        check_for_aggro(npc_id, x, y, instance_id)
      
      :patrol ->
        patrol_behavior(npc_id, x, y, spawn_point)
      
      :chase ->
        chase_behavior(npc_id, target_id, x, y)
      
      :attack ->
        attack_behavior(npc_id, target_id, x, y, last_attack)
      
      :flee ->
        flee_behavior(npc_id, x, y, spawn_point)
      
      :dead ->
        :dead
    end
    
    # Update state
    :mnesia.dirty_write({
      :npc_state,
      npc_id,
      template_id,
      instance_id,
      x, y,
      health,
      max_health,
      new_state,
      target_id,
      last_attack,
      spawn_point
    })
  end
  
  defp check_for_aggro(npc_id, x, y, instance_id) do
    # Find nearest player in aggro range
    case find_nearest_player(x, y, instance_id, @aggro_range) do
      nil -> :idle
      player_id -> 
        # Aggro!
        {:chase, player_id}
    end
  end
  
  defp chase_behavior(npc_id, target_id, x, y) do
    # Get target position
    case get_player_position(target_id) do
      nil ->
        :idle  # Target despawned
      
      {target_x, target_y} ->
        distance = calculate_distance(x, y, target_x, target_y)
        
        cond do
          distance <= @attack_range ->
            {:attack, target_id}
          
          distance > @chase_range ->
            :idle  # Lost aggro
          
          true ->
            # Move toward target
            move_toward(npc_id, target_x, target_y)
            {:chase, target_id}
        end
    end
  end
  
  defp attack_behavior(npc_id, target_id, x, y, last_attack) do
    now = System.monotonic_time(:millisecond)
    
    # Attack cooldown = 1.5 seconds
    if now - last_attack >= 1500 do
      execute_npc_attack(npc_id, target_id)
    end
    
    # Check if target is still in range
    case get_player_position(target_id) do
      nil ->
        :idle
      
      {target_x, target_y} ->
        distance = calculate_distance(x, y, target_x, target_y)
        
        if distance <= @attack_range do
          {:attack, target_id}
        else
          {:chase, target_id}
        end
    end
  end
  
  defp move_toward(npc_id, target_x, target_y) do
    [{_, _, _, instance_id, x, y, _, _, _, _, _, _}] = 
      :mnesia.dirty_read(:npc_state, npc_id)
    
    # Calculate direction
    dx = target_x - x
    dy = target_y - y
    distance = :math.sqrt(dx * dx + dy * dy)
    
    # Normalize and apply speed
    speed = 80.0  # NPC movement speed (pixels/sec)
    delta_time = 0.1  # 100ms tick
    
    new_x = x + (dx / distance) * speed * delta_time
    new_y = y + (dy / distance) * speed * delta_time
    
    # Update position (simplified, no collision for now)
    :mnesia.dirty_update_counter(:npc_state, npc_id, [
      {3, new_x},  # x position
      {4, new_y}   # y position
    ])
  end
end
```

### AI Behaviors by Enemy Type

```elixir
defmodule GameEngine.AI.Templates do
  def get_behavior(:goblin) do
    %{
      aggro_range: 150,
      chase_range: 300,
      attack_range: 40,
      move_speed: 100,
      attack_cooldown: 1500,
      flees_at_health: 0.2,  # Flee at 20% HP
      patrol: true
    }
  end
  
  def get_behavior(:skeleton_warrior) do
    %{
      aggro_range: 200,
      chase_range: 500,
      attack_range: 50,
      move_speed: 80,
      attack_cooldown: 1200,
      flees_at_health: 0.0,  # Never flees
      patrol: false  # Stationary guard
    }
  end
  
  def get_behavior(:boss_ogre) do
    %{
      aggro_range: 300,
      chase_range: 999,  # Never loses aggro
      attack_range: 80,
      move_speed: 60,
      attack_cooldown: 2000,
      flees_at_health: 0.0,
      special_abilities: [:ground_slam, :roar],
      ability_cooldowns: %{
        ground_slam: 8000,
        roar: 15000
      }
    }
  end
end
```

---

## 5. Loot System

### Loot Generation

```elixir
defmodule GameEngine.Loot do
  def generate_loot(npc_template_id, killer_id) do
    loot_table = get_loot_table(npc_template_id)
    
    # Roll for each item in loot table
    items = Enum.flat_map(loot_table.items, fn item_config ->
      if :rand.uniform() < item_config.drop_chance do
        quantity = :rand.uniform(item_config.max_quantity)
        [%{item_id: item_config.item_id, quantity: quantity}]
      else
        []
      end
    end)
    
    # Roll for gold
    gold = if :rand.uniform() < loot_table.gold_chance do
      :rand.uniform(loot_table.max_gold)
    else
      0
    end
    
    %{items: items, gold: gold}
  end
  
  def spawn_loot_pile(instance_id, x, y, loot) do
    loot_id = generate_loot_id()
    now = System.monotonic_time(:millisecond)
    
    :mnesia.dirty_write({
      :loot_piles,
      loot_id,
      instance_id,
      x, y,
      loot.items,
      loot.gold,
      now,
      now + 60_000,  # Expires in 60 seconds
      nil  # Not reserved
    })
    
    # Broadcast to players
    broadcast_loot_spawn(instance_id, loot_id, x, y)
    
    loot_id
  end
  
  def pickup_loot(character_id, loot_id) do
    :mnesia.transaction(fn ->
      case :mnesia.read({:loot_piles, loot_id}) do
        [] ->
          {:error, :not_found}
        
        [{_, _, instance_id, x, y, items, gold, _, _, reserved_by}] ->
          cond do
            reserved_by != nil and reserved_by != character_id ->
              {:error, :reserved}
            
            true ->
              # Add to inventory (write to SurrealDB)
              add_items_to_inventory(character_id, items)
              add_gold(character_id, gold)
              
              # Remove loot pile
              :mnesia.delete({:loot_piles, loot_id})
              
              {:ok, %{items: items, gold: gold}}
          end
      end
    end)
  end
  
  # Cleanup expired loot
  def cleanup_expired do
    now = System.monotonic_time(:millisecond)
    
    :mnesia.dirty_match_object({
      :loot_piles,
      :"$1",  # loot_id
      :_,     # instance_id
      :_,     # x
      :_,     # y
      :_,     # items
      :_,     # gold
      :_,     # spawned_at
      :"$2",  # expires_at
      :_      # reserved_by
    })
    |> Enum.filter(fn {_, _, _, _, _, _, _, _, expires_at, _} ->
      expires_at < now
    end)
    |> Enum.each(fn {_, loot_id, _, _, _, _, _, _, _, _} ->
      :mnesia.dirty_delete(:loot_piles, loot_id)
    end)
  end
end
```

---

## 6. Party System

### Party Formation

```elixir
defmodule GameEngine.Party do
  @max_party_size 8
  
  def create_party(leader_id) do
    party_id = generate_party_id()
    
    :mnesia.transaction(fn ->
      :mnesia.write({
        :party_state,
        party_id,
        leader_id,
        [leader_id],
        @max_party_size,
        :free_for_all,  # Loot mode
        nil,  # No instance yet
        DateTime.utc_now()
      })
    end)
    
    {:ok, party_id}
  end
  
  def invite_to_party(party_id, inviter_id, invitee_id) do
    :mnesia.transaction(fn ->
      case :mnesia.read({:party_state, party_id}) do
        [] ->
          {:error, :party_not_found}
        
        [{_, _, leader_id, members, max_size, _, _, _}] ->
          cond do
            leader_id != inviter_id ->
              {:error, :not_leader}
            
            length(members) >= max_size ->
              {:error, :party_full}
            
            invitee_id in members ->
              {:error, :already_in_party}
            
            true ->
              # Send invitation
              send_party_invite(invitee_id, party_id, inviter_id)
              :ok
          end
      end
    end)
  end
  
  def accept_party_invite(character_id, party_id) do
    :mnesia.transaction(fn ->
      case :mnesia.read({:party_state, party_id}) do
        [] ->
          {:error, :party_not_found}
        
        [{_, _, leader_id, members, max_size, loot_mode, instance, created}] ->
          if length(members) < max_size do
            new_members = [character_id | members]
            
            :mnesia.write({
              :party_state,
              party_id,
              leader_id,
              new_members,
              max_size,
              loot_mode,
              instance,
              created
            })
            
            # Broadcast to party
            broadcast_party_update(party_id, {:member_joined, character_id})
            
            :ok
          else
            {:error, :party_full}
          end
      end
    end)
  end
end
```

### Party Loot Distribution

```elixir
defmodule GameEngine.Party.Loot do
  def determine_loot_recipient(party_id, loot_id) do
    [{_, _, leader_id, members, _, loot_mode, _, _}] = 
      :mnesia.dirty_read(:party_state, party_id)
    
    case loot_mode do
      :free_for_all ->
        # First to click gets it
        nil
      
      :round_robin ->
        # Cycle through party members
        get_next_round_robin(party_id, members)
      
      :master_looter ->
        # Only leader can distribute
        leader_id
    end
  end
  
  defp get_next_round_robin(party_id, members) do
    # Get last recipient index
    last_index = case :mnesia.dirty_read(:party_loot_index, party_id) do
      [{_, _, index}] -> index
      [] -> 0
    end
    
    # Get next member
    next_index = rem(last_index + 1, length(members))
    next_member = Enum.at(members, next_index)
    
    # Update index
    :mnesia.dirty_write({:party_loot_index, party_id, next_index})
    
    next_member
  end
end
```

---

## 7. Dungeon Instancing

### Instance Creation

```elixir
defmodule GameEngine.Dungeon do
  def create_instance(dungeon_template_id, party_id, difficulty) do
    instance_id = generate_instance_id()
    
    # Load dungeon template from SurrealDB
    {:ok, [template]} = SurrealDB.query("""
      SELECT * FROM dungeon_template WHERE dungeon_id = $template_id
    """, %{template_id: dungeon_template_id})
    
    # Get party members
    [{_, _, _leader, members, _, _, _, _}] = 
      :mnesia.dirty_read(:party_state, party_id)
    
    # Create instance in Mnesia
    :mnesia.transaction(fn ->
      :mnesia.write({
        :dungeon_instances,
        instance_id,
        dungeon_template_id,
        party_id,
        members,
        DateTime.utc_now(),
        difficulty,
        :active,
        false,  # Boss not defeated
        []      # No loot spawned yet
      })
      
      # Spawn NPCs
      spawn_npcs(instance_id, template.map_data.npc_spawns, difficulty)
    end)
    
    {:ok, instance_id}
  end
  
  defp spawn_npcs(instance_id, npc_spawns, difficulty) do
    Enum.each(npc_spawns, fn spawn_def ->
      npc_id = generate_npc_id()
      
      # Apply difficulty scaling
      health_multiplier = case difficulty do
        :normal -> 1.0
        :hard -> 1.5
        :nightmare -> 2.5
      end
      
      max_health = trunc(spawn_def.base_health * health_multiplier)
      
      :mnesia.write({
        :npc_state,
        npc_id,
        spawn_def.template_id,
        instance_id,
        spawn_def.x,
        spawn_def.y,
        max_health,
        max_health,
        :idle,
        nil,  # No target
        0,    # Last attack
        {spawn_def.x, spawn_def.y}  # Spawn point
      })
    end)
  end
  
  def cleanup_instance(instance_id) do
    :mnesia.transaction(fn ->
      # Delete instance
      :mnesia.delete({:dungeon_instances, instance_id})
      
      # Delete all NPCs
      :mnesia.match_delete({
        :npc_state,
        :_,  # npc_id
        :_,  # template_id
        instance_id,  # This instance
        :_, :_, :_, :_, :_, :_, :_, :_
      })
      
      # Delete all loot piles
      :mnesia.match_delete({
        :loot_piles,
        :_,  # loot_id
        instance_id,  # This instance
        :_, :_, :_, :_, :_, :_, :_
      })
    end)
  end
end
```

---

## Performance Considerations

### Optimization Strategies

1. **Spatial Partitioning**
   - Divide zones into grid cells
   - Only check collisions within same cell
   - Update cell membership each tick

2. **Dirty Reads**
   - Use `mnesia:dirty_*` for most reads
   - Reserve transactions for critical operations

3. **Batch Updates**
   - Collect position updates
   - Broadcast in single message per client

4. **AI Optimization**
   - Only update NPCs near players
   - Sleep distant NPCs
   - Update bosses every tick, minions every 2-3 ticks

5. **Event Pruning**
   - Combat events expire after 10 seconds
   - Auto-cleanup via scheduled task

---

## Next: API Reference

See **API_REFERENCE.md** for detailed module documentation and usage examples.
