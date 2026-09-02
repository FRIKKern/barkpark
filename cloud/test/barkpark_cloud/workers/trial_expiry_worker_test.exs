defmodule BarkparkCloud.Workers.TrialExpiryWorkerTest do
  @moduledoc """
  dwb-13 — the free-trial lifecycle worker: T-3 / T-1 advance notices (idempotent
  under the hourly cron), expiry teardown via the EXISTING deprovision path, the
  cch-w50 FINALISATION of the subscription row once that teardown has happened,
  and the MONEY-PATH guard that a subscribed team's box is never torn down.

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

  ## 7. cch-w32-s1 — the notice reaches a SLACK-ONLY team, end to end
  ##
  ## Everything above proves the notice is DECIDED and that a Delivery row lands
  ## for the email arm. None of it could see that a team which runs on Slack got
  ## nothing at all: `channels_for_event/2` selected zero chat channels for
  ## `trial_expiring`, so the hourly dispatch fanned out to 0 jobs. This is the
  ## producer end of charter D359, driven through the REAL worker rather than
  ## through `dispatch_event/3` directly.

  test "the T-3 notice fans out to a Slack-only team's chat channel" do
    {team, _sub} = trial_team(2 * 86_400)

    {:ok, _} =
      BarkparkCloud.Notifications.put_channel(team, "slack", true, %{
        "url" => "https://hooks.slack.com/x"
      })

    assert {:ok, %{noticed_3d: 1}} = perform_job(TrialExpiryWorker, %{})

    assert_enqueued(
      worker: BarkparkCloud.Workers.ChatNotificationWorker,
      args: %{channel_type: "slack", event: "trial_expiring"}
    )

    # The `days` integer the render arm is built from rides along — the arm reads
    # ONLY this, never the first-party `detail` sentence next to it.
    assert [%{args: %{"payload" => payload}}] =
             all_enqueued(worker: BarkparkCloud.Workers.ChatNotificationWorker)

    assert payload["days"] == 3

    assert {"Trial ending", body, :warning} =
             BarkparkCloud.Notifications.Render.render("trial_expiring", payload)

    assert body =~ "Your free trial ends in 3 days"
  end

  ## 8. cch-w52-s2 — a mute must not SPEND the warning
  ##
  ## This block REVERSES a prior decision recorded here in a comment reading "the
  ## stamp is the idempotency key, not a delivery receipt", which asserted
  ## `noticed_3d: 1` for a muted team. That reading only holds if the stamp is a
  ## de-dup key over deliveries that happened. It is not: `claim_notice/3` only
  ## ever matches NULL, so the stamp is the warning's ENTIRE budget and it has no
  ## reader anywhere outside this worker's own claim. Spending it on a notice
  ## that was never sent costs the team the warning permanently and shows that
  ## loss on no surface. The contract now: a team that cannot receive the alert
  ## claims nothing, and un-muting recovers the warning.

  test "a muted team gets NEITHER the email nor the chat notice, and SPENDS NO STAMP" do
    {team, _sub} = trial_team(2 * 86_400)

    {:ok, _} =
      BarkparkCloud.Notifications.put_channel(team, "slack", true, %{
        "url" => "https://hooks.slack.com/x"
      })

    {:ok, _} = BarkparkCloud.Notifications.update_settings(team, %{"alerts_enabled" => false})

    # Nothing was sent, so nothing was counted and — the point of this slice —
    # nothing was claimed.
    assert {:ok, %{noticed_3d: 0, noticed_1d: 0}} = perform_job(TrialExpiryWorker, %{})

    t = Repo.get(Team, team.id)
    refute t.trial_notice_3d_sent_at
    refute t.trial_notice_1d_sent_at

    assert notice_count(team.id) == 0
    refute_enqueued(worker: BarkparkCloud.Workers.ChatNotificationWorker)
  end

  test "a muted team inside the T-1 window burns NEITHER stamp (no free supersede)" do
    # The T-1 arm claims the 3-day stamp as well, to suppress a stale T-3. That
    # supersede is only legitimate when a 1-day notice actually went out — a
    # muted run must leave BOTH stamps intact.
    {team, _sub} = trial_team(div(86_400, 2))

    {:ok, _} = BarkparkCloud.Notifications.update_settings(team, %{"alerts_enabled" => false})

    assert {:ok, %{noticed_1d: 0, noticed_3d: 0}} = perform_job(TrialExpiryWorker, %{})

    t = Repo.get(Team, team.id)
    refute t.trial_notice_1d_sent_at
    refute t.trial_notice_3d_sent_at
    assert notice_count(team.id) == 0
  end

  test "un-muting RECOVERS the warning: the next run delivers the T-3 notice" do
    {team, _sub} = trial_team(2 * 86_400)

    {:ok, _} = BarkparkCloud.Notifications.update_settings(team, %{"alerts_enabled" => false})

    assert {:ok, %{noticed_3d: 0}} = perform_job(TrialExpiryWorker, %{})
    assert notice_count(team.id) == 0

    {:ok, _} = BarkparkCloud.Notifications.update_settings(team, %{"alerts_enabled" => true})

    assert {:ok, %{noticed_3d: 1}} = perform_job(TrialExpiryWorker, %{})
    assert Repo.get(Team, team.id).trial_notice_3d_sent_at
    assert notice_count(team.id) == 1

    # And it is still exactly-once afterward.
    assert {:ok, %{noticed_3d: 0}} = perform_job(TrialExpiryWorker, %{})
    assert notice_count(team.id) == 1
  end

  ## 9. cch-w50 — THE TERMINAL WRITE, AND THE GATE THAT MAKES IT SAFE
  ##
  ## Measured on the live control plane 2026-08-07: 15 of 18 trial subscriptions
  ## sat past `current_period_end` with ALL 18 still `status = 'active'` — the
  ## oldest lapsed three weeks earlier — every one of those teams carrying both
  ## notice stamps and ZERO barkparks. The teardown had run; the money row was
  ## the ghost. This worker enqueued deprovision jobs and wrote NOTHING to
  ## `subscriptions` (no `Repo.update` / `update_all` on `Subscription` anywhere
  ## in the module), so nothing could ever close the row, `active_trials/0`
  ## re-read it hourly forever, and `/v1/subscription` kept answering the console
  ## with a live trial for a team whose box was gone.

  describe "cch-w50: finalising the lapsed trial row" do
    test "a lapsed trial with NO boxes left is FINALISED on the first pass — the ghost shape" do
      # The exact production shape: window closed, teardown already done (zero
      # barkparks). This is what all fifteen live rows look like.
      {team, sub} = trial_team(-3600)

      assert Registry.list_barkparks(team) == []

      assert {:ok, %{expired: 1, teardowns: 0, finalized: 1}} =
               perform_job(TrialExpiryWorker, %{})

      finalised = Repo.get!(Subscription, sub.id)
      assert finalised.status == "canceled"
      assert finalised.plan == "trial", "the PLAN is history, not a lie — only the status closes"
      assert finalised.canceled_at

      # The row is out of every LIVE read, which is what stops the console
      # rendering a trial card to a team whose instance is gone.
      assert is_nil(Billing.live_subscription(team))
      assert is_nil(Billing.active_subscription(team))
      assert is_nil(Billing.trial_days_remaining(team))
    end

    test "entitlement is UNCHANGED across the finalisation — false before, false after" do
      # The blast-radius claim, driven rather than asserted in prose: an expired
      # trial was ALREADY un-entitled (entitled?/1's trial clause reads the
      # window, not the status), so this write moves nobody across the launch gate.
      {team, _sub} = trial_team(-3600)
      refute Billing.entitled?(team)

      assert {:ok, %{finalized: 1}} = perform_job(TrialExpiryWorker, %{})

      refute Billing.entitled?(team)
    end

    test "finalisation is IDEMPOTENT — a second pass finalises nothing and rewrites nothing" do
      {_team, sub} = trial_team(-3600)

      assert {:ok, %{finalized: 1}} = perform_job(TrialExpiryWorker, %{})
      first = Repo.get!(Subscription, sub.id)

      # The row has left `active_trials/1` entirely, so the second pass does not
      # even see it — no expiry, no teardown, no second write.
      assert {:ok, %{expired: 0, teardowns: 0, finalized: 0}} =
               perform_job(TrialExpiryWorker, %{})

      after_second = Repo.get!(Subscription, sub.id)
      assert after_second.status == "canceled"
      assert after_second.canceled_at == first.canceled_at
      assert after_second.updated_at == first.updated_at, "the second pass did not touch the row"

      refute Enum.any?(Billing.active_trials(), &(&1.id == sub.id))
    end

    test "a lapsed trial whose box is STILL UP is NOT finalised — the conversion race stays closed" do
      # THE GATE. Finalising on "teardown enqueued" instead of "teardown done"
      # would push a converting team onto activate_from_session/4's INSERT arm,
      # which does not cancel the pending deprovision — the box the team just
      # paid for would be torn down by the job already in flight. So while a box
      # exists the row stays live and the cancelling trial arm still runs.
      {team, sub} = trial_team(-3600)
      bp = barkpark_fixture(team)

      assert {:ok, %{expired: 1, teardowns: 1, finalized: 0}} =
               perform_job(TrialExpiryWorker, %{})

      still_live = Repo.get!(Subscription, sub.id)
      assert still_live.status == "active", "a team with a live box keeps its live row"
      assert is_nil(still_live.canceled_at)
      assert %Subscription{plan: "trial"} = Billing.live_subscription(team)

      # And the in-place conversion arm — the one that cancels the teardown — is
      # therefore still the arm a checkout in this window reaches.
      raw =
        Jason.encode!(%{
          "id" => "evt_w50",
          "type" => "checkout.session.completed",
          "data" => %{
            "object" => %{
              "customer" => "cus_w50",
              "subscription" => "sub_w50",
              "metadata" => %{"team_id" => team.id, "plan" => "supporter"}
            }
          }
        })

      assert {:ok, %Subscription{id: converted_id, plan: "supporter"}} =
               Billing.handle_webhook(raw, BarkparkCloud.Billing.StubGateway.test_signature())

      assert converted_id == sub.id, "converted IN PLACE — the same row, not a second one"
      assert deprovision_jobs(bp.id) == [], "the pending teardown was cancelled"
    end

    test "once the box is GONE, the NEXT pass finalises the row the pass before could not" do
      # The two-pass sequence a real teardown produces, driven end to end. This is
      # the only case that shows the gate OPENS as well as closes — without it, a
      # `finalize/3` hard-wired to 0 would pass every other case in this block.
      {team, sub} = trial_team(-3600)
      bp = barkpark_fixture(team)

      assert {:ok, %{finalized: 0}} = perform_job(TrialExpiryWorker, %{})
      assert Repo.get!(Subscription, sub.id).status == "active"

      # The deprovision drains: the box row is gone.
      Repo.delete!(bp)
      assert Registry.list_barkparks(team) == []

      assert {:ok, %{expired: 1, teardowns: 0, finalized: 1}} =
               perform_job(TrialExpiryWorker, %{})

      assert Repo.get!(Subscription, sub.id).status == "canceled"
    end

    test "a LIVE trial is never finalised, however many passes run" do
      {team, sub} = trial_team(10 * 86_400)

      assert {:ok, %{expired: 0, finalized: 0}} = perform_job(TrialExpiryWorker, %{})
      assert {:ok, %{expired: 0, finalized: 0}} = perform_job(TrialExpiryWorker, %{})

      assert Repo.get!(Subscription, sub.id).status == "active"
      assert %Subscription{plan: "trial"} = Billing.live_subscription(team)
    end
  end

  ## 10. cch-w50 — THE PERIOD FILTER ON `Billing.active_trials/1`
  ##
  ## The query used to be `plan == "trial" and status == "active"` and nothing
  ## else, so every trial row that has ever existed was re-read every hour. The
  ## FUTURE side is bounded here; the PAST side is bounded by the terminal status
  ## above, deliberately NOT by a lookback cutoff (a cutoff would strand every row
  ## that lapsed during a worker outage longer than the window).

  describe "cch-w50: the scan horizon" do
    test "a trial beyond the horizon is not in the working set at all" do
      {_team, sub} = trial_team(10 * 86_400)

      refute Enum.any?(Billing.active_trials(DateTime.utc_now()), &(&1.id == sub.id))
    end

    test "NON-VACUITY: a trial at the T-3 boundary IS in the set, and still gets its notice" do
      # The horizon must cover the worker's largest notice threshold. If it ever
      # shrinks below it, the T-3 notice silently stops being sent to anyone — a
      # loss with no surface, exactly like the stamp bug cch-w52-s2 fixed. This
      # drives the boundary through the REAL query rather than comparing numbers.
      {team, sub} = trial_team(3 * 86_400 - 60)

      assert Enum.any?(Billing.active_trials(DateTime.utc_now()), &(&1.id == sub.id))

      assert {:ok, %{noticed_3d: 1}} = perform_job(TrialExpiryWorker, %{})
      assert Repo.get(Team, team.id).trial_notice_3d_sent_at
    end

    test "a lapsed trial is still in the set — the filter bounds the FUTURE, not the past" do
      # The one direction a period filter must never take: dropping a row that
      # has already lapsed would leave its boxes standing forever.
      {_team, sub} = trial_team(-90 * 86_400)

      assert Enum.any?(Billing.active_trials(DateTime.utc_now()), &(&1.id == sub.id)),
             "a row lapsed 90 days ago is still the worker's business until it is finalised"
    end

    test "a trial with NO window never reaches the scan (the malformed-row no-op, moved into SQL)" do
      {team, sub} = trial_team(-3600)

      sub
      |> Ecto.Changeset.change(current_period_end: nil)
      |> Repo.update!()

      refute Enum.any?(Billing.active_trials(DateTime.utc_now()), &(&1.id == sub.id))
      assert {:ok, %{expired: 0, finalized: 0}} = perform_job(TrialExpiryWorker, %{})
      assert Repo.get!(Subscription, sub.id).status == "active"
      assert is_nil(Repo.get(Team, team.id).trial_notice_3d_sent_at)
    end
  end
end
