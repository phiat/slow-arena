defmodule SlowArena.GameEngine.LootServer do
  @moduledoc "Loot generation, pile management, and expiration."
  use GenServer
  require Logger

  @loot_expire_ms 60_000

  @loot_tables %{
    "goblin" => %{
      gold_chance: 0.8,
      max_gold: 15,
      items: [
        %{item_id: "health_potion", drop_chance: 0.3, max_qty: 2},
        %{item_id: "goblin_ear", drop_chance: 0.5, max_qty: 1}
      ]
    },
    "skeleton_warrior" => %{
      gold_chance: 0.6,
      max_gold: 25,
      items: [
        %{item_id: "bone_fragment", drop_chance: 0.4, max_qty: 3},
        %{item_id: "rusty_sword", drop_chance: 0.1, max_qty: 1}
      ]
    },
    "boss_ogre" => %{
      gold_chance: 1.0,
      max_gold: 100,
      items: [
        %{item_id: "ogre_club", drop_chance: 0.5, max_qty: 1},
        %{item_id: "health_potion", drop_chance: 1.0, max_qty: 3},
        %{item_id: "rare_gem", drop_chance: 0.2, max_qty: 1}
      ]
    },
    "ghost" => %{
      gold_chance: 0.7,
      max_gold: 20,
      items: [
        %{item_id: "ectoplasm", drop_chance: 0.4, max_qty: 1},
        %{item_id: "spirit_shard", drop_chance: 0.15, max_qty: 1}
      ]
    },
    "spider" => %{
      gold_chance: 0.6,
      max_gold: 10,
      items: [
        %{item_id: "spider_silk", drop_chance: 0.5, max_qty: 2},
        %{item_id: "venom_sac", drop_chance: 0.2, max_qty: 1}
      ]
    },
    "necromancer" => %{
      gold_chance: 1.0,
      max_gold: 50,
      min_gold: 20,
      items: [
        %{item_id: "dark_tome", drop_chance: 0.3, max_qty: 1},
        %{item_id: "bone_staff", drop_chance: 0.1, max_qty: 1},
        %{item_id: "health_potion", drop_chance: 0.8, max_qty: 2}
      ]
    },
    "slime" => %{
      gold_chance: 0.5,
      max_gold: 5,
      items: [
        %{item_id: "slime_gel", drop_chance: 0.6, max_qty: 2}
      ]
    }
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_), do: {:ok, %{}}

  def tick do
    cleanup_expired()
  end

  def spawn_loot(template_id, instance_id, x, y, _killer_id) do
    loot = generate_loot(template_id)

    if loot.items != [] or loot.gold > 0 do
      loot_id = "loot_#{:erlang.unique_integer([:positive])}"
      now = System.monotonic_time(:millisecond)

      :mnesia.dirty_write(
        {:loot_piles, loot_id, instance_id, x, y, loot.items, loot.gold, now,
         now + @loot_expire_ms, nil}
      )

      Logger.info("Loot spawned: #{loot_id} (#{length(loot.items)} items, #{loot.gold} gold)")
      {:ok, loot_id}
    else
      :no_loot
    end
  end

  @pickup_range 50.0

  def pickup_loot(character_id, loot_id) do
    case :mnesia.dirty_read(:loot_piles, loot_id) do
      [{:loot_piles, ^loot_id, _iid, _x, _y, items, gold, _spawned, _expires, reserved}] ->
        if reserved != nil and reserved != character_id do
          {:error, :reserved}
        else
          :mnesia.dirty_delete(:loot_piles, loot_id)
          {:ok, %{items: items, gold: gold}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def pickup_loot(character_id, loot_id, player_x, player_y, player_instance_id) do
    case :mnesia.dirty_read(:loot_piles, loot_id) do
      [{:loot_piles, ^loot_id, instance_id, lx, ly, items, gold, _spawned, _expires, reserved}] ->
        cond do
          instance_id != player_instance_id ->
            {:error, :wrong_instance}

          reserved != nil and reserved != character_id ->
            {:error, :reserved}

          distance(player_x, player_y, lx, ly) > @pickup_range ->
            {:error, :too_far}

          true ->
            :mnesia.dirty_delete(:loot_piles, loot_id)
            award_loot(character_id, items, gold)
            {:ok, %{items: items, gold: gold}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp award_loot(character_id, items, gold) do
    # Add gold
    if gold > 0 do
      current_gold =
        case :mnesia.dirty_read(:player_gold, character_id) do
          [{:player_gold, _, amount}] -> amount
          [] -> 0
        end

      :mnesia.dirty_write({:player_gold, character_id, current_gold + gold})
    end

    # Add items to inventory
    Enum.each(items, fn %{item_id: item_id, quantity: qty} ->
      key = {character_id, item_id}

      current_qty =
        case :mnesia.dirty_read(:player_inventory, key) do
          [{:player_inventory, _, _, existing}] -> existing
          [] -> 0
        end

      :mnesia.dirty_write({:player_inventory, key, item_id, current_qty + qty})
    end)
  end

  defp distance(x1, y1, x2, y2) do
    :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2))
  end

  def list_loot(instance_id) do
    :mnesia.dirty_all_keys(:loot_piles)
    |> Enum.flat_map(fn lid ->
      case :mnesia.dirty_read(:loot_piles, lid) do
        [{:loot_piles, ^lid, ^instance_id, x, y, items, gold, _, _, _}] ->
          [%{loot_id: lid, x: x, y: y, items: items, gold: gold}]

        _ ->
          []
      end
    end)
  end

  defp generate_loot(template_id) do
    table =
      Map.get(@loot_tables, to_string(template_id), %{gold_chance: 0.5, max_gold: 10, items: []})

    items =
      Enum.flat_map(table.items, fn item ->
        if :rand.uniform() < item.drop_chance do
          qty = :rand.uniform(item.max_qty)
          [%{item_id: item.item_id, quantity: qty}]
        else
          []
        end
      end)

    min_gold = Map.get(table, :min_gold, 0)

    gold =
      if :rand.uniform() < table.gold_chance do
        if min_gold > 0 do
          min_gold + :rand.uniform(max(1, table.max_gold - min_gold))
        else
          :rand.uniform(table.max_gold)
        end
      else
        0
      end

    %{items: items, gold: gold}
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    :mnesia.dirty_all_keys(:loot_piles)
    |> Enum.each(fn lid ->
      case :mnesia.dirty_read(:loot_piles, lid) do
        [{:loot_piles, ^lid, _, _, _, _, _, _, expires, _}] when expires < now ->
          :mnesia.dirty_delete(:loot_piles, lid)

        _ ->
          :ok
      end
    end)
  end
end
