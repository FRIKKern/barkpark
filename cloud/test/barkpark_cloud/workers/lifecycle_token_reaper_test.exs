defmodule BarkparkCloud.Workers.LifecycleTokenReaperTest do
  @moduledoc """
  cch-bl-lifecycle-token-reaper — the `"reset"` / `"confirm"` / `"change_email"`
  prune, wiring included.

  The defect is the one `OAuthStateReaper`, `DeviceAuthReaper`,
  `SseTicketReaper` and `OAuthExchangeReaper` already paid for elsewhere: a row
  nothing ever deletes. All three contexts here soft-stamp `revoked_at` and
  never DELETE, so the accretion below is measured BEFORE the reaper runs and
  only then reaped.

  TWO tests carry the weight, and both would pass trivially under the WRONG
  implementation this slice exists to avoid:

    * "THE THROTTLE IS NOT WEAKENED" — the no-grace shape the four sibling
      reapers use would delete an expired-but-unrevoked `confirm` row, and
      `Accounts.throttled?/3` COUNTS exactly those rows (it filters `revoked_at`
      but never `expires_at`). That sweep would hand back a resend slot early,
      which is spam email delivery. This test lapses a confirm token WITHOUT
      revoking it, sweeps, and asserts the resend is STILL refused.
    * "SCOPED" — `user_tokens` is polymorphic, so a `where` one context too wide
      deletes live sessions out from under logged-in users, or the burned `sse`
      rows that belong to a DIFFERENT reaper with a DIFFERENT (no-grace) ruling.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs):
  no background poller touches the sandboxed connection, and `perform_job/2`
  runs the worker synchronously inside this test's own transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Workers.LifecycleTokenReaper

  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "lifecycle-reaper-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp count(user, context),
    do:
      Repo.aggregate(
        from(t in UserToken, where: t.user_id == ^user.id and t.context == ^context),
        :count
      )

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  # Age a context's rows by `seconds`, the way wall-clock would: BOTH stamps
  # move, because `inserted_at` is what the throttle counts and `expires_at` is
  # what the reaper's grace clause reads. Moving only one manufactures a row
  # shape the system never produces.
  defp age!(user, context, seconds) do
    past = DateTime.add(now(), -seconds, :second)

    {moved, _} =
      Repo.update_all(
        from(t in UserToken, where: t.user_id == ^user.id and t.context == ^context),
        set: [inserted_at: past, expires_at: past]
      )

    moved
  end

  # Lapse a context's `expires_at` only — the row is DEAD to every reader but
  # STILL counts toward the mint throttle, which is the exact shape the grace
  # window exists to protect.
  defp lapse_only!(user, context) do
    past = DateTime.add(now(), -1, :second)

    {n, _} =
      Repo.update_all(
        from(t in UserToken, where: t.user_id == ^user.id and t.context == ^context),
        set: [expires_at: past]
      )

    n
  end

  describe "the accretion, and its payment" do
    test "THE ACCRETION: reset links pile up as REVOKED rows — nothing deletes them" do
      user = user_fixture()

      # Three reset requests. Each one SUPERSEDES the previous by stamping
      # revoked_at — it never deletes — so the table holds three rows, two dead.
      {:ok, {_u, _t1}} = Accounts.request_password_reset(user.email)
      {:ok, {_u, _t2}} = Accounts.request_password_reset(user.email)
      {:ok, {_u, t3}} = Accounts.request_password_reset(user.email)

      assert count(user, "reset") == 3

      assert Repo.aggregate(
               from(t in UserToken,
                 where:
                   t.user_id == ^user.id and t.context == "reset" and not is_nil(t.revoked_at)
               ),
               :count
             ) == 2

      {:ok, sweep} = perform_job(LifecycleTokenReaper, %{})

      # Survivor count asserted BEFORE the tally on purpose: when the reaper's
      # WHERE is neutered this is the assertion that reds, and it names the rows
      # that wrongly survived rather than only a tally that did not move.
      survivors = count(user, "reset")
      assert survivors == 1, "reset rows surviving the sweep: #{survivors} (expected 1)"
      assert sweep == %{reaped: 2}

      # The surviving link is the LIVE one, and it still works.
      assert {:ok, _} = Accounts.reset_password_by_token(t3, "a-brand-new-passphrase")
    end

    test "a revoked confirm row goes with NO grace; a revoked change_email row too" do
      user = user_fixture()

      # confirm: mint, then consume — confirm_user/1 revokes via update_all.
      assert {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
      assert_receive {:email, email}
      [_, token] = Regex.run(~r/\?confirm=([^\s]+)/, email.text_body)
      assert {:ok, _} = Accounts.confirm_user(token)
      assert count(user, "confirm") == 1

      # change_email: stage twice — the second supersedes (revokes) the first.
      assert {:ok, _} =
               Accounts.deliver_user_update_email_instructions(user, "fresh-a@example.com")

      user = Repo.get!(Accounts.User, user.id)

      assert {:ok, _} =
               Accounts.deliver_user_update_email_instructions(user, "fresh-b@example.com")

      assert count(user, "change_email") == 2

      {:ok, sweep} = perform_job(LifecycleTokenReaper, %{})

      # Revoked rows are reaped IMMEDIATELY — the grace applies only to the
      # expiry clause, because `throttled?/3` already excludes revoked rows from
      # its count, so removing one cannot move that count.
      confirm_left = count(user, "confirm")
      assert confirm_left == 0, "revoked confirm rows surviving: #{confirm_left} (expected 0)"

      change_left = count(user, "change_email")

      assert change_left == 1,
             "change_email rows surviving: #{change_left} (expected 1 — the live one)"

      assert sweep == %{reaped: 2}
    end
  end

  describe "THE THROTTLE IS NOT WEAKENED" do
    test "an EXPIRED-but-unrevoked confirm row survives the sweep AND still throttles" do
      user = user_fixture()

      # One confirm send. @confirm_throttle is {1, 300}, so the resend is
      # refused while this row is unrevoked and inside the window.
      assert {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
      assert_receive {:email, _}
      assert count(user, "confirm") == 1
      assert {:error, :throttled} = Accounts.deliver_user_confirmation_instructions(user)

      # Lapse it past expires_at WITHOUT revoking it. It is now dead to every
      # reader — and STILL a live vote against the throttle, because
      # throttled?/3 filters revoked_at and never expires_at.
      assert lapse_only!(user, "confirm") == 1

      {:ok, sweep} = perform_job(LifecycleTokenReaper, %{})

      # THE WHOLE POINT. The no-grace shape the four sibling reapers use would
      # delete this row here; the grace window is what keeps it.
      survivors = count(user, "confirm")

      assert survivors == 1,
             "expired-unrevoked confirm rows surviving: #{survivors} (expected 1 — " <>
               "reaping it early returns a resend slot and weakens @confirm_throttle)"

      assert sweep == %{reaped: 0}

      # And the throttle it feeds still refuses. THIS is the assertion that
      # turns the row count above into a statement about behaviour.
      assert {:error, :throttled} = Accounts.deliver_user_confirmation_instructions(user)
      refute_received {:email, _}
    end

    test "CONTROL: once the row ages past the grace it IS reaped — and by then the throttle has already released it" do
      user = user_fixture()

      assert {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
      assert_receive {:email, _}
      assert {:error, :throttled} = Accounts.deliver_user_confirmation_instructions(user)

      # Age the row by the full grace window plus a second — BOTH stamps, the
      # way wall-clock does it. The reaper's expiry clause can now reach it.
      grace = Accounts.lifecycle_reap_grace_seconds()
      assert age!(user, "confirm", grace + 1) == 1

      {:ok, sweep} = perform_job(LifecycleTokenReaper, %{})

      survivors = count(user, "confirm")
      assert survivors == 0, "aged confirm rows surviving the sweep: #{survivors} (expected 0)"
      assert sweep == %{reaped: 1}

      # The throttle released it long before the reaper could touch it, so the
      # resend that now succeeds is the throttle's own decision, not the sweep's.
      assert {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
      assert_receive {:email, _}
    end

    test "THE GRACE RULING, as arithmetic: the grace strictly exceeds every mint-throttle window" do
      # The safety argument is `expires_at >= inserted_at`, so a grace at least
      # as large as the biggest throttle window always releases the row late
      # enough. Asserted against the CONSTANTS rather than a copied number, so
      # widening @change_email_throttle without widening the grace REDS here
      # instead of silently shipping an early-resend regression.
      windows = Accounts.lifecycle_throttle_windows()
      grace = Accounts.lifecycle_reap_grace_seconds()

      assert map_size(windows) == 2
      assert windows["confirm"] == 300
      assert windows["change_email"] == 3600

      for {context, window} <- windows do
        assert grace > window,
               "grace #{grace}s must strictly exceed the #{context} throttle window #{window}s"
      end
    end
  end

  describe "scope" do
    test "SCOPED: sessions and sse tickets are untouched — other reapers own those" do
      user = user_fixture()

      # A live and a revoked session. The REVOKED one is load-bearing: it is dead
      # by the same test this sweep uses, so a `where` missing the context clause
      # would delete it — and it is the tombstone the active-sessions UI renders.
      {:ok, _live_session} = Accounts.create_user_session_token(user)
      {:ok, _revoked_session} = Accounts.create_user_session_token(user)

      [session_id | _] =
        Repo.all(
          from(t in UserToken,
            where: t.user_id == ^user.id and t.context == "session",
            select: t.id
          )
        )

      {1, _} =
        Repo.update_all(from(t in UserToken, where: t.id == ^session_id),
          set: [revoked_at: now()]
        )

      # A BURNED sse ticket. It belongs to SseTicketReaper, whose no-grace ruling
      # is a different (correct) answer to a different question — this sweep must
      # not reach into it.
      {:ok, ticket} = Accounts.create_sse_ticket(user)
      assert %{} = Accounts.consume_sse_ticket(ticket)
      assert count(user, "sse") == 1

      # One dead reset row so the sweep is not vacuously a no-op.
      {:ok, {_u, _t}} = Accounts.request_password_reset(user.email)
      {:ok, {_u, _t2}} = Accounts.request_password_reset(user.email)

      {:ok, sweep} = perform_job(LifecycleTokenReaper, %{})

      assert sweep == %{reaped: 1}
      assert count(user, "session") == 2, "a session row was reaped by the LIFECYCLE sweep"
      assert count(user, "sse") == 1, "a burned sse row was reaped by the LIFECYCLE sweep"
      assert count(user, "reset") == 1
    end

    test "a sweep with nothing to do is a clean no-op (idempotent)" do
      user = user_fixture()
      {:ok, {_u, _t}} = Accounts.request_password_reset(user.email)

      assert {:ok, %{reaped: 0}} = perform_job(LifecycleTokenReaper, %{})
      assert {:ok, %{reaped: 0}} = perform_job(LifecycleTokenReaper, %{})
      assert count(user, "reset") == 1
    end
  end

  test "the worker is actually SCHEDULED — per-minute on :maintenance, with dedup" do
    # A worker nobody runs prunes nothing. Assert the crontab entry, not just the
    # module's existence.
    crontab =
      :barkpark_cloud
      |> Application.get_env(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
        _ -> nil
      end)

    assert {"* * * * *", LifecycleTokenReaper} in crontab

    # Rides the cheap queue beside its four twins, and collapses a slow sweep
    # plus the next tick into one in-flight job.
    assert LifecycleTokenReaper.__opts__()[:queue] == :maintenance
    assert LifecycleTokenReaper.__opts__()[:max_attempts] == 3
    assert LifecycleTokenReaper.__opts__()[:unique][:period] == 60
  end
end
