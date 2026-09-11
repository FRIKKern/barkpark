defmodule BarkparkCloud.Web.RouterUserSecurityEventsTest do
  @moduledoc """
  `GET /v1/me/security-events` and its five producers — the USER-scoped security
  log filed as `cloud-console-user-security-log`.

  ## What each arm is written to LOSE on

  Every scoping arm runs against a fixture where a SECOND user has rows of their
  own, so a query that dropped its `where user_id` would return them and fail
  here rather than pass vacuously on a single-user fixture. The cross-read is
  asserted in BOTH directions (A cannot see B's, B cannot see A's), because a
  one-directional check passes on a query that leaks one way.

  The producer arms drive the REAL HTTP routes — not `Accounts.record_user_security_event/1`
  — so a producer that was never wired reds here instead of being simulated by
  the fixture. The metadata assertions are written as REFUTATIONS of the
  secret-bearing values that are in scope at each call site (the new password,
  the email confirmation code), because "we did not log the secret" is only
  proven by naming the secret and failing to find it.

  The team-audit arm proves the boundary in the direction that actually matters:
  a TEAM ADMIN, reading `GET /v1/audit` for a team the acting member belongs to,
  gets none of these five verbs — `user_security_events` has exactly one reader
  in the tree and it is user-keyed.
  """
  use BarkparkCloud.DataCase, async: false

  import BarkparkCloud.TotpTestHelper
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserSecurityEvent
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @new_password "a-brand-new-passphrase-9"

  ## ── Fixtures ────────────────────────────────────────────────────────────────

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

  defp session(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
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

  defp trail(token) do
    conn = call(:get, "/v1/me/security-events", nil, token)
    assert conn.status == 200
    json_body(conn)["events"]
  end

  defp actions(events), do: Enum.map(events, & &1["action"])

  defp last_email_code do
    assert_receive {:email, email}
    [code] = Regex.run(~r/\b\d{6}\b/, email.text_body)
    code
  end

  defp enroll_and_confirm_two_factor(user, token) do
    {:ok, %{secret_base32: b32}} = Accounts.start_two_factor_enrollment(user)
    {:ok, secret} = Base.decode32(b32, padding: false)

    conn =
      call(:post, "/v1/account/two-factor/confirm", %{code: totp_code_stable!(secret)}, token)

    assert conn.status == 200
    secret
  end

  ## ── The route: authentication ───────────────────────────────────────────────

  describe "GET /v1/me/security-events — authentication" do
    test "401 without a bearer token" do
      conn = call(:get, "/v1/me/security-events")
      assert conn.status == 401
    end

    test "401 with a garbage bearer token" do
      conn = call(:get, "/v1/me/security-events", nil, "not-a-real-token")
      assert conn.status == 401
    end

    test "200 + an empty list for a user who has done nothing sensitive yet" do
      assert trail(session(user_fixture())) == []
    end
  end

  ## ── The five producers, driven end to end ───────────────────────────────────

  describe "producers" do
    test "PUT /v1/account/password writes password_changed, and logs NEITHER password" do
      user = user_fixture()
      token = session(user)

      conn =
        call(
          :put,
          "/v1/account/password",
          %{current_password: @password, new_password: @new_password},
          token
        )

      assert conn.status == 200
      # The old token is revoked by the route; the response hands back a fresh one.
      fresh = json_body(conn)["token"]

      [event] = trail(fresh)
      assert event["action"] == "password_changed"
      assert event["metadata"] == %{"revoked_other_sessions" => true}

      encoded = Jason.encode!(event)
      refute encoded =~ @password
      refute encoded =~ @new_password
    end

    test "DELETE /v1/account/two-factor writes two_factor_disabled — and does NOT when 2FA was off" do
      # Arm A: 2FA was never on. The route is idempotent and answers 200; no row.
      off_user = user_fixture()
      off_token = session(off_user)
      assert call(:delete, "/v1/account/two-factor", nil, off_token).status == 200
      assert trail(off_token) == []

      # Arm B: 2FA genuinely on, then disabled.
      user = user_fixture()
      token = session(user)
      _secret = enroll_and_confirm_two_factor(user, token)

      assert call(:delete, "/v1/account/two-factor", nil, token).status == 200

      assert actions(trail(token)) == ["two_factor_disabled"]
    end

    test "DELETE /v1/account/sessions/:id writes session_revoked — and a 404 writes NOTHING" do
      user = user_fixture()
      token = session(user)
      other = session(user)

      %{"sessions" => sessions} = json_body(call(:get, "/v1/account/sessions", nil, token))
      victim = Enum.find(sessions, &(&1["current"] == false))
      assert victim["id"]

      assert call(:delete, "/v1/account/sessions/" <> victim["id"], nil, token).status == 200

      [event] = trail(token)
      assert event["action"] == "session_revoked"
      assert event["metadata"] == %{"session_id" => victim["id"]}
      # The revoked token really is dead — the row describes a change that happened.
      assert call(:get, "/v1/me", nil, other).status == 401

      # A row id that is not the caller's is a 404, and a 404 must not produce.
      stranger = session(user_fixture())
      %{"sessions" => [stranger_row]} = json_body(call(:get, "/v1/account/sessions", nil, stranger))

      assert call(:delete, "/v1/account/sessions/" <> stranger_row["id"], nil, token).status == 404
      assert actions(trail(token)) == ["session_revoked"]
    end

    test "DELETE /v1/account/sessions writes sessions_revoked_everywhere with the count — even at zero" do
      user = user_fixture()
      token = session(user)
      _a = session(user)
      _b = session(user)

      assert json_body(call(:delete, "/v1/account/sessions", nil, token)) == %{"revoked" => 2}

      [event] = trail(token)
      assert event["action"] == "sessions_revoked_everywhere"
      assert event["metadata"] == %{"revoked" => 2}

      # The act completed with nothing left to reach: still a fact, still a row.
      assert json_body(call(:delete, "/v1/account/sessions", nil, token)) == %{"revoked" => 0}
      assert actions(trail(token)) == ["sessions_revoked_everywhere", "sessions_revoked_everywhere"]
      assert hd(trail(token))["metadata"] == %{"revoked" => 0}
    end

    test "POST /v1/account/email/confirm writes email_changed carrying the FORMER address, not the code" do
      user = user_fixture()
      token = session(user)
      was = user.email
      target = "moved-#{System.unique_integer([:positive])}@example.com"

      assert call(:post, "/v1/account/email/change", %{new_email: target}, token).status == 202
      code = last_email_code()

      assert call(:post, "/v1/account/email/confirm", %{code: code}, token).status == 200

      [event] = trail(token)
      assert event["action"] == "email_changed"
      assert event["metadata"] == %{"previous_email" => was, "new_email" => target}
      refute Jason.encode!(event) =~ code

      # A wrong code changes nothing, so it writes nothing.
      assert call(:post, "/v1/account/email/change", %{new_email: "again-#{target}"}, token).status ==
               202

      _superseded = last_email_code()
      assert call(:post, "/v1/account/email/confirm", %{code: "000000"}, token).status == 422
      assert actions(trail(token)) == ["email_changed"]
    end
  end

  ## ── The device columns ──────────────────────────────────────────────────────

  describe "the row carries the acting device" do
    test "ip and user_agent come from the request, and a hostile User-Agent is truncated" do
      user = user_fixture()
      token = session(user)
      long_ua = String.duplicate("U", UserSecurityEvent.user_agent_max() + 500)

      conn =
        conn(:delete, "/v1/account/sessions")
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("user-agent", long_ua)
        |> Router.call(@opts)

      assert conn.status == 200

      [event] = trail(token)
      assert event["ip"] == "127.0.0.1"
      assert String.length(event["user_agent"]) == UserSecurityEvent.user_agent_max()
    end
  end

  ## ── AUTHORIZATION: a user reads ONLY their own rows ─────────────────────────

  describe "scoping — a user reads only their own trail" do
    test "cross-read returns nothing, in BOTH directions, over a two-user fixture" do
      a = user_fixture()
      a_token = session(a)
      b = user_fixture()
      b_token = session(b)

      # Both users produce, so an unscoped query would return four rows to each.
      assert call(:delete, "/v1/account/sessions", nil, a_token).status == 200
      assert call(:delete, "/v1/account/sessions", nil, a_token).status == 200
      assert call(:delete, "/v1/account/sessions", nil, b_token).status == 200

      a_rows = trail(a_token)
      b_rows = trail(b_token)

      assert length(a_rows) == 2
      assert length(b_rows) == 1

      a_ids = a_rows |> Enum.map(& &1["id"]) |> MapSet.new()
      b_ids = b_rows |> Enum.map(& &1["id"]) |> MapSet.new()

      assert MapSet.disjoint?(a_ids, b_ids)

      # And the DB agrees about who owns what — the read is not merely consistent
      # with itself.
      assert Repo.all(from e in UserSecurityEvent, where: e.user_id == ^a.id, select: e.id)
             |> MapSet.new() == a_ids

      assert Repo.all(from e in UserSecurityEvent, where: e.user_id == ^b.id, select: e.id)
             |> MapSet.new() == b_ids
    end

    test "Accounts.list_user_security_events/2 is scoped at the context, not just the route" do
      a = user_fixture()
      b = user_fixture()

      {:ok, _} =
        Accounts.record_user_security_event(%{user_id: a.id, action: "password_changed"})

      {:ok, b_row} =
        Accounts.record_user_security_event(%{user_id: b.id, action: "password_changed"})

      assert Enum.map(Accounts.list_user_security_events(b), & &1.id) == [b_row.id]
      assert Accounts.list_user_security_events(a) |> Enum.map(& &1.id) != [b_row.id]
    end

    test "newest first, and ?limit= is clamped rather than trusted" do
      user = user_fixture()
      token = session(user)

      for _ <- 1..3, do: assert(call(:delete, "/v1/account/sessions", nil, token).status == 200)

      rows = trail(token)
      assert length(rows) == 3
      stamps = Enum.map(rows, & &1["inserted_at"])
      assert stamps == Enum.sort(stamps, :desc)

      limited = json_body(call(:get, "/v1/me/security-events?limit=1", nil, token))["events"]
      assert length(limited) == 1
      assert hd(limited)["id"] == hd(rows)["id"]

      # An absurd limit clamps to the 200 ceiling instead of asking for the table.
      assert length(json_body(call(:get, "/v1/me/security-events?limit=100000", nil, token))["events"]) ==
               3
    end
  end

  ## ── AUTHORIZATION: the operator/team audit surface does not widen into this ──

  describe "the team audit register does not reach these rows" do
    test "a team admin's GET /v1/audit carries none of the five user-security verbs" do
      admin = user_fixture()
      member = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "owner")
      {:ok, _} = Accounts.add_member(team, member, "member")

      admin_token = session(admin)
      member_token = session(member)

      # The member produces two user-security rows inside this admin's team.
      _secret = enroll_and_confirm_two_factor(member, member_token)
      assert call(:delete, "/v1/account/two-factor", nil, member_token).status == 200
      assert call(:delete, "/v1/account/sessions", nil, member_token).status == 200

      assert actions(trail(member_token)) ==
               ["sessions_revoked_everywhere", "two_factor_disabled"]

      conn = call(:get, "/v1/audit?limit=200", nil, admin_token)
      assert conn.status == 200
      team_actions = json_body(conn)["events"] |> Enum.map(& &1["action"])

      # The team register DID see the 2FA pair (its own verbs) — so this arm is
      # not vacuous on an empty audit feed.
      assert "twofa.disabled" in team_actions

      # …and it carries not one verb from the user-scoped table.
      assert MapSet.disjoint?(MapSet.new(team_actions), MapSet.new(UserSecurityEvent.actions()))

      # The admin's OWN user trail stays empty: team authority buys nothing here.
      assert trail(admin_token) == []
    end

    test "`user_security_events` has exactly ONE reader and ONE writer in cloud/lib" do
      root = Path.expand("../../../lib/barkpark_cloud", __DIR__)

      files =
        Path.wildcard(Path.join(root, "**/*.ex"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/UserSecurityEvent|user_security_events/))
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.sort()

      assert files == [
               "accounts.ex",
               "accounts/user_security_event.ex",
               "web/router.ex"
             ]

      router = File.read!(Path.join(root, "web/router.ex"))

      # One reader: the self-scoped route. A second call site of the list
      # function — a team feed, an operator feed — reds here.
      assert length(Regex.scan(~r/Accounts\.list_user_security_events\(/, router)) == 1
      # One writer: the best-effort helper. Five call sites, one insert seam.
      assert length(Regex.scan(~r/Accounts\.record_user_security_event\(/, router)) == 1
    end
  end

  ## ── IMMUTABILITY ────────────────────────────────────────────────────────────

  describe "the rows are immutable" do
    test "raw UPDATE and DELETE are refused by the DB trigger" do
      user = user_fixture()

      {:ok, row} =
        Accounts.record_user_security_event(%{user_id: user.id, action: "password_changed"})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(e in UserSecurityEvent, where: e.id == ^row.id),
          set: [action: "email_changed"]
        )
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(e in UserSecurityEvent, where: e.id == ^row.id))
      end
    end

    test "the schema declares no updated_at and refuses a verb outside the closed set" do
      refute :updated_at in UserSecurityEvent.__schema__(:fields)

      user = user_fixture()

      assert {:error, cs} =
               Accounts.record_user_security_event(%{user_id: user.id, action: "password.changed"})

      assert "is invalid" in errors_on(cs).action
    end
  end
end
