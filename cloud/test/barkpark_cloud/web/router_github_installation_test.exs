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

  defmodule UnwiredOAuth do
    @moduledoc false
    # The answer GitHub.Real gives when GITHUB_APP_CLIENT_ID/SECRET are unset.
    def exchange_user_code(_code), do: {:error, :not_configured}
    def list_user_installation_ids(_token), do: {:error, :not_configured}
  end

  # The record POST carries the team+user-bound install state the plane sealed
  # into the install link (GitHub.install_url/2), and the user-authorization
  # code GitHub sent with the redirect, exactly as the console relays them. The
  # code's user can access the installation being recorded: the legitimate path.
  defp post_body(team, user, id),
    do: %{
      installation_id: id,
      state: GitHub.install_state(team, user.id),
      code: Fake.user_code_for([id])
    }

  defp team_of(user), do: hd(Accounts.list_user_teams(user))

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
        call(
          :post,
          "/v1/github/installations",
          post_body(team_of(user), user, "4242"),
          login_token(user)
        )

      assert conn.status == 503
      assert body(conn)["error"] == "feature_not_configured"
    end

    test "configured + owner + valid id → 201, connected, login echoed, id stored encrypted" do
      configure_github()
      {user, team} = user_with_team("owner")

      conn =
        call(
          :post,
          "/v1/github/installations",
          post_body(team_of(user), user, "4242"),
          login_token(user)
        )

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
          post_body(team, user, Fake.invalid_installation_id()),
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
        call(
          :post,
          "/v1/github/installations",
          post_body(team_of(user), user, "4242"),
          login_token(user)
        )

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

  # task-0cf611238d4ad597 CQ7a (owner ruling #36). The state binds the team that
  # STARTED an install, and an id another team recorded is refused, but an
  # install nobody has recorded yet was still claimable: GET
  # /app/installations/:id answers for every install of the App. The record now
  # needs the user-authorization code GitHub sends with the install, and the
  # code's GitHub user must be able to access the id.
  describe "POST /v1/github/installations — the installer's own GitHub account must see the id" do
    defp post_with_code(team, user, id, code) do
      call(
        :post,
        "/v1/github/installations",
        %{installation_id: id, state: GitHub.install_state(team, user.id), code: code},
        login_token(user)
      )
    end

    test "HOLE: a stranger's unrecorded install, with the admin's own valid state → refused" do
      configure_github()
      {user, team} = user_with_team("admin")

      # The admin's GitHub user can see install 7001 only; 9009 belongs to someone
      # else's org and nobody has recorded it in Cloud.
      conn = post_with_code(team, user, "9009", Fake.user_code_for(["7001"]))

      assert conn.status == 422
      # The same answer as an unknown id: no existence oracle.
      assert body(conn)["error"] == "installation_not_found"
      assert GitHub.installation_for(team) == nil
    end

    test "no code with the install → 422 github_authorization_required, nothing written" do
      configure_github()
      {user, team} = user_with_team("owner")

      for missing <- [nil, ""] do
        body_map = %{installation_id: "4242", state: GitHub.install_state(team, user.id)}
        body_map = if missing, do: Map.put(body_map, :code, missing), else: body_map
        conn = call(:post, "/v1/github/installations", body_map, login_token(user))

        assert conn.status == 422
        assert body(conn)["error"] == "github_authorization_required"
        assert body(conn)["detail"] =~ "Connect GitHub again"
      end

      assert GitHub.installation_for(team) == nil
    end

    test "a spent or forged code → 422 github_authorization_failed, nothing written" do
      configure_github()
      {user, team} = user_with_team("owner")

      conn = post_with_code(team, user, "4242", "spent-or-forged")

      assert conn.status == 422
      assert body(conn)["error"] == "github_authorization_failed"
      assert GitHub.installation_for(team) == nil
    end

    test "LEGIT: the installer's own install records, among several they can see" do
      configure_github()
      {user, team} = user_with_team("admin")

      conn = post_with_code(team, user, "7002", Fake.user_code_for(["7001", "7002", "7003"]))

      assert conn.status == 201
      assert body(conn)["installation"]["account_login"] == "octo-7002"
      assert {:ok, "7002"} = GitHub.reveal_installation_id(GitHub.installation_for(team))
    end

    test "the App's OAuth client not wired → 503 feature_not_configured, nothing written" do
      configure_github()
      base = Application.get_env(:barkpark_cloud, GitHub, [])

      Application.put_env(
        :barkpark_cloud,
        GitHub,
        Keyword.put(base, :client, BarkparkCloud.Web.RouterGithubInstallationTest.UnwiredOAuth)
      )

      {user, team} = user_with_team("owner")
      conn = post_with_code(team, user, "4242", Fake.user_code_for(["4242"]))

      assert conn.status == 503
      assert body(conn)["error"] == "feature_not_configured"
      assert GitHub.installation_for(team) == nil
    end
  end

  describe "POST /v1/github/installations — the id must be bound to the caller's team" do
    # The plane validates an id with GET /app/installations/:id under the APP's
    # JWT, which answers for EVERY install of the App. Without a binding, team
    # B's admin could record team A's installation id and drive A's org.

    test "another team's admin cannot record an id with no state" do
      configure_github()
      {a_user, a_team} = user_with_team("owner")
      {b_user, b_team} = user_with_team("admin")

      assert call(
               :post,
               "/v1/github/installations",
               post_body(a_team, a_user, "4242"),
               login_token(a_user)
             ).status ==
               201

      conn =
        call(:post, "/v1/github/installations", %{installation_id: "4242"}, login_token(b_user))

      assert conn.status == 422
      assert body(conn)["error"] == "install_state_invalid"
      assert GitHub.installation_for(b_team) == nil
    end

    test "another team's admin cannot record A's id under B's OWN valid state" do
      # r4a: the state binds the caller's team and user, never the id. B mints
      # its own state (GET /v1/github/installation hands it out) and pairs it
      # with the id A recorded — that must not connect B to A's org.
      configure_github()
      {a_user, a_team} = user_with_team("owner")
      {b_user, b_team} = user_with_team("admin")

      assert call(
               :post,
               "/v1/github/installations",
               post_body(a_team, a_user, "4343"),
               login_token(a_user)
             ).status == 201

      conn =
        call(
          :post,
          "/v1/github/installations",
          post_body(b_team, b_user, "4343"),
          login_token(b_user)
        )

      assert conn.status == 422, "B recorded A's installation id (#{conn.status})"
      assert body(conn)["error"] == "installation_not_found"
      assert GitHub.installation_for(b_team) == nil
      assert GitHub.connected?(a_team)

      # Control: B's own install still records, and A re-recording its own id is fine.
      assert call(
               :post,
               "/v1/github/installations",
               post_body(b_team, b_user, "4344"),
               login_token(b_user)
             ).status == 201

      assert call(
               :post,
               "/v1/github/installations",
               post_body(a_team, a_user, "4343"),
               login_token(a_user)
             ).status == 201
    end

    test "another team's state (stolen from A's install link) does not bind B" do
      configure_github()
      {a_user, a_team} = user_with_team("owner")
      {b_user, b_team} = user_with_team("admin")

      a_state = GitHub.install_state(a_team, a_user.id)

      conn =
        call(
          :post,
          "/v1/github/installations",
          %{installation_id: "4242", state: a_state},
          login_token(b_user)
        )

      assert conn.status == 422
      assert body(conn)["error"] == "install_state_invalid"
      assert GitHub.installation_for(b_team) == nil
    end

    test "a tampered or another user's state is refused; the caller's own state records" do
      configure_github()
      {user, team} = user_with_team("owner")
      other = user_fixture()

      for bad <- ["garbage", GitHub.install_state(team, other.id), ""] do
        conn =
          call(
            :post,
            "/v1/github/installations",
            %{installation_id: "4242", state: bad},
            login_token(user)
          )

        assert conn.status == 422, "state #{inspect(bad)} must be refused"
        assert body(conn)["error"] == "install_state_invalid"
      end

      assert GitHub.installation_for(team) == nil

      assert call(
               :post,
               "/v1/github/installations",
               post_body(team, user, "4242"),
               login_token(user)
             ).status ==
               201
    end

    test "the install link a member reads carries a state that verifies for that member's team" do
      configure_github()
      {user, team} = user_with_team("owner")

      url = body(call(:get, "/v1/github/installation", nil, login_token(user)))["install_url"]
      assert url =~ "https://github.com/apps/bp-deploy/installations/new?state="

      state =
        url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

      assert GitHub.verify_install_state(state, team, user.id) == :ok
    end
  end
end
