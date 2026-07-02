defmodule BarkparkCloud.Web.RouterBuilderTest do
  @moduledoc """
  The off-box builder surface added in cloud-website-hosting P2 (Move A):

      POST   /v1/builder/claim
      POST   /v1/builder/deployments/:id/transition

  Covers the two load-bearing properties:
    * claim is atomic (`FOR UPDATE SKIP LOCKED` + transactional epoch bump) —
      two workers racing get two distinct rows (or one finds nothing); they
      never both get the same row.
    * transition is fenced — a stale-but-alive worker writing after its lease
      was swept fails the (worker, epoch) CAS with 409 instead of corrupting
      state.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Events, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    team
  end

  defp user_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(team) do
    bp = barkpark_fixture(team)
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  defp login_token(user) do
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

  ## POST /v1/builder/claim

  describe "POST /v1/builder/claim" do
    test "no queued deployments → 404 no_queued" do
      {user, _team} = user_team()
      token = login_token(user)

      conn = call(:post, "/v1/builder/claim", %{worker_id: "w1"}, token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_queued"
    end

    test "claims the oldest queued deployment, bumps epoch, stamps worker" do
      {user, team} = user_team()
      site = site_fixture(team)
      {:ok, d1} = Registry.create_deployment(site, %{git_ref: "older"})
      # Force an ordering — the schema's inserted_at is microsecond-precision
      # but two inserts in a row may share the same microsecond. Bump.
      Process.sleep(2)
      {:ok, _d2} = Registry.create_deployment(site, %{git_ref: "newer"})

      token = login_token(user)
      conn = call(:post, "/v1/builder/claim", %{worker_id: "builder-A"}, token)
      assert conn.status == 200

      body = json_body(conn)
      assert body["deployment"]["id"] == d1.id
      assert body["deployment"]["status"] == "building"
      assert body["observed_epoch"] == 1

      # The row in the DB also reflects the claim.
      reread = Registry.get_deployment(d1.id)
      assert reread.status == "building"
      assert reread.claim_worker == "builder-A"
      assert reread.claim_epoch == 1
      assert %DateTime{} = reread.claimed_at
    end

    test "two concurrent workers never both claim the same row" do
      {user, team} = user_team()
      site = site_fixture(team)

      # 5 queued deployments, 8 workers racing.
      _ds =
        for _ <- 1..5 do
          {:ok, d} = Registry.create_deployment(site, %{git_ref: "ref"})
          d
        end

      results =
        1..8
        |> Task.async_stream(
          fn i -> Registry.claim_next_deployment("worker-#{i}") end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.to_list()

      claimed_ids =
        results
        |> Enum.flat_map(fn
          {:ok, {:ok, %{id: id}}} -> [id]
          {:ok, {:error, :no_queued}} -> []
        end)

      # Exactly 5 successful claims, all distinct ids — no double-claim.
      assert length(claimed_ids) == 5
      assert claimed_ids == Enum.uniq(claimed_ids)

      # Three workers got no_queued.
      no_queued =
        results
        |> Enum.count(fn
          {:ok, {:error, :no_queued}} -> true
          _ -> false
        end)

      assert no_queued == 3
    end

    test "missing worker_id → 422" do
      {user, _team} = user_team()
      token = login_token(user)
      conn = call(:post, "/v1/builder/claim", %{}, token)
      assert conn.status == 422
    end

    test "no auth → 401" do
      conn = call(:post, "/v1/builder/claim", %{worker_id: "w"})
      assert conn.status == 401
    end
  end

  ## POST /v1/builder/deployments/:id/transition

  describe "POST /v1/builder/deployments/:id/transition" do
    test "happy-path transition queued→building→pushing→live" do
      {user, team} = user_team()
      site = site_fixture(team)
      {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
      token = login_token(user)

      # 1. Claim.
      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, token)
      assert claim.status == 200
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      # 2. building → pushing with an image_tag.
      step =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{
            worker_id: "wA",
            observed_epoch: epoch,
            status: "pushing",
            image_tag: "sha256:cafebabe"
          },
          token
        )

      assert step.status == 200
      assert json_body(step)["deployment"]["status"] == "pushing"
      assert json_body(step)["deployment"]["image_tag"] == "sha256:cafebabe"

      # 3. pushing → live.
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      live =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "live", became_live_at: now},
          token
        )

      assert live.status == 200
      assert json_body(live)["deployment"]["status"] == "live"
      assert is_binary(json_body(live)["deployment"]["became_live_at"])
    end

    test "failure path captures failure_reason" do
      {user, team} = user_team()
      site = site_fixture(team)
      {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})
      token = login_token(user)

      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, token)
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      step =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{
            worker_id: "wA",
            observed_epoch: epoch,
            status: "failed",
            failure_reason: "nixpacks: package.json missing engines.node"
          },
          token
        )

      assert step.status == 200
      assert json_body(step)["deployment"]["status"] == "failed"

      assert json_body(step)["deployment"]["failure_reason"] ==
               "nixpacks: package.json missing engines.node"
    end

    test "stale epoch (lease swept + re-claimed) → 409" do
      {user, team} = user_team()
      site = site_fixture(team)
      {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})
      token = login_token(user)

      # wA claims and gets epoch 1.
      claim_a = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, token)
      did = json_body(claim_a)["deployment"]["id"]
      stale_epoch = json_body(claim_a)["observed_epoch"]

      # Simulate a lease sweep: the deployment goes back to queued, then wB
      # re-claims it (epoch bumps to 2).
      {:ok, _} =
        Registry.transition_deployment(
          Registry.get_deployment(did),
          %{status: "queued", claim_worker: nil, claimed_at: nil}
        )

      _ = call(:post, "/v1/builder/claim", %{worker_id: "wB"}, token)

      # wA, oblivious, attempts to transition with its stale epoch.
      step =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{
            worker_id: "wA",
            observed_epoch: stale_epoch,
            status: "pushing",
            image_tag: "sha256:from-stale-worker"
          },
          token
        )

      assert step.status == 409
      assert json_body(step)["error"] == "stale_epoch"

      # And the row was NOT mutated by wA's stale write.
      reread = Registry.get_deployment(did)
      assert reread.status == "building"
      assert reread.claim_worker == "wB"
      assert reread.image_tag == nil
    end

    test "right epoch but wrong worker → 409 (epoch and worker must both match)" do
      {user, team} = user_team()
      site = site_fixture(team)
      {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})
      token = login_token(user)

      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, token)
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      step =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wMalicious", observed_epoch: epoch, status: "pushing"},
          token
        )

      assert step.status == 409
    end

    test "nonexistent deployment → 404" do
      {user, _team} = user_team()
      token = login_token(user)

      fake = Ecto.UUID.generate()

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{fake}/transition",
          %{worker_id: "wA", observed_epoch: 1, status: "pushing"},
          token
        )

      assert conn.status == 404
    end

    test "missing worker_id → 422" do
      {user, _team} = user_team()
      token = login_token(user)
      fake = Ecto.UUID.generate()

      conn =
        call(:post, "/v1/builder/deployments/#{fake}/transition", %{observed_epoch: 1}, token)

      assert conn.status == 422
    end

    test "missing observed_epoch → 422" do
      {user, _team} = user_team()
      token = login_token(user)
      fake = Ecto.UUID.generate()

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{fake}/transition",
          %{worker_id: "wA"},
          token
        )

      assert conn.status == 422
    end

    test "no auth → 401" do
      fake = Ecto.UUID.generate()

      conn =
        call(:post, "/v1/builder/deployments/#{fake}/transition", %{worker_id: "w"})

      assert conn.status == 401
    end

    test "non-UUID deployment id → 404 (no raised CastError)" do
      {user, _team} = user_team()
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/builder/deployments/not-a-uuid/transition",
          %{worker_id: "wA", observed_epoch: 1, status: "pushing"},
          token
        )

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end
  end

  ## POST /v1/builder/deployments/:id/console (gh-5)

  describe "POST /v1/builder/deployments/:id/console" do
    test "appends the line, surfaces it on the deployment JSON + BROADCASTS deployments" do
      {user, team} = user_team()
      :ok = Events.subscribe(team.id)
      site = site_fixture(team)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{d.id}/console",
          %{line: "build: nixpacks build starting"},
          token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      assert [%{"line" => "build: nixpacks build starting"}] =
               Registry.get_deployment(d.id).console

      # The append fires a coarse "deployments" invalidation so an open site view
      # streams the new line without a reload.
      assert_receive {:bpcloud_event, %{type: "deployments"}}

      # Refresh-durable: the console rides along on GET /v1/sites/:id/deployments.
      list = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      row = Enum.find(json_body(list)["deployments"], &(&1["id"] == d.id))
      assert [%{"line" => "build: nixpacks build starting"}] = row["console"]
    end

    test "blank line → 422 invalid" do
      {user, team} = user_team()
      site = site_fixture(team)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
      token = login_token(user)

      conn = call(:post, "/v1/builder/deployments/#{d.id}/console", %{line: "  "}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
      assert Registry.get_deployment(d.id).console == []
    end

    test "unknown deployment id → 404" do
      {user, _team} = user_team()
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{Ecto.UUID.generate()}/console",
          %{line: "hi"},
          token
        )

      assert conn.status == 404
    end

    test "no auth → 401 (builder-token gated, like claim/transition)" do
      conn =
        call(:post, "/v1/builder/deployments/#{Ecto.UUID.generate()}/console", %{line: "hi"})

      assert conn.status == 401
    end
  end

  ## P2 exit gate — end-to-end builder loop, control-plane half.

  describe "P2 exit gate — control-plane half" do
    test "deploy → builder claim → build (simulated) → transition to pushing" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      # 1. User enqueues a deploy.
      deploy = call(:post, "/v1/sites/#{site.id}/deploy", %{git_ref: "main"}, token)
      assert deploy.status == 201
      assert json_body(deploy)["deployment"]["status"] == "queued"

      # 2. Builder claims it.
      claim = call(:post, "/v1/builder/claim", %{worker_id: "builder-host-1"}, token)
      assert claim.status == 200
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]
      assert json_body(claim)["deployment"]["status"] == "building"

      # 3. Builder runs nixpacks (simulated here — the Go binary does the real
      # subprocess), then transitions to pushing with the image_tag.
      step =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{
            worker_id: "builder-host-1",
            observed_epoch: epoch,
            status: "pushing",
            image_tag: "site-#{site.slug}-#{String.slice(did, 0, 8)}",
            build_log_url: "file:///var/lib/barkpark-builder/logs/#{did}.log"
          },
          token
        )

      assert step.status == 200
      d = json_body(step)["deployment"]
      assert d["status"] == "pushing"
      assert String.starts_with?(d["image_tag"], "site-#{site.slug}-")
      assert String.starts_with?(d["build_log_url"], "file://")
    end
  end
end
