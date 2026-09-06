defmodule BarkparkCloud.Web.RouterSseTicketHeadBurnTest do
  @moduledoc """
  `HEAD /v1/events?ticket=…` must not SPEND the ticket.

  THE DEFECT, and why neither slice that created it could see it. Two
  individually-correct wave-2 changes landed on the same main:

    * the SSE ticket (`?ticket=` → `Accounts.consume_sse_ticket/1`, which burns
      the row it resolves), and
    * `plug(Plug.Head)`, which rewrites HEAD→GET once, before matching, and
      stashes nothing — by the time a route runs, HEAD-ness is destroyed.

  Composed, a bare `HEAD /v1/events?ticket=<live>` from any unfurler, uptime
  checker or `curl -I` ran the whole redemption: it answered the teamless refusal
  (auth SUCCEEDED — the `no_team` refusal is this suite's teamless "the credential
  resolved a real user" discriminator; it was 422 until cch-w40-bl converged the
  inline emitters on the gate's 403 shape), stamped `revoked_at`, and the user's own EventSource then got
  401 on a ticket it had never redeemed. `consume_sse_ticket/1` takes a BARE
  BINARY and is structurally method-blind, so no amount of care inside
  `Accounts` could have caught it.

  THE FIX IS ONE FENCE CLAUSE — `side_effecting_get?(["v1", "events"])` — and it
  belongs exactly there: `refuse_head_on_side_effecting_gets` is the LAST layer
  that can still see the request was a HEAD, and it halts BEFORE `plug(:match)`,
  so the 405 costs zero DB access (pinned below against `last_used_at`).
  Threading `conn` into `Accounts` would invert the layering to buy nothing.

  D40 COVERAGE BOUNDARY. This file pins the `/v1/events` instance and the
  fence's no-DB property. It does NOT prove the deny-list is COMPLETE — no
  behavioural test can, since the list is a deny-list by decision (D13). The
  companion census pin (`router_head_fence_census_test.exs`) bounds the drift;
  it does not close that gap either.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  # Teamless ON PURPOSE (same reason as `router_sse_ticket_test.exs`): every
  # /v1/events answer is then SYNCHRONOUS — 401 = credential refused, 403
  # no_team = credential accepted and burned. A user WITH a team parks in the
  # SSE receive loop; that path gets its own out-of-process test below.
  defp teamless_user_with_ticket do
    user = user_fixture()
    {:ok, ticket} = Accounts.create_sse_ticket(user)
    {user, ticket}
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp sse_tokens(user) do
    Repo.all(from(t in UserToken, where: t.user_id == ^user.id and t.context == "sse"))
  end

  defp session_tokens_of(user) do
    from(t in UserToken, where: t.user_id == ^user.id and t.context == "session")
  end

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## The instance

  describe "HEAD /v1/events" do
    test "is refused 405 + `allow: GET` — it does not run the stream handler" do
      {_user, ticket} = teamless_user_with_ticket()

      conn = call(:head, "/v1/events?ticket=#{ticket}")

      # A no_team answer here would be the BURN signature: auth ran, the ticket
      # resolved a user, and the no_team branch answered (403 since cch-w40-bl,
      # 422 before it). 405 is the fence.
      assert conn.status == 405, """
      expected the side-effecting-GET fence to refuse this HEAD with 405, got \
      #{conn.status}. A 422 means `Plug.Head` rewrote the method and the stream \
      route redeemed (and BURNED) the ticket.
      """

      assert get_resp_header(conn, "allow") == ["GET"]
      # 405, never 404: "this path exists, that method is refused" (D12). A 404
      # would re-tell the exact lie `plug(Plug.Head)` was landed to remove.
      refute conn.status == 404
    end

    test "does NOT burn the ticket, and the user's own GET still opens" do
      {user, ticket} = teamless_user_with_ticket()

      assert [%UserToken{revoked_at: nil}] = sse_tokens(user)

      call(:head, "/v1/events?ticket=#{ticket}")

      # THE POINT: the row the probe touched is still live.
      assert [%UserToken{revoked_at: nil}] = sse_tokens(user),
             "the HEAD probe stamped revoked_at — it spent a ticket the real EventSource never redeemed"

      # And the credential is not merely unstamped, it is still REDEEMABLE:
      # 403 no_team = it resolved a real user (401 would mean it was spent).
      # cch-w40-bl converged this inline emitter on the gate shape, so the
      # discriminator is the CAUSE (`reason`), not the status.
      after_head = call(:get, "/v1/events?ticket=#{ticket}")
      assert after_head.status == 403
      assert json_body(after_head)["reason"] == "no_team"

      # That legitimate GET is what burns it — single-use is untouched.
      assert [%UserToken{revoked_at: %DateTime{}}] = sse_tokens(user)
      assert call(:get, "/v1/events?ticket=#{ticket}").status == 401
    end

    test "costs ZERO DB access: it halts before authentication runs at all" do
      # The fence runs before `plug(:match)`, so no route body — and no auth
      # wrapper — executes. `last_used_at` is the observable: the mint already
      # stamps it, so the fixture BACKDATES the row to a known instant and the
      # assertion is "still exactly that instant", which no clock resolution can
      # fake.
      #
      # THE CONTROL LEG WAS RE-BASED (cch-w12-bl), DELIBERATELY. It used to read
      # "the same credential on a real GET DOES move it", asserting the stamp
      # jumped — and that assertion PINNED the over-stamp this file never meant
      # to defend: the GET it fires is the teamless 422, a REFUSED request, and
      # `require_user_sse` stamping there is precisely the defect. The control's
      # job is only to prove the credential is live and reaches the auth layer,
      # so it now measures the STATUS (422 = the header resolved a real user and
      # the route refused) instead of the stamp, and pins the stamp as FROZEN
      # across that refusal. Same fixture, same discriminating power over "the
      # fence is running too late"; it no longer requires the bug to exist.
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
      backdated = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:microsecond)
      {1, _} = Repo.update_all(session_tokens_of(user), set: [last_used_at: backdated])

      assert call(:head, "/v1/events", token).status == 405

      assert [%UserToken{last_used_at: ^backdated}] = Repo.all(session_tokens_of(user)),
             "the HEAD reached the auth layer — the fence is running too late"

      # Control: the same credential on a real GET DOES reach the auth layer —
      # 403 no_team is this suite's "the header resolved a real user" signal, so
      # the assertion above measures the fence and not a dead fixture (cch-w40-bl
      # moved it from 422 to the gate's 403 shape).
      assert call(:get, "/v1/events", token).status == 403

      # And the refused GET leaves the stamp alone, which is the point of
      # cch-w12-bl: `require_user_sse` defers its touch to
      # `register_before_send/2`, so only a request the platform SERVED claims
      # activity. A jump here means the eager touch default is back.
      assert [%UserToken{last_used_at: ^backdated}] = Repo.all(session_tokens_of(user))
    end

    test "an unauthenticated HEAD is refused identically — the fence is credential-blind" do
      # It matches on `conn.path_info` only, so a probe with no ticket at all
      # gets the same 405 rather than the 401 the route would have produced.
      conn = call(:head, "/v1/events")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET"]
    end
  end

  ## The happy path, proven POSITIVELY (not by absence of a burn)

  describe "GET /v1/events for a user WITH a team" do
    test "opens the chunked stream AND burns its ticket" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")
      {:ok, ticket} = Accounts.create_sse_ticket(user)

      # The stream parks in a receive loop forever, so it runs in a separate
      # process. `Plug.Adapters.Test.Conn.send_chunked/3` messages the conn's
      # OWNER (this process, which built the conn) with `{:plug_conn, :sent}` —
      # that message IS the proof the 200 chunked response was sent, and it is
      # the only observable a parked stream can give a test.
      request = conn(:get, "/v1/events?ticket=#{ticket}")
      task = Task.async(fn -> Router.call(request, @opts) end)

      assert_receive {:plug_conn, :sent}, 2_000

      # Its ticket is spent — the connect is the redemption.
      assert [%UserToken{revoked_at: %DateTime{}}] = sse_tokens(user)

      Task.shutdown(task, :brutal_kill)

      # And the spent ticket cannot re-open it (teamless-free proof that the
      # burn was real and not a stray row): a replay is refused before the
      # no_team/stream fork is ever reached.
      assert call(:get, "/v1/events?ticket=#{ticket}").status == 401
    end

    test "HEAD does not open that stream either" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")
      {:ok, ticket} = Accounts.create_sse_ticket(user)

      # No Task, no timeout dance: if the fence works this returns immediately.
      # If it does not, the HEAD would subscribe and park exactly like the GET
      # above — a hung test IS the failure mode this fence removes.
      conn = call(:head, "/v1/events?ticket=#{ticket}")

      assert conn.status == 405
      assert [%UserToken{revoked_at: nil}] = sse_tokens(user)
    end
  end
end
