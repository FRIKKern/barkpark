defmodule BarkparkCloud.Web.RouterBuilderTest do
  @moduledoc """
  The off-box builder surface added in cloud-website-hosting P2 (Move A):

      POST   /v1/builder/claim
      POST   /v1/builder/deployments/:id/transition
      POST   /v1/builder/deployments/:id/console
      POST   /v1/builder/deployments/:id/detail

  Covers the load-bearing properties:
    * AUTH is the BOX'S OWN AGENT TOKEN (`require_agent`) as of
      jpf-w1-builder-identity — no longer the shared fleet WORKER token, and
      never a user session. The old credential was one secret that also opened
      /v1/internal/* and, through /v1/builder/sites/:id/env, returned any site's
      decrypted env; it had been placed on a customer box running untrusted
      nixpacks builds. A user session token → 401; a blank/absent bearer → 401
      (fails closed); the retired WORKER token → 401; the box's agent token →
      200 for its OWN rows.
    * SCOPE-BY-BOX, which is inseparable from the identity change: a per-box
      credential in front of a fleet-wide query would still hand box A a build
      belonging to box B. `claim_queued_deployment_for_barkpark/2` replaces the
      fleet-wide `claim_next_deployment/1` on this route, and every :id route
      re-checks ownership. Another box's row → 404, never 403 — the same shape
      as nonexistent, so the surface cannot be probed for real ids.
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

  # The RETIRED shared WORKER token, still configured for the test env
  # (config/test.exs: config :barkpark_cloud, :worker_token, ...). Kept ONLY so
  # the tests below can prove it no longer opens these routes — a flip nothing
  # asserts against the old credential is a flip that could be silently undone.
  @worker_token "worker-token-test-fixed"

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

  # The credential the builder now presents: the box's own agent token, minted
  # at scope "report" because that is the token the box already has on disk
  # (/etc/barkpark/agent.token) and `verify_agent_token/1` ignores scope. The
  # ruling deliberately mints NO new scope and NO new token kind.
  #
  # MEMOISED PER BOX, and that is not an optimisation: `mint_agent_token/3`
  # supersedes the previous live token of the same scope, so calling it twice
  # for one box would silently revoke the token an earlier line of the same
  # test is still holding — a 401 that looks like a routing bug. Each test runs
  # in its own process (async: true), so the cache cannot leak between tests.
  defp agent_token(box) do
    bp_id = box_id(box)

    case Process.get({:agent_token, bp_id}) do
      nil ->
        {:ok, token, _} = Registry.mint_agent_token(bp_id, "report")
        Process.put({:agent_token, bp_id}, token)
        token

      token ->
        token
    end
  end

  defp box_id(%Registry.Site{barkpark_id: id}), do: id
  defp box_id(%Registry.Barkpark{id: id}), do: id
  defp box_id(id) when is_binary(id), do: id

  # A bare box with no sites — for the routes that must answer before any row
  # exists (empty queue, missing params, unknown id).
  defp box_fixture do
    {_user, team} = user_team()
    barkpark_fixture(team)
  end

  # `count` sites on the SAME box. The old `site_fixture/1` mints a fresh
  # barkpark per site, so under box scoping two of them are two different boxes
  # — exactly right for the cross-box tests below, and exactly wrong for the
  # tests that need ONE builder to see several rows. Returns {barkpark, sites}.
  defp sibling_sites(team, count) do
    bp = barkpark_fixture(team)

    sites =
      for _ <- 1..count do
        n = System.unique_integer([:positive])
        {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
        site
      end

    {bp, sites}
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

  # `console` is an {:array, :map} of line entries, so a substring assertion has
  # to flatten it first — matching on the struct field directly silently
  # compares against a list.
  defp console_text(deployment_id) do
    Registry.get_deployment(deployment_id).console
    |> Enum.map_join("\n", &(&1["line"] || &1[:line] || ""))
  end

  ## POST /v1/builder/claim

  describe "POST /v1/builder/claim" do
    test "no queued deployments → 404 no_queued" do
      conn = call(:post, "/v1/builder/claim", %{worker_id: "w1"}, agent_token(box_fixture()))
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_queued"
    end

    test "claims the oldest queued deployment, bumps epoch, stamps worker" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, d1} = Registry.create_deployment(site, %{git_ref: "older"})
      # Force an ordering — the schema's inserted_at is microsecond-precision
      # but two inserts in a row may share the same microsecond. Bump.
      Process.sleep(2)
      # A SECOND SITE: deploy-truth W1 re-keyed the active index onto
      # (site_id, environment), so two builds can only be queued at once on two
      # different sites. The claim is global, so the ordering claim still holds.
      {:ok, _d2} = Registry.create_deployment(site_fixture(team), %{git_ref: "newer"})

      conn = call(:post, "/v1/builder/claim", %{worker_id: "builder-A"}, agent_token(site))
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
      {_user, team} = user_team()
      site = site_fixture(team)

      # 5 queued deployments, 8 workers racing. One per SITE: deploy-truth W1
      # re-keyed the active index onto (site_id, environment), so a site has at
      # most one build in flight — five concurrent builds means five sites.
      _ds =
        for s <- [site | for(_ <- 1..4, do: site_fixture(team))] do
          {:ok, d} =
            Registry.create_deployment(s, %{
              git_ref: "ref-#{System.unique_integer([:positive])}"
            })

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
      conn = call(:post, "/v1/builder/claim", %{}, agent_token(box_fixture()))
      assert conn.status == 422
    end

    test "no auth → 401" do
      conn = call(:post, "/v1/builder/claim", %{worker_id: "w"})
      assert conn.status == 401
    end
  end

  ## git-ref clone lane — the claim-envelope clone source.
  ##
  ## An artifact-less deployment on a repo-backed site (a webhook push, a branch
  ## preview, a `bp deploy --git-ref`) carries `source` %{kind, url, ref} as a
  ## SIBLING of `deployment` in the claim 200 — the builder's clone recipe.
  ## TENANCY: that key rides ONLY this worker-gated envelope; deployment_json/1
  ## feeds tenant-facing reads and must never carry it.

  describe "POST /v1/builder/claim — git clone source envelope" do
    test "repo-backed artifact-less claim carries source %{kind, url, ref} beside deployment" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, site} = Registry.set_site_github(site, "owner/repo", "main", "hook-secret")

      sha = String.duplicate("ab", 20)
      {:ok, dep} = Registry.create_deployment(site, %{git_ref: sha, artifact_url: nil})

      conn = call(:post, "/v1/builder/claim", %{worker_id: "clone-w"}, agent_token(site))
      assert conn.status == 200

      body = json_body(conn)
      assert body["deployment"]["id"] == dep.id

      # The clone source is a SIBLING of deployment, not a field inside it —
      # deployment_json's own "source" stays the build-provenance string.
      assert body["source"] == %{
               "kind" => "git",
               "url" => "https://github.com/owner/repo.git",
               "ref" => sha
             }
    end

    test "artifact-backed claim on a repo-backed site has NO clone source (nothing to clone)" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, site} = Registry.set_site_github(site, "owner/repo", "main", "hook-secret")

      {:ok, _dep} =
        Registry.create_deployment(site, %{
          git_ref: "v1",
          artifact_url: "https://artifacts.example.com/site.tar.gz"
        })

      conn = call(:post, "/v1/builder/claim", %{worker_id: "artifact-w"}, agent_token(site))
      assert conn.status == 200
      refute Map.has_key?(json_body(conn), "source")
    end

    test "artifact-less claim on a site WITHOUT a linked repo has no clone source" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, _dep} = Registry.create_deployment(site, %{git_ref: "no-repo-ref"})

      conn = call(:post, "/v1/builder/claim", %{worker_id: "norepo-w"}, agent_token(site))
      assert conn.status == 200
      refute Map.has_key?(json_body(conn), "source")
    end

    test "TENANCY: tenant deployment reads never carry the clone source" do
      {user, team} = user_team()
      site = site_fixture(team)
      {:ok, site} = Registry.set_site_github(site, "owner/repo", "main", "hook-secret")

      sha = String.duplicate("cd", 20)
      {:ok, dep} = Registry.create_deployment(site, %{git_ref: sha, artifact_url: nil})
      token = login_token(user)

      # The list read: no top-level source, and the deployment's own "source"
      # field (build provenance) is not the clone map.
      list = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      assert list.status == 200
      refute Map.has_key?(json_body(list), "source")
      [dep_json] = json_body(list)["deployments"]
      assert dep_json["id"] == dep.id
      refute is_map(dep_json["source"])
      refute list.resp_body =~ "github.com/owner/repo.git"

      # The single stage-aware read (site_deployment_json) is clean too.
      get = call(:get, "/v1/sites/#{site.id}/deployments/#{dep.id}", nil, token)
      assert get.status == 200
      refute is_map(json_body(get)["deployment"]["source"])
      refute get.resp_body =~ "github.com/owner/repo.git"
    end
  end

  ## Cross-tenant closure (dwb-builder-cross-tenant-auth) — the security fix.
  ##
  ## claim_next_deployment/1 selects the oldest queued row FLEET-WIDE with no
  ## team filter, so the ONLY thing standing between tenant B and tenant A's
  ## queued deployment (its git_ref/artifact_url, its state machine, its
  ## SSE-broadcast console) is the auth gate. A user session — of ANY team —
  ## must NOT open these routes; only the shared WORKER token does.

  describe "POST /v1/builder/claim — cross-tenant closure" do
    test "tenant B's user session token cannot claim tenant A's queued deployment → 401" do
      # Tenant A owns a site with a queued deployment.
      {_user_a, team_a} = user_team()
      site_a = site_fixture(team_a)
      {:ok, d_a} = Registry.create_deployment(site_a, %{git_ref: "a-secret-ref"})

      # Tenant B is an unrelated logged-in user.
      {user_b, _team_b} = user_team()
      b_token = login_token(user_b)

      # B's valid session token used to claim A's row → now 401 (pre-fix: 200).
      conn = call(:post, "/v1/builder/claim", %{worker_id: "b-attacker"}, b_token)
      assert conn.status == 401
      assert json_body(conn)["error"] == "unauthorized"

      # A blank bearer is likewise rejected (fails closed).
      blank = call(:post, "/v1/builder/claim", %{worker_id: "blank"}, "")
      assert blank.status == 401

      # And an absent bearer too.
      absent = call(:post, "/v1/builder/claim", %{worker_id: "absent"})
      assert absent.status == 401

      # A's deployment was NOT claimed by any of the rejected callers.
      assert Registry.get_deployment(d_a.id).status == "queued"

      # The retired shared WORKER token no longer claims either — 401, not 200.
      # Without this line the flip would be provable only by absence.
      worker = call(:post, "/v1/builder/claim", %{worker_id: "old-fleet"}, @worker_token)
      assert worker.status == 401
      assert Registry.get_deployment(d_a.id).status == "queued"

      # The ONE principal that claims A's row is A's OWN BOX's agent token.
      ok = call(:post, "/v1/builder/claim", %{worker_id: "builder-fleet"}, agent_token(site_a))
      assert ok.status == 200
      assert json_body(ok)["deployment"]["id"] == d_a.id
      assert Registry.get_deployment(d_a.id).status == "building"
    end
  end

  describe "POST /v1/builder/claim — BOX SCOPING (jpf-w1-builder-identity)" do
    test "a box's agent token cannot claim another box's queued deployment → 404 no_queued" do
      # THE HAZARD, stated as a test: before this slice one shared WORKER_TOKEN
      # claimed fleet-wide, so a customer box running untrusted nixpacks builds
      # could take any other tenant's build — and with it the clone `source`
      # envelope, which for a private repo carries a live GitHub installation
      # token (charter D14).
      {_ua, team_a} = user_team()
      {_ub, team_b} = user_team()
      site_a = site_fixture(team_a)
      box_b = barkpark_fixture(team_b)

      {:ok, d_a} = Registry.create_deployment(site_a, %{git_ref: "a-private-ref"})

      conn = call(:post, "/v1/builder/claim", %{worker_id: "b-box"}, agent_token(box_b))

      # 404 no_queued, NOT 403: box B's answer is "my queue is empty", which is
      # byte-identical to the answer it gets when no build exists anywhere. A
      # 403 would confirm that some other box has work waiting.
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_queued"

      # And A's row is untouched — not merely unreturned.
      assert Registry.get_deployment(d_a.id).status == "queued"
      assert is_nil(Registry.get_deployment(d_a.id).claim_worker)

      # A's OWN box still claims it, so the 404 above is scoping and not an
      # outage. Without this arm the test would pass against a claim route that
      # is simply broken for everyone.
      ok = call(:post, "/v1/builder/claim", %{worker_id: "a-box"}, agent_token(site_a))
      assert ok.status == 200
      assert json_body(ok)["deployment"]["id"] == d_a.id
    end

    test "the retired WORKER token no longer claims anything → 401" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "r"})

      conn = call(:post, "/v1/builder/claim", %{worker_id: "old-fleet"}, @worker_token)

      assert conn.status == 401
      assert Registry.get_deployment(d.id).status == "queued"
    end

    test "the route's claim is atomic ON ONE BOX — 8 workers, 5 sibling sites, 5 distinct rows" do
      # The pre-existing concurrency test drives `claim_next_deployment/1`
      # directly, which the route no longer reaches. This one races the
      # function the route DOES reach, on sibling sites of a single box (a
      # site holds at most one active build, so five concurrent builds means
      # five sites).
      {_user, team} = user_team()
      {bp, sites} = sibling_sites(team, 5)

      for s <- sites do
        {:ok, _} =
          Registry.create_deployment(s, %{git_ref: "ref-#{System.unique_integer([:positive])}"})
      end

      results =
        1..8
        |> Task.async_stream(
          fn i -> Registry.claim_queued_deployment_for_barkpark(bp, "worker-#{i}") end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.to_list()

      claimed =
        Enum.flat_map(results, fn
          {:ok, {:ok, %{id: id}}} -> [id]
          {:ok, {:error, :no_queued}} -> []
        end)

      assert length(claimed) == 5
      assert claimed == Enum.uniq(claimed)
      assert Enum.count(results, &match?({:ok, {:error, :no_queued}}, &1)) == 3
    end

    test "a sibling box's queued rows are invisible to this box's claim" do
      # Both-sides-populated on purpose: an empty-vs-empty comparison scans
      # vacuously green. Box A and box B each hold a queued row; each box's
      # claim must return its OWN row and never the other's.
      {_ua, team_a} = user_team()
      {_ub, team_b} = user_team()
      site_a = site_fixture(team_a)
      site_b = site_fixture(team_b)

      # ORDER IS THE WHOLE TEST. B's row is inserted FIRST, so it is the OLDEST
      # queued row in the table — which is exactly the row an unscoped
      # `order_by: [asc: :inserted_at]` claim hands to whoever asks next.
      # Written the other way round (A first) this test passes against a claim
      # with no box filter at all, because A would receive its own row by
      # accident of ordering and B would receive the only row left. Verified by
      # mutation: with the barkpark_id filter deleted, THIS assertion is the one
      # that reds.
      {:ok, d_b} = Registry.create_deployment(site_b, %{git_ref: "b"})
      {:ok, d_a} = Registry.create_deployment(site_a, %{git_ref: "a"})

      a = call(:post, "/v1/builder/claim", %{worker_id: "wa"}, agent_token(site_a))
      b = call(:post, "/v1/builder/claim", %{worker_id: "wb"}, agent_token(site_b))

      assert json_body(a)["deployment"]["id"] == d_a.id
      refute json_body(a)["deployment"]["id"] == d_b.id
      assert json_body(b)["deployment"]["id"] == d_b.id
    end
  end

  ## POST /v1/builder/deployments/:id/transition

  describe "POST /v1/builder/deployments/:id/transition" do
    test "happy-path transition queued→building→pushing→live" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})

      # 1. Claim.
      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, agent_token(site))
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
          agent_token(site)
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
          agent_token(site)
        )

      assert live.status == 200
      assert json_body(live)["deployment"]["status"] == "live"
      assert is_binary(json_body(live)["deployment"]["became_live_at"])
    end

    test "failure path captures failure_reason" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})

      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, agent_token(site))
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
          agent_token(site)
        )

      assert step.status == 200
      assert json_body(step)["deployment"]["status"] == "failed"

      assert json_body(step)["deployment"]["failure_reason"] ==
               "nixpacks: package.json missing engines.node"
    end

    test "stale epoch (lease swept + re-claimed) → 409" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})

      # wA claims and gets epoch 1.
      claim_a = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, agent_token(site))
      did = json_body(claim_a)["deployment"]["id"]
      stale_epoch = json_body(claim_a)["observed_epoch"]

      # Simulate a lease sweep: the deployment goes back to queued, then wB
      # re-claims it (epoch bumps to 2).
      {:ok, _} =
        Registry.transition_deployment(
          Registry.get_deployment(did),
          %{status: "queued", claim_worker: nil, claimed_at: nil}
        )

      _ = call(:post, "/v1/builder/claim", %{worker_id: "wB"}, agent_token(site))

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
          agent_token(site)
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
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})

      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, agent_token(site))
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      step =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wMalicious", observed_epoch: epoch, status: "pushing"},
          agent_token(site)
        )

      assert step.status == 409
    end

    test "nonexistent deployment → 404" do
      fake = Ecto.UUID.generate()

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{fake}/transition",
          %{worker_id: "wA", observed_epoch: 1, status: "pushing"},
          agent_token(box_fixture())
        )

      assert conn.status == 404
    end

    test "missing worker_id → 422" do
      fake = Ecto.UUID.generate()

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{fake}/transition",
          %{observed_epoch: 1},
          agent_token(box_fixture())
        )

      assert conn.status == 422
    end

    test "missing observed_epoch → 422" do
      fake = Ecto.UUID.generate()

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{fake}/transition",
          %{worker_id: "wA"},
          agent_token(box_fixture())
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
      conn =
        call(
          :post,
          "/v1/builder/deployments/not-a-uuid/transition",
          %{worker_id: "wA", observed_epoch: 1, status: "pushing"},
          agent_token(box_fixture())
        )

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "illegal from-status edge (failed → live) → 409 illegal_transition" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})

      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, agent_token(site))
      did = json_body(claim)["deployment"]["id"]
      epoch = json_body(claim)["observed_epoch"]

      # building → failed is legal.
      fail =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "failed"},
          agent_token(site)
        )

      assert fail.status == 200
      assert json_body(fail)["deployment"]["status"] == "failed"

      # A buggy/replayed worker with the same (still-matching) fence tries to
      # resurrect the terminal row: failed → live must be rejected.
      step =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "live"},
          agent_token(site)
        )

      assert step.status == 409
      assert json_body(step)["error"] == "illegal_transition"

      # The row is untouched — still failed.
      assert Registry.get_deployment(did).status == "failed"
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
          agent_token(site)
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      assert [%{"line" => "build: nixpacks build starting"}] =
               Registry.get_deployment(d.id).console

      # The append fires a coarse "deployments" invalidation so an open site view
      # streams the new line without a reload.
      assert_receive {:bpcloud_event, %{type: "deployments"}}

      # Refresh-durable: the console rides along on GET /v1/sites/:id/deployments
      # (a USER-authed read — the owner watching their build).
      list = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      row = Enum.find(json_body(list)["deployments"], &(&1["id"] == d.id))
      assert [%{"line" => "build: nixpacks build starting"}] = row["console"]
    end

    test "blank line → 422 invalid" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

      conn =
        call(:post, "/v1/builder/deployments/#{d.id}/console", %{line: "  "}, agent_token(site))

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
      assert Registry.get_deployment(d.id).console == []
    end

    test "unknown deployment id → 404" do
      conn =
        call(
          :post,
          "/v1/builder/deployments/#{Ecto.UUID.generate()}/console",
          %{line: "hi"},
          agent_token(box_fixture())
        )

      assert conn.status == 404
    end

    test "no auth → 401 (builder-token gated, like claim/transition)" do
      conn =
        call(:post, "/v1/builder/deployments/#{Ecto.UUID.generate()}/console", %{line: "hi"})

      assert conn.status == 401
    end

    test "a plain user session token → 401 (not a worker)" do
      {user, _team} = user_team()
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{Ecto.UUID.generate()}/console",
          %{line: "hi"},
          token
        )

      assert conn.status == 401
    end
  end

  ## POST /v1/builder/deployments/:id/detail (dwb-19)

  describe "POST /v1/builder/deployments/:id/detail" do
    test "sets the caption latest-wins, surfaces on the deployment JSON + BROADCASTS deployments" do
      {user, team} = user_team()
      :ok = Events.subscribe(team.id)
      site = site_fixture(team)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{d.id}/detail",
          %{detail: "Fetching your source…"},
          agent_token(site)
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert Registry.get_deployment(d.id).detail == "Fetching your source…"
      assert_receive {:bpcloud_event, %{type: "deployments"}}

      # Latest-wins: a second caption overwrites (no array to grow).
      _ =
        call(
          :post,
          "/v1/builder/deployments/#{d.id}/detail",
          %{detail: "Building your site…"},
          agent_token(site)
        )

      assert Registry.get_deployment(d.id).detail == "Building your site…"

      # Refresh-durable: it rides along on GET /v1/sites/:id/deployments (a
      # USER-authed read — the owner watching their build).
      list = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      row = Enum.find(json_body(list)["deployments"], &(&1["id"] == d.id))
      assert row["detail"] == "Building your site…"
    end

    test "blank detail → 422 invalid" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

      conn =
        call(:post, "/v1/builder/deployments/#{d.id}/detail", %{detail: "  "}, agent_token(site))

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
      assert Registry.get_deployment(d.id).detail == nil
    end

    # cch-w34-s5, DRIVEN AT THE ROUTE, not at the context function. This route
    # documents 200/404/422 and its @doc promises a detail report "NEVER affects
    # the build's outcome" — but `detail` was varchar(255) while the shared
    # validator caps at 2 KB, so an oversize caption raised Postgrex.Error 22001
    # under `Repo.update/1` and the route answered an UNDOCUMENTED 500 with the
    # caption dropped. `modify :detail, :text` makes the validator the only
    # bound: the same request is a documented 200 and the caption is stored.
    test "cch-w34-s5: an oversize caption is a documented 200, never an undocumented 500" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

      # 300 chars: above the old column width, below the shared cap → stored whole.
      caption = String.duplicate("z", 300)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{d.id}/detail",
          %{detail: caption},
          agent_token(site)
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert Registry.get_deployment(d.id).detail == caption

      # 5_000 chars: above the shared cap → truncated to 2 KB, still a 200, and
      # still not the silent nil the 500 used to leave behind.
      big =
        call(
          :post,
          "/v1/builder/deployments/#{d.id}/detail",
          %{detail: String.duplicate("y", 5_000)},
          agent_token(site)
        )

      assert big.status == 200
      assert String.length(Registry.get_deployment(d.id).detail) == 2_000
    end

    # cch-w34-s5: THE REACHABILITY CASE, with ordinary product data. The builder
    # narrates `"Starting your build (%s)…"` around the ref
    # (internal/builder/builder.go) — +23 characters over it — and `git_ref` is
    # itself varchar(255) with NO validate_length, so a ref of 233..255 chars
    # inserts fine and then makes its own caption overflow the old column. That
    # is the shape that 500'd in production data, so it is the shape pinned here.
    #
    # git_ref's own missing length bound is NOT fixed here — same class, other
    # route, filed as its own row.
    test "cch-w34-s5: a 240-char git_ref, whose builder caption is +23 chars, no longer 500s" do
      {_user, team} = user_team()
      site = site_fixture(team)

      ref = String.duplicate("b", 240)
      {:ok, d} = Registry.create_deployment(site, %{git_ref: ref})
      assert Registry.get_deployment(d.id).git_ref == ref

      # Byte-for-byte the builder's own caption for this ref.
      caption = "Starting your build (#{ref})…"
      assert String.length(caption) == 263

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{d.id}/detail",
          %{detail: caption},
          agent_token(site)
        )

      assert conn.status == 200
      assert Registry.get_deployment(d.id).detail == caption
    end

    test "unknown deployment id → 404" do
      conn =
        call(
          :post,
          "/v1/builder/deployments/#{Ecto.UUID.generate()}/detail",
          %{detail: "hi"},
          agent_token(box_fixture())
        )

      assert conn.status == 404
    end

    test "no auth → 401 (builder-token gated, like claim/transition)" do
      conn =
        call(:post, "/v1/builder/deployments/#{Ecto.UUID.generate()}/detail", %{detail: "hi"})

      assert conn.status == 401
    end

    test "a plain user session token → 401 (not a worker)" do
      {user, _team} = user_team()
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{Ecto.UUID.generate()}/detail",
          %{detail: "hi"},
          token
        )

      assert conn.status == 401
    end
  end

  ## The :id routes — CROSS-BOX CLOSURE (jpf-w1-builder-identity)

  describe "builder :id routes reject a foreign box" do
    setup do
      {_ua, team_a} = user_team()
      {_ub, team_b} = user_team()
      site_a = site_fixture(team_a)
      box_b = barkpark_fixture(team_b)

      {:ok, d} = Registry.create_deployment(site_a, %{git_ref: "a-ref"})

      # Claimed by A's own box, so the row carries a real (worker, epoch) —
      # the transition below fails on SCOPE, not on a missing claim, which is
      # what makes the 404 meaningful rather than incidental.
      claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, agent_token(site_a))
      assert claim.status == 200
      epoch = json_body(claim)["observed_epoch"]

      %{deployment: d, epoch: epoch, foreign: agent_token(box_b), own: agent_token(site_a)}
    end

    test "transition from a foreign box → 404 and the row is NOT mutated", ctx do
      before = Registry.get_deployment(ctx.deployment.id)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{ctx.deployment.id}/transition",
          %{worker_id: "wA", observed_epoch: ctx.epoch, status: "pushing"},
          ctx.foreign
        )

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"

      # The scope check must run BEFORE the fenced write. A 404 returned after
      # the row had already moved would be a cosmetic guard.
      after_ = Registry.get_deployment(ctx.deployment.id)
      assert after_.status == before.status
      assert after_.claim_epoch == before.claim_epoch

      # Same call from the OWN box succeeds — so the 404 is scoping, not a
      # broken route. Without this arm the test passes against a dead endpoint.
      ok =
        call(
          :post,
          "/v1/builder/deployments/#{ctx.deployment.id}/transition",
          %{worker_id: "wA", observed_epoch: ctx.epoch, status: "pushing"},
          ctx.own
        )

      assert ok.status == 200
      assert Registry.get_deployment(ctx.deployment.id).status == "pushing"
    end

    test "console from a foreign box → 404 and no line is appended", ctx do
      conn =
        call(
          :post,
          "/v1/builder/deployments/#{ctx.deployment.id}/console",
          %{line: "injected by another box"},
          ctx.foreign
        )

      assert conn.status == 404
      refute console_text(ctx.deployment.id) =~ "injected by another box"

      ok =
        call(
          :post,
          "/v1/builder/deployments/#{ctx.deployment.id}/console",
          %{line: "mine"},
          ctx.own
        )

      assert ok.status == 200
      assert console_text(ctx.deployment.id) =~ "mine"
    end

    test "detail from a foreign box → 404 and the caption is NOT set", ctx do
      conn =
        call(
          :post,
          "/v1/builder/deployments/#{ctx.deployment.id}/detail",
          %{detail: "foreign caption"},
          ctx.foreign
        )

      assert conn.status == 404
      refute Registry.get_deployment(ctx.deployment.id).detail == "foreign caption"

      ok =
        call(
          :post,
          "/v1/builder/deployments/#{ctx.deployment.id}/detail",
          %{detail: "mine"},
          ctx.own
        )

      assert ok.status == 200
      assert Registry.get_deployment(ctx.deployment.id).detail == "mine"
    end
  end

  ## P2 exit gate — end-to-end builder loop, control-plane half.

  describe "P2 exit gate — control-plane half" do
    test "deploy → builder claim → build (simulated) → transition to pushing" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      # 1. User enqueues a deploy (with an uploaded artifact as the build
      # source) — this half is USER-authed (the owner triggers a deploy).
      deploy =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{git_ref: "main", artifact_url: "file:///tmp/build.tar.gz"},
          token
        )

      assert deploy.status == 201
      assert json_body(deploy)["deployment"]["status"] == "queued"

      # 2. Builder claims it — WORKER-authed (the off-box fleet).
      claim = call(:post, "/v1/builder/claim", %{worker_id: "builder-host-1"}, agent_token(site))
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
          agent_token(site)
        )

      assert step.status == 200
      d = json_body(step)["deployment"]
      assert d["status"] == "pushing"
      assert String.starts_with?(d["image_tag"], "site-#{site.slug}-")
      assert String.starts_with?(d["build_log_url"], "file://")
    end
  end
end
