defmodule SlowArena.GameEngine.Classes do
  @moduledoc "Shared class stat definitions for all player classes."

  @class_stats %{
    warrior: %{class: :warrior, hp: 100, max_hp: 100, mana: 30, max_mana: 30, str: 15, int: 5, agi: 8, armor: 20},
    mage: %{class: :mage, hp: 60, max_hp: 60, mana: 100, max_mana: 100, str: 5, int: 15, agi: 8, armor: 5},
    ranger: %{class: :ranger, hp: 80, max_hp: 80, mana: 50, max_mana: 50, str: 8, int: 8, agi: 15, armor: 10},
    rogue: %{class: :rogue, hp: 70, max_hp: 70, mana: 40, max_mana: 40, str: 10, int: 5, agi: 15, armor: 8}
  }

  @doc "Returns stats map for the given class (atom or string)."
  def stats(class) when is_atom(class), do: Map.fetch!(@class_stats, class)

  def stats(class) when is_binary(class), do: stats(String.to_existing_atom(class))
end
