defmodule BarkparkCloud.Workers.TrialExpiryWorkerTest do
  @moduledoc """
  dwb-13 — the free-trial lifecycle worker: T-3 / T-1 advance notices (idempotent
  under the hourly cron), expiry teardown via the EXISTING deprovision path, and
  the MONEY-PATH guard that a subscribed team's box is never torn down.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs) —
  `perform_job/2` runs the worker synchronously in this test's own transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Registry.ProvisionJob
  alias BarkparkCloud.Workers.TrialExpiryWorker

  ## Fixtures

  # A team with one owner member (so notification dispatch has a recipient) and a
  # live `trial` subscription whose window ends `offset_seconds` from now.
  defp trial_team(offset_seconds) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: "correct horse staple"})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")

    ends =
      DateTime.utc_now()
      |> DateTime.add(offset_seconds, :second)
      |> DateTime.truncate(:microsecond)

    {:ok, sub} =
      %Subscription{}
      |> Subscription.changeset(%{
        team_id: team.id,
        plan: "trial",
        status: "active",
        current_period_end: ends
      })
      |> Repo.insert()

    {team, sub}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp deprovision_jobs(bp_id) do
    Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^bp_id and j.kind == "deprovision"))
  end

  defp notice_count(team_id) do
    Repo.aggregate(
      from(d in Delivery, where: d.team_id == ^team_id and d.event == "trial_expiring"),
      :count
    )
  end

  ## 1. Cron wiring

  test "worker is scheduled hourly on the maintenance queue" do
    crontab =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"0 * * * *", TrialExpiryWorker} in crontab
    assert Ecto.Changeset.get_field(TrialExpiryWorker.new(%{}), :queue) == "maintenance"
  end

  ## 2. T-3 advance notice — sent once, idempotent

  test "sends the T-3 notice once and never again (idempotent)" do
    # 2 days out → inside the 3-day window, outside the 1-day one.
    {team, _sub} = trial_team(2 * 86_400)

    assert {:ok, %{noticed_3d: 1, noticed_1d: 0}} = perform_job(TrialExpiryWorker, %{})
    assert Repo.get(Team, team.id).trial_notice_3d_sent_at
    assert notice_count(team.id) == 1

    # A second run in the same window must NOT re-send.
    assert {:ok, %{noticed_3d: 0}} = perform_job(TrialExpiryWorker, %{})
    assert notice_count(team.id) == 1
  end

  ## 3. T-1 advance notice — supersedes T-3 (no double email)

  test "sends the T-1 notice and suppresses a later T-3" do
    # 12 hours out → inside the 1-day window.
    {team, _sub} = trial_team(div(86_400, 2))

    assert {:ok, %{noticed_1d: 1, noticed_3d: 0}} = perform_job(TrialExpiryWorker, %{})

    t = Repo.get(Team, team.id)
    assert t.trial_notice_1d_sent_at
    # The 3-day stamp is claimed too, so no stale T-3 fires afterward.
    assert t.trial_notice_3d_sent_at
    assert notice_count(team.id) == 1

    assert {:ok, %{noticed_1d: 0, noticed_3d: 0}} = perform_job(TrialExpiryWorker, %{})
    assert notice_count(team.id) == 1
  end

  ## 4. Expiry teardown — enqueues a deprovision via the existing path, idempotently

  test "an EXPIRED unconverted trial is torn down via the deprovision path" do
    {team, _sub} = trial_team(-3600)
    bp = barkpark_fixture(team)

    assert {:ok, %{expired: 1, teardowns: 1}} = perform_job(TrialExpiryWorker, %{})

    jobs = deprovision_jobs(bp.id)
    assert [%ProvisionJob{kind: "deprovision", status: "pending"}] = jobs

    # Idempotent: a second run dedupes on the still-pending job — no second one.
    assert {:ok, %{teardowns: 0}} = perform_job(TrialExpiryWorker, %{})
    assert length(deprovision_jobs(bp.id)) == 1
  end

  ## 5. ADVERSARIAL — a subscribed team is NEVER torn down by the expiry worker

  test "a CONVERTED (paid) team's box is never torn down, even past its trial window" do
    # The paid team: a live `supporter` sub (converted), a past trial_ends_at, a box.
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "paid-#{n}@example.com", password: "correct horse staple"})

    {:ok, paid_team} = Accounts.create_team(%{name: "Paid #{n}", slug: "paid-#{n}"})
    {:ok, _} = Accounts.add_member(paid_team, user, "owner")
    {:ok, _} = Billing.subscribe(paid_team, "supporter")

    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    Repo.update_all(from(t in Team, where: t.id == ^paid_team.id), set: [trial_ends_at: past])
    paid_bp = barkpark_fixture(paid_team)

    # A CONTROL: an unconverted expired trial team with a box — proves the worker
    # actually ran and its `plan == "trial"` filter (not inaction) spared the paid team.
    {trial_team, _sub} = trial_team(-3600)
    trial_bp = barkpark_fixture(trial_team)

    assert {:ok, %{expired: 1, teardowns: 1}} = perform_job(TrialExpiryWorker, %{})

    # The paid team's box is untouched; the unconverted trial's box is torn down.
    assert deprovision_jobs(paid_bp.id) == []
    assert [%ProvisionJob{status: "pending"}] = deprovision_jobs(trial_bp.id)
  end

  ## 6. Conversion cancels an in-flight teardown (the race guard)

  test "a trial→paid conversion cancels any pending trial-deprovision job" do
    {team, _sub} = trial_team(-3600)
    bp = barkpark_fixture(team)

    # The worker enqueues a teardown for the expired trial.
    assert {:ok, %{teardowns: 1}} = perform_job(TrialExpiryWorker, %{})
    assert [%ProvisionJob{status: "pending"}] = deprovision_jobs(bp.id)

    # The team then subscribes (trial → paid, in place) via a signed webhook.
    raw =
      Jason.encode!(%{
        "id" => "evt_conv",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_c",
            "subscription" => "sub_c",
            "metadata" => %{"team_id" => team.id, "plan" => "supporter"}
          }
        }
      })

    assert {:ok, %Subscription{plan: "supporter"}} =
             Billing.handle_webhook(raw, BarkparkCloud.Billing.StubGateway.test_signature())

    # The pending teardown was cancelled — the now-paying box survives.
    assert deprovision_jobs(bp.id) == []
  end
end
