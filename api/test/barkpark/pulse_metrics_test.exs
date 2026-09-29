defmodule Barkpark.Pulse.MetricsTest do
  @moduledoc """
  The live cost sampler (already supervised via the pulse plugin's
  register_workers in the test app): hot-path bumps land in the tick's rate
  snapshot, CPU utilization is a sane fraction, rates decay to zero on a
  quiet interval, and with no counters registered the bump is a no-op.
  """

  use ExUnit.Case, async: false

  alias Barkpark.Pulse.Metrics

  @counters_key {Barkpark.Pulse.Metrics, :counters}

  # DB-touching tests (durable cost meter) need a connection; shared mode so the
  # globally-supervised Metrics process can reach it too if it flushes.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})
    :ok
  end

  # DEFLAKE (felix-w28-s4): the globally-supervised sampler has its OWN 2 s
  # autonomous `Process.send_after(:tick)` loop. The old helper `send(pid,
  # :tick)` competed with it: an autonomous tick firing between a test's bump
  # loop and its explicit tick would DRAIN the counters (`:counters.put(…, 0)`),
  # so `snapshot().cursor_per_s` read 0.0 (this reds #12039 attempt-1 —
  # `assert snap.cursor_per_s > 0`, left: 0.0, at line 40 — while attempt-2 on
  # the SAME sha was green: a load-sensitive race, not a real regression).
  # `Metrics.sample_now/0` samples SYNCHRONOUSLY and cancels the pending
  # autonomous tick without re-arming, so once we call it the 2 s timer can no
  # longer drain the counter mid-test. Re-introducing the race (swap `sample!`
  # back to `send(pid, :tick)` and remove the sync barrier) reds this test.
  defp sample! do
    pid = Process.whereis(Metrics)
    assert is_pid(pid), "Metrics should be supervised via the pulse plugin"
    Metrics.sample_now()
  end

  test "bumps flow into per-interval rates and vitals are sane" do
    sample!()

    for _ <- 1..10, do: Metrics.bump(:cursor)
    for _ <- 1..3, do: Metrics.bump(:strike)
    snap = sample!()

    assert snap.sampled
    assert snap.cursor_per_s > 0
    assert snap.strikes_per_min > 0
    assert snap.cpu_util >= 0.0 and snap.cpu_util <= 1.0
    assert snap.mem_mb > 0
  end

  test "a quiet interval decays the rates back to zero" do
    Metrics.bump(:cursor)
    sample!()
    snap = sample!()
    assert snap.cursor_per_s == 0.0
  end

  test "every tick broadcasts public vitals on each configured channel topic" do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "pulse:test-storm")
    sample!()

    assert_receive %Phoenix.Socket.Broadcast{event: "vitals", payload: p}, 500
    assert p.cpu >= 0.0 and p.cpu <= 1.0
    assert is_number(p.eur) and p.eur >= 0
    assert is_number(p.eur_total) and p.eur_total >= 0
    assert is_integer(p.online)
    assert p.host_eur > 0
  end

  test "cost accrues into the durable meter and reads back" do
    before = Barkpark.Pulse.cost_nanos()
    :ok = Barkpark.Pulse.add_cost_nanos(12_345)
    assert Barkpark.Pulse.cost_nanos() == before + 12_345
    assert_in_delta Barkpark.Pulse.cost_so_far(), (before + 12_345) / 1_000_000_000, 1.0e-12
  end

  test "the snapshot carries a monotonic cost-so-far total" do
    a = sample!().cost_eur_total
    b = sample!().cost_eur_total
    assert is_number(a) and is_number(b)
    assert b >= a
  end

  describe "graceful shutdown durability" do
    # The defect: cost accrues into `cost_pending_nanos` and only reaches the
    # durable meter once a minute, while `init/1` re-seeds the running total
    # FROM that meter — so a stop that discards the buffer is invisible except
    # as `eur_total` stepping backwards on the dashboard. This box auto-deploys
    # on merge, so the graceful stop is the COMMON path, not a rare crash.
    #
    # These tests drive ISOLATED instances (`name:` opt) rather than the
    # globally-supervised one: stopping the global sampler would take the
    # process every other test in this file calls `sample_now/0` on. An
    # isolated instance's `init/1` overwrites the shared `@counters_key`
    # persistent_term with its own counters ref, so we save and restore it —
    # otherwise later `bump/1` calls would land in an orphaned ref and the
    # rate tests above would read 0.0.
    setup do
      old_ref = :persistent_term.get(@counters_key, nil)

      on_exit(fn ->
        if old_ref, do: :persistent_term.put(@counters_key, old_ref)
      end)

      :ok
    end

    defp start_metrics! do
      name = :"pulse_metrics_shutdown_#{System.unique_integer([:positive])}"
      {:ok, pid} = Metrics.start_link(name: name)
      pid
    end

    test "init/1 traps exits so terminate/2 can run at all" do
      assert Process.info(start_metrics!(), :trap_exit) == {:trap_exit, true}
    end

    test "the child spec's shutdown budget bounds the terminate flush" do
      # A terminate/2 that outlives this budget is brutally killed and the
      # buffer is lost anyway; it must exceed Ecto's default 15_000 query
      # timeout so a stalled Repo times out INSIDE the rescue.
      assert Metrics.child_spec([]).shutdown == 20_000
    end

    test "a sample inside the flush window buffers instead of writing" do
      # ticks starts at 0. The old predicate `rem(ticks, 30) == 0` flushed on
      # this very first sample (a durable meter write 2 s after boot); the
      # corrected `rem(ticks + 1, 30) == 0` does not.
      #
      # The buffer is PINNED non-zero first, deliberately: the naturally
      # accrued amount is `cpu_util * price * elapsed` and rounds to 0 on an
      # idle scheduler, and the flush is guarded by `cost_pending > 0` — so
      # against a zero buffer this assertion would pass under EITHER predicate
      # and control nothing. With 777 pending, reverting the predicate to
      # `rem(state.ticks, 30) == 0` reds this test.
      pid = start_metrics!()
      before = Barkpark.Pulse.cost_nanos()
      :sys.replace_state(pid, &%{&1 | cost_pending_nanos: 777})
      GenServer.call(pid, :sample_now)

      assert Barkpark.Pulse.cost_nanos() == before
      assert :sys.get_state(pid).cost_pending_nanos >= 777
    end

    test "GenServer.stop flushes the pending cost to the durable meter" do
      pid = start_metrics!()
      before = Barkpark.Pulse.cost_nanos()

      # Accrue through the real sampling path, then PIN the buffer to a known
      # amount: the accrued value is `cpu_util * price * elapsed`, which can
      # legitimately round to 0 on an idle scheduler, and this file already
      # carries a deflake scar (felix-w28-s4) from asserting on live sampler
      # dynamics. The invariant under test is "the buffer survives a graceful
      # stop", not "the buffer is non-zero".
      GenServer.call(pid, :sample_now)
      :sys.replace_state(pid, &%{&1 | cost_pending_nanos: 4_242})

      :ok = GenServer.stop(pid, :normal)
      refute Process.alive?(pid)

      # RED before terminate/2 existed: the meter stayed at `before`, and the
      # 4_242 nano-euros were discarded silently.
      assert Barkpark.Pulse.cost_nanos() == before + 4_242
    end

    test "a SUPERVISOR shutdown — the actual deploy path — flushes the buffer" do
      # `GenServer.stop/1` above runs `terminate/2` even on a process that does
      # NOT trap exits (`:proc_lib.stop` goes through the `sys` protocol), so it
      # is not by itself a control on `Process.flag(:trap_exit, true)`. THIS is:
      # a supervisor shuts a child down by sending it `exit(:shutdown)`, which
      # an untrapped process obeys immediately, with no `terminate/2` and no
      # flush. Deleting the trap_exit line reds this test and leaves the
      # GenServer.stop one green.
      name = :"pulse_metrics_sup_#{System.unique_integer([:positive])}"

      {:ok, sup} =
        Supervisor.start_link([{Metrics, [name: name]}], strategy: :one_for_one)

      pid = Process.whereis(name)
      assert is_pid(pid)

      before = Barkpark.Pulse.cost_nanos()
      :sys.replace_state(pid, &%{&1 | cost_pending_nanos: 1_313})

      :ok = Supervisor.stop(sup, :normal)
      refute Process.alive?(pid)

      assert Barkpark.Pulse.cost_nanos() == before + 1_313
    end
  end

  test "bump is a no-op when no counters are registered" do
    old = :persistent_term.get(@counters_key, nil)
    :persistent_term.erase(@counters_key)

    try do
      assert Metrics.bump(:cursor) == :ok
    after
      if old, do: :persistent_term.put(@counters_key, old)
    end
  end
end
