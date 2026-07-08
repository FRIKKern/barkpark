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

  defp tick! do
    pid = Process.whereis(Metrics)
    assert is_pid(pid), "Metrics should be supervised via the pulse plugin"
    send(pid, :tick)
    _ = :sys.get_state(pid)
    pid
  end

  test "bumps flow into per-interval rates and vitals are sane" do
    tick!()

    for _ <- 1..10, do: Metrics.bump(:cursor)
    for _ <- 1..3, do: Metrics.bump(:strike)
    tick!()

    snap = Metrics.snapshot()
    assert snap.sampled
    assert snap.cursor_per_s > 0
    assert snap.strikes_per_min > 0
    assert snap.cpu_util >= 0.0 and snap.cpu_util <= 1.0
    assert snap.mem_mb > 0
  end

  test "a quiet interval decays the rates back to zero" do
    Metrics.bump(:cursor)
    tick!()
    tick!()
    assert Metrics.snapshot().cursor_per_s == 0.0
  end

  test "every tick broadcasts public vitals on each configured channel topic" do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "pulse:test-storm")
    tick!()

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
    tick!()
    a = Barkpark.Pulse.Metrics.snapshot().cost_eur_total
    tick!()
    b = Barkpark.Pulse.Metrics.snapshot().cost_eur_total
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
