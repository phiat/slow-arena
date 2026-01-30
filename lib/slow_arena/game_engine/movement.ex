defmodule SlowArena.GameEngine.Movement do
  # pixels per second
  @movement_speed 150.0
  # 100ms per tick
  @delta_time 0.1

  def update_all do
    # Process all players with non-zero velocity
    :mnesia.dirty_all_keys(:player_positions)
    |> Enum.each(fn char_id ->
      case :mnesia.dirty_read(:player_positions, char_id) do
        [{:player_positions, ^char_id, x, y, facing, vx, vy, zone_id, instance_id, _updated}]
        when vx != 0.0 or vy != 0.0 ->
          new_x = x + vx * @movement_speed * @delta_time
          new_y = y + vy * @movement_speed * @delta_time

          # Basic bounds clamping (TODO: real collision)
          {final_x, final_y} = clamp_bounds(new_x, new_y)

          new_facing =
            if vx != 0.0 or vy != 0.0 do
              :math.atan2(vy, vx)
            else
              facing
            end

          :mnesia.dirty_write(
            {:player_positions, char_id, final_x, final_y, new_facing, vx, vy, zone_id,
             instance_id, System.monotonic_time(:millisecond)}
          )

        _ ->
          :ok
      end
    end)
  end

  def set_input(character_id, %{up: up, down: down, left: left, right: right}) do
    vx =
      cond do
        left -> -1.0
        right -> 1.0
        true -> 0.0
      end

    vy =
      cond do
        up -> -1.0
        down -> 1.0
        true -> 0.0
      end

    # Normalize diagonal
    {vx, vy} =
      if vx != 0.0 and vy != 0.0 do
        mag = :math.sqrt(vx * vx + vy * vy)
        {vx / mag, vy / mag}
      else
        {vx, vy}
      end

    case :mnesia.dirty_read(:player_positions, character_id) do
      [{:player_positions, ^character_id, x, y, facing, _vx, _vy, zone_id, instance_id, _t}] ->
        :mnesia.dirty_write(
          {:player_positions, character_id, x, y, facing, vx, vy, zone_id, instance_id,
           System.monotonic_time(:millisecond)}
        )

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  def get_position(character_id) do
    case :mnesia.dirty_read(:player_positions, character_id) do
      [{:player_positions, ^character_id, x, y, facing, vx, vy, zone_id, instance_id, updated}] ->
        {:ok,
         %{
           x: x,
           y: y,
           facing: facing,
           vx: vx,
           vy: vy,
           zone_id: zone_id,
           instance_id: instance_id,
           updated_at: updated
         }}

      [] ->
        {:error, :not_found}
    end
  end

  defp clamp_bounds(x, y) do
    # Default zone bounds (800x600 for now)
    x = max(0.0, min(x, 800.0))
    y = max(0.0, min(y, 600.0))
    {x, y}
  end
end
