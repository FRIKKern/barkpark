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
      the row exists to settle, and it is deliberately first.
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

  # A ticket minted and consumed — `used_at` stamped, row retained.
  defp spent! do
    {:ok, raw} = Auth.mint_login_ticket(@bearer)
    {:ok, @bearer} = Auth.consume_login_ticket(raw)
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
    test "a SPENT row's api_token still authenticates, and it is a decrypt-on-load",
         %{conn: conn} do
      raw = spent!()
      r = row(raw)

      # The row survives the consume — "spent" means stamped, not deleted.
      assert r != nil
      assert r.used_at != nil

      # DECRYPT-ON-LOAD, confirmed rather than assumed: the bytes at rest are
      # ciphertext, and a plain Ecto load through the schema hands back the
      # plaintext bearer. So the consume path is not the only reader.
      ciphertext =
        from(t in "login_tickets",
          where: t.ticket_hash == ^Auth.hash_ticket(raw),
          select: type(t.api_token, :binary)
        )
        |> Repo.one()

      assert is_binary(ciphertext)
      refute ciphertext == @bearer
      refute String.contains?(ciphertext, @bearer)
      assert r.api_token == @bearer

      # Present the recovered bearer to a route that REQUIRES a token.
      recovered = probe(conn, r.api_token)

      # NEGATIVE CONTROL — the route really does enforce auth, so a success
      # above cannot be "this route is public".
      garbage = probe(conn, "not-a-real-token-zzzzzz")
      none = post(conn, "/v1/auth/login-tickets")
      assert garbage.status == 401
      assert none.status == 401

      # POSITIVE CONTROL — the same bearer value, known-good, same route, same
      # shape of request. Without it, "it does not authenticate" and "my
      # request was malformed" would be the same observation.
      control = probe(conn, @bearer)
      assert control.status == 201

      # No arm was rate-limited: a 429 read as an auth failure would invert
      # this conclusion.
      for c <- [recovered, garbage, none, control], do: refute(c.status == 429)

      # THE FINDING. The bearer recovered from a spent row does not merely
      # authenticate — it mints a fresh login-handoff ticket. `sweep_login_tickets/0`'s
      # docstring used to say a dead row "carries no live secret"; it does.
      assert recovered.status == 201
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

    test "consuming a ticket does not revoke the bound token — which is why the row matters" do
      raw = spent!()
      assert {:ok, _} = Auth.verify_token(row(raw).api_token)
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
    test "a tick removes spent and expired-unused rows and keeps the live one" do
      spent = spent!()
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
      spent = spent!()
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
           "expected a per-minute schedule: with a 60s TTL and no grace window the cadence IS the retention floor"
  end
end
