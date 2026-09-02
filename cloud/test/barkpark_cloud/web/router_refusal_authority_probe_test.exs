defmodule BarkparkCloud.Web.RouterRefusalAuthorityProbeTest do
  @moduledoc """
  THE REACHABILITY PROBE for cch-w37-s2 — a 403 must say what it wanted.

  Why this file exists. Eleven refusals in `router.ex` shipped as a bare
  `%{error: "forbidden"}`. The console's `friendly()` resolves a bare forbidden
  body to `ERRORS.forbidden` = "Only the team owner can manage billing." — so a
  plain member who clicked the rendered "Add support server" or "Resurrect" CTA
  was told, confidently and wrongly, about BILLING.

  What is pinned here, and what is deliberately NOT:

    1. FOUR REFUSALS NAME THEIR AUTHORITY — `required: "admin", scope: "team"`,
       driven through the real router by a real member session. (SIX until
       cch-w53-bl's env-var Option A deleted `POST`/`DELETE /v1/env-vars` with
       the team env-var feature — the routes went, so their probes went.)
    2. TWO REFUSALS NAME A CAUSE AND NEVER AN AUTHORITY — the member-management
       arms sit INSIDE `with_team_role(conn, "admin", …)`, so the caller already
       IS an admin. A static `required: "admin"` there would be a new lie, and
       the CONTROL below proves no static label could be sound: the same admin
       refused on a peer admin SUCCEEDS on a plain member.
    3. THE THIRD ARM IS RETIRED, NOT WEAKENED. It pinned charter D396(5)'s
       deliberately-bare cross-tenant env-var refusal — an ADMIN refused on
       another team's `barkpark_id`, which is not a role refusal at all. That
       route was deleted with the team env-var feature (cch-w53-bl, Option A,
       ruled 2026-09-02), and no other route in `router.ex` refuses on
       cross-tenant ownership from inside an admin-gated cond, so there is
       nothing left for it to probe. D396(5) itself is untouched: the next route
       that takes a foreign id inside an admin gate re-earns this arm.

  This is a guard that can lose: every assertion here is RED against the
  unmodified refusal literals.
  """
  use BarkparkCloud.DataCase, async: true
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
        email: "probe-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp member_of(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    user
  end

  defp session(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # A team with a plain member, and that member's session token.
  defp member_session do
    team = team_fixture()
    _owner = member_of(team, "owner")
    member = member_of(team, "member")
    {team, session(member)}
  end

  ## 1 — the refusals that name their authority

  # {label, method, path, body} — every one reachable by a plain member session.
  @named [
    {"POST /v1/fleet/supports", :post, "/v1/fleet/supports", %{name: "support-1"}},
    {"DELETE /v1/fleet/supports/:id", :delete,
     "/v1/fleet/supports/00000000-0000-0000-0000-000000000001", nil},
    {"POST /v1/tokens", :post, "/v1/tokens", %{name: "probe-pat", abilities: ["deploy"]}},
    {"POST /v1/resurrect", :post, "/v1/resurrect", %{name: "box"}}
  ]

  describe "a member's refusal names the authority it wanted" do
    for {label, method, path, req} <- @named do
      test "#{label} → 403 required:admin scope:team" do
        {_team, token} = member_session()

        conn = call(unquote(method), unquote(path), unquote(Macro.escape(req)), token)

        assert conn.status == 403
        b = body(conn)
        # The wire contract is UNCHANGED for old clients — evidence is merged
        # AROUND `error`, never over it.
        assert b["error"] == "forbidden"
        assert b["required"] == "admin", "#{unquote(label)} refused without naming an authority"
        assert b["scope"] == "team"
      end
    end
  end

  ## 2 — the member-management arms name a CAUSE, never an authority

  describe "rank-relative refusals name the relation, not a role" do
    test "PATCH member role: admin on a PEER admin → reason outranked, no required" do
      team = team_fixture()
      _owner = member_of(team, "owner")
      actor = member_of(team, "admin")
      peer = member_of(team, "admin")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{peer.id}", %{role: "member"}, session(actor))

      assert conn.status == 403
      b = body(conn)
      assert b["error"] == "forbidden"
      assert b["reason"] == "outranked"
      refute Map.has_key?(b, "required")
    end

    test "PATCH member role: admin granting OWNER → reason cannot_grant_higher_role" do
      team = team_fixture()
      _owner = member_of(team, "owner")
      actor = member_of(team, "admin")
      target = member_of(team, "member")

      conn =
        call(
          :patch,
          "/v1/teams/#{team.id}/members/#{target.id}",
          %{role: "owner"},
          session(actor)
        )

      assert conn.status == 403
      b = body(conn)
      assert b["reason"] == "cannot_grant_higher_role"
      refute Map.has_key?(b, "required")
    end

    test "DELETE member: admin on a PEER admin → reason outranked, no required" do
      team = team_fixture()
      _owner = member_of(team, "owner")
      actor = member_of(team, "admin")
      peer = member_of(team, "admin")

      conn = call(:delete, "/v1/teams/#{team.id}/members/#{peer.id}", nil, session(actor))

      assert conn.status == 403
      assert body(conn)["reason"] == "outranked"
      refute Map.has_key?(body(conn), "required")
    end

    # THE CONTROL that kills any static authority label on those two arms: the
    # SAME admin credential, refused above, succeeds here. `required: "admin"`
    # would have described a gate the caller already passed.
    test "CONTROL: the same admin refused on a peer SUCCEEDS on a plain member" do
      team = team_fixture()
      _owner = member_of(team, "owner")
      actor = member_of(team, "admin")
      peer = member_of(team, "admin")
      plain = member_of(team, "member")
      token = session(actor)

      refused = call(:delete, "/v1/teams/#{team.id}/members/#{peer.id}", nil, token)
      assert refused.status == 403

      allowed = call(:delete, "/v1/teams/#{team.id}/members/#{plain.id}", nil, token)
      assert allowed.status == 200
      assert body(allowed)["ok"] == true
    end
  end

  # ## 3 — the deliberate exception (charter D396(5)) — RETIRED with the route it
  # probed; see the moduledoc's item 3.
end
