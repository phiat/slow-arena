defmodule SlowArena.GameEngine.PartyServer do
  @moduledoc "Party formation and management for dungeon instances."
  use GenServer
  require Logger

  @max_party_size 8

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_), do: {:ok, %{}}

  def create_party(leader_id) do
    party_id = "party_#{:erlang.unique_integer([:positive])}"

    :mnesia.dirty_write(
      {:party_state, party_id, leader_id, [leader_id], @max_party_size, :free_for_all, nil,
       System.monotonic_time(:millisecond)}
    )

    Logger.info("Party #{party_id} created by #{leader_id}")
    {:ok, party_id}
  end

  def join_party(party_id, character_id) do
    case :mnesia.dirty_read(:party_state, party_id) do
      [{:party_state, ^party_id, leader, members, max, loot_mode, instance, created}] ->
        cond do
          length(members) >= max ->
            {:error, :party_full}

          character_id in members ->
            {:error, :already_in_party}

          true ->
            new_members = members ++ [character_id]

            :mnesia.dirty_write(
              {:party_state, party_id, leader, new_members, max, loot_mode, instance, created}
            )

            {:ok, party_id}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def leave_party(party_id, character_id) do
    case :mnesia.dirty_read(:party_state, party_id) do
      [{:party_state, ^party_id, leader, members, max, loot_mode, instance, created}] ->
        new_members = List.delete(members, character_id)

        if new_members == [] do
          :mnesia.dirty_delete(:party_state, party_id)
          :ok
        else
          new_leader = if leader == character_id, do: hd(new_members), else: leader

          :mnesia.dirty_write(
            {:party_state, party_id, new_leader, new_members, max, loot_mode, instance, created}
          )

          :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  def get_party(party_id) do
    case :mnesia.dirty_read(:party_state, party_id) do
      [{:party_state, ^party_id, leader, members, _max, loot_mode, instance, _created}] ->
        {:ok,
         %{
           party_id: party_id,
           leader: leader,
           members: members,
           loot_mode: loot_mode,
           instance_id: instance
         }}

      [] ->
        {:error, :not_found}
    end
  end

  def list_parties do
    :mnesia.dirty_all_keys(:party_state)
    |> Enum.flat_map(fn pid ->
      case get_party(pid) do
        {:ok, party} -> [party]
        _ -> []
      end
    end)
  end
end
