defmodule BarkparkCloud.Workers.DailyDigestWorkerTest do
  @moduledoc """
  isu-w5 — the daily fleet-update digest: honest fleet roll-up (current/behind/
  paused counts + per-instance running->latest, state, pin/pause flags, last
  checked), TEAM-MEMBER recipients since dr-w19-s5 (a registered user outside the
  owning team is never a recipient, and an allowlisted address that is in no team
  is not one either), and a no-recipient run that is counted, warned, and never
  crashes.

  `async: false` — several tests still WRITE `:platform_admin_emails`, which is
  process-global Application config, precisely to prove the digest no longer
  reads it; they must not run concurrently against a shared key. Oban runs in `:manual` mode (config/test.exs), so `perform_job/2`
  runs the worker synchronously in this test's transaction; the Swoosh Test
  adapter captures every send for `assert_email_sent` / `refute_email_sent`.
  """
  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Notifications.DigestEmail
  alias BarkparkCloud.Workers.DailyDigestWorker

  setup do
    # Each test owns the allowlist explicitly; restore the config default after.
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "correct horse staple"})
    u
  end

  defp team(user) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    team
  end

  # Register a barkpark and stamp its update columns directly (fixture write —
  # `Ecto.Changeset.change/2` sets the fields without the narrow prod changesets).
  defp instance(team, name, slug, attrs) do
    {:ok, bp} = Registry.register_barkpark(team, %{name: name, slug: slug})

    bp
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp set_admins(emails),
    do: Application.put_env(:barkpark_cloud, :platform_admin_emails, emails)

  ## 1. Cron wiring — scheduled daily, unique-guarded, on the maintenance queue

  test "worker is scheduled daily at 06:00, unique-guarded, on the maintenance queue" do
    crontab =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"0 6 * * *", DailyDigestWorker} in crontab
    assert Ecto.Changeset.get_field(DailyDigestWorker.new(%{}), :queue) == "maintenance"

    # Oban uniqueness config is stamped onto the built job (guards double-send).
    unique = Ecto.Changeset.get_field(DailyDigestWorker.new(%{}), :unique)
    assert unique.period == 86_400

    # dr-w29-s4: the states are named EXPLICITLY and `:completed` is NOT among
    # them. Oban's default set includes it, which made the period a rolling
    # window off yesterday's finished row instead of a same-day double-send
    # guard. The behavioural proof is the next test; this is the shape pin, and
    # it matches every other worker in `lib/barkpark_cloud/workers/`.
    assert unique.states == [:available, :scheduled, :executing, :retryable, :suspended]
    refute :completed in unique.states
  end

  ## 1a. THE BOUND ON ANY "IN ITS LIFE" COUNT (dr-w26)
  ##
  ##     Charter D456 reports this worker "has completed FOUR times in its life".
  ##     That number cannot be read off `oban_jobs`: the Pruner reaps finished
  ##     rows on a fixed age, so a daily worker's row count is capped at
  ##     `max_age / 1 day` whatever its real history. This pins the cap, so a
  ##     later reader who quotes a lifetime count off that table has a checked
  ##     reason not to. With the cap at 7, D456's own dates close with no
  ##     remainder: 4 present (08-02/04/05/07) + 3 absent (08-03/06/08, the
  ##     rolling-window losses §1b drives) = the 7 retained days.

  test "the Pruner caps any oban_jobs digest count at 7, so a lifetime count is unreadable there" do
    max_age =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Pruner, opts} -> opts[:max_age]
        _ -> nil
      end)

    assert max_age == 60 * 60 * 24 * 7

    # The cron entry is daily, so the retained row count is the retention in days.
    assert div(max_age, 86_400) == 7
  end

  ## 1b. The rolling-window defect — a COMPLETED digest must not eat today's tick
  ##
  ##     The pin above is a shape; this is the behaviour. Under the bare
  ##     `unique: [period: 86_400]` Oban inherited `states: [scheduled,
  ##     available, executing, retryable, completed]` and `timestamp:
  ##     :inserted_at`, so YESTERDAY'S completed row suppressed today's enqueue
  ##     whenever the cron tick landed microseconds earlier in the second than
  ##     the previous one — no job row, no log, no telemetry, no delivery. Prod
  ##     lost 3 of 7 days to it. Revert `@unique` to the bare option and this
  ##     test REDS: `second.conflict?` is true and only one row exists.

  test "a COMPLETED digest from yesterday does NOT suppress today's enqueue" do
    {:ok, first} = Oban.insert(DailyDigestWorker.new(%{}))
    refute first.conflict?

    # Drive it to the state a finished cron tick leaves behind — the whole point
    # is that a job Oban has already run is not a reason to refuse the next one.
    first
    |> Ecto.Changeset.change(
      state: "completed",
      completed_at: DateTime.utc_now()
    )
    |> Repo.update!()

    # Today's tick: identical args, well inside the 86,400s period.
    {:ok, second} = Oban.insert(DailyDigestWorker.new(%{}))

    refute second.conflict?
    assert second.id != first.id

    # Two DISTINCT rows, not one row handed back twice.
    rows =
      Repo.all(Oban.Job) |> Enum.filter(&(&1.worker == "BarkparkCloud.Workers.DailyDigestWorker"))

    assert length(rows) == 2
    assert Enum.map(rows, & &1.id) |> Enum.uniq() |> length() == 2
  end

  test "a digest still PENDING does suppress a second enqueue (the guard still guards)" do
    {:ok, first} = Oban.insert(DailyDigestWorker.new(%{}))
    {:ok, second} = Oban.insert(DailyDigestWorker.new(%{}))

    # `:available` IS in the state list, so the double-enqueue this option was
    # written for is still refused — the fix widens nothing it should not.
    assert second.conflict?
    assert second.id == first.id
  end

  ## 2. Body rendering — honest fleet truth from fixture rows

  test "subject + body render current/behind/paused counts, per-instance lines and flags" do
    checked = ~U[2026-07-10 05:17:00.000000Z]

    rows = [
      %BarkparkCloud.Registry.Barkpark{
        name: "Acme",
        slug: "acme",
        update_state: "behind",
        update_running_release: "v1.2.0",
        update_latest_release: "v1.10.0",
        update_checked_at: checked,
        commit_ancestry: "behind",
        commit_distance: 42,
        commit_distance_checked_at: checked,
        autoupdate_enabled: true,
        autoupdate_paused: true,
        pinned_release: "v1.2.0"
      },
      %BarkparkCloud.Registry.Barkpark{
        name: "Beta",
        slug: "beta",
        update_state: "current",
        update_running_release: "v1.10.0",
        update_latest_release: "v1.10.0",
        update_checked_at: checked,
        commit_ancestry: "current",
        commit_distance: 0,
        commit_distance_checked_at: checked,
        autoupdate_enabled: true,
        autoupdate_paused: false,
        pinned_release: nil
      },
      %BarkparkCloud.Registry.Barkpark{
        name: "Gamma",
        slug: "gamma",
        update_state: "behind",
        update_running_release: "v1.9.0",
        update_latest_release: "v1.9.0",
        update_checked_at: nil,
        commit_ancestry: "behind",
        commit_distance: 7,
        commit_distance_checked_at: checked,
        autoupdate_enabled: false,
        autoupdate_paused: false,
        pinned_release: nil
      }
    ]

    summary = DigestEmail.summary(rows)
    assert summary.total == 3
    assert summary.current == 1
    assert summary.behind == 2
    assert summary.paused == 1
    assert summary.latest == "v1.10.0"

    # Subject reflects the counts exactly.
    # dr-w25-s6: the rungs are the control plane's MEASURED `commit_ancestry`,
    # not the box's release-tag self-grade, and `unmeasured` is always shown.
    assert DigestEmail.subject(summary) ==
             "Barkpark fleet digest — 1 current / 2 behind / 0 unmeasured / 1 paused"

    body = DigestEmail.body(summary)

    # Header: totals + semver-aware latest (v1.10.0 beats v1.9.0 — a lexical max fails).
    assert body =~ "Fleet: 3 instances — 1 current, 2 behind, 0 unmeasured, 1 paused."
    assert body =~ "Latest available release: v1.10.0"

    # Per-instance honest lines: running -> latest, state, flags, last checked.
    assert body =~
             "- Acme (acme): v1.2.0 -> v1.10.0 | state: behind | 42 commits behind main (measured 2026-07-10 05:17 UTC) | pinned=v1.2.0, paused | checked 2026-07-10 05:17 UTC"

    assert body =~
             "- Beta (beta): v1.10.0 -> v1.10.0 | state: current | 0 commits behind main (measured 2026-07-10 05:17 UTC) | checked 2026-07-10 05:17 UTC"

    # autoupdate-off flag + a never-checked instance render honestly.
    assert body =~
             "- Gamma (gamma): v1.9.0 -> v1.9.0 | state: behind | 7 commits behind main (measured 2026-07-10 05:17 UTC) | autoupdate off | checked never"
  end

  test "an empty fleet renders a clear no-instances digest without crashing" do
    summary = DigestEmail.summary([])
    assert summary.total == 0

    assert DigestEmail.subject(summary) ==
             "Barkpark fleet digest — 0 current / 0 behind / 0 unmeasured / 0 paused"

    body = DigestEmail.body(summary)
    assert body =~ "Fleet: 0 instances."
    assert body =~ "No instances are registered yet"
    assert body =~ "Latest available release: unknown"
  end

  ## 3. Recipients — platform-admin ONLY; a non-admin registered user is excluded

  test "the digest reaches the instance's TEAM MEMBERS and NEVER a user outside the team" do
    admin = user("admin-#{System.unique_integer([:positive])}@example.com")
    outsider = user("member-#{System.unique_integer([:positive])}@example.com")
    t = team(admin)

    _bp =
      instance(t, "Prod", "prod-#{System.unique_integer([:positive])}", %{
        update_state: "behind",
        update_running_release: "v1.0.0",
        update_latest_release: "v1.1.0"
      })

    # dr-w19-s5: the allowlist is EMPTY here on purpose. Before the re-address it
    # was the whole audience, so this test would have sent nothing; the digest is
    # now addressed to the owning team's members and this run must still deliver.
    set_admins([])

    assert {:ok, %{sent: 1, recipients: recipients}} = perform_job(DailyDigestWorker, %{})
    assert recipients == [admin.email]

    # The registered user who is in no team is proven excluded from the RESOLVED
    # recipient set — the exfiltration boundary, and the tenancy boundary too: a
    # fleet-wide fan-out would have handed this account another team's instances.
    refute outsider.email in recipients

    # ...and a real digest actually went to the admin (not a silent empty send).
    assert_email_sent(fn email ->
      assert Enum.any?(email.to, fn {_, a} -> a == admin.email end)
      assert email.subject =~ "Barkpark fleet digest"
      assert email.text_body =~ "- Prod"
    end)
  end

  test "an allowlisted address that is in no team is dropped, never mailed" do
    n = System.unique_integer([:positive])
    member = user("op-#{n}@example.com")
    listed_outsider = user("listed-#{n}@example.com")
    t = team(member)

    _bp = instance(t, "Prod", "prod-#{n}", %{update_state: "current"})

    # A REGISTERED platform admin, a ghost address, and neither in the team that
    # owns the instance. Before dr-w19-s5 the first two would both have been
    # resolved (the ghost dropped for being unregistered, the admin mailed); now
    # the allowlist decides nothing at all and only the team's member is mailed.
    set_admins([listed_outsider.email, "ghost@example.com"])

    assert {:ok, %{sent: 1, recipients: recipients}} = perform_job(DailyDigestWorker, %{})
    assert recipients == [member.email]
    refute listed_outsider.email in recipients
    refute "ghost@example.com" in recipients
  end

  ## 4. Zero admins — a COUNTED LOSS (dr-w18-s3), never a send, never a crash
  ##
  ##    This section used to be titled "a logged no-op", and it asserted exactly
  ##    the no-op: `{:ok, :no_admins}`, no email. Both of those are still true and
  ##    both are still asserted — but on prod `PLATFORM_ADMIN_EMAILS` is unset, so
  ##    this is the arm that runs EVERY day, and the pin below said nothing about
  ##    whether anyone could tell. Oban recorded 5 of 5 digest jobs `completed`
  ##    and `notification_deliveries` held zero `fleet_digest` rows across 37
  ##    unpruned days: a push channel succeeding at sending nothing.
  ##
  ##    So the pin is WIDENED, not loosened. `{:ok, :no_admins}` stays exact on
  ##    the DELIVERY function (loosening it to `{:ok, _}` is the vacuity this
  ##    epic exists to kill) and the run must now also produce a countable record
  ##    of the loss.
  ##
  ##    dr-w26 ESCALATION. The counted record was not enough: the WORKER still
  ##    returned `{:ok, :no_admins}`, so Oban wrote `completed` over a run that
  ##    mailed nobody, and on 2026-08-08 an 18-row five-site outage passed with
  ##    every Oban read reporting a healthy digest. The worker now returns
  ##    `{:cancel, :no_team_recipients}`. `deliver_fleet_digest/1`'s own return is
  ##    UNCHANGED — `notifications_test.exs`, `withhold_test.exs` and
  ##    `notifications_platform_admin_env_test.exs` still pin `{:ok, :no_admins}`
  ##    there, and this file's job-state test below is the behavioural half.

  # Attach a telemetry collector for one test and hand back the ref it tags with.
  defp attach_digest_probe do
    ref = make_ref()
    test = self()
    handler = "digest-probe-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark_cloud, :notifications, :fleet_digest, :settled],
      fn _event, measurements, metadata, _ ->
        send(test, {:fleet_digest, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  test "a fleet with no reachable recipient is a COUNTED loss: recipients=0 sent=0, warned, and REFUSED" do
    # dr-w19-s5 re-addressed the digest: the empty population is no longer the
    # platform allowlist (which nobody could join) but a team with no members —
    # the honest zero. An instance owned by a memberless team is the fleet row
    # that reaches nobody, and the allowlist is set to a REGISTERED admin here on
    # purpose: the old address must not be able to rescue this run.
    n = System.unique_integer([:positive])
    orphan_owner = user("nobody-#{n}@example.com")
    {:ok, memberless} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    _bp = instance(memberless, "Prod", "prod-#{n}", %{update_state: "behind"})

    set_admins([orphan_owner.email])
    ref = attach_digest_probe()

    log =
      capture_log(fn ->
        # dr-w26: the worker REFUSES, it does not report success. Exact tuple, not
        # `{:cancel, _}` — the reason is the whole point of choosing this return.
        assert {:cancel, :no_team_recipients} = perform_job(DailyDigestWorker, %{})
      end)

    # (a) THE COUNT — the record a reporter or a test can attach to. No Delivery
    # row and no synthetic recipient are involved: charter D362 names this digest
    # as a consented recipient-less withhold, and the count needs no recipient.
    assert_received {:fleet_digest, ^ref, measurements, metadata}
    assert measurements == %{recipients: 0, sent: 0}
    assert metadata.phase == :settled
    assert metadata.reason == "no_team_recipients"
    assert metadata.instances == 1

    # (a2) THE WITHHOLD COUNT, from the shared funnel and not from this
    # branch's own arithmetic (dr-w18-s3 criterion 5 / dr-w18-s3-fu).
    # `deliver_fleet_digest/1` calls `Withhold.record(nil, "fleet_digest",
    # :no_recipient_by_construction)` and threads its RETURNED value here, so
    # this assertion is on the call's answer and not on a literal: `0` is the
    # honest count because `Delivery` requires a recipient this branch does not
    # have, and a non-zero would mean a row was written where D362 forbids one.
    # Before the consented clause landed, that same call returned 0 too — but
    # only after logging "refused an unrecordable withhold" as an operator
    # error, every day, for a case withhold.ex's own moduledoc calls consented.
    assert metadata.withheld == 0
    refute log =~ "refused an unrecordable withhold"

    # (b) THE LINE — greppable in journald, at WARNING, because "nobody was
    # mailed" must not read like the info-level chatter of a healthy run.
    assert log =~ "fleet_digest phase=settled"
    assert log =~ "recipients=0"
    assert log =~ "sent=0"
    assert log =~ "withheld=0"
    assert log =~ "[warning]"

    # The Swoosh Test adapter posts {:email, _} to this process on any send —
    # none arrives, proving the zero-admin path never delivered.
    refute_received {:email, _}
  end

  ## 4b. THE OBAN ROW ITSELF — `cancelled` with a reason, never `completed`
  ##
  ##     §4 pins the RETURN. This pins what Oban writes to `oban_jobs`, which is
  ##     the surface the escalation is actually about: on 2026-08-08 the only
  ##     machine-readable trace of the digest channel was a `completed` row, and
  ##     `completed` is the word every "is it working?" query filters FOR.
  ##
  ##     It runs the job through Oban's own executor (`Oban.drain_queue/1`, legal
  ##     in `testing: :manual`) rather than `perform_job/2`, because `perform_job`
  ##     never writes a row: a test over the return alone cannot see the state,
  ##     and the state is the defect.

  test "an empty audience lands the Oban row in `cancelled` with its reason, not `completed`" do
    n = System.unique_integer([:positive])
    orphan_owner = user("nobody-#{n}@example.com")
    {:ok, memberless} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    _bp = instance(memberless, "Prod", "prod-#{n}", %{update_state: "behind"})
    set_admins([orphan_owner.email])

    {:ok, job} = Oban.insert(DailyDigestWorker.new(%{}))

    capture_log(fn ->
      assert %{cancelled: 1} = Oban.drain_queue(queue: :maintenance, with_safety: false)
    end)

    row = Repo.get!(Oban.Job, job.id)

    # THE ASSERTION THE WHOLE ROW EXISTS FOR.
    assert row.state == "cancelled"
    refute row.state == "completed"

    # ...and the row NAMES why, so a reader who finds it does not have to go
    # correlate a journald line to learn what happened.
    assert Enum.any?(row.errors, fn e ->
             e |> Map.get("error", "") |> to_string() =~ "no_team_recipients"
           end),
           "the cancelled row must carry :no_team_recipients: #{inspect(row.errors)}"

    # NO RETRY STORM. `:cancel` is terminal on the first attempt — the audience
    # cannot change between attempts, so an `{:error, _}` would have been a lie
    # about recoverability as well as a `discarded` row.
    assert row.attempt == 1
    refute_email_sent()
  end

  ## 4c. AND THE STATE IS NOT A CONSTANT — a run that DID mail somebody completes
  ##
  ##     Without this, §4b would pass against a worker hard-wired to cancel, which
  ##     is the same false green one layer up: a digest channel that always reads
  ##     `cancelled` is exactly as uninformative as one that always read
  ##     `completed`.

  test "a run that reaches a real recipient still lands the Oban row in `completed`" do
    admin = user("op-#{System.unique_integer([:positive])}@example.com")
    t = team(admin)
    _bp = instance(t, "Prod", "prod-#{System.unique_integer([:positive])}", %{})

    set_admins([])

    {:ok, job} = Oban.insert(DailyDigestWorker.new(%{}))

    capture_log(fn ->
      assert %{success: 1} = Oban.drain_queue(queue: :maintenance, with_safety: false)
    end)

    row = Repo.get!(Oban.Job, job.id)

    assert row.state == "completed"
    assert row.errors == []
    assert_email_sent()
  end

  ## 5. The counted loss is not a constant — a healthy run counts what it sent
  ##
  ##    Without this, §4 would pass against an accounting seam hard-wired to
  ##    zero, which is the same false green one layer up.

  test "a real send accounts recipients=1 sent=1 at info, not at warning" do
    admin = user("op-#{System.unique_integer([:positive])}@example.com")
    t = team(admin)

    _bp =
      instance(t, "Prod", "prod-#{System.unique_integer([:positive])}", %{update_state: "current"})

    set_admins([admin.email])
    ref = attach_digest_probe()

    # `config/test.exs` pins the PRIMARY logger level at :warning, which drops an
    # info line before any capture handler sees it — so the level is lowered for
    # this one test (the file is `async: false`) and restored. That the healthy
    # line is invisible at the default level is the point, not an accident: the
    # loss is loud where it runs, the healthy run is not.
    prior_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prior_level) end)

    log =
      capture_log(fn ->
        assert {:ok, %{sent: 1, recipients: [_]}} = perform_job(DailyDigestWorker, %{})
      end)

    assert_received {:fleet_digest, ^ref, %{recipients: 1, sent: 1}, metadata}
    assert metadata.reason == nil
    assert log =~ "fleet_digest phase=settled recipients=1 sent=1"
    refute log =~ "[warning]"
    assert_email_sent()
  end

  ## 6. A PARTIAL send is a LOSS — `sent` is counted, never assumed (w18 review)
  ##
  ##    `sent` used to be `length(recipients)`: a digest that failed for two of
  ##    three admins reported `sent: 3`. dr-w18-s3 derived it from
  ##    `record_delivery/5`'s own `{:ok, _}` classification instead, which is a
  ##    real correctness fix — and shipped with NO test over the `sent <
  ##    recipients` branch, so the only witness of the counter was a run where
  ##    every send succeeded. That is indistinguishable from `sent =
  ##    length(recipients)` and leaves the fix unproven.
  ##
  ##    This drives a mailer that fails for ONE of two real recipients, so the
  ##    counter has to disagree with the recipient count to pass.

  test "a partial send counts what actually left: sent=1 of recipients=2, warned as partial_send" do
    n = System.unique_integer([:positive])
    good = user("op-good-#{n}@example.com")
    bad = user("fail-op-#{n}@example.com")
    t = team(good)
    {:ok, _} = Accounts.add_member(t, bad, "admin")

    _bp = instance(t, "Prod", "prod-#{n}", %{update_state: "behind"})

    set_admins([good.email, bad.email])
    swap_mailer_adapter(BarkparkCloud.Workers.DailyDigestWorkerTest.HalfDeadAdapter)
    ref = attach_digest_probe()

    log =
      capture_log(fn ->
        assert {:ok, %{sent: 1, recipients: recipients}} = perform_job(DailyDigestWorker, %{})
        assert length(recipients) == 2
      end)

    # THE COUNTER DISAGREES WITH THE RECIPIENT COUNT. This is the assertion the
    # old `sent = length(recipients)` could not satisfy at any value.
    assert_received {:fleet_digest, ^ref, %{recipients: 2, sent: 1}, metadata}
    assert metadata.reason == "partial_send"
    assert log =~ "fleet_digest phase=settled recipients=2 sent=1"
    assert log =~ "reason=partial_send"
    assert log =~ "[warning]"

    # And the Delivery rows agree with the count, because both read the same
    # `{:ok, _}` classification: one sent, one failed.
    rows = Repo.all(BarkparkCloud.Notifications.Delivery)
    digest_rows = Enum.filter(rows, &(&1.event == "fleet_digest"))
    assert Enum.count(digest_rows, &(&1.status == "sent")) == 1
    assert Enum.count(digest_rows, &(&1.status == "failed")) == 1
  end

  # Swap the platform mailer adapter for one test and restore it after. The
  # Swoosh Test adapter cannot fail, so a partial send is unreachable without
  # this seam.
  defp swap_mailer_adapter(adapter) do
    prior = Application.get_env(:barkpark_cloud, BarkparkCloud.Mailer, [])

    Application.put_env(
      :barkpark_cloud,
      BarkparkCloud.Mailer,
      Keyword.put(prior, :adapter, adapter)
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, prior) end)
  end

  # A mailer that refuses any recipient whose local part starts with "fail" and
  # hands everything else to the ordinary Test adapter, so `assert_email_sent`
  # still works for the half that got through.
  defmodule HalfDeadAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(%Swoosh.Email{to: [{_name, address} | _]} = email, config) do
      if String.starts_with?(address, "fail") do
        {:error, {:temporary_failure, "450 4.2.1 mailbox busy"}}
      else
        Swoosh.Adapters.Test.deliver(email, config)
      end
    end
  end
end
