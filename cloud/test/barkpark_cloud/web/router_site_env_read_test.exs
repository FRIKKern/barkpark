defmodule BarkparkCloud.Web.RouterSiteEnvReadTest do
  @moduledoc """
  The fleet-facing site-env read surface (site-env-injection):

      GET    /v1/builder/sites/:id/env   worker  — build-time injection (nixpacks --env)
      GET    /v1/agent/sites/:id/env     agent   — run-time injection (docker run -e)

  `bp sites env set` stores the blob Vault-encrypted; these two routes are the
  ONLY places it is decrypted back out, so the auth matrix is the load-bearing
  property:

  * **Builder route is WORKER-only.** The builder is a faceless fleet principal
    that builds any team's site — a user session token, an agent token, or no
    bearer at all → 401 (require_worker fails closed).
  * **Agent route is BOX-SCOPED.** An agent reads env only for sites on its own
    Barkpark; another box's site (or a nonexistent / non-UUID id) is the SAME
    404 — no existence leak, mirroring the agent transition route.
  * **Missing blob is empty, not an error.** `{env: %{}}` — the fleet proceeds
    env-less rather than failing a site that never set env.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The shared WORKER token configured for the test env (config/test.exs).
  @worker_token "worker-token-test-fixed"

  @env %{"BARKPARK_READ_TOKEN" => "tok-secret", "DATABASE_URL" => "postgres://u:p@h/db"}

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(barkpark) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(barkpark, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Returns {agent_token, barkpark, site} with a real AgentToken minted, so
  # require_agent exercises the real verify path.
  defp agent_setup do
    team = team_fixture()
    barkpark = barkpark_fixture(team)
    site = site_fixture(barkpark)
    {:ok, token, _} = Registry.mint_agent_token(barkpark, "runtime")
    {token, barkpark, site}
  end

  defp user_token do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## GET /v1/builder/sites/:id/env — worker

  describe "GET /v1/builder/sites/:id/env" do
    test "worker token → 200 with the decrypted env" do
      {_agent, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", @worker_token)
      assert conn.status == 200
      assert json_body(conn)["env"] == @env
    end

    test "no env blob ever set → 200 with an empty env (build proceeds env-less)" do
      {_agent, _bp, site} = agent_setup()

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", @worker_token)
      assert conn.status == 200
      assert json_body(conn)["env"] == %{}
    end

    test "nonexistent site → 404; non-UUID id → 404 (never a 500)" do
      conn = call(:get, "/v1/builder/sites/#{Ecto.UUID.generate()}/env", @worker_token)
      assert conn.status == 404

      conn = call(:get, "/v1/builder/sites/not-a-uuid/env", @worker_token)
      assert conn.status == 404
    end

    test "user session token → 401 (worker-only, never a logged-in user)" do
      {_agent, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", user_token())
      assert conn.status == 401
    end

    test "agent token → 401 (an agent must use its own box-scoped route)" do
      {agent_token, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", agent_token)
      assert conn.status == 401
    end

    test "no bearer at all → 401 (fails closed)" do
      {_agent, _bp, site} = agent_setup()

      conn = call(:get, "/v1/builder/sites/#{site.id}/env")
      assert conn.status == 401
    end
  end

  ## GET /v1/agent/sites/:id/env — agent, own box only

  describe "GET /v1/agent/sites/:id/env" do
    test "own agent → 200 with the decrypted env" do
      {agent_token, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      conn = call(:get, "/v1/agent/sites/#{site.id}/env", agent_token)
      assert conn.status == 200
      assert json_body(conn)["env"] == @env
    end

    test "no env blob ever set → 200 with an empty env" do
      {agent_token, _bp, site} = agent_setup()

      conn = call(:get, "/v1/agent/sites/#{site.id}/env", agent_token)
      assert conn.status == 200
      assert json_body(conn)["env"] == %{}
    end

    test "FOREIGN agent → 404, indistinguishable from nonexistent (no cross-box leak)" do
      # The site (with a real env blob) lives on box A...
      {_a_token, _bp_a, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      # ...and box B's agent asks for it.
      {b_token, _bp_b, _b_site} = agent_setup()

      conn = call(:get, "/v1/agent/sites/#{site.id}/env", b_token)
      assert conn.status == 404
      assert json_body(conn) == %{"error" => "not_found"}
    end

    test "nonexistent site → 404; non-UUID id → 404 (never a 500)" do
      {agent_token, _bp, _site} = agent_setup()

      conn = call(:get, "/v1/agent/sites/#{Ecto.UUID.generate()}/env", agent_token)
      assert conn.status == 404

      conn = call(:get, "/v1/agent/sites/not-a-uuid/env", agent_token)
      assert conn.status == 404
    end

    test "worker token → 401 (the builder must use its own route); user token → 401; no bearer → 401" do
      {_agent, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      assert call(:get, "/v1/agent/sites/#{site.id}/env", @worker_token).status == 401
      assert call(:get, "/v1/agent/sites/#{site.id}/env", user_token()).status == 401
      assert call(:get, "/v1/agent/sites/#{site.id}/env").status == 401
    end
  end
end
