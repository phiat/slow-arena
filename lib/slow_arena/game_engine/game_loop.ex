defmodule SlowArena.GameEngine.GameLoop do
  use GenServer
  require Logger

  # ms (10 Hz)
  @tick_rate 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    schedule_tick()
    Logger.info("Game loop started at #{@tick_rate}ms tick rate (#{div(1000, @tick_rate)} Hz)")
    {:ok, %{tick_count: 0, last_tick: System.monotonic_time(:millisecond), avg_elapsed: 0.0}}
  end

  def handle_info(:tick, state) do
    start_time = System.monotonic_time(:millisecond)

    # === TICK OPERATIONS ===
    SlowArena.GameEngine.Movement.update_all()
    SlowArena.GameEngine.AIServer.tick()
    SlowArena.GameEngine.CombatServer.tick()
    SlowArena.GameEngine.LootServer.tick()

    # === BROADCAST ===
    # SlowArena.GameEngine.Broadcast.send_updates()

    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > @tick_rate do
      Logger.warning("Tick #{state.tick_count} took #{elapsed}ms (> #{@tick_rate}ms target)")
    end

    # Running average
    avg = state.avg_elapsed * 0.95 + elapsed * 0.05

    schedule_tick()

    {:noreply,
     %{state | tick_count: state.tick_count + 1, last_tick: start_time, avg_elapsed: avg}}
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def handle_call(:get_stats, _from, state) do
    {:reply,
     %{
       tick_count: state.tick_count,
       avg_elapsed_ms: Float.round(state.avg_elapsed, 2),
       tick_rate: @tick_rate
     }, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_rate)
  end
end
