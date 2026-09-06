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

  # cch-w52-bl — the TEARDOWN notice's own delivery rows, at ANY status. The
  # measured defect was `delivery_rows_any_status = 0`, so this counts rows
  # regardless of outcome: a count restricted to `sent` would report the same 0
  # for "nothing was dispatched" and for "the send failed", and only the first is
  # the bug.
  defp teardown_notice_rows(team_id) do
    Repo.all(
      from(d in Delivery,
        where: d.team_id == ^team_id and d.event == "trial_expired",
        order_by: d.recipient
      )
    )
  end

  # A second member, so the teardown notice's ROLE split is driven rather than
  # asserted in prose.
  defp add_member(team, role) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "m-#{n}@example.com", password: "correct horse staple"})

    {:ok, _} = Accounts.add_member(team, user, role)
    user.email
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
        "url" => "https://203.0.113.12/x"
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
        "url" => "https://203.0.113.12/x"
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

  ## 10. cch-w52-bl — THE TEARDOWN'S OWN NOTICE
  ##
  ## Measured during wave 52 by running this worker against a trial whose window
  ## was already closed: `%{expired: 1, teardowns: 1}`, `delivery_rows_any_status
  ## = 0`, and the ONLY artefact was a `{"deprovision","pending"}` ProvisionJob.
  ## The T-3/T-1 advance notices were the only warning a team ever got; a team
  ## that missed both learned its instances were gone at the outage.
  ##
  ## These tests assert the DELIVERY ROWS and the enqueued chat job — the record
  ## a person could have been reached through — never that a particular function
  ## was called. Every one of them fails on the pre-change worker with
  ## `teardown_notice_rows == []`.

  describe "cch-w52-bl: the teardown notifies" do
    test "the teardown writes a trial_expired delivery row for EVERY member, naming what went" do
      {team, _sub} = trial_team(-3600)
      member = add_member(team, "member")
      # ONE box, not two, and that is the product's own ceiling rather than a
      # convenience: `Registry.register_barkpark/2` refuses a trial team's second
      # instance with `{:error, :limit_reached}`. The plural clause of
      # `Render.teardown_clause/1` is driven in render_test.exs, where a payload
      # can carry a list no trial team could ever have owned.
      bp = barkpark_fixture(team)

      assert {:ok, %{expired: 1, teardowns: 1}} = perform_job(TrialExpiryWorker, %{})

      rows = teardown_notice_rows(team.id)

      assert length(rows) == 2,
             "one row per team member — the reach of a teardown notice is maximal"

      assert Enum.all?(rows, &(&1.kind == "alert" and &1.status == "sent"))
      assert member in Enum.map(rows, & &1.recipient)

      # The COPY, off the real mail this dispatch produced: the instance is
      # NAMED, in the past tense, and nothing is promised in the future tense.
      mails =
        Map.new(1..2, fn _ ->
          assert_receive {:email, email}
          {elem(hd(email.to), 1), email}
        end)

      for {_addr, email} <- mails do
        assert email.subject == "Your Barkpark free trial has ended"
        assert email.text_body =~ "#{bp.name} has been torn down"
        refute email.text_body =~ "will be"
        refute email.text_body =~ "ends in"
      end

      # The one action left, split on the door that actually refuses a member.
      assert mails[member].text_body =~ "Only the team owner can subscribe"
      refute mails[member].text_body =~ "Subscribe to a paid plan to run Barkpark again."
    end

    test "a SECOND pass over the same lapsed trial mails nothing more (the dedup IS the budget)" do
      {team, sub} = trial_team(-3600)
      bp = barkpark_fixture(team)

      assert {:ok, %{teardowns: 1}} = perform_job(TrialExpiryWorker, %{})
      assert [%Delivery{}] = teardown_notice_rows(team.id)

      # Pass 2: the box is still up and its teardown is still pending, so the
      # enqueue is refused (`:already_deprovisioning`) and there is nothing to
      # report. No second row.
      assert {:ok, %{expired: 1, teardowns: 0, finalized: 0}} =
               perform_job(TrialExpiryWorker, %{})

      assert length(teardown_notice_rows(team.id)) == 1

      # Pass 3: the teardown has HAPPENED (the deprovision deletes the barkpark
      # row) — the trial is finalised and leaves `active_trials/1` for good, so no
      # later pass can ever mail about it again.
      Repo.delete!(bp)

      assert {:ok, %{expired: 1, teardowns: 0, finalized: 1}} =
               perform_job(TrialExpiryWorker, %{})

      assert Repo.get!(Subscription, sub.id).status == "canceled"
      assert length(teardown_notice_rows(team.id)) == 1

      assert {:ok, %{expired: 0}} = perform_job(TrialExpiryWorker, %{})
      assert length(teardown_notice_rows(team.id)) == 1
    end

    test "the teardown notice reaches a SLACK-ONLY team, rendered as itself" do
      {team, _sub} = trial_team(-3600)
      bp = barkpark_fixture(team)

      {:ok, _} =
        BarkparkCloud.Notifications.put_channel(team, "slack", true, %{
          "url" => "https://203.0.113.12/x"
        })

      assert {:ok, %{teardowns: 1}} = perform_job(TrialExpiryWorker, %{})

      assert_enqueued(
        worker: BarkparkCloud.Workers.ChatNotificationWorker,
        args: %{channel_type: "slack", event: "trial_expired"}
      )

      assert [%{args: %{"payload" => payload}}] =
               all_enqueued(worker: BarkparkCloud.Workers.ChatNotificationWorker)

      assert payload["instances"] == [bp.name]

      # NOT the catch-all: `{"Barkpark Cloud", "Event: trial_expired for …", :info}`
      # is Discord GREEN, and a teardown report arriving as good news is the exact
      # failure the wave-32 census exists to foreclose.
      assert {"Trial ended", body, :warning} =
               BarkparkCloud.Notifications.Render.render("trial_expired", payload)

      assert body =~ "#{bp.name} has been torn down"
      refute body =~ "Event: trial_expired"
    end

    test "a lapsed trial with NOTHING to tear down sends no teardown notice (the stated limit)" do
      # The cch-w50 ghost shape: window closed, zero boxes. This pass tore nothing
      # down, so a teardown report here would describe an act it did not perform
      # and could name nothing. It is finalised, silently.
      {team, _sub} = trial_team(-3600)
      assert Registry.list_barkparks(team) == []

      assert {:ok, %{expired: 1, teardowns: 0, finalized: 1}} =
               perform_job(TrialExpiryWorker, %{})

      assert teardown_notice_rows(team.id) == []
    end

    test "a MUTED team gets no teardown notice — the master switch still governs" do
      {team, _sub} = trial_team(-3600)
      _bp = barkpark_fixture(team)
      {:ok, _} = BarkparkCloud.Notifications.update_settings(team, %{"alerts_enabled" => false})

      assert {:ok, %{teardowns: 1}} = perform_job(TrialExpiryWorker, %{})

      assert teardown_notice_rows(team.id) == []
      refute_enqueued(worker: BarkparkCloud.Workers.ChatNotificationWorker)
    end
  end

  ## 10. cch-w50-s5 — THE DAY COUNT IS DERIVED, NOT TYPED
  ##
  ## THE DEFECT THIS CLOSES. `notify/3`'s day count used to be a bare literal at
  ## the call site — `notify(team, sub, 3)` one line below a guard on
  ## `@three_days` — and both renderers build the whole sentence from that
  ## integer (`Notifications.Render.trial_window/1`,
  ## `EventEmail.trial_window/1`), so THE INTEGER IS THE SENTENCE. Nothing
  ## connected "who we selected" to "what we told them".
  ##
  ## MEASURED ON origin/main (d6de5fe6f), before the fix: widening `@three_days`
  ## AND `Billing.@trial_scan_horizon_seconds` to `5 * 86_400` left the entire
  ## committed suite GREEN (37 tests, 0 failures) while a trial ending in FOUR
  ## days was noticed with `payload["days"] == 3` and a chat body reading "Your
  ## free trial ends in 3 days" — sent five days out. The probe was proven
  ## non-vacuous: reverting both to `3 * 86_400` flipped the same probe to
  ## `noticed_3d: 0` and it FAILED.
  ##
  ## Test 7 above already pinned `payload["days"] == 3` at a HAND-TYPED two-day
  ## fixture offset, which is why the mutation slipped past it: both the fixture
  ## and the expectation were literals, so they agreed with each other while
  ## disagreeing with the threshold. The tests below take BOTH from the accessor.

  describe "the advance-notice schedule" do
    # Declared HERE, not derived, for the reason billing_client_mirror_test.exs
    # gives for @pinned_plans: a guard that only compares the code to itself goes
    # green on a coordinated edit. This list is the third opinion, and the
    # console's TRIAL_NOTICE_DAYS is the fourth (mirrored there).
    @pinned_notice_days [3, 1]

    test "the accessor is PUBLIC and states the schedule the console promises" do
      assert TrialExpiryWorker.notice_thresholds_days() == @pinned_notice_days
    end

    test "the day count in the BODY equals the threshold that selected the team — for every threshold" do
      # Both the fixture offset and the expected numeral come from the accessor,
      # so this cannot go vacuous on a hand-typed pair. Each threshold is driven
      # in its OWN team + its own run, an hour inside its boundary.
      for days <- TrialExpiryWorker.notice_thresholds_days() do
        {team, _sub} = trial_team(days * 86_400 - 3600)

        {:ok, _} =
          BarkparkCloud.Notifications.put_channel(team, "slack", true, %{
            "url" => "https://203.0.113.12/x"
          })

        assert {:ok, summary} = perform_job(TrialExpiryWorker, %{})

        assert summary.noticed_3d + summary.noticed_1d >= 1,
               "a trial #{days} days out (the T-#{days} threshold, minus an hour) was noticed by nothing: #{inspect(summary)}"

        payload =
          all_enqueued(worker: BarkparkCloud.Workers.ChatNotificationWorker)
          |> Enum.map(& &1.args["payload"])
          |> Enum.find(&(&1["name"] == team.name))

        assert payload,
               "the T-#{days} notice fanned out to no chat job for team #{team.name}"

        assert payload["days"] == days,
               "the T-#{days} threshold selected this team and then told it #{inspect(payload["days"])} — the day count is decoupled from the threshold again"

        # ...and the SENTENCE, because the payload integer is only half the
        # promise. Both rails build the window from it; this is the chat rail.
        {_title, body, _sev} =
          BarkparkCloud.Notifications.Render.render("trial_expiring", payload)

        window = if days == 1, do: "in 1 day", else: "in #{days} days"

        assert body =~ window,
               "the T-#{days} notice's body does not say #{inspect(window)}: #{body}"
      end
    end

    test "REACHABILITY: no threshold sits beyond Billing's trial scan horizon" do
      # A threshold further out than `Billing.active_trials/1` looks is DEAD: the
      # row is never returned, so the arm cannot fire. cch-w50 introduced that
      # horizon as its OWN hand-typed `3 * 86_400` in a different module, and
      # nothing tied the two together — which is exactly why the mutation above
      # had to move BOTH to reproduce the defect.
      horizon_days = div(Billing.trial_scan_horizon_seconds(), 86_400)

      for day <- TrialExpiryWorker.notice_thresholds_days() do
        assert day <= horizon_days,
               "the worker notices at T-#{day} days but the scan horizon is #{horizon_days} days — that threshold can never fire"
      end
    end
  end
end
