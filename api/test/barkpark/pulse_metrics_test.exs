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
