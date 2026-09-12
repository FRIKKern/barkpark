defmodule Barkpark.Tenancy.WorkspaceBundleExportPoolTest do
  @moduledoc """
  THE DETECTOR for `pds-bl-export-pool-starvation`.

  ## What was observed, and what this file reproduces

  Six seconds after a ~66 MB dev-profile export finished on guerrilla:

      Postgrex.Protocol disconnected: (DBConnection.ConnectionError) client
      (Barkpark.EdgeProjector.ProjectorWorker) timed out because it queued and
      checked out the connection for longer than 15000ms

  The export was not the client that died. It was holding a member of the pool
  the dying client needed: `run_copy_out/3` holds ONE connection for the whole
  of one `COPY … TO STDOUT` (measured 9.34 s / 478 MB on `mutation_events`,
  8.04 s / 385 MB on `revisions`, WARM), with `statement_timeout` deliberately
  lifted to `0`, out of the same `POOL_SIZE` (default 10) that 29 Oban queue
  slots and all HTTP traffic share.

  Both tests below run against REAL Postgres pools of this repo (never the SQL
  sandbox, which owns one connection and cannot model contention) and hold their
  connections with `pg_sleep` — the host is never loaded, the connections are
  simply occupied, deterministically.

  ## The pair

    * `starves …` is the REPRODUCTION (c0). It runs the shipped
      `run_copy_out/3` with `export_repo: nil` — byte-for-byte origin/main's
      path — and asserts the unrelated client is DROPPED FROM THE QUEUE. It
      passes on origin/main and after the fix: it pins the mechanism, not the
      bug.
    * `does not starve …` is the DETECTOR (c2). Same hold, same shared pool,
      same probe; the only change is that the COPY runs on the dedicated
      per-export pool. It FAILS on origin/main's path (run it with
      `:export_pool_size` at `0` and it reproduces the drop above).

  Both print the measured numbers; the PR body quotes them.
  """
  use ExUnit.Case, async: false

  # `with_log/1` runs the probe and hands back BOTH its measurements and every
  # line the pool logged while it ran — the disconnect message is the evidence.
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle

  # The shared pool, standing in for prod's POOL_SIZE=10. Three is enough to
  # model the real shape: some members already busy, one left, and one client
  # that needs it.
  @shared_pool_size 3
  # The "29 Oban queue slots and all HTTP traffic" half — occupied, not loaded.
  @peer_holders 2
  # One COPY's hold. Prod measured 9.34 s; two seconds is the same shape at a
  # length a test may spend.
  @copy_hold_s 2
  # The background worker's checkout budget. Prod's is Ecto's 15_000 ms default,
  # which is exactly the number in the disconnect message above; scaled here so
  # the whole file runs inside ExUnit's timeout.
  @probe_timeout_ms 1_000
  # How long the peers stay put — past the COPY, so the probe can only ever be
  # served by the member the COPY is or is not holding.
  @peer_hold_s 4

  setup do
    {:ok, shared_name, shared_pid} = start_real_pool(@shared_pool_size)

    on_exit(fn -> stop_pool(shared_pid) end)

    %{shared: shared_name}
  end

  describe "a COPY stream's hold on the shared pool" do
    test "starves an unrelated client when the export shares that pool (the reproduction)",
         %{shared: shared} do
      %{probe: probe, copy_ms: copy_ms, log: log} = run_starvation_probe(shared, nil)

      IO.puts("""

      [pds-bl-export-pool-starvation] REPRODUCTION — export on the SHARED pool
        shared pool size .......... #{@shared_pool_size}
        peers already holding ..... #{@peer_holders} (pg_sleep #{@peer_hold_s}s)
        COPY hold ................. #{copy_ms} ms (COPY (SELECT pg_sleep(#{@copy_hold_s})) TO STDOUT)
        background probe budget ... #{@probe_timeout_ms} ms
        background probe waited ... #{probe.waited_ms} ms (outcome #{inspect(probe.outcome)})
        disconnect logged ......... #{inspect(disconnect_line(log))}
      """)

      # THE INCIDENT LINE, reproduced. Prod's read
      #   client (Barkpark.EdgeProjector.ProjectorWorker) timed out because it
      #   queued and checked out the connection for longer than 15000ms
      # and this one is the same sentence at this test's scaled budget, raised
      # against the probe standing in for that worker.
      assert log =~ "timed out because it queued and checked out the connection for longer than"

      assert log =~ "longer than #{@probe_timeout_ms}ms",
             "the disconnect must be the PROBE's budget, not some other hold: #{inspect(log)}"

      # And the cost is real whether or not DBConnection eventually retries the
      # probe onto a replacement connection: the client spent MORE than its whole
      # budget waiting, and one pool connection was destroyed and reconnected.
      assert probe.waited_ms >= @probe_timeout_ms,
             "the probe did not blow its #{@probe_timeout_ms} ms budget (waited #{probe.waited_ms} ms)"

      assert copy_ms >= @copy_hold_s * 1000,
             "the COPY did not actually hold for #{@copy_hold_s}s (#{copy_ms} ms)"
    end

    test "does not starve that client once the COPY runs on the dedicated export pool",
         %{shared: shared} do
      {:ok, export_pid} = Repo.start_export_pool(pool_size: 1)
      on_exit(fn -> Repo.stop_export_pool(export_pid) end)

      %{probe: probe, copy_ms: copy_ms, log: log} = run_starvation_probe(shared, export_pid)

      IO.puts("""

      [pds-bl-export-pool-starvation] AFTER THE FIX — export on its OWN pool
        shared pool size .......... #{@shared_pool_size} (unchanged)
        peers already holding ..... #{@peer_holders} (pg_sleep #{@peer_hold_s}s)
        export pool size .......... 1 (dedicated, started for this export only)
        COPY hold ................. #{copy_ms} ms (same statement, same function)
        background probe budget ... #{@probe_timeout_ms} ms
        background probe waited ... #{probe.waited_ms} ms (outcome #{inspect(probe.outcome)})
        disconnect logged ......... #{inspect(disconnect_line(log))}
      """)

      refute log =~ "timed out because it queued and checked out the connection for longer than",
             "the background worker was still disconnected: #{inspect(disconnect_line(log))}"

      assert probe.outcome == :ok, "the background worker was still starved: #{inspect(probe)}"

      assert probe.waited_ms < 300,
             "the probe was served, but only after queueing #{probe.waited_ms} ms — " <>
               "the COPY is still touching the shared pool"

      # And the export still did its job: the COPY really ran, on the other pool.
      # A probe that sails through while the COPY never held anything proves
      # nothing, so the hold is asserted, not assumed.
      assert copy_ms >= @copy_hold_s * 1000,
             "the COPY did not actually hold for #{@copy_hold_s}s (#{copy_ms} ms)"
    end
  end

  test "the dedicated pool is disabled by config under the SQL sandbox" do
    assert Repo.export_pool_size() == 0
    assert Repo.start_export_pool() == :disabled
    # …and `nil` degrades to the caller's own repo rather than raising.
    assert Repo.with_export_repo(nil, fn -> :ran end) == :ran
  end

  # ── harness ────────────────────────────────────────────────────────────────

  # Occupy @peer_holders members, run the shipped run_copy_out/3 against the
  # remaining one (or against its own pool), and time an unrelated client's
  # checkout while the COPY is in flight.
  defp run_starvation_probe(shared, export_repo) do
    {outcome, log} =
      with_log(fn -> do_starvation_probe(shared, export_repo) end)

    Map.put(outcome, :log, log)
  end

  defp do_starvation_probe(shared, export_repo) do
    peers = Enum.map(1..@peer_holders, fn _ -> hold_connection(shared, @peer_hold_s) end)
    # Every peer must be HOLDING before the COPY starts — otherwise the probe
    # could be served by a member nobody had taken yet and the test would
    # measure nothing.
    Enum.each(peers, fn peer -> assert_receive {:holding, ^peer}, 5_000 end)

    spill =
      Path.join(
        System.tmp_dir!(),
        "bp-w10r12-export-pool-#{System.unique_integer([:positive])}.copy"
      )

    on_exit(fn -> File.rm(spill) end)

    copy_started = System.monotonic_time(:millisecond)
    parent = self()

    copy =
      Task.async(fn ->
        # The export's own catalog/manifest work runs on the shared repo; only
        # the COPY moves. Mirror that: put the task on the shared pool first.
        Repo.put_dynamic_repo(shared)
        send(parent, {:copying, self()})

        WorkspaceBundle.run_copy_out(
          "COPY (SELECT pg_sleep(#{@copy_hold_s})) TO STDOUT",
          spill,
          export_repo
        )
      end)

    assert_receive {:copying, _}, 5_000
    # Give the COPY time to take its connection. Without this the probe can win
    # the race and pass for the wrong reason.
    Process.sleep(300)

    probe = probe_shared_pool(shared)

    Task.await(copy, 30_000)
    copy_ms = System.monotonic_time(:millisecond) - copy_started

    Enum.each(peers, fn peer -> send(peer, :release) end)
    # Let the pool's own disconnect logging land before capture_log stops.
    Process.sleep(300)

    %{probe: probe, copy_ms: copy_ms}
  end

  defp disconnect_line(log) do
    log
    |> String.split("\n")
    |> Enum.find(:none, &String.contains?(&1, "timed out because it queued"))
  end

  # The stand-in for EdgeProjector.ProjectorWorker: an unrelated, trivial query
  # that only ever fails because it could not get a connection.
  defp probe_shared_pool(shared) do
    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(shared)
        started = System.monotonic_time(:millisecond)

        result =
          try do
            # queue_target/queue_interval are POOL options, not per-call
            # ones — they are set on the pool in start_real_pool/1, at Ecto's
            # own defaults, which is what prod runs (config/test.exs's widened
            # 5_000/30_000 deliberately DO NOT transfer to prod, per the note
            # above `repo_opts` in config/runtime.exs).
            Repo.query!("SELECT 1", [], timeout: @probe_timeout_ms)

            {:ok, ""}
          rescue
            error -> {:timed_out, Exception.message(error)}
          catch
            :exit, reason -> {:timed_out, inspect(reason)}
          end

        {outcome, message} = result

        %{
          outcome: outcome,
          message: message,
          waited_ms: System.monotonic_time(:millisecond) - started
        }
      end)

    Task.await(task, 30_000)
  end

  # Hold one member of `pool` for `seconds` with a server-side sleep: the
  # connection is OCCUPIED, the box is not loaded (one idle backend, no CPU).
  defp hold_connection(pool, seconds) do
    parent = self()

    spawn(fn ->
      Repo.put_dynamic_repo(pool)
      send(parent, {:holding, self()})

      # The hold is what matters; how it ENDS does not. When the probe's holder
      # is disconnected, DBConnection takes this peer's socket down with the
      # pool's reconnect, and an unrescued raise here would only add noise to a
      # log the assertions read.
      try do
        Repo.query!("SELECT pg_sleep(#{seconds})", [], timeout: :infinity)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      receive do
        :release -> :ok
      after
        0 -> :ok
      end
    end)
  end

  # `Supervisor.stop/3` on a repo supervisor exits `:shutdown` rather than
  # returning — a teardown detail, never a test result.
  defp stop_pool(pid) do
    if Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # A REAL pool (never Ecto.Adapters.SQL.Sandbox) on the partitioned test
  # database, standing in for prod's shared Repo pool.
  defp start_real_pool(size) do
    name = :"w10r12_shared_#{System.unique_integer([:positive, :monotonic])}"

    opts =
      Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size, :pool_count, :queue_target, :queue_interval])
      |> Keyword.merge(
        name: name,
        pool: DBConnection.ConnectionPool,
        pool_size: size,
        # PROD's values, not config/test.exs's widened 5_000/30_000 — the whole
        # point is to measure what guerrilla's pool does.
        queue_target: 50,
        queue_interval: 1_000
      )

    {:ok, pid} = Repo.start_link(opts)
    {:ok, name, pid}
  end
end
