defmodule BarkparkCloud.Web.RouterSseTicketTest do
  @moduledoc """
  The SSE stream ticket (cch-w3): `POST /v1/auth/sse-ticket` and the `?ticket=`
  leg of `GET /v1/events`.

  The defect this closes: `GET /v1/events` used to accept a full 30-day session
  token as `?token=`, so every access log and proxy trace along the path held a
  live credential. `EventSource` cannot set request headers, so the fix is not
  "move it to a header" — it is to make the thing in the URL worthless: an
  SSE-scoped ticket that lives 60 seconds and is BURNED by the connect.

  Three invariants are pinned here, each of which fails in a different, quiet way:

    1. SINGLE-USE — a replayed ticket is refused.
    2. MATCHED-ROW-ONLY — burning one ticket must not touch a sibling. Every
       `revoke_*_tokens/2` helper in `Accounts` is scoped by `user_id + context`
       with NO `token_hash`, so reusing one would revoke the user's other live
       tickets. Under the client's remint-on-error loop that is a two-tab
       mutual-eviction storm: tab B mints, A's unconsumed ticket dies, A 401s, A
       remints, B dies — forever, one junk 401 per turn. A test that mints only
       ONE ticket cannot see it.
    3. NO GET CLAUSE ON THE MINT PATH — `plug(Plug.Head)` rewrites HEAD→GET
       unconditionally BEFORE matching, so HEAD-ness is destroyed by the time a
       route runs and a POST-only path can only refuse a HEAD prober by having no
       GET clause AT ALL. (Measured counterexample elsewhere in this router: HEAD
       /v1/tokens answers 401, not 404, precisely because a `get "/v1/tokens"`
       lives beside its `post`.) The invariant is the PATH, not the verb.
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

  # A teamless user + a live session token. Teamless ON PURPOSE: every
  # /v1/events assertion below then answers SYNCHRONOUSLY (401 = credential
  # refused, 403 no_team = credential accepted and resolved a real user). A user
  # WITH a team parks in the SSE receive loop and would hang the test.
  defp user_with_token do
    user = user_fixture()
    {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
    {user, token}
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp sse_tokens(user) do
    Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "sse")
  end

  ## POST /v1/auth/sse-ticket

  describe "POST /v1/auth/sse-ticket" do
    test "mints a ticket for a bearer presented in an Authorization HEADER" do
      {user, token} = user_with_token()

      conn = call(:post, "/v1/auth/sse-ticket", %{}, token)

      assert conn.status == 200
      body = json_body(conn)
      assert is_binary(body["ticket"]) and body["ticket"] != ""
      assert body["expires_in"] == 60

      # THE POINT OF THE ROUTE: the credential that authorised the mint rode a
      # header, and the thing handed back is NOT that credential.
      refute body["ticket"] == token

      # Zero migration: it is a row in the existing polymorphic user_tokens
      # table, discriminated by `context`, with only a hash at rest.
      assert [%UserToken{context: "sse", token_hash: hash, revoked_at: nil}] = sse_tokens(user)
      assert hash == UserToken.hash_token(body["ticket"])
      refute hash == body["ticket"]
    end

    test "401s without a bearer" do
      assert call(:post, "/v1/auth/sse-ticket", %{}).status == 401
    end

    test "401s for a revoked session — a dead session cannot mint stream access" do
      {_user, token} = user_with_token()
      {:ok, _} = Accounts.revoke_user_session_token(token)

      assert call(:post, "/v1/auth/sse-ticket", %{}, token).status == 401
    end

    test "mint does NOT supersede: a second mint leaves the first ticket live" do
      # The mutual-eviction storm starts here if the mint is copied from the
      # password-reset template (which revokes the user's live siblings).
      {user, token} = user_with_token()

      first = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]
      second = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]

      refute first == second
      assert length(sse_tokens(user)) == 2
      assert Enum.all?(sse_tokens(user), &is_nil(&1.revoked_at))
      # Both still redeem — order-independent.
      assert %{} = Accounts.consume_sse_ticket(second)
      assert %{} = Accounts.consume_sse_ticket(first)
    end
  end

  ## The route SHAPE (D26): the invariant is that the PATH has no GET clause.

  describe "the mint path has no GET route" do
    test "GET /v1/auth/sse-ticket does not match any route" do
      # 404, not 401: a 401 would mean SOME clause matched the path and only the
      # auth check refused it, which is what HEAD /v1/tokens does (it has a GET
      # twin). Here nothing matches, which is the only way to keep a HEAD prober
      # off the route at all — Plug.Head rewrites HEAD→GET before matching, so
      # the route can never see that the request was a HEAD.
      assert call(:get, "/v1/auth/sse-ticket").status == 404

      # Authenticated too: a live bearer must not turn the 404 into a reachable
      # handler (that is exactly how HEAD /v1/tokens reaches the LIST handler).
      {_user, token} = user_with_token()
      assert call(:get, "/v1/auth/sse-ticket", nil, token).status == 404
    end

    test "HEAD /v1/auth/sse-ticket cannot reach the mint handler and mints nothing" do
      {user, token} = user_with_token()

      conn = call(:head, "/v1/auth/sse-ticket", nil, token)

      assert conn.status == 404
      assert sse_tokens(user) == []
    end

    test "the router source declares no GET clause on the mint path" do
      # Belt to the behavioural braces: a future `get "/v1/auth/sse-ticket"`
      # (however innocent) silently re-opens the HEAD hole, and the status
      # assertions above would then read 401/200 rather than 404. Fail on the
      # DECLARATION, so the reason is unmistakable.
      src = File.read!(Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__))
      refute src =~ ~r/^\s*get[\s(]+"\/v1\/auth\/sse-ticket"/m
      assert src =~ ~r/^\s*post[\s(]+"\/v1\/auth\/sse-ticket"/m
    end
  end

  ## Single-use + matched-row-only (D28/D29)

  describe "ticket redemption" do
    test "a ticket opens the stream exactly once; the replay is refused" do
      {_user, token} = user_with_token()
      ticket = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]

      # First use resolves a real user (403 no_team = past auth, teamless —
      # cch-w40-bl converged this inline emitter on the gate's shape, so the
      # discriminator is the CAUSE, `reason`, not the status).
      first = call(:get, "/v1/events?ticket=#{ticket}")
      assert first.status == 403
      assert json_body(first)["reason"] == "no_team"

      # The replay — the shape of an attacker reading the URL out of an access
      # log, or of the browser's own native retry re-sending the frozen URL.
      assert call(:get, "/v1/events?ticket=#{ticket}").status == 401
      assert call(:get, "/v1/events?ticket=#{ticket}").status == 401
    end

    test "consume burns the MATCHED ROW ONLY, never a live sibling" do
      # D28's storm test. With a user_id-scoped revoke helper, consuming one of
      # two tickets stamps revoked_at on BOTH and this drops from 2 live to 0.
      {user, token} = user_with_token()
      a = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]
      b = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]

      assert length(sse_tokens(user)) == 2
      assert Enum.count(sse_tokens(user), &is_nil(&1.revoked_at)) == 2

      assert %{id: uid} = Accounts.consume_sse_ticket(a)
      assert uid == user.id

      # Exactly ONE row burned.
      assert Enum.count(sse_tokens(user), &is_nil(&1.revoked_at)) == 1
      # And the survivor is genuinely still redeemable — not merely unstamped.
      assert %{} = Accounts.consume_sse_ticket(b)
      assert Enum.count(sse_tokens(user), &is_nil(&1.revoked_at)) == 0
      # Now both are spent.
      assert Accounts.consume_sse_ticket(a) == nil
      assert Accounts.consume_sse_ticket(b) == nil
    end

    test "consume refuses a revoked row — the single-use guarantee is enforceable" do
      # `verify_two_factor_pending_token/1` does NOT filter revoked_at, so a
      # token stamped revoked_at still verifies through it. Copying that verify
      # would have made single-use unenforceable while every other test passed.
      {user, token} = user_with_token()
      ticket = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]

      [row] = sse_tokens(user)
      {:ok, _} = Repo.update(UserToken.changeset(row, %{revoked_at: DateTime.utc_now()}))

      assert Accounts.consume_sse_ticket(ticket) == nil
      assert call(:get, "/v1/events?ticket=#{ticket}").status == 401
    end

    test "consume refuses an expired ticket" do
      {user, token} = user_with_token()
      ticket = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]

      [row] = sse_tokens(user)
      past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)
      {:ok, _} = Repo.update(UserToken.changeset(row, %{expires_at: past}))

      assert Accounts.consume_sse_ticket(ticket) == nil
      assert call(:get, "/v1/events?ticket=#{ticket}").status == 401
    end

    test "the ticket is SSE-scoped: it is not a session token and cannot act as one" do
      {_user, token} = user_with_token()
      ticket = json_body(call(:post, "/v1/auth/sse-ticket", %{}, token))["ticket"]

      # The whole reason the leak was severe is that `?token=` carried a
      # credential good for the entire API. A ticket is good for one stream.
      assert Accounts.verify_user_session_token(ticket) == nil
      assert call(:get, "/v1/me", nil, ticket).status == 401
      assert call(:post, "/v1/auth/sse-ticket", %{}, ticket).status == 401
    end

    test "a session token presented as a ticket is refused (contexts never cross)" do
      {_user, token} = user_with_token()

      assert Accounts.consume_sse_ticket(token) == nil
      assert call(:get, "/v1/events?ticket=#{token}").status == 401
      # And consuming it did not damage the session token.
      assert %{} = Accounts.verify_user_session_token(token)
    end

    test "garbage and non-binary input are refused without raising" do
      assert Accounts.consume_sse_ticket("not-a-ticket") == nil
      assert Accounts.consume_sse_ticket(nil) == nil
      assert Accounts.consume_sse_ticket(123) == nil
      assert call(:get, "/v1/events?ticket=").status == 401
    end
  end
end
