defmodule BarkparkCloud.Workers.SseTicketReaperTest do
  @moduledoc """
  cch-w3 sibling-class payment — the `"sse"` ticket prune, wiring included.

  The defect is the one `OAuthStateReaper` and `DeviceAuthReaper` already paid
  for elsewhere: a row nothing ever deletes. `create_sse_ticket/1` is a bare
  `Repo.insert` per call and is deliberately NON-SUPERSEDING (two-tab eviction
  storm), and `consume_sse_ticket/1` BURNS by stamping `revoked_at` rather than
  deleting. So the accretion below is not a hypothesis — it is measured here,
  BEFORE the reaper runs, and then reaped.

  The scoping test is the one that matters most: `user_tokens` is polymorphic,
  and a `where` one context too wide would delete live sessions out from under
  logged-in users. That is pinned, not assumed.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs): no
  background poller touches the sandboxed connection, and `perform_job/2` runs
  the worker synchronously inside this test's own transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Workers.SseTicketReaper

  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "reaper-#{System.unique_integer([:positive])}@example.com",
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

  # Backdate every `"sse"` row of `user` past its TTL, the way wall-clock would.
  defp lapse_all!(user) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    {n, _} =
      Repo.update_all(
        from(t in UserToken, where: t.user_id == ^user.id and t.context == "sse"),
        set: [expires_at: past]
      )

    n
  end

  test "THE ACCRETION: N mints leave N rows, and burning one leaves N — nothing deletes" do
    user = user_fixture()

    {:ok, a} = Accounts.create_sse_ticket(user)
    {:ok, _b} = Accounts.create_sse_ticket(user)
    {:ok, _c} = Accounts.create_sse_ticket(user)

    # Three mints, three rows: the mint is non-superseding on purpose.
    assert count(user, "sse") == 3

    # Redeeming one resolves the user and BURNS the ticket — by stamping
    # revoked_at, not by deleting. The row count does not move.
    assert %{id: uid} = Accounts.consume_sse_ticket(a)
    assert uid == user.id
    assert count(user, "sse") == 3

    assert Repo.aggregate(
             from(t in UserToken,
               where: t.user_id == ^user.id and t.context == "sse" and not is_nil(t.revoked_at)
             ),
             :count
           ) == 1

    # …and it is unredeemable, so the row it left behind is pure residue. THAT is
    # what the reaper exists to remove.
    assert Accounts.consume_sse_ticket(a) == nil

    {:ok, sweep} = perform_job(SseTicketReaper, %{})

    # Survivor count asserted BEFORE the reaped tally on purpose: when the
    # reaper's WHERE is neutered, this is the assertion that reds, and it names
    # the rows that wrongly survived rather than only the tally that did not move.
    survivors = count(user, "sse")
    assert survivors == 2, "sse rows surviving the sweep: #{survivors} (expected 2)"
    assert sweep == %{reaped: 1}
  end

  test "reaps BOTH kinds of dead row — burned and lapsed — in one sweep" do
    user = user_fixture()

    {:ok, burned} = Accounts.create_sse_ticket(user)
    assert %{} = Accounts.consume_sse_ticket(burned)

    # A second, untouched ticket, aged past its 60s TTL.
    {:ok, _lapsed} = Accounts.create_sse_ticket(user)
    assert lapse_all!(user) == 2

    {:ok, sweep} = perform_job(SseTicketReaper, %{})

    survivors = count(user, "sse")
    assert survivors == 0, "dead sse rows surviving the sweep: #{survivors} (expected 0)"
    assert sweep == %{reaped: 2}
  end

  test "SCOPED: a live sse ticket survives, and NO other context is touched" do
    user = user_fixture()

    # One live ticket, one dead one.
    {:ok, live} = Accounts.create_sse_ticket(user)
    {:ok, dead} = Accounts.create_sse_ticket(user)
    assert %{} = Accounts.consume_sse_ticket(dead)

    # Other contexts riding the same polymorphic table. The REVOKED session is
    # the load-bearing one: it is dead by the same test the sse sweep uses
    # (`revoked_at` stamped), so a `where` that dropped the context clause would
    # delete it — and it is the tombstone the active-sessions UI renders.
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
      Repo.update_all(
        from(t in UserToken, where: t.id == ^session_id),
        set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
      )

    assert count(user, "session") == 2

    {:ok, sweep} = perform_job(SseTicketReaper, %{})

    # The live ticket survives AND still redeems — but the burned one must not.
    survivors = count(user, "sse")

    assert survivors == 1,
           "sse rows surviving the sweep: #{survivors} (expected 1 — the live one)"

    assert sweep == %{reaped: 1}
    assert %{id: uid} = Accounts.consume_sse_ticket(live)
    assert uid == user.id

    # Both session rows — live and revoked — are untouched.
    assert count(user, "session") == 2
  end

  test "a sweep with nothing to do is a clean no-op (idempotent)" do
    user = user_fixture()
    {:ok, _live} = Accounts.create_sse_ticket(user)

    assert {:ok, %{reaped: 0}} = perform_job(SseTicketReaper, %{})
    assert {:ok, %{reaped: 0}} = perform_job(SseTicketReaper, %{})
    assert count(user, "sse") == 1
  end

  test "there is NO grace window — a row is reaped the moment it is unredeemable" do
    # Deliberate divergence from the visually-similar AgentRetentionWorker, which
    # DOES keep a day-scale grace. Its rows stay readable evidence past their
    # retention date; a burned ticket is the opposite — it stores only a SHA-256
    # hash and `consume_sse_ticket/1` has ALREADY written it off.
    user = user_fixture()
    {:ok, ticket} = Accounts.create_sse_ticket(user)
    assert %{} = Accounts.consume_sse_ticket(ticket)

    # Prove the write-off first, then prove nothing waits on it.
    assert Accounts.consume_sse_ticket(ticket) == nil

    {:ok, sweep} = perform_job(SseTicketReaper, %{})

    survivors = count(user, "sse")
    assert survivors == 0, "burned sse rows surviving the sweep: #{survivors} (expected 0)"
    assert sweep == %{reaped: 1}
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

    assert {"* * * * *", SseTicketReaper} in crontab

    # Rides the cheap queue beside its twins DeviceAuthReaper / OAuthStateReaper,
    # and collapses a slow sweep plus the next tick into one in-flight job.
    assert SseTicketReaper.__opts__()[:queue] == :maintenance
    assert SseTicketReaper.__opts__()[:max_attempts] == 3
    assert SseTicketReaper.__opts__()[:unique][:period] == 60
  end
end
