defmodule SlowArena.Persistence do
  @moduledoc "Character save/load between Mnesia (gameplay) and SurrealDB (storage)."
  require Logger

  alias SlowArena.SurrealDB
  alias SlowArena.GameEngine.Classes

  @save_interval_ms 30_000

  def save_interval_ms, do: @save_interval_ms

  @doc "Create a new character in SurrealDB and load into Mnesia."
  def create_character(player_id, class_name) do
    stats = Classes.stats(class_name)

    char = %{
      name: player_id,
      class: to_string(stats.class),
      level: 1,
      experience: 0,
      gold: 0,
      stats: %{
        max_hp: stats.max_hp,
        max_mana: stats.max_mana,
        str: stats.str,
        int: stats.int,
        agi: stats.agi,
        armor: stats.armor
      },
      position: %{x: 50.0, y: 300.0, zone: "lobby", facing: "right"}
    }

    results = SurrealDB.query!("CREATE characters CONTENT #{Jason.encode!(char)}")
    [%{"result" => [created]}] = results
    surreal_id = created["id"]

    write_to_mnesia(player_id, char, stats)
    Logger.info("Created character #{player_id} (#{class_name}) in SurrealDB: #{surreal_id}")
    {:ok, surreal_id}
  end

  @doc "Load character from SurrealDB into Mnesia. Returns :ok or :not_found."
  def load_character(player_id) do
    results = SurrealDB.query!("SELECT * FROM characters WHERE name = '#{escape(player_id)}' LIMIT 1")

    case results do
      [%{"result" => [char], "status" => "OK"}] ->
        stats = Classes.stats(char["class"])
        merged = Map.merge(stats, %{
          max_hp: char["stats"]["max_hp"],
          max_mana: char["stats"]["max_mana"],
          str: char["stats"]["str"],
          int: char["stats"]["int"],
          agi: char["stats"]["agi"],
          armor: char["stats"]["armor"]
        })

        write_to_mnesia(player_id, char, merged)

        # Restore gold
        gold = char["gold"] || 0
        :mnesia.dirty_write({:player_gold, player_id, gold})

        # Restore inventory
        load_inventory(player_id, char["id"])

        # Update last_played
        SurrealDB.query!("UPDATE #{char["id"]} SET last_played = time::now()")

        Logger.info("Loaded character #{player_id} from SurrealDB (level #{char["level"]}, #{char["gold"]} gold)")
        {:ok, char}

      [%{"result" => [], "status" => "OK"}] ->
        :not_found

      _ ->
        :not_found
    end
  end

  @doc "Save current Mnesia state to SurrealDB."
  def save_character(player_id) do
    with [{:player_positions, _, x, y, facing, _, _, zone, _, _}] <-
           :mnesia.dirty_read(:player_positions, player_id),
         [{:player_stats, _, _class, level, _hp, _max_hp, _mana, _max_mana, _str, _int, _agi, _armor}] <-
           :mnesia.dirty_read(:player_stats, player_id) do

      gold = case :mnesia.dirty_read(:player_gold, player_id) do
        [{:player_gold, _, amount}] -> amount
        [] -> 0
      end

      facing_str = if is_number(facing), do: to_string(facing), else: facing

      sql = """
      UPDATE characters SET
        level = #{level},
        gold = #{gold},
        position = #{Jason.encode!(%{x: x, y: y, zone: zone || "lobby", facing: facing_str})},
        last_played = time::now()
      WHERE name = '#{escape(player_id)}'
      """

      SurrealDB.query!(sql)
      save_inventory(player_id)
      Logger.debug("Saved character #{player_id} (level #{level}, #{gold} gold)")
      :ok
    else
      _ ->
        Logger.warning("Cannot save #{player_id}: not found in Mnesia")
        :error
    end
  end

  defp write_to_mnesia(player_id, char, stats) do
    pos = char["position"] || %{"x" => 50.0, "y" => 300.0, "zone" => "lobby", "facing" => "right"}
    x = (pos["x"] || 50.0) / 1
    y = (pos["y"] || 300.0) / 1

    :mnesia.dirty_write(
      {:player_positions, player_id, x, y, 0.0, 0.0, 0.0,
       pos["zone"] || "lobby", nil, System.monotonic_time(:millisecond)}
    )

    level = char["level"] || 1
    class_atom = if is_atom(stats.class), do: stats.class, else: String.to_existing_atom(to_string(stats.class))

    :mnesia.dirty_write(
      {:player_stats, player_id, class_atom, level,
       stats.max_hp, stats.max_hp, stats.max_mana, stats.max_mana,
       stats.str, stats.int, stats.agi, stats.armor}
    )

    :mnesia.dirty_write({:player_gold, player_id, char["gold"] || 0})
  end

  defp save_inventory(player_id) do
    # Get character SurrealDB ID
    case SurrealDB.query!("SELECT id FROM characters WHERE name = '#{escape(player_id)}' LIMIT 1") do
      [%{"result" => [%{"id" => char_id}]}] ->
        items = :mnesia.dirty_all_keys(:player_inventory)
        |> Enum.flat_map(fn
          {^player_id, _item_id} = key ->
            case :mnesia.dirty_read(:player_inventory, key) do
              [{:player_inventory, _, item_id, qty}] -> [%{item_id: item_id, quantity: qty}]
              _ -> []
            end
          _ -> []
        end)

        # Delete old inventory, insert current
        SurrealDB.query!("DELETE inventory WHERE character = #{char_id}")

        Enum.each(items, fn %{item_id: item_id, quantity: qty} ->
          # Find item definition
          case SurrealDB.query!("SELECT id FROM item_definitions WHERE item_id = '#{escape(item_id)}' LIMIT 1") do
            [%{"result" => [%{"id" => item_def_id}]}] ->
              SurrealDB.query!("CREATE inventory CONTENT #{Jason.encode!(%{
                character: char_id,
                item: item_def_id,
                quantity: qty,
                equipped: false
              })}")
            _ ->
              Logger.warning("Item definition not found for #{item_id}, skipping inventory save")
          end
        end)

      _ -> :ok
    end
  end

  defp load_inventory(player_id, char_id) do
    case SurrealDB.query!("SELECT item.item_id AS item_id, quantity FROM inventory WHERE character = #{char_id}") do
      [%{"result" => items, "status" => "OK"}] ->
        Enum.each(items, fn item ->
          key = {player_id, item["item_id"]}
          :mnesia.dirty_write({:player_inventory, key, item["item_id"], item["quantity"]})
        end)
      _ -> :ok
    end
  end

  defp escape(str), do: String.replace(to_string(str), "'", "\\'")
end
