defmodule BarkparkCloud.Workers.DailyDigestWorkerTest do
  @moduledoc """
  isu-w5 — the daily fleet-update digest: honest fleet roll-up (current/behind/
  paused counts + per-instance running->latest, state, pin/pause flags, last
  checked), platform-admin-ONLY recipients (a non-admin registered user is never
  a recipient), and a zero-admin logged no-op that never crashes.

  `async: false` — the recipient allowlist is process-global Application config
  (`:platform_admin_emails`), so these tests must not run concurrently against a
  shared key. Oban runs in `:manual` mode (config/test.exs), so `perform_job/2`
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
    assert DigestEmail.subject(summary) ==
             "Barkpark fleet digest — 1 current / 2 behind / 1 paused"

    body = DigestEmail.body(summary)

    # Header: totals + semver-aware latest (v1.10.0 beats v1.9.0 — a lexical max fails).
    assert body =~ "Fleet: 3 instances — 1 current, 2 behind, 1 paused."
    assert body =~ "Latest available release: v1.10.0"

    # Per-instance honest lines: running -> latest, state, flags, last checked.
    assert body =~
             "- Acme (acme): v1.2.0 -> v1.10.0 | state: behind | pinned=v1.2.0, paused | checked 2026-07-10 05:17 UTC"

    assert body =~
             "- Beta (beta): v1.10.0 -> v1.10.0 | state: current | checked 2026-07-10 05:17 UTC"

    # autoupdate-off flag + a never-checked instance render honestly.
    assert body =~
             "- Gamma (gamma): v1.9.0 -> v1.9.0 | state: behind | autoupdate off | checked never"
  end

  test "an empty fleet renders a clear no-instances digest without crashing" do
    summary = DigestEmail.summary([])
    assert summary.total == 0

    assert DigestEmail.subject(summary) ==
             "Barkpark fleet digest — 0 current / 0 behind / 0 paused"

    body = DigestEmail.body(summary)
    assert body =~ "Fleet: 0 instances."
    assert body =~ "No instances are registered yet"
    assert body =~ "Latest available release: unknown"
  end

  ## 3. Recipients — platform-admin ONLY; a non-admin registered user is excluded

  test "the digest reaches configured platform admins and NEVER a non-admin user" do
    admin = user("admin-#{System.unique_integer([:positive])}@example.com")
    non_admin = user("member-#{System.unique_integer([:positive])}@example.com")
    t = team(admin)

    _bp =
      instance(t, "Prod", "prod-#{System.unique_integer([:positive])}", %{
        update_state: "behind",
        update_running_release: "v1.0.0",
        update_latest_release: "v1.1.0"
      })

    # Only the admin is on the allowlist — the non-admin user exists but is not.
    set_admins([admin.email])

    assert {:ok, %{sent: 1, recipients: recipients}} = perform_job(DailyDigestWorker, %{})
    assert recipients == [admin.email]

    # The non-admin registered user is proven excluded from the RESOLVED recipient
    # set (the exfiltration boundary — this is where a non-admin would leak in).
    refute non_admin.email in recipients

    # ...and a real digest actually went to the admin (not a silent empty send).
    assert_email_sent(fn email ->
      assert Enum.any?(email.to, fn {_, a} -> a == admin.email end)
      assert email.subject =~ "Barkpark fleet digest"
      assert email.text_body =~ "- Prod"
    end)
  end

  test "a configured email with no registered account is dropped, never mailed" do
    admin = user("op-#{System.unique_integer([:positive])}@example.com")
    t = team(admin)

    _bp =
      instance(t, "Prod", "prod-#{System.unique_integer([:positive])}", %{update_state: "current"})

    # Real admin + a ghost address that was never registered.
    set_admins([admin.email, "ghost@example.com"])

    assert {:ok, %{sent: 1, recipients: recipients}} = perform_job(DailyDigestWorker, %{})
    assert recipients == [admin.email]
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
  ##    So the pin is WIDENED, not loosened. `{:ok, :no_admins}` stays exact
  ##    (loosening it to `{:ok, _}` is the vacuity this epic exists to kill) and
  ##    the run must now also produce a countable record of the loss.

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

  test "zero configured admins is a COUNTED loss: recipients=0 sent=0, warned, still :ok" do
    admin = user("nobody-#{System.unique_integer([:positive])}@example.com")
    t = team(admin)

    _bp =
      instance(t, "Prod", "prod-#{System.unique_integer([:positive])}", %{update_state: "behind"})

    set_admins([])
    ref = attach_digest_probe()

    log =
      capture_log(fn ->
        assert {:ok, :no_admins} = perform_job(DailyDigestWorker, %{})
      end)

    # (a) THE COUNT — the record a reporter or a test can attach to. No Delivery
    # row and no synthetic recipient are involved: charter D362 names this digest
    # as a consented recipient-less withhold, and the count needs no recipient.
    assert_received {:fleet_digest, ^ref, measurements, metadata}
    assert measurements == %{recipients: 0, sent: 0}
    assert metadata.phase == :settled
    assert metadata.reason == "no_platform_admins"
    assert metadata.instances == 1

    # (b) THE LINE — greppable in journald, at WARNING, because "nobody was
    # mailed" must not read like the info-level chatter of a healthy run.
    assert log =~ "fleet_digest phase=settled"
    assert log =~ "recipients=0"
    assert log =~ "sent=0"
    assert log =~ "[warning]"

    # The Swoosh Test adapter posts {:email, _} to this process on any send —
    # none arrives, proving the zero-admin path never delivered.
    refute_received {:email, _}
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
end
