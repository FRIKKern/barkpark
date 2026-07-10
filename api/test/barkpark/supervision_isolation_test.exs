defmodule Barkpark.SupervisionIsolationTest do
  @moduledoc """
  Protective test for the top-level supervision restructuring (task
  task-d328fb91ff55b743).

  It reproduces the NAMED failure mode on a replica of the OLD flat topology and
  proves the NEW tiered topology contains it — using the exact scenario the audit
  named: "several workers each crashing ONCE inside the same 5s window during a
  Postgres blip" breaching the shared 3-restarts-in-5s budget.

  Under the FLAT replica (all children direct, one default budget) the burst of
  independent single-crashes exceeds the budget and the WHOLE supervisor
  terminates — the critical "Repo/Endpoint" sentinel dies with it.

  Under the TIERED replica (the volatile workers wrapped in their own supervisor
  with its own budget, mirroring `Barkpark.Plugins.Supervisor` at 5/10s) the same
  burst is absorbed by the sub-supervisor, the top supervisor sees zero child
  deaths, and the critical sentinel stays up on its original pid.
  """
  use ExUnit.Case, async: true

  # A worker that starts cleanly, then crashes EXACTLY ONCE at runtime (its first
  # incarnation) — modelling a transient blip. The restarted incarnation stays
  # up. The ETS counter (seeded per test) makes "crash once" deterministic.
  defmodule BlipWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      id = Keyword.fetch!(opts, :id)
      table = Keyword.fetch!(opts, :table)
      # First incarnation → schedule a one-shot crash. Subsequent incarnations
      # (counter > 1) start clean.
      if :ets.update_counter(table, id, {2, 1}, {id, 0}) == 1 do
        send(self(), :blip)
      end

      {:ok, %{}}
    end

    @impl true
    def handle_info(:blip, state), do: {:stop, :blip, state}
  end

  # Stand-in for Repo/Oban/Endpoint: starts and stays alive forever.
  defmodule Sentinel do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  # 4 blip workers: 4 runtime restarts in the same instant window — strictly more
  # than the default budget of 3 (flat topology escalates), but within the
  # volatile tier's 5/10s budget (tiered topology absorbs).
  @blip_count 4

  setup do
    table = :ets.new(:blip_counters, [:public, :set])
    on_exit(fn -> if :ets.info(table) != :undefined, do: :ets.delete(table) end)
    {:ok, table: table}
  end

  defp blip_children(table) do
    for i <- 1..@blip_count do
      Supervisor.child_spec({BlipWorker, id: i, table: table},
        id: {:blip, i},
        restart: :permanent
      )
    end
  end

  test "FLAT topology: a burst of single-crash workers breaches the shared budget and takes the whole tree down",
       %{table: table} do
    Process.flag(:trap_exit, true)

    sentinel_spec = Supervisor.child_spec({Sentinel, []}, id: :sentinel)

    children = [sentinel_spec | blip_children(table)]

    {:ok, sup} =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 5
      )

    [{:sentinel, sentinel_pid, _, _}] =
      Supervisor.which_children(sup) |> Enum.filter(fn {id, _, _, _} -> id == :sentinel end)

    sup_ref = Process.monitor(sup)
    sentinel_ref = Process.monitor(sentinel_pid)

    # Escalation: the top supervisor terminates, taking the critical sentinel
    # sibling with it (total-outage repro).
    assert_receive {:DOWN, ^sup_ref, :process, ^sup, _reason}, 2_000
    assert_receive {:DOWN, ^sentinel_ref, :process, ^sentinel_pid, _}, 2_000
  end

  test "TIERED topology: the same burst is contained to the volatile sub-supervisor; the critical sentinel survives",
       %{table: table} do
    Process.flag(:trap_exit, true)

    # Volatile tier mirrors Barkpark.Plugins.Supervisor: own budget 5/10s.
    volatile_tier =
      %{
        id: :volatile_tier,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             blip_children(table),
             [strategy: :one_for_one, max_restarts: 5, max_seconds: 10]
           ]}
      }

    sentinel_spec = Supervisor.child_spec({Sentinel, []}, id: :sentinel)

    {:ok, sup} =
      Supervisor.start_link([sentinel_spec, volatile_tier],
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 5
      )

    [{:sentinel, sentinel_pid, _, _}] =
      Supervisor.which_children(sup) |> Enum.filter(fn {id, _, _, _} -> id == :sentinel end)

    sup_ref = Process.monitor(sup)
    sentinel_ref = Process.monitor(sentinel_pid)

    # Give the blip burst time to fire and be absorbed by the sub-supervisor.
    refute_receive {:DOWN, ^sup_ref, :process, ^sup, _}, 800
    refute_receive {:DOWN, ^sentinel_ref, :process, ^sentinel_pid, _}, 10

    # Top supervisor and the ORIGINAL sentinel pid are both still alive: the
    # crash burst never escalated past the volatile tier.
    assert Process.alive?(sup)
    assert Process.alive?(sentinel_pid)

    # And every blip worker recovered inside the sub-supervisor (4 running).
    [{:volatile_tier, tier_pid, :supervisor, _}] =
      Supervisor.which_children(sup) |> Enum.filter(fn {id, _, _, _} -> id == :volatile_tier end)

    assert %{active: @blip_count, workers: @blip_count} =
             Supervisor.count_children(tier_pid) |> Map.take([:active, :workers])

    Supervisor.stop(sup)
  end
end
