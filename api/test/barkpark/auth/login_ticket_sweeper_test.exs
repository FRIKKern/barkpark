defmodule Barkpark.Auth.LoginTicketSweeperTest do
  @moduledoc """
  task-e4d5cc40193a3ef5 — the third member of the sweeps-with-no-production-caller
  family, and the one that touches a live credential.

  RED before this row: `Auth.sweep_login_tickets/0` existed and
  `git grep -rn 'sweep_login_tickets' origin/main` matched exactly two lines —
  the definition in `api/lib/barkpark/auth.ex` and ONE test caller in
  `api/test/barkpark_web/controllers/login_ticket_test.exs`. Nothing in `lib/`,
  nothing in the Oban crontab, nothing in the supervision tree. `login_tickets`
  was therefore APPEND-ONLY in production.

  These tests pin three things:

    * WHAT AN UN-SWEPT ROW HOLDS — measured, not argued. This is the criterion
      the row exists to settle, and it is deliberately first. The SPENT arm of
      that measurement was INVERTED by task-62e7b342b85e88fe: the consume now
      deletes the row it wins, so the 201 #16543 recorded from a spent row is
      now a 401 with nothing to present. The EXPIRED-BUT-UNUSED arm still reads
      201 — it has no consume to hook, and its residue is an accepted decision
      recorded in `Barkpark.Auth.LoginTicketSweeper`'s moduledoc.
    * the sweep is BOUNDED per statement (`sweep_login_tickets_batch/1`), so a
      cold first pass over a never-swept table is not one giant transaction;
    * it is SCHEDULED — the crontab entry exists and names this worker. An
      unwired worker reads exactly like a wired one from its own tests, so the
      schedule needs its own guard that reads the configured crontab.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.LoginTicket
  alias Barkpark.Auth.LoginTicketSweeper
  alias Barkpark.Repo

  @bearer "login-ticket-sweeper-bearer-abcdef"

  setup do
    ensure_default_scope!()

    {:ok, _} =
      Auth.create_token(@bearer, "sweeper suite", "production", ["read", "write", "admin"])

    # This suite counts rows in a table other cases also write, so start from a
    # known floor. The sandbox owns the connection, so this is test-local.
    Repo.delete_all(LoginTicket)
    :ok
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp row(raw_ticket) do
    LoginTicket |> where(ticket_hash: ^Auth.hash_ticket(raw_ticket)) |> Repo.one()
  end

  defp present?(raw_ticket), do: row(raw_ticket) != nil

  defp count, do: Repo.aggregate(LoginTicket, :count)

  defp back_date!(raw_ticket, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    from(t in LoginTicket, where: t.ticket_hash == ^Auth.hash_ticket(raw_ticket))
    |> Repo.update_all(set: [expires_at: at])

    raw_ticket
  end

  # A ticket minted and then aged past its 60s TTL, never consumed.
  defp expired_unused!(seconds_ago) do
    {:ok, raw} = Auth.mint_login_ticket(@bearer)
    back_date!(raw, seconds_ago)
  end

  # A ticket minted and consumed. Since task-62e7b342b85e88fe the winning
  # consume DELETES the row, so this leaves NOTHING behind — that is the point.
  defp consumed! do
    {:ok, raw} = Auth.mint_login_ticket(@bearer)
    {:ok, @bearer} = Auth.consume_login_ticket(raw)
    raw
  end

  # A row in the shape the PRE-#16555 consume left behind: `used_at` stamped,
  # row retained, bearer still bound. Written directly because no code path
  # produces this shape any more — but rows like it exist in every database
  # deployed before the consume started deleting, and the sweeper's
  # `used_at IS NOT NULL` arm exists for exactly them. Using `consumed!/0` here
  # would make every sweeper assertion below vacuous (nothing left to sweep).
  defp legacy_spent!(seconds_ago \\ 0) do
    raw = "bplt_legacy_" <> Ecto.UUID.generate()
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    {:ok, _} =
      %LoginTicket{}
      |> LoginTicket.changeset(%{
        ticket_hash: Auth.hash_ticket(raw),
        api_token: @bearer,
        expires_at: at,
        used_at: at
      })
      |> Repo.insert()

    raw
  end

  defp live! do
    {:ok, raw} = Auth.mint_login_ticket(@bearer)
    raw
  end

  defp with_batch_limit(n) do
    prev = Application.get_env(:barkpark, :login_ticket, [])
    Application.put_env(:barkpark, :login_ticket, Keyword.put(prev, :sweep_batch_limit, n))
    on_exit(fn -> Application.put_env(:barkpark, :login_ticket, prev) end)
  end

  # ── C0: the retention question, settled by running it ───────────────────

  describe "the retention question — what an un-swept row actually holds" do
    test "a CONSUMED ticket leaves NO row and NO recoverable bearer — 401, not 201",
         %{conn: conn} do
      # THE INVERSE OF #16543's MEASUREMENT, on the same route with the same
      # controls (task-62e7b342b85e88fe). #16543 recorded that a spent row's
      # `api_token` came back decrypted from a plain load and minted a fresh
      # ticket (201). The consume now DELETES the row, so the same probe must
      # find nothing and the route must answer 401.
      raw = consumed!()

      # Whatever a reader CAN recover for this ticket is what gets presented.
      # After the change that is nothing, so the ticket string itself is the
      # most an attacker holds; before it, this was the live bearer.
      r = row(raw)
      recovered = r && r.api_token
      probed = probe(conn, recovered || raw)

      # NEGATIVE CONTROL — the route really does enforce auth, so a 401 below
      # cannot be "this route rejects everything for an unrelated reason"...
      garbage = probe(conn, "not-a-real-token-zzzzzz")
      none = post(conn, "/v1/auth/login-tickets")
      assert garbage.status == 401
      assert none.status == 401

      # ...and POSITIVE CONTROL — the same bearer value, known-good, same
      # route, same shape of request — so a 401 below cannot be "the route is
      # down" or "my request was malformed".
      control = probe(conn, @bearer)
      assert control.status == 201

      # No arm was rate-limited: a 429 read as an auth failure would invert
      # this conclusion.
      for c <- [probed, garbage, none, control], do: refute(c.status == 429)

      # THE FINDING, inverted. Reverting the consume to a `used_at` stamp reds
      # HERE, printing the bearer it recovered and the 201 that bearer bought.
      assert recovered == nil,
             "a consumed ticket still yields a bearer from login_tickets: #{inspect(recovered)} — presenting it to POST /v1/auth/login-tickets returned #{probed.status} (201 means it minted a fresh handoff ticket)"

      assert probed.status == 401,
             "expected 401 for whatever remains of a consumed ticket, got #{probed.status}"

      # ...and nothing at all survives the consume — not the row, not the
      # ciphertext under it. (Asserted AFTER the finding above so a regression
      # reds on the message that names the bearer and the status, not on a
      # bare struct dump.)
      assert row(raw) == nil

      ciphertext =
        from(t in "login_tickets",
          where: t.ticket_hash == ^Auth.hash_ticket(raw),
          select: type(t.api_token, :binary)
        )
        |> Repo.one()

      assert ciphertext == nil
    end

    test "an EXPIRED-BUT-UNUSED row's api_token still authenticates too", %{conn: conn} do
      # This arm was never consumed at all, so a reachability-through-consume
      # argument does not even reach it — and it IS in the sweep predicate.
      raw = expired_unused!(300)
      r = row(raw)

      assert r != nil
      assert r.used_at == nil
      assert DateTime.compare(r.expires_at, DateTime.utc_now()) == :lt
      assert r.api_token == @bearer

      recovered = probe(conn, r.api_token)
      control = probe(conn, @bearer)
      garbage = probe(conn, "not-a-real-token-zzzzzz")

      assert garbage.status == 401
      assert control.status == 201
      for c <- [recovered, control, garbage], do: refute(c.status == 429)

      assert recovered.status == 201
    end

    test "consuming does not revoke the bound token — which is why the row must not survive it" do
      # The reason the retention question had teeth: the consume cannot revoke
      # the bound token (it is the operator's real long-lived api_token). So
      # the ONLY lever is not to keep it — which the consume now pulls.
      raw = consumed!()
      assert {:ok, _} = Auth.verify_token(@bearer)
      assert row(raw) == nil
    end

    test "a row spent by the PRE-#16555 stamping consume is still swept, and is unconsumable" do
      # The backstop arm: rows in deployed databases that the old consume
      # stamped instead of deleting. They still hold the bearer, so the sweeper
      # must still take them — and the consume must still refuse them.
      raw = legacy_spent!()
      assert row(raw).api_token == @bearer
      assert Auth.consume_login_ticket(raw) == {:error, :invalid}

      assert %{deleted: 1} = LoginTicketSweeper.sweep()
      refute present?(raw)
    end
  end

  defp probe(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/v1/auth/login-tickets")
  end

  # ── bounded by construction ─────────────────────────────────────────────

  describe "sweep_login_tickets_batch/1 — bounded by construction" do
    test "one statement takes at most :sweep_batch_limit, oldest first" do
      # Deepest-expired first in this list, so index 0 is the OLDEST.
      [oldest, second, third] = for age <- [9000, 8400, 7800], do: expired_unused!(age)
      newers = for age <- [180, 120], do: expired_unused!(age)

      with_batch_limit(2)

      # BOUNDED: one statement takes the limit, never the whole backlog.
      assert Auth.sweep_login_tickets_batch() == 2
      assert count() == 3

      # OLDEST FIRST: the two it took are the two deepest-expired rows.
      refute present?(oldest)
      refute present?(second)
      assert present?(third)
      for n <- newers, do: assert(present?(n))
    end

    test "returns 0 over an empty backlog — the loop terminator" do
      assert Auth.sweep_login_tickets_batch() == 0
    end

    test "leaves a LIVE ticket alone — unused and not yet expired" do
      raw = live!()

      assert Auth.sweep_login_tickets_batch() == 0
      assert present?(raw)
    end
  end

  # ── the worker ──────────────────────────────────────────────────────────

  describe "LoginTicketSweeper.sweep/1 — the worker" do
    test "a tick removes legacy-spent and expired-unused rows and keeps the live one" do
      spent = legacy_spent!()
      expired = expired_unused!(300)
      live = live!()

      assert %{deleted: 2} = LoginTicketSweeper.sweep()

      # Row-precise, not count-only: a count assertion would be vacuous under
      # any row this suite did not create.
      refute present?(spent)
      refute present?(expired)
      assert present?(live)
    end

    test "a tick over an empty backlog is a no-op, not an error" do
      assert %{deleted: 0, passes: 1} = LoginTicketSweeper.sweep()
    end

    test "the loop finishes a backlog deeper than one batch" do
      for n <- 1..5, do: expired_unused!(7200 + n * 60)
      with_batch_limit(2)

      # 2 + 2 + 1 deleting passes, plus the terminating empty one.
      assert %{deleted: 5, passes: 4} = LoginTicketSweeper.sweep()
      assert count() == 0
    end

    test "perform/1 drives the same sweep" do
      spent = legacy_spent!()
      assert {:ok, %{deleted: 1}} = LoginTicketSweeper.perform(%Oban.Job{args: %{}})
      refute present?(spent)
    end
  end

  # ── THE WIRE ────────────────────────────────────────────────────────────

  # A worker nothing schedules is the defect this row is about. Assert the
  # SCHEDULE by reading the same crontab Oban is configured with, so deleting
  # the entry reds HERE and only here — the module's own tests above cannot
  # tell a wired worker from an unwired one.
  test "the sweeper is actually scheduled in the Oban crontab" do
    crontab =
      Application.get_env(:barkpark, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
        _ -> nil
      end)

    entry =
      Enum.find(crontab, fn
        {_expr, LoginTicketSweeper} -> true
        {_expr, LoginTicketSweeper, _opts} -> true
        _ -> false
      end)

    assert entry,
           "Barkpark.Auth.LoginTicketSweeper is not in the crontab — login_tickets grows forever again, each row holding a live bearer"

    # The cadence is the retention floor here (60s TTL, no grace window), so an
    # hourly slot would not be an equivalent wire. Pin per-minute.
    assert elem(entry, 0) == "* * * * *",
           "expected a per-minute schedule: with a 60s TTL and no grace window the cadence IS the retention floor for the EXPIRED-BUT-UNUSED arm (the spent arm is held by the consume's delete, task-62e7b342b85e88fe)"
  end
end
