defmodule BarkparkCloud.Workers.StaleProvisionJobReaperTest do
  @moduledoc """
  oban-substrate — the sample worker + its wiring.

  Proves the substrate end to end against the real Sandbox: the worker is on the
  maintenance queue and scheduled every minute (config), `perform_job/2` drives a
  real DB mutation through `Registry.reap_stale_provision_jobs/0`, the sweep is
  idempotent, and the attempt budget is honoured.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs) — no
  background poller touches the sandboxed connection; `perform_job/2` runs the
  worker synchronously inside this test's own transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Workers.StaleProvisionJobReaper

  ## Fixtures (mirror ProvisioningTest)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # A support row bound under a fresh in-team main (mirrors FleetSupportsTest) —
  # the fixture for the per-kind provision_support threshold tests.
  defp support_fixture(team) do
    n = System.unique_integer([:positive])
    main = barkpark_fixture(team)
    {:ok, main} = main |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()

    {:ok, support} =
      Registry.register_support_barkpark(team, %{
        name: "Support #{n}",
        slug: "support-#{n}",
        parent_id: main.id,
        token_id: nil
      })

    support
  end

  # Backdate a claimed job's claimed_at to `seconds_ago` before now.
  defp backdate(job_id, seconds_ago) do
    at =
      DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(j in ProvisionJob, where: j.id == ^job_id),
      set: [claimed_at: at]
    )
  end

  # Claim the just-enqueued job, then backdate its claimed_at past the staleness
  # threshold so the reaper treats it as abandoned. Returns the claimed job id.
  defp claim_and_backdate(token \\ "worker-1") do
    {%ProvisionJob{} = claimed, _bp} = Registry.claim_next_job(token)

    stale_at =
      DateTime.add(DateTime.utc_now(), -(Registry.stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(j in ProvisionJob, where: j.id == ^claimed.id),
      set: [claimed_at: stale_at]
    )

    claimed.id
  end

  ## 1. Cron wiring — the worker is scheduled every minute on the maintenance queue.

  test "reaper is registered every minute on the maintenance queue" do
    crontab =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"* * * * *", StaleProvisionJobReaper} in crontab

    # The worker declares the maintenance queue — read it off a built job
    # changeset (Oban stamps :queue from `use Oban.Worker, queue: :maintenance`).
    assert Ecto.Changeset.get_field(StaleProvisionJobReaper.new(%{}), :queue) == "maintenance"
  end

  ## 2. Happy path — a stale claimed job is re-pended for a fresh worker.

  test "perform re-pends a stale claimed job" do
    team = team_fixture()
    bp = barkpark_fixture(team)
    {:ok, _job} = Registry.enqueue_provision_job(bp)
    job_id = claim_and_backdate()

    assert {:ok, %{reaped: 1, failed: 0}} = perform_job(StaleProvisionJobReaper, %{})

    reaped = Repo.get(ProvisionJob, job_id)
    assert reaped.status == "pending"
    assert is_nil(reaped.claim_token)
    assert is_nil(reaped.claimed_at)
  end

  ## 3. Idempotency — nothing stale is a no-op, never raises.

  test "perform is a no-op when no claimed job is stale" do
    team = team_fixture()
    bp = barkpark_fixture(team)
    # A fresh (non-stale) claim must be left ALONE — a live worker is never raced.
    {:ok, _job} = Registry.enqueue_provision_job(bp)
    {%ProvisionJob{} = fresh, _bp} = Registry.claim_next_job("worker-live")

    assert {:ok, %{reaped: 0, failed: 0}} = perform_job(StaleProvisionJobReaper, %{})

    assert Repo.get(ProvisionJob, fresh.id).status == "claimed"
  end

  ## 4. Attempt budget — a stale job at the cap is failed, not re-pended.

  test "stale job at the attempt cap is failed, not re-pended" do
    team = team_fixture()
    bp = barkpark_fixture(team)
    {:ok, _job} = Registry.enqueue_provision_job(bp)
    job_id = claim_and_backdate()

    # Burn the attempt budget: claim() set attempts to 1; pin it at the cap.
    Repo.update_all(
      from(j in ProvisionJob, where: j.id == ^job_id),
      set: [attempts: Registry.max_provision_attempts()]
    )

    assert {:ok, %{reaped: 0, failed: 1}} = perform_job(StaleProvisionJobReaper, %{})

    failed = Repo.get(ProvisionJob, job_id)
    assert failed.status == "failed"
    assert failed.error =~ "exceeded max provision attempts"
  end

  ## 5. Per-kind threshold (task-314de6aa36248bea) — a healthy provision_support
  ##    chain (30-minute Go worker budget) must never be re-pended at the generic
  ##    ~12-minute threshold: a re-pend double-claims (two billed boxes per add).

  test "a claimed provision_support job aged 20 minutes is NOT re-pended" do
    team = team_fixture()
    support = support_fixture(team)
    {:ok, _job} = Registry.enqueue_support_provision_job(support)
    {%ProvisionJob{} = claimed, _bp} = Registry.claim_next_support_provision_job("support-w1")

    # 20 minutes in: past the generic threshold (12m), well under the support
    # threshold (35m) — the chain is presumed HEALTHY and must be left alone.
    backdate(claimed.id, 20 * 60)

    assert {:ok, %{reaped: 0, failed: 0}} = perform_job(StaleProvisionJobReaper, %{})

    untouched = Repo.get(ProvisionJob, claimed.id)
    assert untouched.status == "claimed"
    assert untouched.claim_token == "support-w1"
  end

  test "a claimed provision_support job aged past the 35-minute support threshold IS re-pended" do
    team = team_fixture()
    support = support_fixture(team)
    {:ok, _job} = Registry.enqueue_support_provision_job(support)
    {%ProvisionJob{} = claimed, _bp} = Registry.claim_next_support_provision_job("support-w1")

    backdate(claimed.id, Registry.support_stale_after_seconds() + 60)

    assert {:ok, %{reaped: 1, failed: 0}} = perform_job(StaleProvisionJobReaper, %{})

    reaped = Repo.get(ProvisionJob, claimed.id)
    assert reaped.status == "pending"
    assert is_nil(reaped.claim_token)
    assert is_nil(reaped.claimed_at)
  end

  test "regression pin: a plain provision job past the generic threshold still re-pends " <>
         "while an equally-aged support claim survives" do
    team = team_fixture()

    # Plain provision job, aged just past the generic threshold.
    bp = barkpark_fixture(team)
    {:ok, _job} = Registry.enqueue_provision_job(bp)
    {%ProvisionJob{} = plain, _} = Registry.claim_next_job("plain-w1")
    backdate(plain.id, Registry.stale_after_seconds() + 60)

    # Support job, aged the SAME — under its own 35-minute threshold.
    support = support_fixture(team)
    {:ok, _sjob} = Registry.enqueue_support_provision_job(support)
    {%ProvisionJob{} = sup, _} = Registry.claim_next_support_provision_job("support-w1")
    backdate(sup.id, Registry.stale_after_seconds() + 60)

    assert {:ok, %{reaped: 1, failed: 0}} = perform_job(StaleProvisionJobReaper, %{})

    assert Repo.get(ProvisionJob, plain.id).status == "pending"
    assert Repo.get(ProvisionJob, sup.id).status == "claimed"
  end

  ## 6. Migration smoke — the oban_jobs table exists in the test DB.

  test "oban_jobs table exists" do
    assert %Postgrex.Result{} = Repo.query!("SELECT 1 FROM oban_jobs LIMIT 1")
  end
end
