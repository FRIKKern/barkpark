defmodule BarkparkCloud.Web.RouterSiteEnvReadTest do
  @moduledoc """
  The fleet-facing site-env read surface (site-env-injection):

      GET    /v1/builder/sites/:id/env   agent   — build-time injection (nixpacks --env)
      GET    /v1/agent/sites/:id/env     agent   — run-time injection (docker run -e)

  `bp sites env set` stores the blob Vault-encrypted; these two routes are the
  ONLY places it is decrypted back out, so the auth matrix is the load-bearing
  property:

  * **Builder route is AGENT-gated and BOX-SCOPED** as of
    jpf-w1-builder-identity — the same law as the agent route beside it, which
    is why the two describe blocks below now assert the same matrix.

    It was WORKER-only, and that was the single worst consequence of the shared
    credential: one fleet secret, held by every box including a customer box
    running untrusted nixpacks builds, returned ANY site's DECRYPTED env — every
    database URL and API token any tenant had ever set. The flip is what closes
    that read. A foreign box, a user session token, the retired worker token, or
    no bearer at all → 401/404, and the 404 is deliberately the same shape as a
    nonexistent site.
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

  # The RETIRED shared WORKER token, still configured for the test env
  # (config/test.exs). Kept so both routes can prove it opens NEITHER of them.
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

  ## GET /v1/builder/sites/:id/env — agent, own box only (jpf-w1-builder-identity)

  describe "GET /v1/builder/sites/:id/env" do
    test "the site's OWN box agent → 200 with the decrypted env" do
      {agent_token, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", agent_token)
      assert conn.status == 200
      assert json_body(conn)["env"] == @env
    end

    test "no env blob ever set → 200 with an empty env (build proceeds env-less)" do
      {agent_token, _bp, site} = agent_setup()

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", agent_token)
      assert conn.status == 200
      assert json_body(conn)["env"] == %{}
    end

    test "FOREIGN box → 404, and the secret does not appear in the body" do
      # THE READ THIS SLICE CLOSES. Box A's site holds real secrets; box B asks
      # for them with its own perfectly valid agent token.
      {_a_token, _bp_a, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      {b_token, _bp_b, _b_site} = agent_setup()

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", b_token)

      # 404 and not 403: identical to a site that does not exist, so the route
      # cannot be walked to learn which site ids are real.
      assert conn.status == 404
      assert json_body(conn) == %{"error" => "not_found"}

      # Asserted on the RAW body, not the decoded map: a status assertion alone
      # would still pass if the secret rode along in an unexpected field.
      refute conn.resp_body =~ "tok-secret"
      refute conn.resp_body =~ "postgres://"
    end

    test "nonexistent site → 404; non-UUID id → 404 (never a 500)" do
      {agent_token, _bp, _site} = agent_setup()

      conn = call(:get, "/v1/builder/sites/#{Ecto.UUID.generate()}/env", agent_token)
      assert conn.status == 404

      conn = call(:get, "/v1/builder/sites/not-a-uuid/env", agent_token)
      assert conn.status == 404
    end

    test "the RETIRED worker token → 401 (it no longer reads any site's env)" do
      # The regression this file exists to prevent. Before the flip this exact
      # call returned 200 and the plaintext env of a site on a box the caller
      # had nothing to do with.
      {_agent, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", @worker_token)
      assert conn.status == 401
      refute conn.resp_body =~ "tok-secret"
    end

    test "user session token → 401 (never a logged-in user)" do
      {_agent, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      conn = call(:get, "/v1/builder/sites/#{site.id}/env", user_token())
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

    test "retired worker token → 401; user token → 401; no bearer → 401" do
      {_agent, _bp, site} = agent_setup()
      {:ok, _} = Registry.set_site_env(site, @env)

      assert call(:get, "/v1/agent/sites/#{site.id}/env", @worker_token).status == 401
      assert call(:get, "/v1/agent/sites/#{site.id}/env", user_token()).status == 401
      assert call(:get, "/v1/agent/sites/#{site.id}/env").status == 401
    end
  end
end
