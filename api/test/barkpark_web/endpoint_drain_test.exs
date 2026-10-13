defmodule BarkparkWeb.EndpointDrainTest do
  @moduledoc """
  task-234799142dfd8559: the retiring slot in a blue/green deploy must not
  drop an in-flight ORDINARY HTTP request (reset/502) the instant
  `systemctl disable --now` sends SIGTERM. SIGTERM triggers a graceful OTP
  application stop by default, and Bandit's transport (ThousandIsland) stops
  ACCEPTING new connections immediately but keeps serving one it already
  holds, up to `thousand_island_options: [shutdown_timeout: _]`
  (`config/runtime.exs`) — so a request completes (2xx) as long as it
  finishes within that bound.

  This is the seam a long-lived SSE stream does NOT rely on:
  `Barkpark.Realtime.DrainSignal` (task-2bcada0faa01ebb2) tells those streams
  to end themselves BEFORE the slot stops, because the ordinary drain bound
  here (tens of seconds) is far too short for a connection meant to stay open
  for minutes. This file's subject is the OTHER, much larger share of
  traffic: a short request that happens to be in flight at the wrong moment.

  REAL SOCKET, ON PURPOSE. The property under test is ThousandIsland's own
  connection-draining behaviour — no ConnCase/Plug.Test seam can stand in for
  an actual TCP connection here, the same reasoning
  `listen_backpressure_test.exs` documents for its own real-mailbox tests.
  A throwaway Bandit + Plug, started as a REAL supervised child (not a bare
  `GenServer.start_link/2` outside any supervision tree — a bare one is
  invisible to `Supervisor.stop/3`'s shutdown cascade and silently proves
  nothing), on its own port, never touching the shared `BarkparkWeb.Endpoint`
  the rest of the suite depends on.

  MUTATION-SHAPED BY CONSTRUCTION: this is a two-arm comparison, not a single
  "it works" assertion. The SURVIVES arm (shutdown_timeout above the
  request's duration) and the CUT arm (shutdown_timeout below it) use the
  exact same plug and the exact same stop call — only the bound differs. A
  shutdown_timeout that doesn't bound anything (either a no-op stop, or an
  unconditional wait) could pass the SURVIVES arm by accident; it cannot pass
  both.
  """
  use ExUnit.Case, async: true

  defmodule SlowPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, sleep_ms: sleep_ms) do
      Process.sleep(sleep_ms)
      send_resp(conn, 200, "ok")
    end
  end

  # `port: 0` asks the OS for any free ephemeral port instead of a hand-picked
  # one: a fixed range collided with another test's own Bandit instance in CI
  # (`:eacces` starting the listener — measured on a real run, not guessed),
  # and a free-port race is exactly what port 0 exists to avoid. The actual
  # bound port comes back from ThousandIsland.listener_info/1 on the Bandit
  # child Supervisor.start_link/2 returns among its children.
  defp start_bandit(shutdown_timeout, sleep_ms) do
    {:ok, sup} =
      Supervisor.start_link(
        [
          {Bandit,
           plug: {SlowPlug, sleep_ms: sleep_ms},
           port: 0,
           startup_log: false,
           thousand_island_options: [shutdown_timeout: shutdown_timeout]}
        ],
        strategy: :one_for_one
      )

    # Bandit's own child_spec id is `{Bandit, make_ref()}`, not the bare atom
    # — and this supervisor starts exactly one child, so take it by position.
    [{_id, bandit_pid, _type, _modules}] = Supervisor.which_children(sup)
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
    {:ok, sup, port}
  end

  # curl, not :httpc/Req: a bare GenServer client here would need its own
  # socket-level timeout handling to tell "clean 200" apart from "connection
  # reset mid-response", and curl's exit code already draws exactly that
  # line (0 vs 52 "Empty reply from server").
  defp curl_get(port) do
    System.cmd("curl", [
      "-s",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      "--max-time",
      "20",
      "http://localhost:#{port}/"
    ])
  end

  test "a request in flight survives a graceful stop within the drain bound" do
    {:ok, sup, port} = start_bandit(5_000, 1_500)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    test_pid = self()

    spawn(fn ->
      send(test_pid, {:http_done, curl_get(port)})
    end)

    # Give the request time to actually reach the plug and start sleeping
    # before the stop begins, the same startup-gated reasoning
    # listen_backpressure_test.exs documents (a timing budget cannot mask a
    # dropped response — it either arrives correctly within the wait or it
    # does not arrive at all).
    Process.sleep(300)

    assert :ok == Supervisor.stop(sup, :normal, 10_000),
           "the graceful stop itself must complete inside its own 10s test timeout"

    assert_receive {:http_done, {"200", 0}}, 10_000
  end

  test "a request that outlives the drain bound is cut, not served stale" do
    # The bound (800ms) is deliberately SHORTER than the plug's own sleep
    # (3s): the stop must not wait past its own bound no matter how long the
    # handler still has to run.
    {:ok, sup, port} = start_bandit(800, 3_000)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    test_pid = self()

    spawn(fn ->
      send(test_pid, {:http_done, curl_get(port)})
    end)

    Process.sleep(300)

    t0 = System.monotonic_time(:millisecond)
    assert :ok == Supervisor.stop(sup, :normal, 10_000)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert elapsed < 3_000,
           "the stop waited #{elapsed}ms — past the plug's own 3s sleep, as if the " <>
             "800ms bound were not honoured at all"

    assert_receive {:http_done, {_code, exit_status}}, 10_000
    refute exit_status == 0, "a request past the drain bound must NOT read as a clean 200"
  end
end
