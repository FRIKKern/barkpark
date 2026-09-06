defmodule BarkparkCloud.Web.RouterAccountSecurityAuditTest do
  @moduledoc """
  `GET /v1/account/security-audit` — the MEMBER SELF-READ over account-security
  audit rows, implementing the owner's ruling of 2026-08-23
  (task-ddaeea4356664b7a): a member may read the rows where they are BOTH THE
  ACTOR AND THE TARGET, and `GET /v1/audit` is NOT widened.

  "Self" on an audit row is a COMPOUND predicate — a row carries an actor, a
  target and a team — so every assertion here is written to lose in a specific
  way:

    * the self-only arms run against a fixture that ALSO carries another
      member's rows, so a query that returned everything fails instead of
      passing vacuously on a single-row fixture;
    * the actor and target halves are asserted in BOTH directions (target but
      not actor, actor but not target), because a single-column check satisfies
      one and silently fails the other;
    * the MOVED-MEMBER case is asserted against the DECISION
      (`:across_teams`, documented on `Accounts.list_self_security_audit_events/2`),
      not against whatever the query happens to produce — audit team scoping
      resolves by primary-team-at-write-time, so a member whose primary team
      changed has rows under a FORMER team, and either answer would have been
      implementable.

  Driven via Plug.Test, mirroring `RouterAuditTest`.
  """
  use BarkparkCloud.DataCase, async: false

  import BarkparkCloud.TotpTestHelper
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
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

  # An OWNER of a fresh team, plus a session token. {user, team, token}.
  defp logged_in do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  # Add a member to `team` at `role` and return {user, token}.
  defp member_of(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  # The exact shape `Router.audit_account_security/2` writes: actor and target
  # are the SAME human, target_type "user". Spelled out here rather than
  # borrowed, so a drift at the write seam shows up as a red in the two
  # end-to-end arms below instead of being copied into the fixture.
  defp self_row(team, user, action) do
    {:ok, ev} =
      Accounts.record_audit(%{
        team_id: team.id,
        actor_user_id: user.id,
        action: action,
        target_type: "user",
        target_id: user.id
      })

    ev
  end

  defp row(team, actor, target_type, target_id, action) do
    {:ok, ev} =
      Accounts.record_audit(%{
        team_id: team.id,
        actor_user_id: actor && actor.id,
        action: action,
        target_type: target_type,
        target_id: target_id
      })

    ev
  end

  defp enroll_two_factor(user) do
    {:ok, %{secret_base32: b32}} = Accounts.start_two_factor_enrollment(user)
    {:ok, secret} = Base.decode32(b32, padding: false)
    secret
  end

  ## Request helpers

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

  defp self_read(token) do
    conn = call(:get, "/v1/account/security-audit", nil, token)
    assert conn.status == 200
    %{"events" => events} = json_body(conn)
    events
  end

  defp ids(events), do: events |> Enum.map(& &1["id"]) |> MapSet.new()

  ## The surface

  describe "GET /v1/account/security-audit — authentication" do
    test "401 without a bearer token" do
      conn = call(:get, "/v1/account/security-audit")
      assert conn.status == 401
    end

    test "200 with an empty list for a member who has no security rows" do
      {_owner, team, _owner_token} = logged_in()
      {_member, member_token} = member_of(team, "member")

      assert self_read(member_token) == []
    end
  end

  ## Criterion 1 — a plain member sees THEIR OWN two-factor rows.

  describe "a plain member reads their own two-factor history" do
    test "a row produced by the REAL 2FA route comes back to the member who caused it" do
      {_owner, team, _owner_token} = logged_in()
      {member, member_token} = member_of(team, "member")

      secret = enroll_two_factor(member)

      conn =
        call(
          :post,
          "/v1/account/two-factor/confirm",
          %{code: totp_code_stable!(secret)},
          member_token
        )

      assert conn.status == 200

      # The read is driven end to end: the row under assertion was written by
      # `audit_account_security/2`, not hand-inserted by this test, so the
      # predicate is proven against the shape the producer actually stamps.
      assert [ev] = self_read(member_token)
      assert ev["action"] == "twofa.enabled"
      assert ev["target_type"] == "user"
      assert ev["target_id"] == member.id
      assert ev["actor"]["id"] == member.id

      # And the same member is still refused the TEAM trail — the self-read is
      # additive, not a back door into `/v1/audit`.
      assert call(:get, "/v1/audit", nil, member_token).status == 403
    end

    test "both verbs of the pair come back, newest first" do
      {_owner, team, _owner_token} = logged_in()
      {member, member_token} = member_of(team, "member")

      enabled = self_row(team, member, "twofa.enabled")
      disabled = self_row(team, member, "twofa.disabled")

      events = self_read(member_token)
      assert Enum.map(events, & &1["id"]) == [disabled.id, enabled.id]
    end
  end

  ## Criterion 2 — no other member's rows, on a fixture carrying both.

  describe "the response is self-only on a mixed fixture" do
    test "a fixture carrying BOTH members' rows returns only the caller's" do
      {owner, team, _owner_token} = logged_in()
      {member, member_token} = member_of(team, "member")
      {other, _other_token} = member_of(team, "member")

      mine = self_row(team, member, "twofa.enabled")
      theirs = self_row(team, other, "twofa.enabled")
      owners = self_row(team, owner, "twofa.enabled")

      events = self_read(member_token)

      # Positive AND negative on ONE input: a query that dropped the actor
      # predicate would return all three and fail here, where a self-only
      # fixture would have passed it vacuously.
      assert ids(events) == MapSet.new([mine.id])
      refute theirs.id in ids(events)
      refute owners.id in ids(events)
    end
  end

  ## Criterion 3 — the compound predicate, BOTH directions.

  describe "'self' is actor AND target, and each half is asserted alone" do
    test "TARGET but not ACTOR is not self-scoped; ACTOR but not TARGET is not either" do
      {owner, team, _owner_token} = logged_in()
      {member, member_token} = member_of(team, "member")
      {other, _other_token} = member_of(team, "member")

      # The genuine self row — the control that keeps the two negatives from
      # being green on an empty response.
      mine = self_row(team, member, "twofa.enabled")

      # DIRECTION 1: the member is the TARGET, the owner is the actor (an admin
      # disabling someone else's 2FA). Not the member's own act — not self.
      target_not_actor = row(team, owner, "user", member.id, "twofa.disabled")

      # DIRECTION 2: the member is the ACTOR, someone else is the target. The
      # member did it, but it was not done to THEM — not self.
      actor_not_target = row(team, member, "user", other.id, "twofa.disabled")

      # DIRECTION 3: actor and target id both match, but the target is a
      # different KIND of thing. `target_type` is half of the target half.
      wrong_target_type = row(team, member, "site", member.id, "site.created")

      events = self_read(member_token)

      assert ids(events) == MapSet.new([mine.id])
      refute target_not_actor.id in ids(events)
      refute actor_not_target.id in ids(events)
      refute wrong_target_type.id in ids(events)
    end
  end

  ## Criterion 4 — THE MOVED-MEMBER CASE, both directions on one fixture.

  describe "the moved member (audit team scoping is primary-team-at-write-time)" do
    test "keeps sight of rows written under a FORMER primary team, and of the new team's" do
      old_team = team_fixture()
      new_team = team_fixture()

      member = user_fixture()
      {:ok, _} = Accounts.add_member(old_team, member, "member")

      # A second human moving on the same path, so the widened team scope is
      # proven NOT to have widened past `self`.
      other = user_fixture()
      {:ok, _} = Accounts.add_member(old_team, other, "member")

      # Written while `old_team` is the primary team.
      written_before_the_move = self_row(old_team, member, "twofa.enabled")
      others_old_row = self_row(old_team, other, "twofa.enabled")

      # THE MOVE. `Accounts.primary_team/1` is the OLDEST membership, so
      # dropping the old one and adding the new one is exactly what an admin
      # moving a member between teams does to this read's scoping input.
      {:ok, _} = Accounts.remove_member(old_team, member)
      {:ok, _} = Accounts.add_member(new_team, member, "member")
      {:ok, _} = Accounts.remove_member(old_team, other)
      {:ok, _} = Accounts.add_member(new_team, other, "member")

      assert Accounts.primary_team(member).id == new_team.id

      # The session is minted AFTER the move on purpose: `remove_member/2`
      # revokes the removed member's sessions, so a token held from before the
      # move is a 401 and would never reach the predicate under test.
      {:ok, token} = Accounts.create_user_session_token(member)

      written_after_the_move = self_row(new_team, member, "twofa.disabled")
      others_new_row = self_row(new_team, other, "twofa.disabled")

      events = self_read(token)

      # THE DECISION, ASSERTED — `:across_teams` (the default on
      # `Accounts.list_self_security_audit_events/2`): the rows are about the
      # HUMAN, so the former team's row survives the move. Both directions on
      # one fixture: the old row is present AND the new one is, so a build that
      # clamped to the current team fails on the first assertion and a build
      # that clamped to the former team fails on the second.
      assert written_before_the_move.id in ids(events)
      assert written_after_the_move.id in ids(events)

      # Widening the TEAM scope did not widen the SELF scope: another mover's
      # rows stay invisible on both sides of the move.
      refute others_old_row.id in ids(events)
      refute others_new_row.id in ids(events)

      assert ids(events) ==
               MapSet.new([written_before_the_move.id, written_after_the_move.id])
    end

    test "the rejected alternative is a REAL clause, not an absence: :current_team clamps" do
      old_team = team_fixture()
      new_team = team_fixture()

      member = user_fixture()
      {:ok, _} = Accounts.add_member(old_team, member, "member")

      old_row = self_row(old_team, member, "twofa.enabled")
      new_row = self_row(new_team, member, "twofa.disabled")

      # The named alternative arm, exercised at the context so it cannot rot
      # into dead code that merely LOOKS like a documented decision.
      clamped =
        Accounts.list_self_security_audit_events(member,
          team_scope: :current_team,
          team: new_team
        )

      assert Enum.map(clamped, & &1.id) == [new_row.id]
      refute old_row.id in Enum.map(clamped, & &1.id)
    end
  end

  ## Criterion 5 — the general surface is UNCHANGED and still admin-gated.

  describe "GET /v1/audit is still admin-gated" do
    test "a plain member is 403 on the team trail while holding the self-read" do
      {_owner, team, _owner_token} = logged_in()
      {member, member_token} = member_of(team, "member")

      # The member HAS rows and CAN read them through the new surface...
      mine = self_row(team, member, "twofa.enabled")
      assert ids(self_read(member_token)) == MapSet.new([mine.id])

      # ...and the team trail is still refused, with the same refusal envelope
      # `require_current_team_admin/1` emitted before this change.
      conn = call(:get, "/v1/audit", nil, member_token)
      assert conn.status == 403

      assert json_body(conn) == %{
               "error" => "forbidden",
               "required" => "admin",
               "scope" => "team"
             }
    end

    test "an ADMIN still gets the whole team trail, including other members' rows" do
      {_owner, team, _owner_token} = logged_in()
      {admin, admin_token} = member_of(team, "admin")
      {member, _member_token} = member_of(team, "member")

      theirs = self_row(team, member, "twofa.enabled")
      mine = self_row(team, admin, "twofa.enabled")

      conn = call(:get, "/v1/audit", nil, admin_token)
      assert conn.status == 200
      assert ids(json_body(conn)["events"]) == MapSet.new([theirs.id, mine.id])
    end
  end
end
