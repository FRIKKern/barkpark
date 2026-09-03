defmodule BarkparkCloud.Web.RouterTeamTokensTest do
  @moduledoc """
  The TEAM-SCOPED PAT surface: `GET /v1/teams/:id/tokens` and
  `DELETE /v1/teams/:id/tokens/:token_id`.

  Why this file exists. Every `/v1/tokens` route is CALLER-scoped — a PAT is
  listable and revocable by exactly one principal, its holder. So a team owner
  could not enumerate the programmatic credentials acting on their own team, let
  alone kill a leaked one while the holder was still a member. The
  membership-scoped eviction (`revoke_team_pats/2`) closes only the removal /
  demotion hole; this pair closes the leak with the membership INTACT.

  Four properties are pinned, each as a separate test so a red names which one
  broke:

    1. AUTHORITY — admin+ only (a plain member is 403), and a team the caller is
       not a member of (or that does not exist) is 404, never 403.
    2. TENANTED — the list carries this team's rows and no other team's, even
       when the SAME user holds a PAT on both.
    3. THE KILL — an admin's revoke actually stops the credential: the revoked
       token's NEXT request answers 401. This is the test that reds if the
       revoke call is dropped from the handler.
    4. THE LEDGER + THE NO-LEAK PIN — every admin revoke writes a
       `token.revoked` audit row naming the actor, the token and the holder, and
       the caller-scoped `DELETE /v1/tokens/:id` still 404s a foreign id
       (this change must not have widened it).
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

  defp pat(user, team, abilities \\ ["read"]) do
    {:ok, plaintext, stored} =
      Accounts.create_personal_access_token(user, team, %{
        name: "key-#{System.unique_integer([:positive])}",
        abilities: abilities
      })

    {plaintext, stored}
  end

  # An owner, a plain member, and the team they share.
  defp team_with_members do
    team = team_fixture()
    owner = user_fixture()
    member = user_fixture()
    {:ok, _} = Accounts.add_member(team, owner, "owner")
    {:ok, _} = Accounts.add_member(team, member, "member")
    %{team: team, owner: owner, member: member}
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

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  ## 1. Authority

  describe "GET /v1/teams/:id/tokens — authority" do
    test "an admin (owner) gets 200" do
      %{team: team, owner: owner} = team_with_members()
      conn = call(:get, "/v1/teams/#{team.id}/tokens", nil, session(owner))
      assert conn.status == 200
    end

    test "a plain MEMBER of the team gets 403, not the list" do
      %{team: team, member: member} = team_with_members()
      {_plain, _stored} = pat(member, team)

      conn = call(:get, "/v1/teams/#{team.id}/tokens", nil, session(member))

      assert conn.status == 403
      body = decode(conn)
      assert body["error"] == "forbidden"
      assert body["required"] == "admin"
      # The refusal must not leak the rows it refused.
      refute Map.has_key?(body, "tokens")
    end

    test "a FOREIGN team (caller is not a member) is 404, never 403" do
      %{team: _mine, owner: owner} = team_with_members()
      %{team: theirs} = team_with_members()

      conn = call(:get, "/v1/teams/#{theirs.id}/tokens", nil, session(owner))

      assert conn.status == 404
      assert decode(conn)["error"] == "not_found"
    end

    test "a nonexistent team id is the SAME 404 as a foreign one" do
      %{owner: owner} = team_with_members()

      conn =
        call(
          :get,
          "/v1/teams/00000000-0000-0000-0000-000000000000/tokens",
          nil,
          session(owner)
        )

      assert conn.status == 404
      assert decode(conn)["error"] == "not_found"
    end

    test "unauthenticated is 401, not 404" do
      %{team: team} = team_with_members()
      assert call(:get, "/v1/teams/#{team.id}/tokens").status == 401
    end
  end

  ## 2. Tenanted

  describe "GET /v1/teams/:id/tokens — scope" do
    test "lists this team's PATs, names the holder, and emits no secret" do
      %{team: team, owner: owner, member: member} = team_with_members()
      {_p, mine} = pat(owner, team)
      {_p, theirs} = pat(member, team)

      conn = call(:get, "/v1/teams/#{team.id}/tokens", nil, session(owner))
      assert conn.status == 200

      tokens = decode(conn)["tokens"]
      ids = Enum.map(tokens, & &1["id"])

      assert mine.id in ids
      assert theirs.id in ids

      row = Enum.find(tokens, &(&1["id"] == theirs.id))
      assert row["user_id"] == member.id
      assert row["email"] == member.email
      refute Map.has_key?(row, "token_hash")
      refute Map.has_key?(row, "token")
    end

    test "a PAT the SAME user holds on ANOTHER team is ABSENT from the list" do
      %{team: team, owner: owner} = team_with_members()
      other_team = team_fixture()
      {:ok, _} = Accounts.add_member(other_team, owner, "owner")

      {_p, here} = pat(owner, team)
      {_p, elsewhere} = pat(owner, other_team)

      conn = call(:get, "/v1/teams/#{team.id}/tokens", nil, session(owner))
      ids = decode(conn)["tokens"] |> Enum.map(& &1["id"])

      assert here.id in ids
      refute elsewhere.id in ids
    end
  end

  ## 3. The kill

  describe "DELETE /v1/teams/:id/tokens/:token_id" do
    test "an admin revokes ANOTHER member's PAT and that token's next request 401s" do
      %{team: team, owner: owner, member: member} = team_with_members()
      {plaintext, stored} = pat(member, team)

      # Alive BEFORE the revoke — otherwise a 401 after proves nothing.
      assert call(:get, "/v1/me", nil, plaintext).status == 200

      conn = call(:delete, "/v1/teams/#{team.id}/tokens/#{stored.id}", nil, session(owner))
      assert conn.status == 200
      assert decode(conn)["ok"] == true

      # THE PROPERTY: the credential is dead on its very next request.
      assert call(:get, "/v1/me", nil, plaintext).status == 401
      assert Accounts.verify_personal_access_token(plaintext) == nil
    end

    test "the revoke is idempotent" do
      %{team: team, owner: owner, member: member} = team_with_members()
      {_p, stored} = pat(member, team)

      assert call(:delete, "/v1/teams/#{team.id}/tokens/#{stored.id}", nil, session(owner)).status ==
               200

      assert call(:delete, "/v1/teams/#{team.id}/tokens/#{stored.id}", nil, session(owner)).status ==
               200
    end

    test "a plain member cannot revoke — 403, and the token still works" do
      %{team: team, owner: owner, member: member} = team_with_members()
      {plaintext, stored} = pat(owner, team)

      conn = call(:delete, "/v1/teams/#{team.id}/tokens/#{stored.id}", nil, session(member))
      assert conn.status == 403

      assert call(:get, "/v1/me", nil, plaintext).status == 200
    end

    test "a token id from ANOTHER team is 404 and that token survives" do
      %{team: team, owner: owner} = team_with_members()
      %{team: theirs, owner: their_owner} = team_with_members()
      {plaintext, stored} = pat(their_owner, theirs)

      conn = call(:delete, "/v1/teams/#{team.id}/tokens/#{stored.id}", nil, session(owner))
      assert conn.status == 404
      assert decode(conn)["error"] == "not_found"

      assert call(:get, "/v1/me", nil, plaintext).status == 200
    end

    test "a non-UUID token id is 404, not a 500" do
      %{team: team, owner: owner} = team_with_members()

      conn = call(:delete, "/v1/teams/#{team.id}/tokens/not-a-uuid", nil, session(owner))
      assert conn.status == 404
    end

    test "a foreign TEAM in the path is 404 even with a real token id of that team" do
      %{owner: owner} = team_with_members()
      %{team: theirs, owner: their_owner} = team_with_members()
      {_p, stored} = pat(their_owner, theirs)

      conn = call(:delete, "/v1/teams/#{theirs.id}/tokens/#{stored.id}", nil, session(owner))
      assert conn.status == 404
    end
  end

  ## 4. The ledger + the no-leak regression pin

  describe "audit" do
    test "an admin revoke writes a token.revoked row naming actor, token and holder" do
      %{team: team, owner: owner, member: member} = team_with_members()
      {_p, stored} = pat(member, team)

      assert call(:delete, "/v1/teams/#{team.id}/tokens/#{stored.id}", nil, session(owner)).status ==
               200

      event =
        Accounts.list_audit_events(team, limit: 50)
        |> Enum.find(&(&1.action == "token.revoked" and &1.target_id == stored.id))

      assert event, "no token.revoked audit row for the admin revoke"
      assert event.actor_user_id == owner.id
      assert event.target_type == "token"
      assert event.team_id == team.id
      assert event.metadata["admin_revoke"] == true
      assert event.metadata["user_id"] == member.id
      assert event.metadata["email"] == member.email
    end

    test "a REFUSED revoke (foreign token id) writes NO audit row" do
      %{team: team, owner: owner} = team_with_members()
      %{team: theirs, owner: their_owner} = team_with_members()
      {_p, stored} = pat(their_owner, theirs)

      before = Accounts.list_audit_events(team, limit: 200) |> length()

      assert call(:delete, "/v1/teams/#{team.id}/tokens/#{stored.id}", nil, session(owner)).status ==
               404

      assert Accounts.list_audit_events(team, limit: 200) |> length() == before
    end

    test "REGRESSION PIN: the caller-scoped DELETE /v1/tokens/:id still 404s a foreign id" do
      %{team: team, owner: owner, member: member} = team_with_members()
      {plaintext, stored} = pat(member, team)

      # The owner is an ADMIN of the token's team and STILL gets 404 here — this
      # route is caller-scoped by design, and the new team route is the only way
      # an admin reaches someone else's token.
      conn = call(:delete, "/v1/tokens/#{stored.id}", nil, session(owner))
      assert conn.status == 404
      assert decode(conn)["error"] == "not_found"

      assert call(:get, "/v1/me", nil, plaintext).status == 200
    end
  end

  ## Context boundary — a "pat" route never touches a session row

  describe "context fence" do
    test "a SESSION token id is not revocable through the team-tokens route" do
      %{team: team, owner: owner, member: member} = team_with_members()
      {:ok, _plain} = Accounts.create_user_session_token(member)

      [row] =
        BarkparkCloud.Repo.all(
          from(t in BarkparkCloud.Accounts.UserToken,
            where: t.user_id == ^member.id and t.context == "session"
          )
        )

      conn = call(:delete, "/v1/teams/#{team.id}/tokens/#{row.id}", nil, session(owner))
      assert conn.status == 404
    end
  end
end
