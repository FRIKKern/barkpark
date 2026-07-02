defmodule BarkparkCloud.Web.RouterAgentRuntimeTest do
  @moduledoc """
  The on-box runtime executor surface added in cloud-website-hosting P3:

      GET    /v1/agent/pending
      POST   /v1/agent/deployments/claim
      POST   /v1/agent/deployments/:id/transition

  Three load-bearing properties:

  * **Scope-by-barkpark.** An agent only sees / claims / transitions deployments
    whose Site is on its own Barkpark. Other boxes' deployments are 404 —
    indistinguishable from nonexistent (no existence leak).
  * **Epoch fencing.** Same CAS semantics as the builder transition: stale
    epoch or wrong worker → 409, the row is NOT mutated.
  * **Atomic site update.** When the agent transitions `pushing → live` with
    `make_current=true`, the deployment status AND the site's
    `current_deployment_id` + `port` flip in ONE transaction. No window where
    the deployment is `live` but the site still points at the old port.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

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

  # Returns {agent_token, barkpark, site}. Mints a real AgentToken so the
  # require_agent plug exercises the real path.
  defp agent_setup do
    team = team_fixture()
    barkpark = barkpark_fixture(team)
    site = site_fixture(barkpark)
    {:ok, token, _} = Registry.mint_agent_token(barkpark, "runtime")
    {token, barkpark, site}
  end

  # A queued deployment that the builder has built and transitioned to `pushing`
  # (the agent's pickup state). Returns the row.
  defp pushing_deployment(site) do
    # Unique git_ref per row: the dwb-18 partial unique index (dwb-18) allows at
    # most one active deployment per (site, git_ref), and these claim-race
    # fixtures stand up several active rows at once (each a distinct commit).
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, d} = Registry.create_deployment(site, %{git_ref: ref})
    {:ok, d} = Registry.transition_deployment(d, %{status: "pushing", image_tag: "site-x-1"})
    d
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

  ## GET /v1/agent/pending

  describe "GET /v1/agent/pending" do
    test "lists pushing deployments for this barkpark only" do
      {token, _bp, site} = agent_setup()
      _d_pushing = pushing_deployment(site)
      # A queued deployment shouldn't show — not yet built.
      {:ok, _queued} = Registry.create_deployment(site, %{git_ref: "old"})

      conn = call(:get, "/v1/agent/pending", nil, token)
      assert conn.status == 200
      assert length(json_body(conn)["deployments"]) == 1
      assert hd(json_body(conn)["deployments"])["status"] == "pushing"
    end

    test "does NOT see another box's pushing deployments" do
      {_t1, _bp1, other_site} = agent_setup()
      _other_pushing = pushing_deployment(other_site)

      {token, _bp, site} = agent_setup()
      my_pushing = pushing_deployment(site)

      conn = call(:get, "/v1/agent/pending", nil, token)
      assert conn.status == 200
      ids = Enum.map(json_body(conn)["deployments"], & &1["id"])
      assert ids == [my_pushing.id]
    end

    test "empty pending → 200 with empty list" do
      {token, _bp, _site} = agent_setup()
      conn = call(:get, "/v1/agent/pending", nil, token)
      assert conn.status == 200
      assert json_body(conn)["deployments"] == []
    end

    test "no auth → 401" do
      conn = call(:get, "/v1/agent/pending")
      assert conn.status == 401
    end
  end

  ## POST /v1/agent/deployments/claim

  describe "POST /v1/agent/deployments/claim" do
    test "atomic claim of the oldest pushing deployment on this box" do
      {token, _bp, site} = agent_setup()
      d1 = pushing_deployment(site)
      Process.sleep(2)
      _d2 = pushing_deployment(site)

      conn = call(:post, "/v1/agent/deployments/claim", %{worker_id: "agent-A"}, token)
      assert conn.status == 200
      body = json_body(conn)
      # Oldest claimed first.
      assert body["deployment"]["id"] == d1.id
      assert body["observed_epoch"] == 1

      reread = Registry.get_deployment(d1.id)
      # Status STAYS pushing — claim only flips the runtime ownership; the agent
      # transitions to `live` once the container is up.
      assert reread.status == "pushing"
      assert reread.claim_worker == "agent-A"
      assert reread.claim_epoch == 1
    end

    test "another box's pushing deployment is invisible (no claim leak)" do
      # Other box's pushing deployment exists, but isn't visible to this agent.
      {_t1, _other_bp, other_site} = agent_setup()
      _other = pushing_deployment(other_site)

      {token, _bp, _site} = agent_setup()

      conn = call(:post, "/v1/agent/deployments/claim", %{worker_id: "agent-A"}, token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_pending"
    end

    test "two agents racing on the same box never both claim the same row" do
      {token1, bp, site} = agent_setup()
      # Mint a second agent token for the same barkpark.
      {:ok, token2, _} = Registry.mint_agent_token(bp, "runtime")

      # 4 pushing deployments, 6 racing claims (2 from each token).
      _ds = for _ <- 1..4, do: pushing_deployment(site)

      results =
        1..6
        |> Task.async_stream(
          fn i ->
            tok = if rem(i, 2) == 0, do: token1, else: token2
            call(:post, "/v1/agent/deployments/claim", %{worker_id: "w-#{i}"}, tok)
          end,
          max_concurrency: 6,
          ordered: false
        )
        |> Enum.to_list()

      claimed_ids =
        results
        |> Enum.flat_map(fn
          {:ok, conn} ->
            case conn.status do
              200 -> [json_body(conn)["deployment"]["id"]]
              _ -> []
            end
        end)

      assert length(claimed_ids) == 4
      assert claimed_ids == Enum.uniq(claimed_ids)
    end

    test "no auth → 401" do
      conn = call(:post, "/v1/agent/deployments/claim", %{worker_id: "x"})
      assert conn.status == 401
    end

    test "missing worker_id → 422" do
      {token, _bp, _site} = agent_setup()
      conn = call(:post, "/v1/agent/deployments/claim", %{}, token)
      assert conn.status == 422
    end
  end

  ## POST /v1/agent/deployments/:id/transition

  describe "POST /v1/agent/deployments/:id/transition" do
    test "happy path: pushing → live, atomic site update (current + port)" do
      {token, _bp, site} = agent_setup()
      _ = pushing_deployment(site)

      claim = call(:post, "/v1/agent/deployments/claim", %{worker_id: "agent-A"}, token)
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      now = DateTime.utc_now() |> DateTime.to_iso8601()

      live =
        call(
          :post,
          "/v1/agent/deployments/#{did}/transition",
          %{
            worker_id: "agent-A",
            observed_epoch: epoch,
            status: "live",
            became_live_at: now,
            make_current: true,
            site_port: 7001
          },
          token
        )

      assert live.status == 200
      assert json_body(live)["deployment"]["status"] == "live"

      # Site got the atomic update in the same transaction.
      reread_site = Registry.get_site(site.id)
      assert reread_site.current_deployment_id == did
      assert reread_site.port == 7001

      # Deployment is live with became_live_at stamped.
      reread = Registry.get_deployment(did)
      assert reread.status == "live"
      assert %DateTime{} = reread.became_live_at
    end

    test "without make_current=true, site is NOT updated even on live" do
      {token, _bp, site} = agent_setup()
      _ = pushing_deployment(site)
      claim = call(:post, "/v1/agent/deployments/claim", %{worker_id: "wA"}, token)
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      live =
        call(
          :post,
          "/v1/agent/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "live"},
          token
        )

      assert live.status == 200
      assert json_body(live)["deployment"]["status"] == "live"
      assert Registry.get_site(site.id).current_deployment_id == nil
    end

    test "transition another box's deployment → 404 (no cross-box leak)" do
      # Other box has a pushing deployment.
      {_t1, _other_bp, other_site} = agent_setup()
      other = pushing_deployment(other_site)

      # This agent (different box) tries to transition the other's deployment.
      {token, _bp, _site} = agent_setup()

      conn =
        call(
          :post,
          "/v1/agent/deployments/#{other.id}/transition",
          %{worker_id: "wA", observed_epoch: 1, status: "live"},
          token
        )

      assert conn.status == 404
    end

    test "stale epoch → 409, row NOT mutated" do
      {token, _bp, site} = agent_setup()
      _ = pushing_deployment(site)
      claim_a = call(:post, "/v1/agent/deployments/claim", %{worker_id: "wA"}, token)
      did = json_body(claim_a)["deployment"]["id"]
      stale_epoch = json_body(claim_a)["observed_epoch"]

      # Simulate a sweep + re-claim.
      {:ok, _} =
        Registry.transition_deployment(
          Registry.get_deployment(did),
          %{claim_worker: nil, claimed_at: nil}
        )

      _ = call(:post, "/v1/agent/deployments/claim", %{worker_id: "wB"}, token)

      conn =
        call(
          :post,
          "/v1/agent/deployments/#{did}/transition",
          %{
            worker_id: "wA",
            observed_epoch: stale_epoch,
            status: "live",
            make_current: true,
            site_port: 7777
          },
          token
        )

      assert conn.status == 409

      # Site untouched.
      assert Registry.get_site(site.id).port == nil
      assert Registry.get_site(site.id).current_deployment_id == nil
    end

    test "failure path: pushing → failed with failure_reason" do
      {token, _bp, site} = agent_setup()
      _ = pushing_deployment(site)
      claim = call(:post, "/v1/agent/deployments/claim", %{worker_id: "wA"}, token)
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      conn =
        call(
          :post,
          "/v1/agent/deployments/#{did}/transition",
          %{
            worker_id: "wA",
            observed_epoch: epoch,
            status: "failed",
            failure_reason: "health check timed out after 30s"
          },
          token
        )

      assert conn.status == 200
      assert json_body(conn)["deployment"]["status"] == "failed"

      assert Registry.get_deployment(did).failure_reason ==
               "health check timed out after 30s"

      # And the site is unchanged — current_deployment stays whatever it was.
      assert Registry.get_site(site.id).current_deployment_id == nil
    end

    test "no auth → 401" do
      fake = Ecto.UUID.generate()
      conn = call(:post, "/v1/agent/deployments/#{fake}/transition", %{worker_id: "x"})
      assert conn.status == 401
    end

    test "missing observed_epoch → 422" do
      {token, _bp, _site} = agent_setup()
      fake = Ecto.UUID.generate()

      conn =
        call(
          :post,
          "/v1/agent/deployments/#{fake}/transition",
          %{worker_id: "wA"},
          token
        )

      assert conn.status == 422
    end
  end

  ## P3 exit-gate sketch (mechanism — the real e2e proof lives in the Go
  ## runtime tests + the manual full-chain proof).

  describe "P3 exit gate — control-plane half" do
    test "agent claims → transitions live with atomic site update" do
      {token, _bp, site} = agent_setup()
      _ = pushing_deployment(site)

      # Discover.
      pending = call(:get, "/v1/agent/pending", nil, token)
      assert pending.status == 200
      assert length(json_body(pending)["deployments"]) == 1

      # Claim.
      claim = call(:post, "/v1/agent/deployments/claim", %{worker_id: "agent-1"}, token)
      assert claim.status == 200
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      # ... agent runs the container locally, health-checks, swaps Caddy ...

      # Flip live + point the site at the new deployment + port.
      live =
        call(
          :post,
          "/v1/agent/deployments/#{did}/transition",
          %{
            worker_id: "agent-1",
            observed_epoch: epoch,
            status: "live",
            became_live_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            make_current: true,
            site_port: 7001
          },
          token
        )

      assert live.status == 200

      reread_site = Registry.get_site(site.id)
      assert reread_site.current_deployment_id == did
      assert reread_site.port == 7001
    end
  end
end
