defmodule BarkparkCloud.Web.RouterEventsRefusalTouchTest do
  @moduledoc """
  `GET /v1/events` must not claim a device is active on a request it REFUSED.

  ## The defect

  `require_user_sse/1` resolved its Bearer header through
  `Accounts.verify_user_session_token/1` — the arity that takes the EAGER
  `touch: true` default — and the route answered `422 no_team` afterwards. So a
  teamless header client fired one request, was refused, and its session row's
  `last_used_at` jumped to now. The sessions card renders that column as
  "Active just now", i.e. it printed a REFUSED device as freshly active. A
  throttle cannot fix it: an idle device satisfies any staleness window, which
  is exactly what the frozen-backdate fixtures below measure.

  The two `Web.Auth` plug sites already defer their stamp to
  `register_before_send/2`; this route did not, on the stated ground that "its
  only refusal is a 401 on a credential that never resolved a user". The route's
  own 422 arm refutes that, and the tests below are keyed on the 422.

  ## The reach, stated honestly

  HEADER CLIENTS ONLY — curl, the `bp` CLI, an EventSource polyfill. The browser
  console opens this stream with `?ticket=`, because the EventSource API cannot
  set an Authorization header, and ticket redemption stamps NOTHING on the
  session row. That last clause is not reasoning, it is
  `the ticket branch stamps nothing on the session row` below, driven.

  ## Why `send_chunked` keeps the honest half honest

  `register_before_send/2` fires for `send_chunked/2` as well as `send_resp/3`,
  so the SERVED stream still stamps — at its 200, the same instant the eager
  call used to. Nothing is deferred past the park.
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

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp session_tokens_of(user) do
    from(t in UserToken, where: t.user_id == ^user.id and t.context == "session")
  end

  # The mint itself stamps `last_used_at`, so every assertion here works off a
  # KNOWN backdated instant rather than a comparison against "now": "still
  # exactly that instant" is a claim no clock resolution can fake.
  defp backdate_session(user) do
    backdated = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:microsecond)
    {1, _} = Repo.update_all(session_tokens_of(user), set: [last_used_at: backdated])
    backdated
  end

  defp stamp_of(user) do
    [%UserToken{last_used_at: stamp}] = Repo.all(session_tokens_of(user))
    stamp
  end

  defp get(path, token \\ nil) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  ## The refusal

  describe "a refused GET /v1/events" do
    test "422 no_team leaves last_used_at exactly where it was" do
      # Teamless ON PURPOSE: it is the discriminator this suite family uses —
      # 401 means the credential never resolved, 422 no_team means it resolved a
      # real user and the ROUTE then refused. Only the second one can over-stamp.
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
      backdated = backdate_session(user)

      conn = get("/v1/events", token)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["reason"] == "no_team"

      assert stamp_of(user) == backdated, """
      the 422 advanced last_used_at — the sessions card will print this refused \
      device as freshly active. `require_user_sse` is resolving its header with \
      the eager touch default again.
      """
    end

    test "401 on an unresolvable header stamps nothing either" do
      # The control that keeps the test above from being satisfied by a broken
      # route: a credential that resolves NO user cannot stamp any row, so the
      # 422 case is the one that carries the information.
      user = user_fixture()
      {:ok, _token} = Accounts.create_user_session_token(user)
      backdated = backdate_session(user)

      assert get("/v1/events", "not-a-real-token").status == 401
      assert stamp_of(user) == backdated
    end
  end

  ## The genuinely-eager path — the half that MUST still stamp

  describe "a served GET /v1/events" do
    test "the opened stream stamps last_used_at at its 200" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
      backdated = backdate_session(user)

      # The stream parks in a receive loop forever, so it runs in a separate
      # process. `Plug.Adapters.Test.Conn.send_chunked/3` messages the conn's
      # OWNER with `{:plug_conn, :sent}` — that message IS the proof the 200
      # chunked response was sent, and `register_before_send/2` callbacks have
      # already run by the time it is delivered.
      request = conn(:get, "/v1/events") |> put_req_header("authorization", "Bearer #{token}")
      task = Task.async(fn -> Router.call(request, @opts) end)

      assert_receive {:plug_conn, :sent}, 2_000

      Task.shutdown(task, :brutal_kill)

      assert DateTime.compare(stamp_of(user), backdated) == :gt, """
      the SERVED stream no longer stamps. Deferring the touch must not silence \
      the honest half: a device that really is streaming has to read as active.
      """
    end
  end

  ## The reach reading, driven

  describe "the ticket branch" do
    test "stamps nothing on the session row — which is why the SPA never saw this" do
      # The console opens the stream with `?ticket=` (EventSource cannot set an
      # Authorization header). The ticket is minted BOUND to the session token,
      # so this is the strongest form of the reading: even a ticket that knows
      # its session row moves no stamp on it. Hence the defect above was only
      # ever reachable by header clients.
      user = user_fixture()
      {:ok, session_token} = Accounts.create_user_session_token(user)
      {:ok, ticket} = Accounts.create_sse_ticket(user, session_token)
      backdated = backdate_session(user)

      conn = get("/v1/events?ticket=#{ticket}")

      # Teamless, so the redemption answers synchronously: 422 proves the ticket
      # WAS redeemed (401 would mean it never resolved a user at all).
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["reason"] == "no_team"

      assert stamp_of(user) == backdated, """
      ticket redemption moved the session row's last_used_at. If that ever \
      becomes true, the reach statement on this fix (header clients only) is \
      false and the console is misinformed too.
      """
    end
  end
end
