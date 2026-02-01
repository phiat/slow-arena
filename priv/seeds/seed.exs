alias SlowArena.SurrealDB

IO.puts("=== SurrealDB Schema & Seed ===")

# -- Namespace / Database --
SurrealDB.query!("USE NS slow_arena DB game")

# ============================================================
# 1. accounts
# ============================================================
SurrealDB.query!("""
DEFINE TABLE accounts SCHEMAFULL;
DEFINE FIELD username      ON accounts TYPE string;
DEFINE FIELD password_hash  ON accounts TYPE string;
DEFINE FIELD email          ON accounts TYPE option<string>;
DEFINE FIELD created_at     ON accounts TYPE datetime DEFAULT time::now();
DEFINE FIELD last_login     ON accounts TYPE option<datetime>;
DEFINE INDEX idx_username   ON accounts FIELDS username UNIQUE;
""")
IO.puts("✓ accounts")

# ============================================================
# 2. characters
# ============================================================
SurrealDB.query!("""
DEFINE TABLE characters SCHEMAFULL;
DEFINE FIELD account       ON characters TYPE record<accounts>;
DEFINE FIELD name          ON characters TYPE string;
DEFINE FIELD class         ON characters TYPE string
  ASSERT $value IN ["warrior", "mage", "ranger", "rogue"];
DEFINE FIELD level         ON characters TYPE int DEFAULT 1;
DEFINE FIELD experience    ON characters TYPE int DEFAULT 0;
DEFINE FIELD gold          ON characters TYPE int DEFAULT 0;
DEFINE FIELD stats         ON characters TYPE object;
DEFINE FIELD stats.max_hp  ON characters TYPE int;
DEFINE FIELD stats.max_mana ON characters TYPE int;
DEFINE FIELD stats.str     ON characters TYPE int;
DEFINE FIELD stats.int     ON characters TYPE int;
DEFINE FIELD stats.agi     ON characters TYPE int;
DEFINE FIELD stats.armor   ON characters TYPE int;
DEFINE FIELD position      ON characters TYPE object;
DEFINE FIELD position.x    ON characters TYPE float DEFAULT 50.0;
DEFINE FIELD position.y    ON characters TYPE float DEFAULT 300.0;
DEFINE FIELD position.zone ON characters TYPE string DEFAULT "lobby";
DEFINE FIELD position.facing ON characters TYPE string DEFAULT "right";
DEFINE FIELD created_at    ON characters TYPE datetime DEFAULT time::now();
DEFINE FIELD last_played   ON characters TYPE option<datetime>;
DEFINE INDEX idx_char_name    ON characters FIELDS name UNIQUE;
DEFINE INDEX idx_char_account ON characters FIELDS account;
""")
IO.puts("✓ characters")

# ============================================================
# 3. item_definitions
# ============================================================
SurrealDB.query!("""
DEFINE TABLE item_definitions SCHEMAFULL;
DEFINE FIELD item_id          ON item_definitions TYPE string;
DEFINE FIELD name             ON item_definitions TYPE string;
DEFINE FIELD description      ON item_definitions TYPE string;
DEFINE FIELD type             ON item_definitions TYPE string
  ASSERT $value IN ["weapon", "armor", "accessory", "consumable", "material"];
DEFINE FIELD rarity           ON item_definitions TYPE string
  ASSERT $value IN ["common", "uncommon", "rare", "epic", "legendary"];
DEFINE FIELD level_requirement ON item_definitions TYPE int DEFAULT 1;
DEFINE FIELD slot             ON item_definitions TYPE option<string>;
DEFINE FIELD stats            ON item_definitions FLEXIBLE TYPE option<object>;
DEFINE FIELD stack_size       ON item_definitions TYPE int DEFAULT 1;
DEFINE FIELD vendor_price     ON item_definitions TYPE int DEFAULT 0;
DEFINE INDEX idx_item_id      ON item_definitions FIELDS item_id UNIQUE;
""")
IO.puts("✓ item_definitions")

# ============================================================
# 4. inventory
# ============================================================
SurrealDB.query!("""
DEFINE TABLE inventory SCHEMAFULL;
DEFINE FIELD character   ON inventory TYPE record<characters>;
DEFINE FIELD item        ON inventory TYPE record<item_definitions>;
DEFINE FIELD quantity    ON inventory TYPE int DEFAULT 1;
DEFINE FIELD equipped    ON inventory TYPE bool DEFAULT false;
DEFINE FIELD acquired_at ON inventory TYPE datetime DEFAULT time::now();
DEFINE INDEX idx_char_item ON inventory FIELDS character, item UNIQUE;
""")
IO.puts("✓ inventory")

# ============================================================
# 5. dungeon_templates
# ============================================================
SurrealDB.query!("""
DEFINE TABLE dungeon_templates SCHEMAFULL;
DEFINE FIELD template_id  ON dungeon_templates TYPE string;
DEFINE FIELD name         ON dungeon_templates TYPE string;
DEFINE FIELD description  ON dungeon_templates TYPE string;
DEFINE FIELD min_level    ON dungeon_templates TYPE int DEFAULT 1;
DEFINE FIELD max_level    ON dungeon_templates TYPE int DEFAULT 99;
DEFINE FIELD difficulty   ON dungeon_templates FLEXIBLE TYPE object;
DEFINE FIELD npc_spawns   ON dungeon_templates TYPE array;
DEFINE FIELD npc_spawns.*  ON dungeon_templates FLEXIBLE TYPE object;
DEFINE FIELD loot_tables  ON dungeon_templates TYPE array;
DEFINE FIELD loot_tables.* ON dungeon_templates FLEXIBLE TYPE object;
DEFINE FIELD map          ON dungeon_templates TYPE object;
DEFINE FIELD map.width    ON dungeon_templates TYPE int;
DEFINE FIELD map.height   ON dungeon_templates TYPE int;
DEFINE INDEX idx_template_id ON dungeon_templates FIELDS template_id UNIQUE;
""")
IO.puts("✓ dungeon_templates")

# ============================================================
# 6. run_history
# ============================================================
SurrealDB.query!("""
DEFINE TABLE run_history SCHEMAFULL;
DEFINE FIELD character      ON run_history TYPE record<characters>;
DEFINE FIELD dungeon        ON run_history TYPE record<dungeon_templates>;
DEFINE FIELD party_members  ON run_history TYPE array;
DEFINE FIELD party_members.* ON run_history TYPE string;
DEFINE FIELD started_at     ON run_history TYPE datetime DEFAULT time::now();
DEFINE FIELD completed_at   ON run_history TYPE option<datetime>;
DEFINE FIELD duration_seconds ON run_history TYPE option<int>;
DEFINE FIELD result         ON run_history TYPE string
  ASSERT $value IN ["completed", "failed", "abandoned"];
DEFINE FIELD metrics        ON run_history FLEXIBLE TYPE object;
DEFINE FIELD rewards        ON run_history FLEXIBLE TYPE object;
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
  SurrealDB.query!("CREATE item_definitions CONTENT #{Jason.encode!(item)}")
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
  SurrealDB.query!("CREATE dungeon_templates CONTENT #{Jason.encode!(dungeon)}")
end)
IO.puts("✓ seeded #{length(dungeons)} dungeon_templates")

IO.puts("\n=== Schema & seed complete ===")
