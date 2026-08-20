defmodule BarkparkCloud.TerminalWriteCensus.EpochThiefRelay do
  @moduledoc """
  A BOX THAT STEALS THE LEASE MID-RUN — the census's instrument.

  Everything `FakeBoxRelay` does, plus one thing it cannot: at a programmed
  moment it bumps the driven deployment's `claim_epoch` past the epoch the
  running driver is holding, exactly as a `StaleDeploymentReaper` requeue + a
  fresh claim does on prod (`deployment_stale_after_seconds` defaults to 15
  minutes, and `record_stage/2` only heartbeats on a stage TRANSITION, so a BUILD
  stage longer than that lets the reaper move the row under a driver that is
  still running). From that moment on, every `transition_deployment_fenced/4` the
  driver issues answers `{:error, :stale_epoch}` — which is the ONLY way to reach
  the four discarded terminal writes this census is about.

  It is programmed from, and steals in, the DRIVING process: the census calls
  `Sites.Deploy.run/1` synchronously, so there is no Task and no `$callers` hop,
  and the sandbox connection is the test's own.
  """

  @behaviour BarkparkCloud.Sites.BoxRelay

  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Repo

  import Ecto.Query, only: [from: 2]

  @key :terminal_write_census_relay

  @doc """
  Program the box for this process.

    * `:start` — the reply to `start_deploy/2`
    * `:polls` — replies to `poll_deploy/3`, consumed in order; the last repeats
    * `:rollback` — the reply to `rollback/2`
    * `:steal` — WHEN the lease is stolen: `:start` (before the start reply) or
      `{:poll, n}` (before the n-th poll reply), or `nil` (never)
    * `:steal_from` — the deployment id whose `claim_epoch` is bumped
  """
  def program(opts) do
    Process.put(@key, %{
      start: Keyword.get(opts, :start, {:ok, 202, %{"status" => "started"}}),
      polls: Keyword.get(opts, :polls, []),
      rollback: Keyword.get(opts, :rollback, {:ok, 200, %{"status" => "rolled_back"}}),
      steal: Keyword.get(opts, :steal),
      steal_from: Keyword.get(opts, :steal_from),
      polls_seen: 0
    })

    :ok
  end

  @impl true
  def start_deploy(_bp, _payload) do
    state = state()
    maybe_steal(state, :start)
    state.start
  end

  @impl true
  def poll_deploy(_bp, _slug, _build_id) do
    state = state()
    n = state.polls_seen + 1
    Process.put(@key, %{state | polls_seen: n})
    maybe_steal(state, {:poll, n})

    Enum.at(state.polls, n - 1) || List.last(state.polls) ||
      {:ok, 200, %{"state" => "running", "stages" => []}}
  end

  @impl true
  def rollback(_bp, _payload), do: state().rollback

  @impl true
  def teardown(_bp, _payload), do: {:ok, 200, %{"status" => "torn_down"}}

  # The theft itself: the epoch moves to the claim CAP, which is both "past the
  # driver's view" (every fenced write now loses) and the state a row is in after
  # its lease has been swept and re-claimed to the budget — the shape the reaper's
  # over-budget pass terminates.
  defp maybe_steal(%{steal: when_to, steal_from: id}, now)
       when now == when_to and is_binary(id) do
    {1, _} =
      Repo.update_all(
        from(d in Deployment, where: d.id == ^id),
        set: [claim_epoch: BarkparkCloud.Registry.max_deploy_claims()]
      )

    :ok
  end

  defp maybe_steal(_state, _now), do: :ok

  defp state, do: Process.get(@key) || %{start: nil, polls: [], rollback: nil, polls_seen: 0}
end

defmodule BarkparkCloud.TerminalWriteCensusTest do
  @moduledoc """
  deploy-reliability W27 — THE FOUR TERMINAL WRITES THE DRIVER DISCARDS.

  `grep -n '^\\s*_ ='` over `lib/barkpark_cloud/sites/deploy.ex` returns four
  sites, and every one of them is at the END of a path, where a lost write costs
  the most: `defer/3` (:1300), the deferral's own `fail/2` call (:1357, benign —
  it inherits arm A), `fail/2` (:1462) and `finish_rollback/4` (:1711). Each
  discards the result of the LAST write the driver will ever make about that
  deployment, and `Deploy.TaskStarter.start/1` discards the driver's return value
  by construction — so in production the ROW WRITE IS THE ONLY CARRIER, and a
  lost one carries nothing at all.

  ## THE PREDICATE — one sentence, four arms

  > A terminal write whose result the driver LOST must be OBSERVABLE: either the
  > durable state reflects the terminal outcome, or a log line NAMES the
  > deployment whose terminal write was lost.

  The disjunction is deliberate. This wave does NOT change a single return shape
  (making `fail/2` answer `{:error, _}` would route through
  `AutoDeployWorker.start_and_report/2`'s "could not start the driver — retrying"
  arm: a NEW mis-report plus an Oban retry of a build that did start), and it
  does not fabricate a durable write the fence just refused. What it refuses is
  SILENCE.

    * ARM A — `fail/2` loses its fenced CAS: the row is not `failed`,
      `failure_reason` is nil, AND no failure alert fires either, because
      `maybe_dispatch_deployment_failed/2` lives inside the WON-CAS branch
      (`registry.ex:6754-6757`). The failure had no carrier at all.
    * ARM B — `settle_live/2` loses its CAS on a build the box IS serving. The
      row never goes live, the site pointer never flips, and the stale reaper
      then terminally reports that SERVING build `failed`, blaming the lease.
    * ARM C — `finish_rollback/4` SKIPS the site-pointer write when `now_live` is
      nil and still answers 200.
    * ARM D — `defer/3` loses the deferral row entirely: the rebuild IS enqueued,
      but the row never becomes `deferred` and `deferral_depth` / `_bound` /
      `_cause` are never written. A COUNTING defect — invisible to every deferral
      census and to the post-door rate this epic publishes.

  ## THE SPOKEN HALF IS A CONTRACT, not an incidental assertion

  Three of the four arms can only be satisfied by SPEECH (the durable half is
  what the fence refused), so this census asserts on `capture_log` output. That
  makes the wording load-bearing, and it is declared here rather than left
  implicit: **a fix must NAME the lost terminal write — the log line must carry
  the deployment id (arm C: the site id) and say WHICH write was lost and what
  the row therefore does NOT say.** A keyword-shaped assertion whose contract is
  undeclared is exactly the class `dr-w27-s3` audits; this one is declared, and a
  reworded fix is expected to update this moduledoc with it.

  ## Behavioural, never a source scan

  Every arm drives the REAL driver (`Sites.Deploy.run/1`, `Sites.Deploy.rollback/2`)
  against `EpochThiefRelay`, a box that steals `claim_epoch` mid-run, and asserts
  on Postgres rows plus captured logs. Nothing here greps `deploy.ex`.

  `async: false` is LOAD-BEARING: the module swaps `:site_box_relay` through
  `Application.put_env/3`, which is one GLOBAL for the whole node — an async
  module would point every concurrently running cloud test at this thief.
  """

  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, Site, Vault}
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.TerminalWriteCensus.EpochThiefRelay
  alias BarkparkCloud.Workers.StaleDeploymentReaper

  @instance_url "https://acme.barkpark.cloud"
  @read_token "bpt_public_read_xyz"

  setup do
    previous = Application.get_env(:barkpark_cloud, :site_box_relay)
    Application.put_env(:barkpark_cloud, :site_box_relay, EpochThiefRelay)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark_cloud, :site_box_relay)
        mod -> Application.put_env(:barkpark_cloud, :site_box_relay, mod)
      end
    end)

    :ok
  end

  ## Fixtures ------------------------------------------------------------------

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: @read_token
      })

    site
  end

  defp setup_site do
    bp = team_fixture() |> live_barkpark()
    {bp, static_site(bp)}
  end

  # The box's report shape, same fold `FakeBoxRelay.walk/2` uses.
  defp walk(stage_names) do
    stages = Enum.map(stage_names, &%{"name" => &1, "status" => "done", "detail" => "#{&1} ok"})
    state = if "RETIRE" in stage_names, do: "succeeded", else: "running"
    {:ok, 200, %{"state" => state, "stages" => stages, "url" => nil}}
  end

  # A TYPED 5xx — the box stating a real fault about itself, terminal on the
  # first answer (an UNTYPED one is graced and retried, which would never reach
  # `fail/2`).
  defp typed_500 do
    {:ok, 500,
     %{
       "error" => %{
         "code" => "runner_start_failed",
         "message" => "the deploy runner could not be started",
         "request_id" => "W27-typed"
       }
     }}
  end

  # The box refusing because a run for this slug is already in flight — the ONE
  # transient refusal, and the only way into `defer/3`.
  defp busy_409 do
    {:ok, 409,
     %{"error" => %{"code" => "already_running", "message" => "a deploy is already running"}}}
  end

  defp reload(%Deployment{id: id}), do: Repo.get(Deployment, id)
  defp reload_site(%Site{id: id}), do: Repo.get(Site, id)

  ## ---------------------------------------------------------------------------
  ## ARM A — fail/2 (deploy.ex:1462)
  ## ---------------------------------------------------------------------------

  test "ARM A: a fail/2 whose fenced CAS is lost NAMES the deployment, and says the row is not failed AND no alert fired" do
    {bp, site} = setup_site()
    {:ok, d} = Deploy.enqueue(site, bp)

    EpochThiefRelay.program(start: typed_500(), steal: :start, steal_from: d.id)

    log = capture_log(fn -> assert {:ok, :failed} = Deploy.run(d.id) end)

    # THE DURABLE HALF IS GONE — this is the finding, not a bug in the census.
    # The fence was right to refuse (someone else owns the row); what is wrong is
    # that nothing said so.
    row = reload(d)
    assert row.status == "building"
    assert is_nil(row.failure_reason)

    # …so the SPOKEN half must carry it. The contract (see @moduledoc): NAME the
    # deployment, name WHICH write was lost, and state what the row does not say.
    assert log =~ d.id
    assert log =~ "could not be recorded"
    assert log =~ "was NOT marked failed"
    # And the second half of arm A, the one that makes this a total blackout:
    # `maybe_dispatch_deployment_failed/2` is inside the won-CAS branch, so a
    # lost CAS silences the alert too.
    assert log =~ "no failure alert"
    # The box's own words survive into the line — otherwise the operator learns
    # that something was lost but never what it was.
    assert log =~ "runner_start_failed"
  end

  ## ---------------------------------------------------------------------------
  ## ARM B — settle_live/2 (deploy.ex:1127-1150)
  ## ---------------------------------------------------------------------------

  test "ARM B: a settle_live/2 whose CAS is lost says the box IS serving this build — and the reaper then reports that serving build failed" do
    {bp, site} = setup_site()
    {:ok, d} = Deploy.enqueue(site, bp)

    # Poll 1 walks to HEALTH (still `building`, CASes win). The lease is stolen
    # on the way into poll 2, which reports the run SUCCEEDED — the box has
    # switched, the release is serving, and every write the driver has left
    # loses.
    EpochThiefRelay.program(
      polls: [walk(~w(PLAN BUILD STAGE HEALTH)), walk(~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE))],
      steal: {:poll, 2},
      steal_from: d.id
    )

    log = capture_log(fn -> assert {:error, :stale_epoch} = Deploy.run(d.id) end)

    row = reload(d)
    refute row.status == "live"
    assert is_nil(row.became_live_at)
    # The site still points nowhere: visitors are being served a build the
    # control plane does not know is live.
    assert is_nil(reload_site(site).current_deployment_id)

    assert log =~ d.id
    assert log =~ "could not be recorded"
    assert log =~ "is serving"
    assert log =~ "never went live"
    # The line must also name what happens NEXT, because that is the mis-report
    # the operator will actually see (asserted for real below).
    assert log =~ "reaper"

    # WHAT HAPPENS WITHOUT THE LINE. The row is `building` with a claim_epoch at
    # the budget and a lease nobody is renewing, so the stale reaper's
    # over-budget pass terminates it — a SUCCESSFUL deploy, still serving, ends
    # as a terminal `failed` row blaming the builder lease.
    stale_at =
      DateTime.utc_now()
      |> DateTime.add(-(Registry.deployment_stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(from(x in Deployment, where: x.id == ^d.id), set: [claimed_at: stale_at])

    assert {:ok, %{failed: 1, requeued: 0}} = perform_job(StaleDeploymentReaper, %{})

    reaped = reload(d)
    assert reaped.status == "failed"
    assert reaped.failure_reason == "exceeded max deploy claim attempts (stale builder lease)"
  end

  ## ---------------------------------------------------------------------------
  ## ARM C — finish_rollback/4 (deploy.ex:1704-1731)
  ## ---------------------------------------------------------------------------

  # THE FIXTURE IS CODE-REAL, PROD-UNEXHIBITED: the box naming a build the
  # control plane has no Deployment row for is reachable straight from the code
  # (a build deployed before the row was pruned, a box restored from a snapshot),
  # but it was not observed on prod this wave. Note also that
  # `sites.current_deployment_id` has no FK, so the DISCARDED `Repo.update`
  # result is near-unfailable — the loss here is the SKIPPED write, not a failed
  # one, and that is what the predicate has to catch.
  test "ARM C: a rollback that SKIPS the site-pointer write still answers 200 — so it must say the pointer did not move" do
    {bp, site} = setup_site()

    # The site is live on a build the control plane knows.
    {:ok, current} = Deploy.enqueue(site, bp)
    {:ok, site} = Registry.set_site_current_deployment(site, current.id)
    pointer_before = reload_site(site).current_deployment_id
    assert pointer_before == current.id

    # The box rolls back to a build with no Deployment row: `now_live` is nil, so
    # the pointer write never happens.
    EpochThiefRelay.program(
      rollback: {:ok, 200, %{"status" => "rolled_back", "build_id" => "b-unknown-to-us"}}
    )

    log =
      capture_log(fn ->
        assert {:ok, %{deployment_id: nil, previous_deployment_id: ^pointer_before}} =
                 Deploy.rollback(site, bp)
      end)

    # 200 out, pointer unmoved: `bp cloud site status` still names the build the
    # site just rolled AWAY from.
    pointer_after = reload_site(site).current_deployment_id
    assert pointer_after == pointer_before

    assert log =~ site.id
    assert log =~ "b-unknown-to-us"
    assert log =~ "was SKIPPED"
    assert log =~ "still names"
  end

  ## ---------------------------------------------------------------------------
  ## ARM D — defer/3 (deploy.ex:1300)
  ## ---------------------------------------------------------------------------

  test "ARM D: a deferral whose CAS is lost is a COUNTING defect — the rebuild is queued but no deferred row exists" do
    {bp, site} = setup_site()
    {:ok, d} = Deploy.enqueue(site, bp)

    EpochThiefRelay.program(start: busy_409(), steal: :start, steal_from: d.id)

    log = capture_log(fn -> assert {:ok, :deferred} = Deploy.run(d.id) end)

    # The PROMISE held (the rebuild really is queued)…
    assert [_job] =
             Repo.all(
               from(j in Oban.Job,
                 where:
                   j.worker == "BarkparkCloud.Sites.AutoDeployWorker" and
                     fragment("?->>'site_id' = ?", j.args, ^site.id) and
                     j.state in ["available", "scheduled"]
               )
             )

    # …but the ROW does not exist, so this deferral is uncountable: it is in no
    # deferral census, in no chain depth, and in no post-door rate.
    row = reload(d)
    refute row.status == "deferred"
    assert is_nil(row.deferral_depth)
    assert is_nil(row.deferral_bound)
    assert is_nil(row.deferral_cause)

    assert log =~ d.id
    assert log =~ "could not be recorded"
    assert log =~ "deferral_depth"
    assert log =~ "invisible"
  end
end
