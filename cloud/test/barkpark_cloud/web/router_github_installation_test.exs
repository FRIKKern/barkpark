defmodule BarkparkCloud.Web.RouterGithubInstallationTest do
  @moduledoc """
  The GitHub connect surface (gh-2):

      GET    /v1/github/installation
      POST   /v1/github/installations
      DELETE /v1/github/installation

  Fake-backed: connect/disconnect/state, cross-team isolation, no-leak reads, the
  RBAC gate, and the HUMAN-LAST 503 feature_not_configured when the App
  credentials are absent.

  `async: false` — the connect tests toggle the global `BarkparkCloud.GitHub`
  app env to simulate a configured App.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, GitHub}
  alias BarkparkCloud.GitHub.Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

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

  defp user_with_team(role) do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp login_token(user) do
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

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Simulate a wired GitHub App (id + private key present) so `configured?/0` is
  # true. The client stays the in-memory Fake, so validation is €0.
  defp configure_github do
    base = Application.get_env(:barkpark_cloud, GitHub, [])

    Application.put_env(
      :barkpark_cloud,
      GitHub,
      Keyword.merge(base, app_id: "test-app-id", private_key: "dummy-pem", app_slug: "bp-deploy")
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)
  end

  describe "GET /v1/github/installation" do
    test "unauthenticated → 401" do
      assert call(:get, "/v1/github/installation", nil, nil).status == 401
    end

    test "authed, no connection → not connected, not configured (default), no secrets" do
      {user, _team} = user_with_team("owner")
      conn = call(:get, "/v1/github/installation", nil, login_token(user))
      assert conn.status == 200

      b = body(conn)
      assert b["connected"] == false
      assert b["account_login"] == nil
      assert b["configured"] == false
      # No installation handle ever appears on the read path.
      refute Map.has_key?(b, "installation_id")
      refute Map.has_key?(b, "installation_id_encrypted")
    end

    test "authed, connected → shows the account login, still no handle" do
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")

      conn = call(:get, "/v1/github/installation", nil, login_token(user))
      b = body(conn)
      assert b["connected"] == true
      assert b["account_login"] == "octo-4242"
      refute Map.has_key?(b, "installation_id")
      refute Map.has_key?(b, "installation_id_encrypted")
    end
  end

  describe "POST /v1/github/installations" do
    test "credentials absent → 503 feature_not_configured (even for the owner)" do
      {user, _team} = user_with_team("owner")

      conn =
        call(:post, "/v1/github/installations", %{installation_id: "4242"}, login_token(user))

      assert conn.status == 503
      assert body(conn)["error"] == "feature_not_configured"
    end

    test "configured + owner + valid id → 201, connected, login echoed, id stored encrypted" do
      configure_github()
      {user, team} = user_with_team("owner")

      conn =
        call(:post, "/v1/github/installations", %{installation_id: "4242"}, login_token(user))

      assert conn.status == 201

      inst = body(conn)["installation"]
      assert inst["connected"] == true
      assert inst["account_login"] == "octo-4242"
      refute Map.has_key?(inst, "installation_id")

      # Persisted + encrypted at rest.
      row = GitHub.installation_for(team)
      assert row.account_login == "octo-4242"
      assert {:ok, "4242"} = GitHub.reveal_installation_id(row)
    end

    test "configured + missing id → 422 installation_id_required" do
      configure_github()
      {user, _team} = user_with_team("owner")

      conn = call(:post, "/v1/github/installations", %{}, login_token(user))
      assert conn.status == 422
      assert body(conn)["error"] == "installation_id_required"
    end

    test "configured + unknown id → 422 installation_not_found, nothing written" do
      configure_github()
      {user, team} = user_with_team("owner")

      conn =
        call(
          :post,
          "/v1/github/installations",
          %{installation_id: Fake.invalid_installation_id()},
          login_token(user)
        )

      assert conn.status == 422
      assert body(conn)["error"] == "installation_not_found"
      assert GitHub.installation_for(team) == nil
    end

    test "configured + member → 403 (RBAC: admin only)" do
      configure_github()
      {user, _team} = user_with_team("member")

      conn =
        call(:post, "/v1/github/installations", %{installation_id: "4242"}, login_token(user))

      assert conn.status == 403
    end

    test "unauthenticated → 401" do
      configure_github()
      conn = call(:post, "/v1/github/installations", %{installation_id: "4242"}, nil)
      assert conn.status == 401
    end
  end

  describe "DELETE /v1/github/installation" do
    test "owner with a connection → 200, row gone" do
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "9")

      conn = call(:delete, "/v1/github/installation", nil, login_token(user))
      assert conn.status == 200
      assert body(conn)["ok"] == true
      assert GitHub.installation_for(team) == nil
    end

    test "owner with no connection → 404" do
      {user, _team} = user_with_team("owner")
      conn = call(:delete, "/v1/github/installation", nil, login_token(user))
      assert conn.status == 404
    end

    test "member → 403" do
      {_owner, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "9")
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      conn = call(:delete, "/v1/github/installation", nil, login_token(member))
      assert conn.status == 403
      # The connection survives a forbidden delete.
      assert GitHub.connected?(team)
    end
  end

  describe "cross-team isolation" do
    test "team A's connection is invisible to team B, and B's delete can't touch it" do
      {_ua, team_a} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team_a, "11")
      {user_b, _team_b} = user_with_team("owner")
      token_b = login_token(user_b)

      # B sees no connection.
      assert body(call(:get, "/v1/github/installation", nil, token_b))["connected"] == false
      # B's disconnect is a 404 and leaves A intact.
      assert call(:delete, "/v1/github/installation", nil, token_b).status == 404
      assert GitHub.connected?(team_a)
    end
  end
end
