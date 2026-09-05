defmodule Barkpark.SupervisionIsolationTest do
  @moduledoc """
  Protective test for the top-level supervision restructuring (task
  task-d328fb91ff55b743).

  It reproduces the NAMED failure mode on a replica of the OLD flat topology and
  proves the NEW tiered topology contains it — using the exact scenario the audit
  named: "several workers each crashing ONCE during a Postgres blip" breaching a
  shared restart-intensity budget.

  Under the FLAT replica (all children direct, one shared budget) the burst of
  independent single-crashes exceeds the intensity budget and the WHOLE
  supervisor terminates — the critical "Repo/Endpoint" sentinel dies with it.

  Under the TIERED replica (the volatile workers wrapped in their own supervisor
  with its own budget, mirroring `Barkpark.Plugins.Supervisor`) the same burst is
  absorbed by the sub-supervisor, the top supervisor sees zero child deaths, and
  the critical sentinel stays up on its original pid.

  ## Determinism (why this used to flake, task-d7787d0a0260f95d)

  OTP's restart-intensity is a rolling WALL-CLOCK window (`max_seconds`): a burst
  breaches only if `max_restarts + 1` restarts all land inside ONE window. The
  original replica used a 5s window, so on a loaded CI box the 4 restarts could
  spread past 5s — the earliest aged out before the last landed, `count` never
  exceeded the budget, and the "tree terminates" assertion falsely reds (confirmed
  flaky: passed on #2403, failed on #2431, same code).

  The fix keeps the audit's exact scenario — a burst of 4 single-crashes breaching
  an intensity budget of 3 — but sets `max_seconds` to `@intensity_window_s`, a
  window no test run can outlast. The crash COUNT is already deterministic: the
  ETS counter makes each worker crash EXACTLY once and `restart: :permanent`
  guarantees exactly one restart per crash, so exactly 4 restarts occur. With a
  window wide enough that none age out, `4 > 3` holds on every run regardless of
  wall-clock scheduling. Intensity, not timing, decides the outcome — the FLAT
  supervisor now always escalates and the TIERED sub-supervisor (budget 5, so
  `4 <= 5`) always absorbs.
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
    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    # When given the test's ETS table, register our pid at init: the FLAT test
    # must be able to find the sentinel WITHOUT calling the supervisor — the
    # burst can escalate before any which_children call returns (live flake:
    # GenServer.call(:which_children) → (EXIT) shutdown). Child starts are
    # synchronous, so the row exists the instant start_link(sup) returns.
    @impl true
    def init([]), do: {:ok, :ok}

    def init(table) do
      :ets.insert(table, {:sentinel, self()})
      {:ok, :ok}
    end
  end

  # 4 blip workers: 4 runtime restarts — strictly more than the flat budget of 3
  # (flat topology escalates), but within the volatile tier's budget of 5 (tiered
  # topology absorbs).
  @blip_count 4

  # Restart-intensity budgets. The top budget is IDENTICAL in both topologies so
  # the ONLY variable under test is the topology (flat vs tiered).
  @top_max_restarts 3
  @tier_max_restarts 5

  # A restart-intensity window (`max_seconds`) wide enough that no test run can
  # outlast it. This decouples the 4-restart intensity breach from wall-clock
  # scheduling: all 4 restarts are always counted inside one window, so `4 > 3`
  # holds deterministically even on a starved CI box. (The original 5s window was
  # the sole source of the flake — a loaded box could spread the restarts past
  # it.) `max_seconds` must be a positive integer.
  @intensity_window_s 3600

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

    sentinel_spec = Supervisor.child_spec({Sentinel, table}, id: :sentinel)

    children = [sentinel_spec | blip_children(table)]

    {:ok, sup} =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        max_restarts: @top_max_restarts,
        max_seconds: @intensity_window_s
      )

    sup_ref = Process.monitor(sup)

    # Never ask the supervisor: the escalation under test can complete before a
    # which_children call returns (observed live as `(EXIT) shutdown` from the
    # probe itself). The sentinel registered its pid in ETS during its own init;
    # monitoring an already-dead pid delivers an immediate :DOWN (:noproc),
    # which the assertion below accepts as the same outcome.
    [{:sentinel, sentinel_pid}] = :ets.lookup(table, :sentinel)
    sentinel_ref = Process.monitor(sentinel_pid)

    # Escalation: the top supervisor terminates, taking the critical sentinel
    # sibling with it (total-outage repro). The outcome is deterministic (4 > 3
    # in a window nothing outlasts); the generous timeout only bounds patience on
    # a scheduler-starved box — it never masks a regression (a tree that fails to
    # die just times out here and reds).
    assert_receive {:DOWN, ^sup_ref, :process, ^sup, _reason}, 5_000
    assert_receive {:DOWN, ^sentinel_ref, :process, ^sentinel_pid, _}, 5_000
  end

  test "TIERED topology: the same burst is contained to the volatile sub-supervisor; the critical sentinel survives",
       %{table: table} do
    Process.flag(:trap_exit, true)

    # Volatile tier mirrors Barkpark.Plugins.Supervisor: its OWN budget, wide
    # enough (5 restarts) to absorb the 4-crash burst.
    volatile_tier =
      %{
        id: :volatile_tier,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             blip_children(table),
             [
               strategy: :one_for_one,
               max_restarts: @tier_max_restarts,
               max_seconds: @intensity_window_s
             ]
           ]}
      }

    sentinel_spec = Supervisor.child_spec({Sentinel, []}, id: :sentinel)

    # Top budget is IDENTICAL to the FLAT test — topology is the only variable.
    {:ok, sup} =
      Supervisor.start_link([sentinel_spec, volatile_tier],
        strategy: :one_for_one,
        max_restarts: @top_max_restarts,
        max_seconds: @intensity_window_s
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

  # Read a supervisor module's own flags by calling its `init/1` — pure here
  # (it only builds child specs), and it reads the SHIPPED module, not a copy.
  defp supervisor_flags(module, arg) do
    {:ok, {flags, _children}} = module.init(arg)
    flags
  end

  describe "the REAL intermediate supervisors carry a WIDER budget than the top tier" do
    # The tests above prove the DOCTRINE on a synthetic tier built with
    # @tier_max_restarts — they never read a real module, so an intermediate
    # supervisor that silently kept the OTP default 3/5s passed them all.
    # These read the shipped modules' own supervisor flags.
    #
    # Why the default is the bug and not merely a smell: `Barkpark.Supervisor`
    # ALSO runs 3/5s. A tier whose budget equals its parent's cannot absorb a
    # burst its parent would not have absorbed — the wall and the thing behind
    # the wall fall over in the same window.

    test "the reader can see the OTP default it must reject (non-vacuity)" do
      # If `Supervisor.init/2`'s flag map ever renamed :intensity/:period this
      # assertion breaks FIRST, so a green below can never be a green on a key
      # that silently read nil.
      {:ok, {default_flags, _}} = Supervisor.init([], strategy: :one_for_one)

      assert %{intensity: 3, period: 5} = Map.take(default_flags, [:intensity, :period])
    end

    test "Barkpark.StudioChat.Supervisor widens to 5 restarts / 10 seconds" do
      studio_chat = supervisor_flags(Barkpark.StudioChat.Supervisor, :ok)

      assert studio_chat.intensity == 5
      assert studio_chat.period == 10
    end

    test "the studio_chat budget is strictly wider than the top supervisor's" do
      studio_chat = supervisor_flags(Barkpark.StudioChat.Supervisor, :ok)
      {:ok, {top, _}} = Supervisor.init([], strategy: :one_for_one)

      refute {studio_chat.intensity, studio_chat.period} == {top.intensity, top.period}
      assert studio_chat.intensity > top.intensity
    end

    test "it matches the corrected sibling Barkpark.Plugins.Supervisor" do
      studio_chat = supervisor_flags(Barkpark.StudioChat.Supervisor, :ok)
      plugins = supervisor_flags(Barkpark.Plugins.Supervisor, [])

      assert {studio_chat.intensity, studio_chat.period} ==
               {plugins.intensity, plugins.period}
    end
  end
end
