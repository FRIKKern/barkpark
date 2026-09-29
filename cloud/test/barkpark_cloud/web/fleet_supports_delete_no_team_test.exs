defmodule BarkparkCloud.Web.FleetSupportsDeleteNoTeamTest do
  @moduledoc """
  task-3ae0ca3aec358df9 — the TEAMLESS half of the `/v1/fleet/supports` pair.

  `POST /v1/fleet/supports` and `DELETE /v1/fleet/supports/:id` are one
  credential family (a credential that can BIND can UNBIND; the router says so
  in both route comments). They diverged on the one caller neither of them can
  serve: a session with NO active team. POST answered the shared gate shape
  `403 {"error":"forbidden","reason":"no_team","scope":"team"}` (emitted by
  `no_team/1` → `Auth.forbidden(conn, reason: "no_team", scope: "team")`);
  DELETE answered `404 {"error":"not_found"}` from its own inline
  `is_nil(conn.assigns.current_team)` arm.

  Not a leak — the 404 discloses nothing — a MIS-NARRATION: `bp cloud support
  remove` keys its control-plane arm on status and told a teamless operator the
  row was "already gone (404)", pointing at nothing, when the truth was
  `bp team use <team>`. The CLI half landed first (#17916, `supportCPNoTeam`),
  so the status flip is safe.

  This suite drives BOTH halves of the pair with the SAME teamless session in
  one test, so the two can never drift apart again silently, and pins the two
  controls the conversion must not disturb: a caller WITH a team still deletes
  its own support (200) and still gets 404 on a row outside its team.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The one body `no_team/1` emits — asserted WHOLE, so a near-miss (403 with no
  # `scope`, or a flat `{error: "no_team"}`) fails as loudly as the old 404.
  @gate_shape %{"error" => "forbidden", "reason" => "no_team", "scope" => "team"}

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "fleet-no-team-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A registered user with NO team membership at all, plus a live session token.
  defp teamless_session do
    {:ok, token} = Accounts.create_user_session_token(user_fixture())
    token
  end

  defp owner_session do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  defp main_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Main #{n}", slug: "main-#{n}"})
    {:ok, main} = bp |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()
    main
  end

  defp support_fixture(team) do
    main = main_fixture(team)
    n = System.unique_integer([:positive])

    {:ok, support} =
      Registry.register_support_barkpark(team, %{
        name: "Bound #{n}",
        slug: "bound-#{n}",
        parent_id: main.id,
        token_id: "t"
      })

    support
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          method
          |> conn(path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "a teamless caller gets the SAME refusal from both halves of the pair" do
    test "DELETE /v1/fleet/supports/:id answers the 403 no_team gate shape, exactly as its POST twin" do
      session = teamless_session()

      # The POST twin — the reference shape. Unchanged by this row.
      post = call(:post, "/v1/fleet/supports", %{name: "support-1"}, session)
      assert post.status == 403, "POST: expected 403, got #{post.status}: #{post.resp_body}"
      assert decode(post) == @gate_shape

      # The DELETE half. Its team arm precedes the id lookup, so any well-formed
      # id reaches it — the id is irrelevant to the refusal, which is the point:
      # nothing was looked up, so "not_found" was never a true answer.
      del = call(:delete, "/v1/fleet/supports/#{Ecto.UUID.generate()}", nil, session)
      assert del.status == 403, "DELETE: expected 403, got #{del.status}: #{del.resp_body}"
      assert decode(del) == @gate_shape

      # The parity assertion itself: one caller, one refusal.
      assert decode(del) == decode(post)
      assert del.status == post.status
    end

    test "the refusal does not depend on the id being well-formed" do
      session = teamless_session()

      for id <- ["not-a-uuid", Ecto.UUID.generate()] do
        conn = call(:delete, "/v1/fleet/supports/#{id}", nil, session)
        assert conn.status == 403, "id=#{id}: got #{conn.status}: #{conn.resp_body}"
        assert decode(conn) == @gate_shape
      end
    end
  end

  describe "CONTROLS — the team-scoped behaviour the conversion must not disturb" do
    test "a caller WITH a team still deletes its own support row → 200, row gone" do
      {team, token} = owner_session()
      support = support_fixture(team)

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, token)

      assert conn.status == 200
      assert decode(conn)["status"] == "removed"
      assert Registry.get_barkpark(support.id) == nil
    end

    test "a caller WITH a team still gets 404 on a support OUTSIDE its team, row untouched" do
      {_team_a, token_a} = owner_session()
      {team_b, _token_b} = owner_session()
      support_b = support_fixture(team_b)

      conn = call(:delete, "/v1/fleet/supports/#{support_b.id}", nil, token_a)

      assert conn.status == 404
      assert decode(conn) == %{"error" => "not_found"}
      assert Registry.get_barkpark(support_b.id) != nil
    end
  end
end
