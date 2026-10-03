defmodule Barkpark.Quiz.RoomSpawnSurfaceProbeTest do
  @moduledoc """
  A HERMETIC probe of the quiz room-creation surface (hq-room-spawn-abuse-paper).
  It measures the three numbers `/papers/hyperquiz-risks` states about that
  surface, from the running code rather than from prose, and touches no
  production room:

    * RATE — how many rooms ONE anonymous principal can open before
      `Barkpark.Quiz.SpawnBudget` refuses (the default per-hour budget), and that
      a second principal is unaffected;
    * CAP — the global `max_children` backstop, read off the live
      `Barkpark.Quiz.RoomSupervisor` state, never retyped;
    * REAP — the idle timer a never-populated room arms at birth (the empty
      lifetime), read off the room's own timer.

  POSITIVE CONTROL: every room the probe claims to have opened is looked up in
  the room registry AND counted by the supervisor, so a probe that silently
  spawned nothing cannot report a budget of zero as a measurement.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.RateLimiterSandbox

  alias Barkpark.Quiz
  alias Barkpark.Quiz.{Room, SpawnBudget}

  setup :reset_rate_limiter!

  setup do
    original = Application.get_env(:barkpark, :quiz_room_spawn)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :quiz_room_spawn)
        opts -> Application.put_env(:barkpark, :quiz_room_spawn, opts)
      end
    end)

    # The DEFAULTS are what an anonymous visitor meets in production.
    Application.delete_env(:barkpark, :quiz_room_spawn)
    :ok
  end

  defp pin, do: "PR" <> Integer.to_string(System.unique_integer([:positive]))

  defp visitor(address), do: %{scoped_conn() | remote_ip: address}

  defp live_rooms, do: DynamicSupervisor.count_children(Barkpark.Quiz.RoomSupervisor).active

  test "RATE: one anonymous principal opens exactly the default budget, then is refused" do
    a = visitor({203, 0, 113, 7})
    before = live_rooms()

    results =
      for _ <- 1..15 do
        p = pin()
        on_exit(fn -> Quiz.stop_room(p) end)
        {p, Room.ensure(p, a)}
      end

    admitted = for {p, {:ok, pid}} <- results, do: {p, pid}
    refused = for {_p, {:error, :spawn_budget}} <- results, do: :refused

    # the measurement — read from the module, never retyped
    assert length(admitted) == SpawnBudget.per_hour()
    assert length(refused) == 15 - SpawnBudget.per_hour()

    # POSITIVE CONTROL: the admitted rooms really exist, registered and supervised
    for {p, pid} <- admitted, do: assert(Room.whereis(p) == pid)
    assert live_rooms() - before == length(admitted)

    # a different principal is untouched by the first one's exhausted budget
    b = visitor({198, 51, 100, 9})
    p = pin()
    on_exit(fn -> Quiz.stop_room(p) end)
    assert {:ok, _} = Room.ensure(p, b)
  end

  test "CAP: the global backstop is the supervisor's own max_children" do
    # DynamicSupervisor keeps max_children in its state; read it, do not retype it.
    state = :sys.get_state(Barkpark.Quiz.RoomSupervisor)
    cap = Map.get(Map.from_struct(state), :max_children)
    assert cap == 10_000
  end

  test "REAP: a never-populated room arms the SHORT empty-idle timer at birth" do
    p = pin()
    on_exit(fn -> Quiz.stop_room(p) end)
    {:ok, pid} = Room.ensure(p, :internal)

    %{idle_timer: ref, players: players} = :sys.get_state(pid)
    assert players == %{}
    remaining = Process.read_timer(ref)

    # empty lifetime is 2 minutes (@empty_idle_ms); a populated room gets 60
    assert is_integer(remaining) and remaining > 110_000 and remaining <= 120_000
  end
end
