alias SlowArena.SurrealDB

# Helper to convert a map to SurrealDB SET clause values
map_to_set = fn map ->
  Enum.map_join(map, ", ", fn {k, v} -> "#{k} = #{Jason.encode!(v)}" end)
end

IO.puts("=== SurrealDB Schema & Seed ===")

# -- Namespace / Database --
SurrealDB.query!("USE NS slow_arena DB game")

# ============================================================
# 1. accounts
# ============================================================
SurrealDB.query!("""
DEFINE TABLE IF NOT EXISTS accounts SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS username      ON accounts TYPE string;
DEFINE FIELD IF NOT EXISTS password_hash  ON accounts TYPE string;
DEFINE FIELD IF NOT EXISTS email          ON accounts TYPE option<string>;
DEFINE FIELD IF NOT EXISTS created_at     ON accounts TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS last_login     ON accounts TYPE option<datetime>;
DEFINE INDEX IF NOT EXISTS idx_username   ON accounts FIELDS username UNIQUE;
""")
IO.puts("✓ accounts")

# ============================================================
# 2. characters
# ============================================================
SurrealDB.query!("""
DEFINE TABLE IF NOT EXISTS characters SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS account       ON characters TYPE option<record<accounts>>;
DEFINE FIELD IF NOT EXISTS name          ON characters TYPE string;
DEFINE FIELD IF NOT EXISTS class         ON characters TYPE string
  ASSERT $value IN ["warrior", "mage", "ranger", "rogue"];
DEFINE FIELD IF NOT EXISTS level         ON characters TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS experience    ON characters TYPE int DEFAULT 0;
DEFINE FIELD IF NOT EXISTS gold          ON characters TYPE int DEFAULT 0;
DEFINE FIELD IF NOT EXISTS stats         ON characters TYPE object;
DEFINE FIELD IF NOT EXISTS stats.max_hp  ON characters TYPE int;
DEFINE FIELD IF NOT EXISTS stats.max_mana ON characters TYPE int;
DEFINE FIELD IF NOT EXISTS stats.str     ON characters TYPE int;
DEFINE FIELD IF NOT EXISTS stats.int     ON characters TYPE int;
DEFINE FIELD IF NOT EXISTS stats.agi     ON characters TYPE int;
DEFINE FIELD IF NOT EXISTS stats.armor   ON characters TYPE int;
DEFINE FIELD IF NOT EXISTS position      ON characters TYPE object;
DEFINE FIELD IF NOT EXISTS position.x    ON characters TYPE float DEFAULT 50.0;
DEFINE FIELD IF NOT EXISTS position.y    ON characters TYPE float DEFAULT 300.0;
DEFINE FIELD IF NOT EXISTS position.zone ON characters TYPE string DEFAULT "lobby";
DEFINE FIELD IF NOT EXISTS position.facing ON characters TYPE string DEFAULT "right";
DEFINE FIELD IF NOT EXISTS created_at    ON characters TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS last_played   ON characters TYPE option<datetime>;
DEFINE INDEX IF NOT EXISTS idx_char_name    ON characters FIELDS name UNIQUE;
DEFINE INDEX IF NOT EXISTS idx_char_account ON characters FIELDS account;
""")
IO.puts("✓ characters")

# ============================================================
# 3. item_definitions
# ============================================================
SurrealDB.query!("""
DEFINE TABLE IF NOT EXISTS item_definitions SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS item_id          ON item_definitions TYPE string;
DEFINE FIELD IF NOT EXISTS name             ON item_definitions TYPE string;
DEFINE FIELD IF NOT EXISTS description      ON item_definitions TYPE string;
DEFINE FIELD IF NOT EXISTS type             ON item_definitions TYPE string
  ASSERT $value IN ["weapon", "armor", "accessory", "consumable", "material"];
DEFINE FIELD IF NOT EXISTS rarity           ON item_definitions TYPE string
  ASSERT $value IN ["common", "uncommon", "rare", "epic", "legendary"];
DEFINE FIELD IF NOT EXISTS level_requirement ON item_definitions TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS slot             ON item_definitions TYPE option<string>;
DEFINE FIELD IF NOT EXISTS stats            ON item_definitions FLEXIBLE TYPE option<object>;
DEFINE FIELD IF NOT EXISTS stack_size       ON item_definitions TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS vendor_price     ON item_definitions TYPE int DEFAULT 0;
DEFINE INDEX IF NOT EXISTS idx_item_id      ON item_definitions FIELDS item_id UNIQUE;
""")
IO.puts("✓ item_definitions")

# ============================================================
# 4. inventory
# ============================================================
SurrealDB.query!("""
DEFINE TABLE IF NOT EXISTS inventory SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS character   ON inventory TYPE record<characters>;
DEFINE FIELD IF NOT EXISTS item        ON inventory TYPE record<item_definitions>;
DEFINE FIELD IF NOT EXISTS quantity    ON inventory TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS equipped    ON inventory TYPE bool DEFAULT false;
DEFINE FIELD IF NOT EXISTS acquired_at ON inventory TYPE datetime DEFAULT time::now();
DEFINE INDEX IF NOT EXISTS idx_char_item ON inventory FIELDS character, item UNIQUE;
""")
IO.puts("✓ inventory")

# ============================================================
# 5. dungeon_templates
# ============================================================
SurrealDB.query!("""
DEFINE TABLE IF NOT EXISTS dungeon_templates SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS template_id  ON dungeon_templates TYPE string;
DEFINE FIELD IF NOT EXISTS name         ON dungeon_templates TYPE string;
DEFINE FIELD IF NOT EXISTS description  ON dungeon_templates TYPE string;
DEFINE FIELD IF NOT EXISTS min_level    ON dungeon_templates TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS max_level    ON dungeon_templates TYPE int DEFAULT 99;
DEFINE FIELD IF NOT EXISTS difficulty   ON dungeon_templates FLEXIBLE TYPE object;
DEFINE FIELD IF NOT EXISTS npc_spawns   ON dungeon_templates TYPE array;
DEFINE FIELD IF NOT EXISTS npc_spawns.*  ON dungeon_templates FLEXIBLE TYPE object;
DEFINE FIELD IF NOT EXISTS loot_tables  ON dungeon_templates TYPE array;
DEFINE FIELD IF NOT EXISTS loot_tables.* ON dungeon_templates FLEXIBLE TYPE object;
DEFINE FIELD IF NOT EXISTS map          ON dungeon_templates TYPE object;
DEFINE FIELD IF NOT EXISTS map.width    ON dungeon_templates TYPE int;
DEFINE FIELD IF NOT EXISTS map.height   ON dungeon_templates TYPE int;
DEFINE INDEX IF NOT EXISTS idx_template_id ON dungeon_templates FIELDS template_id UNIQUE;
""")
IO.puts("✓ dungeon_templates")

# ============================================================
# 6. run_history
# ============================================================
SurrealDB.query!("""
DEFINE TABLE IF NOT EXISTS run_history SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS character      ON run_history TYPE record<characters>;
DEFINE FIELD IF NOT EXISTS dungeon        ON run_history TYPE record<dungeon_templates>;
DEFINE FIELD IF NOT EXISTS party_members  ON run_history TYPE array;
DEFINE FIELD IF NOT EXISTS party_members.* ON run_history TYPE string;
DEFINE FIELD IF NOT EXISTS started_at     ON run_history TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS completed_at   ON run_history TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS duration_seconds ON run_history TYPE option<int>;
DEFINE FIELD IF NOT EXISTS result         ON run_history TYPE string
  ASSERT $value IN ["completed", "failed", "abandoned"];
DEFINE FIELD IF NOT EXISTS metrics        ON run_history FLEXIBLE TYPE object;
DEFINE FIELD IF NOT EXISTS rewards        ON run_history FLEXIBLE TYPE object;
""")
IO.puts("✓ run_history")

# ============================================================
# Seed: item_definitions
# ============================================================
items = [
  %{item_id: "health_potion", name: "Health Potion", description: "Restores 50 HP",
    type: "consumable", rarity: "common", stack_size: 20, vendor_price: 10},
  %{item_id: "goblin_ear", name: "Goblin Ear", description: "Trophy from a slain goblin",
    type: "material", rarity: "common", stack_size: 50, vendor_price: 2},
  %{item_id: "bone_fragment", name: "Bone Fragment", description: "A shard of enchanted bone",
    type: "material", rarity: "common", stack_size: 50, vendor_price: 3},
  %{item_id: "rusty_sword", name: "Rusty Sword", description: "A battered but serviceable blade",
    type: "weapon", rarity: "common", slot: "weapon", stack_size: 1, vendor_price: 15,
    stats: %{damage: 8, str: 2}},
  %{item_id: "ogre_club", name: "Ogre Club", description: "Massive club wielded by ogre bosses",
    type: "weapon", rarity: "rare", slot: "weapon", stack_size: 1, vendor_price: 80,
    stats: %{damage: 22, str: 5}},
  %{item_id: "rare_gem", name: "Rare Gem", description: "A glittering gemstone of great value",
    type: "material", rarity: "rare", stack_size: 10, vendor_price: 50},
  %{item_id: "ectoplasm", name: "Ectoplasm", description: "Spectral residue from a ghost",
    type: "material", rarity: "uncommon", stack_size: 30, vendor_price: 8},
  %{item_id: "spirit_shard", name: "Spirit Shard", description: "Crystallized spiritual energy",
    type: "material", rarity: "rare", stack_size: 10, vendor_price: 35},
  %{item_id: "spider_silk", name: "Spider Silk", description: "Strong, sticky webbing",
    type: "material", rarity: "common", stack_size: 50, vendor_price: 4},
  %{item_id: "venom_sac", name: "Venom Sac", description: "Potent spider venom gland",
    type: "material", rarity: "uncommon", stack_size: 20, vendor_price: 12},
  %{item_id: "dark_tome", name: "Dark Tome", description: "A book of forbidden necromantic knowledge",
    type: "accessory", rarity: "epic", slot: "accessory", stack_size: 1, vendor_price: 100,
    stats: %{int: 8, mana: 20}},
  %{item_id: "bone_staff", name: "Bone Staff", description: "Staff carved from the spine of a lich",
    type: "weapon", rarity: "epic", slot: "weapon", stack_size: 1, vendor_price: 120,
    stats: %{damage: 18, int: 10}},
  %{item_id: "slime_gel", name: "Slime Gel", description: "Gelatinous residue, surprisingly useful",
    type: "material", rarity: "common", stack_size: 50, vendor_price: 1}
]

Enum.each(items, fn item ->
  SurrealDB.query!("UPSERT item_definitions SET #{map_to_set.(item)} WHERE item_id = '#{item.item_id}'")
end)
IO.puts("✓ seeded #{length(items)} item_definitions")

# ============================================================
# Seed: dungeon_templates
# ============================================================
dungeons = [
  %{
    template_id: "crypt_of_bones",
    name: "Crypt of Bones",
    description: "A crumbling crypt overrun with undead and a fearsome ogre guardian.",
    min_level: 1, max_level: 10,
    difficulty: %{hp_mult: 1.0, damage_mult: 1.0, xp_mult: 1.0, loot_mult: 1.0},
    npc_spawns: [
      %{template_id: "skeleton_warrior", x: 200, y: 150, base_health: 50},
      %{template_id: "skeleton_warrior", x: 400, y: 300, base_health: 50},
      %{template_id: "skeleton_warrior", x: 600, y: 200, base_health: 50},
      %{template_id: "goblin", x: 300, y: 400, base_health: 30},
      %{template_id: "goblin", x: 500, y: 450, base_health: 30},
      %{template_id: "boss_ogre", x: 700, y: 500, base_health: 200}
    ],
    loot_tables: [
      %{npc: "skeleton_warrior", gold_chance: 0.6, max_gold: 25,
        items: [%{item_id: "bone_fragment", drop_chance: 0.4, max_qty: 3},
                %{item_id: "rusty_sword", drop_chance: 0.1, max_qty: 1}]},
      %{npc: "goblin", gold_chance: 0.8, max_gold: 15,
        items: [%{item_id: "health_potion", drop_chance: 0.3, max_qty: 2},
                %{item_id: "goblin_ear", drop_chance: 0.5, max_qty: 1}]},
      %{npc: "boss_ogre", gold_chance: 1.0, max_gold: 100,
        items: [%{item_id: "ogre_club", drop_chance: 0.5, max_qty: 1},
                %{item_id: "health_potion", drop_chance: 1.0, max_qty: 3},
                %{item_id: "rare_gem", drop_chance: 0.2, max_qty: 1}]}
    ],
    map: %{width: 800, height: 600}
  },
  %{
    template_id: "spider_den",
    name: "Spider Den",
    description: "A dark cavern teeming with spiders, ghosts, and a necromancer.",
    min_level: 3, max_level: 15,
    difficulty: %{hp_mult: 1.0, damage_mult: 1.0, xp_mult: 1.2, loot_mult: 1.1},
    npc_spawns: [
      %{template_id: "spider", x: 150, y: 120, base_health: 20},
      %{template_id: "spider", x: 180, y: 150, base_health: 20},
      %{template_id: "spider", x: 130, y: 170, base_health: 20},
      %{template_id: "spider", x: 550, y: 280, base_health: 20},
      %{template_id: "spider", x: 580, y: 310, base_health: 20},
      %{template_id: "spider", x: 520, y: 320, base_health: 20},
      %{template_id: "ghost", x: 350, y: 200, base_health: 25},
      %{template_id: "ghost", x: 400, y: 420, base_health: 25},
      %{template_id: "necromancer", x: 700, y: 500, base_health: 120}
    ],
    loot_tables: [
      %{npc: "spider", gold_chance: 0.6, max_gold: 10,
        items: [%{item_id: "spider_silk", drop_chance: 0.5, max_qty: 2},
                %{item_id: "venom_sac", drop_chance: 0.2, max_qty: 1}]},
      %{npc: "ghost", gold_chance: 0.7, max_gold: 20,
        items: [%{item_id: "ectoplasm", drop_chance: 0.4, max_qty: 1},
                %{item_id: "spirit_shard", drop_chance: 0.15, max_qty: 1}]},
      %{npc: "necromancer", gold_chance: 1.0, max_gold: 50,
        items: [%{item_id: "dark_tome", drop_chance: 0.3, max_qty: 1},
                %{item_id: "bone_staff", drop_chance: 0.1, max_qty: 1},
                %{item_id: "health_potion", drop_chance: 0.8, max_qty: 2}]}
    ],
    map: %{width: 800, height: 600}
  }
]

Enum.each(dungeons, fn dungeon ->
  SurrealDB.query!("UPSERT dungeon_templates SET #{map_to_set.(dungeon)} WHERE template_id = '#{dungeon.template_id}'")
end)
IO.puts("✓ seeded #{length(dungeons)} dungeon_templates")

IO.puts("\n=== Schema & seed complete ===")
