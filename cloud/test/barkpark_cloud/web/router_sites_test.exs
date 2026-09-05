defmodule BarkparkCloud.Web.RouterSitesTest do
  @moduledoc """
  Drives the Sites + Deployments surface added in cloud-website-hosting P1:

      POST   /v1/sites
      GET    /v1/sites
      GET    /v1/sites/:id
      POST   /v1/sites/:id/deploy
      GET    /v1/sites/:id/deployments
      POST   /v1/sites/:id/env
      POST   /v1/sites/:id/domains
      GET    /v1/tls/ask?domain=...

  And the cross-team isolation: a Site is reachable only to its owning Team;
  other teams get 404 (existence-leak protection), never 403.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Sites, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Cloudflare.Fake, as: CfFake
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Sites.FakeBoxRelay
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"
  @instance_admin_token "instance-admin-token-plaintext"

  ## Fixtures

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # deploy-reliability W14 S4. Every other fixture in this file hands back an
  # OWNER — `user_with_team/0` hardcodes the role — which is exactly why the
  # role-blindness of the deploy-reporting reads was invisible to 101 tests.
  # This one joins a SECOND user to an existing team at the lowest role there is.
  defp member_of(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    user
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # site-spawner: a LIVE instance — url + encrypted admin token, i.e. what the
  # provision-succeed path writes. Both are required before the control plane can
  # mint a token on it or drive a deploy.
  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> BarkparkCloud.Repo.update!()
  end

  # A content-bound static site with its read token already at rest (the mint is
  # exercised separately, through the create route).
  defp static_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_public_read_xyz"
        })
      )

    site
  end

  # site-spawner W7: a content-bound NODE site (the node-slot SSR runtime target)
  # with its read token at rest AND a port_base allocated. The create ROUTE folds
  # port_base in through NodePortAllocator; this fixture bypasses the route, so it
  # sets the base explicitly (blue=7002, green=7003).
  defp node_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "SSR #{n}",
          slug: "ssr-#{n}",
          kind: "node",
          framework: "nextjs",
          bootstrap_workspace: "acme",
          bootstrap_project: "app",
          bootstrap_dataset: "production",
          read_token: "bpt_public_read_xyz"
        })
      )

    site
    |> Ecto.Changeset.change(port_base: Map.get(attrs, :port_base, 7002))
    |> BarkparkCloud.Repo.update!()
  end

  ## Request helpers

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

  # Like call/4 but ships a raw octet-stream body — used by the artifact
  # upload tests so the body isn't JSON-encoded.
  defp call_binary(method, path, body, token) when is_binary(body) do
    conn =
      conn(method, path, body)
      |> put_req_header("content-type", "application/octet-stream")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp sha256_hex(bytes),
    do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # site-spawner W9: a content-bound static site that has OPTED IN to accepting
  # builds produced somewhere other than its box.
  defp prebuilt_site(bp, attrs \\ %{}) do
    {:ok, site} = Registry.update_site_settings(static_site(bp, attrs), %{prebuilt_enabled: true})
    site
  end

  # Mint a prebuilt deployment through the real route and hand back its JSON —
  # every upload test starts from a row that exists but has NOT been started.
  defp mint_prebuilt(site, token) do
    conn = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)
    assert conn.status == 201
    json_body(conn)["deployment"]
  end

  # What the deployment row looked like AT THE INSTANT its driver was started —
  # left in THIS process's dictionary by the configured test starter
  # (`Sites.Deploy.NoopStarter`). An ordering nothing can observe is an ordering
  # nothing protects, and an after-the-fact DB read cannot see it: by then both
  # writes have landed.
  defp started_snapshot(deployment_id), do: Process.get({:deploy_started, deployment_id})

  ## POST /v1/sites — create

  describe "POST /v1/sites" do
    test "creates a site under a barkpark of the same team → 201" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "Shop", framework: "nextjs"},
          token
        )

      assert conn.status == 201
      body = json_body(conn)
      assert body["site"]["name"] == "Shop"
      assert body["site"]["slug"] == "shop"
      assert body["site"]["framework"] == "nextjs"
      assert body["site"]["barkpark_id"] == bp.id
      assert body["site"]["team_id"] == team.id
      # env_encrypted is never serialized
      refute Map.has_key?(body["site"], "env_encrypted")
    end

    test "barkpark belongs to another team → 404 (no existence leak)" do
      {other_user, other_team} = user_with_team()
      other_bp = barkpark_fixture(other_team)
      _ = other_user

      {user, _team} = user_with_team()
      token = login_token(user)

      conn = call(:post, "/v1/sites", %{barkpark_id: other_bp.id, name: "Shop"}, token)

      assert conn.status == 404
      assert json_body(conn)["error"] == "barkpark_not_found"
    end

    test "missing name → 422" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      token = login_token(user)

      conn = call(:post, "/v1/sites", %{barkpark_id: bp.id}, token)

      assert conn.status == 422
    end

    test "without auth → 401" do
      conn = call(:post, "/v1/sites", %{barkpark_id: "x", name: "Shop"})
      assert conn.status == 401
    end
  end

  ## GET /v1/sites — list

  describe "GET /v1/sites" do
    test "lists the team's sites" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _s1} = Registry.create_site(bp, %{name: "A", slug: "a"})
      {:ok, _s2} = Registry.create_site(bp, %{name: "B", slug: "b"})
      token = login_token(user)

      conn = call(:get, "/v1/sites", nil, token)

      assert conn.status == 200
      slugs = Enum.map(json_body(conn)["sites"], & &1["slug"])
      assert Enum.sort(slugs) == ["a", "b"]
    end

    test "does NOT list another team's sites" do
      {_o, other_team} = user_with_team()
      other_bp = barkpark_fixture(other_team)
      {:ok, _} = Registry.create_site(other_bp, %{name: "Secret", slug: "secret"})

      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.create_site(bp, %{name: "Mine", slug: "mine"})
      token = login_token(user)

      conn = call(:get, "/v1/sites", nil, token)

      slugs = Enum.map(json_body(conn)["sites"], & &1["slug"])
      assert slugs == ["mine"]
    end

    # stw4-freshness (charter D24): each row carries the SLIM batched
    # last_deployment embed — status/trigger/timestamps only (never console /
    # build_log_url / content_rev) — nil-honest for a site that never deployed.
    test "rows carry a slim last_deployment embed (nil-honest when absent)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, deployed} = Registry.create_site(bp, %{name: "Deployed", slug: "deployed"})
      {:ok, _fresh} = Registry.create_site(bp, %{name: "Fresh", slug: "fresh"})

      {:ok, _d} =
        Registry.create_deployment(deployed, %{git_ref: "main", trigger: "content-auto"})

      token = login_token(user)

      conn = call(:get, "/v1/sites", nil, token)
      assert conn.status == 200

      rows = Map.new(json_body(conn)["sites"], fn r -> {r["slug"], r} end)

      last = rows["deployed"]["last_deployment"]
      assert last["status"] == "queued"
      assert last["trigger"] == "content-auto"
      assert last["inserted_at"]
      assert last["updated_at"]
      # HONESTY LAW: no build internals ride the embed.
      refute Map.has_key?(last, "console")
      refute Map.has_key?(last, "build_log_url")
      refute Map.has_key?(last, "content_rev")

      # A never-deployed site is nil-honest, not a fabricated pending state.
      assert Map.get(rows["fresh"], "last_deployment") == nil
    end
  end

  ## GET /v1/sites/:id — show

  describe "GET /v1/sites/:id" do
    test "team's own site → 200" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn = call(:get, "/v1/sites/#{site.id}", nil, token)
      assert conn.status == 200
      assert json_body(conn)["site"]["id"] == site.id
    end

    test "another team's site → 404 (no existence leak)" do
      {_o, other_team} = user_with_team()
      other_bp = barkpark_fixture(other_team)
      {:ok, other_site} = Registry.create_site(other_bp, %{name: "S", slug: "s"})

      {user, _team} = user_with_team()
      token = login_token(user)

      conn = call(:get, "/v1/sites/#{other_site.id}", nil, token)
      assert conn.status == 404
    end
  end

  ## POST /v1/sites/:id/deploy — enqueue a Deployment (the build job)

  describe "POST /v1/sites/:id/deploy" do
    test "a connected repo → 201 queued Deployment" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      # Connect a GitHub repo so the deploy has a build source.
      {:ok, _site} = Registry.set_site_github(site, "owner/repo", "main", "shh")
      token = login_token(user)

      conn =
        call(:post, "/v1/sites/#{site.id}/deploy", %{git_ref: "main"}, token)

      assert conn.status == 201
      body = json_body(conn)
      assert body["deployment"]["status"] == "queued"
      assert body["deployment"]["site_id"] == site.id
      assert body["deployment"]["git_ref"] == "main"
    end

    test "a repeat deploy of the same active ref → 200 the existing row (no duplicate)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      {:ok, _site} = Registry.set_site_github(site, "owner/repo", "main", "shh")
      token = login_token(user)

      first = call(:post, "/v1/sites/#{site.id}/deploy", %{git_ref: "main"}, token)
      assert first.status == 201
      first_id = json_body(first)["deployment"]["id"]

      # A double-click / client retry must coalesce onto the still-active row.
      second = call(:post, "/v1/sites/#{site.id}/deploy", %{git_ref: "main"}, token)
      assert second.status == 200
      assert json_body(second)["deployment"]["id"] == first_id

      # Exactly one production Deployment exists for this ref.
      assert length(Registry.list_deployments(site, 10, environment: "production")) == 1
    end

    test "an uploaded artifact → 201 queued Deployment" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{git_ref: "main", artifact_url: "file:///tmp/artifact.tar.gz"},
          token
        )

      assert conn.status == 201
      body = json_body(conn)
      assert body["deployment"]["status"] == "queued"
      assert body["deployment"]["artifact_url"] == "file:///tmp/artifact.tar.gz"
    end

    test "no artifact AND no connected repo → 422 no_build_source" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{git_ref: "main"}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "no_build_source"
      # No un-buildable row was minted.
      assert Registry.list_deployments(site, 10, environment: "production") == []
    end

    test "other team's site → 404" do
      {_o, other_team} = user_with_team()
      other_bp = barkpark_fixture(other_team)
      {:ok, other_site} = Registry.create_site(other_bp, %{name: "S", slug: "s"})

      {user, _team} = user_with_team()
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{other_site.id}/deploy", %{}, token)
      assert conn.status == 404
    end
  end

  ## GET /v1/sites/:id/deployments

  describe "GET /v1/sites/:id/deployments" do
    test "lists the site's deployments, newest first" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      # Settled between mints: deploy-truth W1 re-keyed the active index onto
      # (site_id, environment), so a site's HISTORY has many rows but only ever
      # one build in flight.
      {:ok, d1} = Registry.create_deployment(site, %{git_ref: "a"})
      {:ok, _} = Registry.transition_deployment(d1, %{status: "failed"})
      {:ok, _d2} = Registry.create_deployment(site, %{git_ref: "b"})
      token = login_token(user)

      conn = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      assert conn.status == 200
      assert length(json_body(conn)["deployments"]) == 2
    end

    test "?limit= caps the newest-first window" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      # One build in flight per site (deploy-truth W1) — settle as we go.
      for ref <- ~w(a b) do
        {:ok, d} = Registry.create_deployment(site, %{git_ref: ref})
        {:ok, _} = Registry.transition_deployment(d, %{status: "failed"})
      end

      {:ok, _d3} = Registry.create_deployment(site, %{git_ref: "c"})
      token = login_token(user)

      capped = call(:get, "/v1/sites/#{site.id}/deployments?limit=2", nil, token)
      assert capped.status == 200
      deps = json_body(capped)["deployments"]
      assert length(deps) == 2
      assert Enum.map(deps, & &1["git_ref"]) == ["c", "b"]

      full = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      assert length(json_body(full)["deployments"]) == 3
    end

    # deploy-reliability W13 S3. W12 shipped the deferral WRITER
    # (`Sites.Deploy.defer/3` fills deferral_depth/bound/cause) and no reader:
    # this payload did not mention the columns, so the only route to a wait's
    # depth was a regex over the English in `failure_reason`. These keys are the
    # reader.
    #
    # IT CAN LOSE: delete the three `deferral_*` lines from
    # `deployment_json/1` and the presence assertions red; coerce a nil to 0 and
    # the non-deferred assertions red.
    test "the deferral chain reaches the wire, and a row with no chain says nil rather than 0" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})

      {:ok, deferred} = Registry.create_deployment(site, %{git_ref: "a"})

      {:ok, _} =
        Registry.transition_deployment(deferred, %{
          status: "deferred",
          deferral_depth: 3,
          deferral_bound: 12,
          deferral_cause: "BOX_AT_CAPACITY_DEFERRED"
        })

      {:ok, clean} = Registry.create_deployment(site, %{git_ref: "b"})
      token = login_token(user)

      conn = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      assert conn.status == 200
      rows = Map.new(json_body(conn)["deployments"], &{&1["id"], &1})

      chain = rows[deferred.id]
      assert chain["deferral_depth"] == 3
      assert chain["deferral_bound"] == 12
      # THE LEDGER CLASS, frozen at defer time — not a raw box code.
      assert chain["deferral_cause"] == "BOX_AT_CAPACITY_DEFERRED"

      # A row that never deferred carries NO chain, and the honest answer is
      # nil: a 0 here would read as "deferred zero times", which is a different
      # sentence from "nobody recorded a chain" — and it is the sentence 98.75%
      # of prod's deferred rows (every one written before migration
      # 20260807150000) would falsely tell.
      none = rows[clean.id]
      assert Map.has_key?(none, "deferral_depth")
      assert none["deferral_depth"] == nil
      assert none["deferral_bound"] == nil
      assert none["deferral_cause"] == nil
    end
  end

  ## deploy-reliability W14 S4 — WHO can read the owner's own deploy numbers.
  ##
  ## Two reads carry every owner-facing deployment number in this epic:
  ##
  ##     GET /v1/sites/:id/deployments   (the ledger list — `bp cloud site status`)
  ##     GET /v1/sites/:id               (the site's current deployment)
  ##
  ## Both are gated by the 2-arity `with_team_site(conn, fun)`, which defaults to
  ## `:session` (router.ex:11065) and runs `Auth.require_user/2` ONLY — the cond
  ## in its body is `halted -> is_nil(current_team) -> Registry.get_team_site`,
  ## with no Authz/role call anywhere; `resolve_team/2` asks for nothing beyond
  ## membership. GET /v1/sites/:id inlines the same three steps.
  ##
  ## THE REACHABILITY WAS GUARDED BY NOTHING. Every other test in this file logs
  ## in an OWNER (`user_with_team/0` hardcodes the role), so prepending
  ## `Auth.require_team_admin(conn, [])` to the list route reds ONLY the probes
  ## below while all 101 pre-existing tests here stay green. That is the shape of
  ## a guard that cannot lose, and these three tests are the guard that can.
  describe "deploy-reliability W14 S4: role reachability of the deploy-reporting reads" do
    # IT CAN LOSE: put any role gate on the list route and this reds 403 vs 200.
    test "a plain team MEMBER — not an owner — lists the site's deployments → 200 with rows" do
      {_owner, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      {:ok, d1} = Registry.create_deployment(site, %{git_ref: "a"})
      {:ok, _} = Registry.transition_deployment(d1, %{status: "failed"})
      {:ok, d2} = Registry.create_deployment(site, %{git_ref: "b"})

      member = member_of(team, "member")
      assert Accounts.get_membership(team, member).role == "member"

      conn = call(:get, "/v1/sites/#{site.id}/deployments", nil, login_token(member))

      assert conn.status == 200
      rows = json_body(conn)["deployments"]
      # Rows, not an empty 200: a gate that quietly filtered the ledger to
      # nothing would still answer 200, and that is the failure this asserts past.
      assert Enum.map(rows, & &1["id"]) |> Enum.sort() == Enum.sort([d1.id, d2.id])
    end

    # The same role blindness on the sibling read the dashboard opens first.
    test "a plain team MEMBER reads GET /v1/sites/:id → 200" do
      {_owner, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})

      member = member_of(team, "member")

      conn = call(:get, "/v1/sites/#{site.id}", nil, login_token(member))

      assert conn.status == 200
      assert json_body(conn)["site"]["id"] == site.id
    end

    # PINS TODAY'S PAT CONTRACT, deliberately — see the PR body for the cost.
    #
    # The refusal on the two reads above is CREDENTIAL-CLASS, not role-class: no
    # PAT of any tier reaches a `:session` route, so a read PAT is 401 (not 403 —
    # `require_user` never saw a session token) on both, while the single-
    # deployment poll, which is gated `{:ability, "read"}`, answers 200 on a REAL
    # row with the SAME token. A member's read PAT is equally 401.
    #
    # The consequence, stated so the pin is deliberate: no automation credential
    # can compute the owner's number, because `bp cloud site status` reads the
    # ledger through the session-only list route. Re-tiering it to
    # {:ability, "read"} sits inside cloud-console-hardening's auth fence and is
    # FILED, not built here (deploy-reliability charter D219).
    test "a read PAT is 401 on BOTH owner reads while the single-deployment poll is 200" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      {:ok, dep} = Registry.create_deployment(site, %{git_ref: "a"})

      {:ok, read_pat, stored} =
        Accounts.create_personal_access_token(user, team, %{
          name: "read-key",
          abilities: ["read"]
        })

      assert stored.abilities == ["read"]

      list = call(:get, "/v1/sites/#{site.id}/deployments", nil, read_pat)
      assert list.status == 401
      assert json_body(list)["error"] == "unauthorized"

      show = call(:get, "/v1/sites/#{site.id}", nil, read_pat)
      assert show.status == 401

      # The SAME token, on the SAME site, one path segment deeper — 200 on a real
      # row. The refusal above is therefore about the credential CLASS the route
      # accepts, not about what the token is allowed to read.
      poll = call(:get, "/v1/sites/#{site.id}/deployments/#{dep.id}", nil, read_pat)
      assert poll.status == 200
      assert json_body(poll)["deployment"]["id"] == dep.id
    end
  end

  ## POST /v1/sites/:id/env — encrypted env round-trip

  describe "POST /v1/sites/:id/env" do
    test "encrypts at rest; never serialized back" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      env = %{"DATABASE_URL" => "postgres://x", "SECRET" => "shh"}
      conn = call(:post, "/v1/sites/#{site.id}/env", %{env: env}, token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      # The env_encrypted column is populated, AND decrypts back to the same map.
      site = Registry.get_site(site.id)
      assert is_binary(site.env_encrypted)
      assert {:ok, ^env} = Registry.reveal_site_env(site)

      # The GET /v1/sites/:id surface NEVER echoes env_encrypted.
      show = call(:get, "/v1/sites/#{site.id}", nil, token)
      refute Map.has_key?(json_body(show)["site"], "env_encrypted")
      refute Map.has_key?(json_body(show)["site"], "env")
    end

    test "missing env body → 422" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/env", %{}, token)
      assert conn.status == 422
    end
  end

  ## POST /v1/sites/:id/domains + GET /v1/tls/ask

  describe "domains + on-demand TLS ask-gate" do
    test "added domain makes /v1/tls/ask?domain=... return 200" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      # Before: ask gate says no.
      pre = call(:get, "/v1/tls/ask?domain=acme.example.com")
      assert pre.status == 404

      # Add the domain.
      add = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "ACME.example.com"}, token)
      assert add.status == 200
      assert "acme.example.com" in json_body(add)["site"]["domains"]

      # After: ask gate says yes (case-insensitive).
      post = call(:get, "/v1/tls/ask?domain=acme.example.com")
      assert post.status == 200

      # Trailing dot is normalised away.
      post_dot = call(:get, "/v1/tls/ask?domain=acme.example.com.")
      assert post_dot.status == 200
    end

    test "unrelated domain stays 404 (DoS-protection)" do
      conn = call(:get, "/v1/tls/ask?domain=evil.example.com")
      assert conn.status == 404
    end

    test "empty domain → 404" do
      conn = call(:get, "/v1/tls/ask?domain=")
      assert conn.status == 404
    end

    test "invalid domain shape → 422" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "not a domain"}, token)
      assert conn.status == 422
    end
  end

  ## The hostname namespace — BOTH claim doors, and the route that frees a name
  ##
  ## `custom_host → site domain` was guarded from day one; `site domain →
  ## custom_host` was not, and the CREATE door ran no collision test at all
  ## (`POST /v1/sites` writes `domains` straight into `create_site/2` and never
  ## calls `add_site_domain/2`). Testing ONE door proves nothing about the other,
  ## so both are driven here over HTTP, plus the DELETE that makes a wrongly
  ## claimed name recoverable — before it existed, nothing short of deleting the
  ## whole site could free one.

  describe "site domains vs. an instance custom_host (both doors)" do
    test "ATTACH door: POST /v1/sites/:id/domains with another team's custom_host → 409" do
      # Team A attaches its own hostname to its own instance.
      {_owner, victim_team} = user_with_team()
      victim_bp = barkpark_fixture(victim_team)
      {:ok, _} = Registry.set_custom_host(victim_bp, "barkpark.jarl.no")

      # Team B points one of its sites at team A's live hostname.
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "Grab", slug: "grab-attach"})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "barkpark.jarl.no"}, token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "domain_taken"

      # Nothing was written, so the UNAUTHENTICATED ask-gate still resolves the
      # name to no site at all — which is the reachable half of the takeover.
      assert BarkparkCloud.Repo.get!(Registry.Site, site.id).domains == []
      assert Registry.domain_owner_site("barkpark.jarl.no") == nil
    end

    test "CREATE door: POST /v1/sites with the same hostname in `domains` → 409, and NO site row" do
      {_owner, victim_team} = user_with_team()
      victim_bp = barkpark_fixture(victim_team)
      {:ok, _} = Registry.set_custom_host(victim_bp, "barkpark.jarl.no")

      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      token = login_token(user)
      before = BarkparkCloud.Repo.aggregate(Registry.Site, :count)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "Grab", domains: ["barkpark.jarl.no"]},
          token
        )

      assert conn.status == 409
      assert json_body(conn)["error"] == "domain_taken"

      # Fixing only the attach door would be theatre: the grabber would just
      # create the site with the name instead of attaching it afterwards.
      assert BarkparkCloud.Repo.aggregate(Registry.Site, :count) == before
      assert Registry.domain_owner_site("barkpark.jarl.no") == nil
    end

    test "CREATE door: a site-held hostname is refused too, and a FREE one still creates" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      token = login_token(user)

      {:ok, holder} = Registry.create_site(bp, %{name: "Holder", slug: "holder-cd"})
      {:ok, _} = Registry.add_site_domain(holder, "held.example.com")

      taken =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "Dup", domains: ["held.example.com"]},
          token
        )

      assert taken.status == 409

      free =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "Fresh", domains: ["FRESH.example.com"]},
          token
        )

      assert free.status == 201
      assert json_body(free)["site"]["domains"] == ["fresh.example.com"]
    end

    test "DELETE /v1/sites/:id/domains frees the name — and only then can another team claim it" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "Holder", slug: "holder-del"})
      token = login_token(user)

      add = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "release.example.com"}, token)
      assert add.status == 200
      assert "release.example.com" in json_body(add)["site"]["domains"]
      assert call(:get, "/v1/tls/ask?domain=release.example.com").status == 200

      # A second team cannot take it while it is held.
      {other_user, other_team} = user_with_team()
      other_bp = barkpark_fixture(other_team)
      {:ok, other_site} = Registry.create_site(other_bp, %{name: "Next", slug: "next-del"})
      other_token = login_token(other_user)

      blocked =
        call(
          :post,
          "/v1/sites/#{other_site.id}/domains",
          %{domain: "release.example.com"},
          other_token
        )

      assert blocked.status == 409

      # The holder releases it over HTTP. Before this route there was no way to:
      # PATCH /v1/sites/:id touches only theme/doc_type/prebuilt_enabled and
      # Registry.remove_site_domain/2 had zero router callers. The mixed-case
      # spelling proves the release runs the SAME normalization the claim does.
      del =
        call(:delete, "/v1/sites/#{site.id}/domains", %{domain: "RELEASE.example.com"}, token)

      assert del.status == 200
      refute "release.example.com" in json_body(del)["site"]["domains"]
      assert call(:get, "/v1/tls/ask?domain=release.example.com").status == 404

      # A 200 also proves `site.domain_removed` is a declared audit verb: the
      # event and the update share one transaction, so an unknown verb would have
      # rolled the removal back into a 422.
      assert Enum.any?(
               Accounts.list_audit_events(team),
               &(&1.action == "site.domain_removed")
             )

      # …and now the name is genuinely free.
      freed =
        call(
          :post,
          "/v1/sites/#{other_site.id}/domains",
          %{domain: "release.example.com"},
          other_token
        )

      assert freed.status == 200
    end

    test "DELETE /v1/sites/:id/domains is team-scoped (a stranger gets 404, never 403)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "Holder", slug: "holder-scope"})
      token = login_token(user)

      assert call(:post, "/v1/sites/#{site.id}/domains", %{domain: "scoped.example.com"}, token).status ==
               200

      {stranger, _stranger_team} = user_with_team()

      conn =
        call(
          :delete,
          "/v1/sites/#{site.id}/domains",
          %{domain: "scoped.example.com"},
          login_token(stranger)
        )

      assert conn.status == 404
      assert "scoped.example.com" in BarkparkCloud.Repo.get!(Registry.Site, site.id).domains
    end

    test "DELETE /v1/sites/:id/domains without a domain → 422" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "Holder", slug: "holder-422"})

      conn = call(:delete, "/v1/sites/#{site.id}/domains", %{}, login_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "domain_required"
    end
  end

  ## POST /v1/sites/:id/artifact — RETIRED (site-spawner W10).
  ##
  ## The site-scoped upload route is GONE, and this describe block is what keeps it
  ## gone. It inserted a SiteArtifact with a site_id and NO deployment_id, while
  ## the only read (`Sites.Deploy.artifact_for/1`) and the only delete
  ## (`drop_artifact/1`) both key on deployment_id — so every row it wrote was a
  ## permanent up-to-32 MB bytea nothing could find and nothing could reap. Its
  ## six W9 tests all asserted the STORE worked; none asserted anyone could ever
  ## read what was stored, which is why the leak shipped green.
  ##
  ## Restore the route and the first test goes red (201 instead of 404).

  describe "POST /v1/sites/:id/artifact (retired)" do
    test "the site-scoped upload path no longer exists → 404, and NOTHING is stored" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "Demo", slug: "demo-retired"})
      token = login_token(user)

      conn = call_binary(:post, "/v1/sites/#{site.id}/artifact", "tarball-bytes", token)

      # 404 from the router's fall-through `match _`, not from the site lookup:
      # the path itself is unrouted now.
      assert conn.status == 404

      # The whole point: an unrouted POST cannot leave an orphan behind.
      assert BarkparkCloud.Repo.aggregate(BarkparkCloud.Registry.SiteArtifact, :count) == 0
    end

    test "the DEPLOYMENT-scoped route is the replacement and still binds its bytes" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      dep = mint_prebuilt(site, token)

      conn =
        call_binary(
          :post,
          "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact",
          "real-bytes",
          token
        )

      assert conn.status == 201

      # Bound at INSERT — findable by artifact_for/1, reapable by drop_artifact/1.
      # That is the whole difference from the route retired above.
      stored = Sites.Deploy.artifact_for(dep["id"])
      assert stored.deployment_id == dep["id"]
      assert stored.site_id == site.id
      assert stored.bytes == "real-bytes"
    end
  end

  ## THE TYPED REFUSAL HAS TO REACH THE USER (site-spawner W10).
  ##
  ## The box answers every refusal NESTED: `BarkparkWeb.SiteDeployController`'s
  ## `bad_request/3`, `feature_not_configured/1` and `build_id_mismatch/3` all
  ## render `%{error: %{code: …, message: …}}`, and `Registry.relay_with/5` decodes
  ## it with string keys. `box_refusal/2` read a FLAT `body["error"]`, so it bound
  ## a map, failed its `is_binary` guard, and produced the bare "the instance
  ## refused the deploy (HTTP 400)" — which made all eighteen typed codes
  ## (`invalid_artifact`, `invalid_artifact_digest`, `artifact_too_large`, the
  ## `DeployRequest` validation set …) invisible, and the refusals that name their
  ## cause most precisely the ones that named it least. There is no BPSTAGE line
  ## to fall back on either: a request-decode refusal happens BEFORE
  ## `site-deploy.sh` runs, so there are no stages at all.
  ##
  ## Revert `refusal_detail/1`'s nested clause and the first test goes red.

  describe "site-spawner W10: a typed box refusal travels intact" do
    test "the box's NESTED %{error: %{code, message}} lands in failure_reason, both halves" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      # Byte-for-byte the shape `SiteDeployController.bad_request/3` renders, with
      # a real `DeployRequest` code (deploy_request.ex:314) — read off the actual
      # decode site (`Registry.relay_with/5` → `Jason.decode` → string keys), not
      # assumed.
      FakeBoxRelay.program(
        start:
          {:ok, 400,
           %{
             "error" => %{
               "code" => "invalid_artifact_digest",
               "message" => "artifact_sha256 must be 64 lowercase hex characters"
             }
           }}
      )

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      reason = Registry.get_deployment(d.id).failure_reason
      assert reason =~ "invalid_artifact_digest"
      assert reason =~ "artifact_sha256 must be 64 lowercase hex characters"
      assert reason =~ "HTTP 400"
    end

    test "a nested error with only a code still names the code" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      FakeBoxRelay.program(start: {:ok, 503, %{"error" => %{"code" => "feature_not_configured"}}})

      assert {:ok, :failed} = Sites.Deploy.run(d.id)
      assert Registry.get_deployment(d.id).failure_reason =~ "feature_not_configured"
    end

    test "a FLAT string body still works — the pre-existing arm is not regressed" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      FakeBoxRelay.program(start: {:ok, 409, %{"error" => "another deploy holds the lock"}})

      # deploy-truth W1: a 409 is the box's ONE transient refusal, so the row
      # settles `deferred` (with a re-queued rebuild) rather than terminal-
      # `failed`. What this test guards is unchanged: the FLAT body's words still
      # travel intact.
      assert {:ok, :deferred} = Sites.Deploy.run(d.id)
      assert Registry.get_deployment(d.id).failure_reason =~ "another deploy holds the lock"
    end

    test "an UNREADABLE body degrades to the status alone rather than crashing" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      # `relay_with/5`'s own fallback for a body it cannot decode as an object.
      FakeBoxRelay.program(start: {:ok, 502, %{}})

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      assert Registry.get_deployment(d.id).failure_reason ==
               "the instance refused the deploy (HTTP 502)"
    end
  end

  ## THE TYPED REFUSAL HAS TO SURVIVE THE JSON BOUNDARY TOO (site-spawner W11).
  ##
  ## W10 above proved STORAGE: all four of its tests read
  ## `Registry.get_deployment(d.id).failure_reason` — the RAW DB column. The user
  ## never sees that column. `deployment_json/1` renders
  ## `FailureCopy.humanize(d.failure_reason)`, and `humanize/1` is a cond of
  ## SUBSTRING matches that replaces the WHOLE string.
  ##
  ## Nine of the extractor's typed messages interpolate a PRODUCER-CONTROLLED tar
  ## entry name (`Barkpark.Sites.PrebuiltArtifact` — E_ABSOLUTE_PATH,
  ## E_PATH_TRAVERSAL, E_BAD_NAME, E_UNSAFE_PARENT x3, E_WRITE_FAILED x2), so the
  ## refusal on a site whose content includes `/quota/index.html` rendered here as
  ## the capacity class (then "Hetzner ran out of server capacity", now the
  ## provider-neutral copy), and a `../timeout/` PATH TRAVERSAL — a
  ## security event — as "A network step timed out." The SAME response already
  ## carried the honest bytes in `detail` (`Sites.Deploy.fail/2` writes the
  ## identical string to both columns; only `failure_reason` was humanized), so the
  ## payload contradicted itself.
  ##
  ## These are the repo's first tests driving a real extractor `E_*` code across
  ## that boundary. Delete `FailureCopy`'s `typed_refusal?(reason) -> reason`
  ## clause and they go red on canned provider copy.

  # The user-facing read of one deployment: what `deployment_json/1` renders, not
  # the raw DB column. Every W11 test below reads through it.
  defp rendered_deployment(site, d, token) do
    json_body(call(:get, "/v1/sites/#{site.id}/deployments/#{d.id}", nil, token))["deployment"]
  end

  describe "site-spawner W11: a typed extractor refusal survives deployment_json/1" do
    test "E_ABSOLUTE_PATH on /quota/index.html reaches the user as itself, not as Hetzner capacity" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      # prebuilt_artifact.ex:626, byte-for-byte, nested exactly as
      # SiteDeployController.bad_request/3 renders it.
      FakeBoxRelay.program(
        start:
          {:ok, 400,
           %{
             "error" => %{
               "code" => "E_ABSOLUTE_PATH",
               "message" => ~s(entry "/quota/index.html" is an absolute path — refused)
             }
           }}
      )

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      raw = Registry.get_deployment(d.id).failure_reason

      assert raw ==
               ~s|the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry "/quota/index.html" is an absolute path — refused|

      dep = rendered_deployment(site, d, token)

      # THE BOUNDARY: what the CLI and the dashboard actually read.
      assert dep["failure_reason"] == raw,
             ~s(rendered failure_reason diverged from the raw refusal:\n  raw      = #{raw}\n  rendered = #{dep["failure_reason"]})

      assert dep["failure_reason"] =~ "E_ABSOLUTE_PATH"
      assert dep["failure_reason"] =~ "/quota/index.html"

      refute dep["failure_reason"] =~
               "A capacity or quota limit was reached at the hosting provider"
    end

    test "a PATH TRAVERSAL is never rendered as a network timeout" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start:
          {:ok, 400,
           %{
             "error" => %{
               "code" => "E_PATH_TRAVERSAL",
               "message" => ~s(entry "../timeout/index.html" escapes the artifact root)
             }
           }}
      )

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      dep = rendered_deployment(site, d, token)

      assert dep["failure_reason"] =~ "E_PATH_TRAVERSAL"
      assert dep["failure_reason"] =~ "escapes the artifact root"

      refute dep["failure_reason"] =~ "A network step timed out",
             "a traversal refusal is a SECURITY event — it must never read as a retryable blip"
    end

    test "the BASELINE non-colliding refusal (the accented-slug E_UNKNOWN_TYPE) arrives intact too" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      # The headline defect of this wave: Go emits a PAX ('x') header for a
      # non-ASCII entry name, and the extractor refuses it (prebuilt_artifact.ex:572).
      FakeBoxRelay.program(
        start:
          {:ok, 400,
           %{
             "error" => %{
               "code" => "E_UNKNOWN_TYPE",
               "message" => ~s(unsupported tar entry type "x")
             }
           }}
      )

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      dep = rendered_deployment(site, d, token)

      assert dep["failure_reason"] =~ "E_UNKNOWN_TYPE"
      assert dep["failure_reason"] =~ ~s(unsupported tar entry type "x")
    end

    test "every colliding static-site slug keeps its typed code across the boundary" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      # Ordinary static-site paths: /quota and /dns/failed.html are content slugs,
      # and timeout.html / unauthorized.html are what framework error pages are
      # CALLED. Each is a single common English word inside a producer-controlled
      # name — which is why the token list can never be made safe.
      cases = [
        {"E_ABSOLUTE_PATH", ~s(entry "/quota/index.html" is an absolute path — refused),
         "A capacity or quota limit was reached at the hosting provider"},
        {"E_ABSOLUTE_PATH", ~s(entry "/timeout.html" is an absolute path — refused),
         "A network step timed out"},
        {"E_ABSOLUTE_PATH", ~s(entry "/unauthorized.html" is an absolute path — refused),
         "A credential was rejected."},
        {"E_PATH_TRAVERSAL", ~s(entry "../dns/failed.html" escapes the artifact root),
         "Securing the domain failed on the provider side."}
      ]

      for {code, message, canned} <- cases do
        site = static_site(bp)
        {:ok, d} = Sites.Deploy.enqueue(site, bp)

        FakeBoxRelay.program(
          start: {:ok, 400, %{"error" => %{"code" => code, "message" => message}}}
        )

        assert {:ok, :failed} = Sites.Deploy.run(d.id)

        dep = rendered_deployment(site, d, token)

        assert dep["failure_reason"] =~ code, "#{code} lost for #{message}"
        assert dep["failure_reason"] =~ message
        refute dep["failure_reason"] =~ canned
      end
    end

    test "failure_reason and detail in the SAME response agree about the typed code" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start:
          {:ok, 400,
           %{
             "error" => %{
               "code" => "E_UNSAFE_PARENT",
               "message" => ~s(the archive names "/srv/blog/quota/index.html" more than once)
             }
           }}
      )

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      dep = rendered_deployment(site, d, token)

      # `Sites.Deploy.fail/2` writes the SAME string to failure_reason and detail;
      # `detail` is passed through RAW. Before W11 the humanize hop made the two
      # halves of one payload contradict each other. They must agree now.
      assert dep["detail"] =~ "E_UNSAFE_PARENT"
      assert dep["failure_reason"] == dep["detail"]
    end

    test "an UNTYPED provider failure is still humanized — the guard is not a blanket bypass" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # A reason with no typed code and no box-refusal prefix: the reaper/provider
      # jargon FailureCopy exists for. Written straight onto the row because no box
      # path produces it — the point here is the JSON boundary, not the producer.
      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      d
      |> Ecto.Changeset.change(
        status: "failed",
        failure_reason: "account quota exceeded for servers"
      )
      |> BarkparkCloud.Repo.update!()

      dep = rendered_deployment(site, d, token)

      assert dep["failure_reason"] ==
               "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."
    end
  end

  ## site-spawner (D28/D29/D30) — the STATIC spawn spine.
  ##
  ## Everything below is the wire the `bp cloud site` CLI already speaks. The CLI
  ## is merged and green against its own fakes, and was NEVER run against a real
  ## router — so every shape mismatch here is a SILENT failure in the product (a
  ## blank progress bar, a checkmark for a rollback that never happened). These
  ## tests are the contract.

  describe "site-spawner: POST /v1/sites (create + content binding + read-token mint)" do
    test "accepts the CLI's OWN keys (workspace/project/dataset), mints the read token, and 201s a CONTENT-BOUND site" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      # The instance mints the site's public-read token over the SCOPED route.
      # (The unscoped /v1/tokens 404s — the scoping is the tenant isolation.)
      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          # EXACTLY what cloudclient.SpawnSiteCreate sends — not bootstrap_*.
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            framework: "astro",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 201
      site_json = json_body(conn)["site"]

      # The binding was STORED (Ecto's cast/3 used to discard these keys silently,
      # producing a cheerful 201 for a site bound to nothing).
      assert site_json["bootstrap_workspace"] == "acme"
      assert site_json["bootstrap_dataset"] == "production"
      # …and echoed back in the CLI's vocabulary.
      assert site_json["workspace"] == "acme"
      assert site_json["dataset"] == "production"
      assert site_json["url"] == "#{@instance_url}/sites/blog/"

      # A 201 MEANS content-bound: the token was minted and encrypted at rest.
      assert site_json["content_bound"] == true
      site = Registry.get_site(site_json["id"])
      assert is_binary(site.read_token_encrypted)
      assert {:ok, "bpt_public_read_minted"} = Registry.reveal_site_read_token(site)

      # The plaintext token NEVER appears on the wire.
      refute conn.resp_body =~ "bpt_public_read_minted"

      # It was minted over the SCOPED route with the instance's admin token.
      # Create makes TWO outbound calls now: this read-token mint AND a
      # best-effort content-publish webhook registration (site-spawner W5,
      # `maybe_register_content_webhook/3`). Pick the mint by its path rather
      # than asserting a single request — the registration is fire-and-forget.
      assert %{url: url, headers: headers, body: body} =
               Enum.find(StudioLinkFakeHttpClient.requests(), fn r ->
                 String.contains?(r.url, "/v1/tokens")
               end)

      assert url == "#{@instance_url}/w/acme/p/blog/v1/tokens"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(headers, "Authorization", 0)

      # …and the relay carried a real BODY (the self-update relay hard-codes "{}",
      # which cannot mint anything).
      decoded = Jason.decode!(body)
      assert decoded["permissions"] == ["public-read"]
      assert decoded["dataset"] == "production"

      # The content-publish webhook registration MUST carry a non-blank `name`:
      # the box's webhook changeset validate_required([:name, :url]), so a body
      # without a name 422s and the registration silently fails (the site never
      # auto-rebuilds on publish). Regression guard for that gap.
      # stw9 (charter D56): registration is now list-then-create-by-name, so the
      # webhook traffic is a GET (the lookup, empty body) followed by the WRITE.
      # Match the write specifically — matching any /v1/webhooks/ request would
      # pick the lookup and decode an empty body.
      wh_req =
        Enum.find(StudioLinkFakeHttpClient.requests(), fn r ->
          r.method in [:post, :put] and String.contains?(r.url, "/v1/webhooks/")
        end)

      assert wh_req, "create must register the content-publish webhook on the box"
      wh_body = Jason.decode!(wh_req.body)
      assert is_binary(wh_body["name"]) and wh_body["name"] != ""
      assert wh_body["events"] == ["publish", "unpublish", "delete"]
    end

    test "an instance that refuses the mint → 502 naming the box, and NO ghost site row" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" => {:ok, %{status: 403, body: ~s({"error":"forbidden"})}}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 502
      body = json_body(conn)
      assert body["error"] == "read_token_mint_failed"
      assert body["detail"] =~ bp.slug
      # A FLAT `{"error": "..."}` body carries its word straight through — the
      # box's own refusal survives into the console-facing detail, unchanged.
      assert body["detail"] =~ "forbidden"
      # BYTE-IDENTITY PIN: the flat arm is untouched by the nested-envelope fix,
      # so the whole detail string is exactly the pre-fix output — slug, the
      # `(HTTP <status>)` framing, then `: <box word>`. A regression that widened
      # the flat path (e.g. re-wrapping it) breaks this equality.
      assert body["detail"] ==
               "#{bp.slug} refused to mint the site's read token (HTTP 403): forbidden"

      # A site that cannot read its content is not a site. Nothing was written.
      assert Registry.list_sites_for_team(team) == []
    end

    # cch-w70-bl: the box's refusal may arrive wrapped in a TYPED ENVELOPE
    # (`{"error": {"code": ..., "message": ...}}`), not flat — TokenController's
    # 422 unprocessable. mint_failure_copy/2 used to read `body["error"]`, get a
    # MAP, fail the is_binary guard, and discard the box's message — the third
    # box-word-discarding chain, sibling of the rollback/teardown relay drop.
    # Before the fix the detail was `bp-<n> refused to mint the site's read token
    # (HTTP 422)` with the box's code and message ABSENT. It must now compose the
    # machine `code` and the human `message` as `code — message`.
    test "a nested 422 unprocessable mint refusal → 502 composing code — message, and NO ghost row" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok,
           %{
             status: 422,
             body:
               ~s({"error":{"code":"unprocessable","message":"permissions [\\"write\\"] not allowed"}})
           }}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 502
      body = json_body(conn)
      assert body["error"] == "read_token_mint_failed"
      # Names WHICH box, carries the `(HTTP 422)` framing…
      assert body["detail"] =~ bp.slug
      assert body["detail"] =~ "(HTTP 422)"
      # …AND surfaces WHAT it said — the code AND the message inside the typed
      # envelope, composed `code — message`, no longer discarded by the guard.
      assert body["detail"] =~ "unprocessable"
      assert body["detail"] =~ "permissions"
      assert body["detail"] =~ "not allowed"
      assert body["detail"] =~ "unprocessable — permissions"
      # A site that cannot read its content is not a site. Nothing was written.
      assert Registry.list_sites_for_team(team) == []
    end

    # cch-w70-bl: the 401/403 auth plugs on the scoped token route ALSO nest
    # their refusal (`{"error": {"code": "forbidden", "message": ...}}`), not just
    # TokenController's 422. The same nested-envelope unwrap must carry the plug's
    # words through, composed `code — message` like the 422 arm (and the helper
    # degrades to the bare human string when an envelope carries no code).
    test "a nested 403 scoped-plug mint refusal → 502 carrying the plug's message, and NO ghost row" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok,
           %{
             status: 403,
             body:
               ~s({"error":{"code":"forbidden","message":"admin token cannot mint public-read here"}})
           }}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 502
      body = json_body(conn)
      assert body["error"] == "read_token_mint_failed"
      assert body["detail"] =~ bp.slug
      assert body["detail"] =~ "(HTTP 403)"
      assert body["detail"] =~ "forbidden — admin token cannot mint public-read here"
      # A site that cannot read its content is not a site. Nothing was written.
      assert Registry.list_sites_for_team(team) == []
    end

    ## site-spawner W8 (charter D73/D74/D75) — CREATE READS THE BINDING BACK.
    ##
    ## Everything below exists because `content_bound: true` meant only "a token
    ## was minted" — a field every content-bound site sets, so it discriminated
    ## nothing. A typo'd dataset or an unreadable doc_type 201'd, and the build
    ## died minutes later on `BarkparkNotFoundError: document not found`, naming
    ## neither the type, nor the dataset, nor a remedy.

    test "relay_as carries the CALLER's bearer; relay_admin still carries the instance admin token" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      path = "/w/acme/p/blog/v1/data/query/production/post"

      StudioLinkFakeHttpClient.program(%{
        path => {:ok, %{status: 200, body: ~s({"result":{"count":3,"documents":[]}})}}
      })

      # Same transport, same {:ok, status, decoded} contract — only the bearer differs.
      assert {:ok, 200, %{"result" => %{"count" => 3}}} =
               Registry.relay_as(bp, :get, path, "site-read-token-plaintext")

      assert {:ok, 200, %{"result" => %{"count" => 3}}} =
               Registry.relay_admin(bp, :get, path, nil)

      [as_req, admin_req] = StudioLinkFakeHttpClient.requests()

      # THE point of the sibling (charter D74): the site's clamped credential goes
      # on the wire, NOT the instance admin token — an admin relay would report
      # content the build's token cannot see, manufacturing a new false green.
      assert List.keyfind(as_req.headers, "Authorization", 0) ==
               {"Authorization", "Bearer site-read-token-plaintext"}

      assert List.keyfind(admin_req.headers, "Authorization", 0) ==
               {"Authorization", "Bearer " <> @instance_admin_token}

      # …over the SAME URL, i.e. the shared body really is shared.
      assert as_req.url == admin_req.url
      assert as_req.url == "#{@instance_url}#{path}"

      # A box with no URL, or a blank bearer, is :not_live — never a silent nil call.
      assert Registry.relay_as(%Registry.Barkpark{url: nil}, :get, path, "t") ==
               {:error, :not_live}

      assert Registry.relay_as(bp, :get, path, "") == {:error, :not_live}
    end

    test "a binding the site's OWN token reads as EMPTY → 422 with the real menu, the re-run, and NO site row" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}},
        # The bound type: interpretable, and it shows NOTHING. That is a refusal.
        "/w/acme/p/blog/v1/data/query/production/post" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":0,"documents":[]}})}},
        # The admin menu — one call, no N+1. Its numbers are the CANDIDATE LIST and
        # the probe order ONLY; they are deliberately DIFFERENT from the site's own
        # totals below so a menu that echoed them would be caught here.
        "/w/acme/p/blog/v1/data/counts/production" =>
          {:ok,
           %{
             status: 200,
             body: ~s({"ok":true,"counts":{"paper":579,"task":3328,"session":5,"post":0}})
           }},
        # …intersected with what the SITE token can actually read, and the
        # magnitude the user is shown is the one the SITE's own probe returned.
        "/w/acme/p/blog/v1/data/query/production/paper" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":1,"total":40,"documents":[{}]}})}},
        "/w/acme/p/blog/v1/data/query/production/task" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":1,"total":12,"documents":[{}]}})}}
        # `session` is deliberately UNPROGRAMMED: the fake answers 200 "{}", which
        # the control plane cannot interpret, so it is NOT offered as readable.
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            framework: "astro",
            workspace: "acme",
            project: "blog",
            dataset: "production",
            doc_type: "post"
          },
          token
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "content_binding_empty"

      # The refusal names what IS readable, with the numbers the SITE's OWN token
      # produced — 40 and 12, NOT the admin aggregate's 579 and 3328. A sentence
      # opening "This site CAN read" may not carry an admin number wearing a site
      # label: the admin sees types whose documents are field-redacted for a
      # public-read caller, so its magnitudes are an upper bound, not the site's.
      assert body["detail"] =~ "paper (40)"
      assert body["detail"] =~ "task (12)"
      refute body["detail"] =~ "579"
      refute body["detail"] =~ "3328"
      # …and never a type the site's own token could not prove it can read.
      refute body["detail"] =~ "session"
      # …and the EXACT re-run, not "check your dataset".
      assert body["detail"] =~ "acme/blog/production"
      assert body["detail"] =~ "--doc-type"
      # Machine-readable menu for the CLI/console, same intersection, same
      # provenance. Order is the admin candidate order (task outranks paper);
      # the NUMBERS are the site's.
      assert body["readable_types"] == [
               %{"type" => "task", "count" => 12},
               %{"type" => "paper", "count" => 40}
             ]

      # Refused AT THE DOOR: no row, so no ghost for the reaper to kill later.
      assert Registry.list_sites_for_team(team) == []
    end

    test "a typo'd dataset 404s the site's own token → refused, even when the menu is unavailable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}},
        # A typo'd dataset, a typo'd type and a private type are byte-identical here.
        "/w/acme/p/blog/v1/data/query/prodcution/post" =>
          {:ok, %{status: 404, body: ~s({"error":"not found"})}}
        # counts is unprogrammed → 200 "{}" → no menu, and the refusal SAYS so.
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "prodcution"
          },
          token
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "content_binding_empty"
      assert body["detail"] =~ "prodcution/post"
      assert body["detail"] =~ "404"
      # No menu was obtainable — say that, do not invent one.
      assert body["detail"] =~ "could not list what IS readable"
      refute Map.has_key?(body, "readable_types")
      assert Registry.list_sites_for_team(team) == []
    end

    test "a body the control plane cannot INTERPRET is unverified — it creates, and says so (charter D75)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      # ONLY the mint is programmed. The verification read therefore lands on the
      # fake's unprogrammed-path default, {:ok, 200, "{}"} — a 200 whose shape the
      # control plane does not know. That is a BLIND SPOT, not a verdict on the
      # user's content: it must NOT become a refusal.
      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 201
      body = json_body(conn)
      # Never "ok" — the 201 carries the unverified verdict in the same breath.
      assert body["content_binding"]["status"] == "unverified"
      assert body["content_binding"]["detail"] =~ "could not interpret"
      refute body["content_binding"]["status"] == "bound"
      # The site EXISTS — an un-performable check never costs the user their site.
      assert [%Registry.Site{}] = Registry.list_sites_for_team(team)
    end

    test "a read that could not be PERFORMED is unverified too, naming the box" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}},
        "/w/acme/p/blog/v1/data/query/production/post" => {:error, :timeout}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 201
      binding = json_body(conn)["content_binding"]
      assert binding["status"] == "unverified"
      assert binding["detail"] =~ bp.slug
      assert [%Registry.Site{}] = Registry.list_sites_for_team(team)
    end

    test "a binding the site CAN read → 201 content_binding bound, with what it saw" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}},
        # `count` is the PAGE size the `?limit=1` probe itself chose, so it is 1 for
        # every non-empty binding that will ever exist. `total` is the box's own
        # published aggregate — the only number this route may report.
        "/w/acme/p/blog/v1/data/query/production/paper" =>
          {:ok,
           %{status: 200, body: ~s({"result":{"count":1,"total":100,"documents":[{"_id":"p1"}]}})}}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production",
            doc_type: "paper"
          },
          token
        )

      assert conn.status == 201

      assert json_body(conn)["content_binding"] == %{
               "status" => "bound",
               "doc_type" => "paper",
               "count" => 100
             }

      # …and the read was made with the JUST-MINTED site token over the SAME
      # scoped query route the build later fetches with — not the admin token.
      probe =
        Enum.find(StudioLinkFakeHttpClient.requests(), fn r ->
          String.contains?(r.url, "/v1/data/query/production/paper")
        end)

      assert probe, "create must READ the binding before writing the row"

      assert List.keyfind(probe.headers, "Authorization", 0) ==
               {"Authorization", "Bearer bpt_public_read_minted"}

      # …and it ASKED for the total. Without `count=true` the box reports only the
      # page size, and a `count` in the 201 would be the probe's own limit echoed
      # back as if it were the site's content.
      assert probe.url =~ "count=true"
      assert probe.url =~ "limit=1"
    end

    # An older box that does not know `?count=true` reports no `total`. The verdict
    # is still `bound` — the read PROVED readability — but it carries no magnitude
    # rather than passing the page size off as one.
    test "a box that reports no total is BOUND without a fabricated count" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}},
        "/w/acme/p/blog/v1/data/query/production/paper" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":1,"documents":[{"_id":"p1"}]}})}}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production",
            doc_type: "paper"
          },
          token
        )

      assert conn.status == 201

      assert json_body(conn)["content_binding"] == %{
               "status" => "bound",
               "doc_type" => "paper"
             }
    end

    # The BYO-token branch short-circuits the mint entirely, so here the
    # verification read is the FIRST contact this route ever makes with the box.
    # It had no test at all before W8.
    test "a caller-supplied read_token skips the mint but STILL verifies, with the caller's token" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/data/query/production/post" =>
          {:ok,
           %{status: 200, body: ~s({"result":{"count":1,"total":4,"documents":[{"_id":"p1"}]}})}}
      })

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "blog",
            kind: "static",
            workspace: "acme",
            project: "blog",
            dataset: "production",
            read_token: "bpt_caller_supplied"
          },
          token
        )

      assert conn.status == 201
      assert json_body(conn)["content_binding"]["status"] == "bound"
      assert json_body(conn)["content_binding"]["count"] == 4

      requests = StudioLinkFakeHttpClient.requests()
      # The mint really was short-circuited…
      refute Enum.any?(requests, &String.contains?(&1.url, "/v1/tokens"))

      # …and the verification rode the CALLER's token, not the instance admin one.
      probe = Enum.find(requests, &String.contains?(&1.url, "/v1/data/query/production/post"))
      assert probe, "the BYO-token branch must verify too"

      assert List.keyfind(probe.headers, "Authorization", 0) ==
               {"Authorization", "Bearer bpt_caller_supplied"}

      # The caller's token is what was stored — the plaintext never comes back.
      [site] = Registry.list_sites_for_team(team)
      assert {:ok, "bpt_caller_supplied"} = Registry.reveal_site_read_token(site)
      refute conn.resp_body =~ "bpt_caller_supplied"
    end

    # A container site has no binding, so the 201 must invent no verdict about one.
    test "a CONTAINER site's 201 carries NO content_binding verdict" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(:post, "/v1/sites", %{barkpark_id: bp.id, name: "api", kind: "container"}, token)

      assert conn.status == 201
      refute Map.has_key?(json_body(conn), "content_binding")
    end

    # The ghost 201 this route exists to kill has a second door: a static site
    # created with NO content binding at all. It used to insert cleanly, and the
    # deploy reaper would terminally fail it ~60s later — long after the user
    # could act on the advice ("create the site with --dataset …"), because the
    # site already existed. Refuse it at the door instead.
    test "a static site with no content binding is refused at CREATE, not by the reaper a minute later" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "blog", kind: "static", framework: "astro"},
          token
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "content_binding_required"
      # The message names the FLAG that fixes it, and exactly what is missing.
      assert body["detail"] =~ "--dataset"
      assert body["detail"] =~ "workspace"
      assert body["detail"] =~ "dataset"

      # No ghost row.
      assert Registry.list_sites_for_team(team) == []
    end

    test "a PARTIAL content binding is refused too — a build needs all three" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "blog", kind: "static", workspace: "acme"},
          token
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "content_binding_required"
      assert Registry.list_sites_for_team(team) == []
    end

    # A container site has no content binding BY DESIGN (it builds from a repo or
    # an artifact) — the new guard must not touch it.
    test "a CONTAINER site still creates with no content binding" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "api", kind: "container"},
          token
        )

      assert conn.status == 201
    end

    test "a missing barkpark_id says BARKPARK_REQUIRED — not the lying 'name_required'" do
      {user, _team} = user_with_team()
      token = login_token(user)

      conn = call(:post, "/v1/sites", %{name: "blog"}, token)

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "barkpark_required"
      refute body["error"] == "name_required"
    end
  end

  describe "site-spawner: POST /v1/sites/:id/deploy (kind-branched)" do
    test "a content-bound STATIC site → 201 with a build_id (never 422 no_build_source)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{}, token)

      assert conn.status == 201
      d = json_body(conn)["deployment"]
      assert d["status"] == "queued"
      assert is_binary(d["build_id"])
      # The container refusal must NEVER be what a static site hears — it is not
      # what it builds from.
      refute d["error"] == "no_build_source"

      # The six-stage bar is present from the very first response (all pending).
      assert Enum.map(d["stages"], & &1["name"]) ==
               ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)
    end

    test "an UNBOUND static site → 422 no_content_binding, naming the cure (not no_build_source)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp, %{bootstrap_dataset: nil})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{}, token)

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "no_content_binding"
      assert body["detail"] =~ "--dataset"
      # No un-buildable row was minted.
      assert Registry.list_deployments(site, 10) == []
    end

    test "a static site is NOT promotable — it rolls back instantly instead" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      {:ok, d} = Registry.create_deployment(site, %{build_id: "b1"})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/deployments/#{d.id}/promote", %{}, token)

      assert conn.status == 422
      body = json_body(conn)
      # The twin guard: without the kind branch this 422s `no_build_source` — the
      # SAME lie the deploy route told.
      assert body["error"] == "not_promotable"
      assert body["detail"] =~ "rollback"
    end
  end

  describe "site-spawner: GET /v1/sites/:id/deployments/:dep_id (the CLI's poll)" do
    test "returns {deployment: {stages: [{name,status}]}} with the LITERAL words the CLI renders" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE))])
      assert {:ok, :live} = Sites.Deploy.run(d.id)

      conn = call(:get, "/v1/sites/#{site.id}/deployments/#{d.id}", nil, token)
      assert conn.status == 200

      dep = json_body(conn)["deployment"]
      assert dep["id"] == d.id
      assert dep["site_id"] == site.id
      assert dep["status"] == "live"
      assert dep["stage"] == "RETIRE"
      assert dep["url"] == "#{@instance_url}/sites/#{site.slug}/"

      stages = dep["stages"]
      assert Enum.map(stages, & &1["name"]) == ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)

      # THE contract: the CLI's stream prints a stage line ONLY for done|failed|
      # skipped. An `ok` / `passed` / `running` here renders NOTHING — a blank
      # six-stage bar, with no error anywhere to explain it.
      assert Enum.all?(stages, &(&1["status"] == "done")),
             "want every stage literally 'done', got #{inspect(Enum.map(stages, & &1["status"]))}"

      assert Enum.all?(stages, &is_binary(&1["started_at"]))
    end

    test "a failed build reports the failing stage as `failed` and the un-run ones as `skipped`" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.failed_at("HEALTH", "probe returned 500")])
      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      conn = call(:get, "/v1/sites/#{site.id}/deployments/#{d.id}", nil, token)
      dep = json_body(conn)["deployment"]

      assert dep["status"] == "failed"
      assert dep["failure_reason"] =~ "probe returned 500"
      by_name = Map.new(dep["stages"], &{&1["name"], &1["status"]})
      assert by_name["HEALTH"] == "failed"
      assert by_name["SWITCH"] == "skipped"
      # A failed build has NO url — sending the user to the site would show them
      # the build that is still (correctly) serving, as if the broken one shipped.
      assert is_nil(dep["url"])
    end

    test "another site's deployment → 404 (no existence leak)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      other = static_site(bp)
      {:ok, d} = Registry.create_deployment(other, %{build_id: "b9"})
      token = login_token(user)

      conn = call(:get, "/v1/sites/#{site.id}/deployments/#{d.id}", nil, token)
      assert conn.status == 404
    end
  end

  describe "site-spawner: POST /v1/sites/:id/rollback (the sub-second flip)" do
    test "answers a FLAT body (never enveloped) after the box has really flipped" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # The previous build FINISHED — that is what makes it previous, and what
      # the re-keyed active index (deploy-truth W1) requires: one build in
      # flight per site.
      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000001"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "building"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "pushing"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "live"})
      {:ok, live} = Registry.create_deployment(site, %{build_id: "livebuild0000001"})
      {:ok, site} = Registry.set_site_current_deployment(site, live.id)

      FakeBoxRelay.program(
        rollback: {:ok, 200, %{"status" => "rolled_back", "build_id" => "prevbuild0000001"}}
      )

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)
      assert conn.status == 200

      body = json_body(conn)
      # FLAT. Wrapped as {"deployment": …}, Go leaves every field at its zero value
      # and the CLI STILL prints "✓ site rolled back" — naming no build, erroring
      # nowhere.
      refute Map.has_key?(body, "deployment")
      assert body["ok"] == true
      assert body["status"] == "rolled_back"
      assert body["deployment_id"] == prev.id
      assert body["previous_deployment_id"] == live.id
      assert body["url"] == "#{@instance_url}/sites/#{site.slug}/"

      # The control plane's view agrees with the box immediately.
      assert Registry.get_site(site.id).current_deployment_id == prev.id
    end

    test "the rollback LANDS in the audit trail — the console calls Activity append-only" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000002"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "building"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "pushing"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "live"})
      {:ok, live} = Registry.create_deployment(site, %{build_id: "livebuild0000002"})
      {:ok, site} = Registry.set_site_current_deployment(site, live.id)

      FakeBoxRelay.program(
        rollback: {:ok, 200, %{"status" => "rolled_back", "build_id" => "prevbuild0000002"}}
      )

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)
      assert conn.status == 200

      # The router writes this event through a `case Accounts.record_audit(…)`
      # whose error arm LOGS (post-commit best-effort: the box already rolled
      # back, so a refused insert must not 500 a success). The 200 above still
      # says nothing about whether the row exists — only the trail can answer.
      # What the `case` buys is that the error is no longer thrown away and the
      # console's "audit" push no longer fires over a row that was never
      # written. `router_audit_discard_census_test.exs` keeps the shape.
      events = Accounts.list_audit_events(team)
      assert ev = Enum.find(events, &(&1.action == "site.rolled_back"))
      assert ev.team_id == team.id
      assert ev.actor_user_id == user.id
      assert ev.target_type == "site"
      assert ev.target_id == site.id
      assert ev.metadata["deployment_id"] == prev.id
      assert ev.metadata["previous_deployment_id"] == live.id
    end

    test "a rollback that CANNOT happen answers non-2xx — the CLI gates success on the status alone" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program(rollback: {:ok, 422, %{"error" => "no_previous"}})

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)

      refute conn.status in 200..299
      body = json_body(conn)
      assert body["ok"] == false
      assert body["detail"] =~ "no previous build"
    end

    # cch-w62-bl — the wire carries the box's TYPED code in `error`, flat, so
    # the console's siteRollbackRefusalTerminal can classify the refusal instead
    # of string-matching prose. The nested already_running case below this
    # describe (the W70 flat-detail law) keeps `rollback_failed` — the promotion
    # is allowlisted to the box's typed site-rollback exits.
    test "a no_previous refusal reaches the wire as error: no_previous — flat, beside its prose" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program(rollback: {:ok, 422, %{"error" => "no_previous"}})

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)
      assert conn.status == 422

      body = json_body(conn)
      assert body["ok"] == false
      assert body["error"] == "no_previous"
      assert body["detail"] =~ "no previous build"
    end

    test "a NESTED not_supported refusal relays code AND the box's words in flat detail" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program(
        rollback:
          {:ok, 422,
           %{"error" => %{"code" => "not_supported", "message" => "no current symlink (exit 22)"}}}
      )

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)
      assert conn.status == 422

      body = json_body(conn)
      assert body["error"] == "not_supported"
      assert is_binary(body["detail"])
      assert body["detail"] =~ "no current symlink (exit 22)"
    end

    ## W70 (D847/D854) — THE FLAT-DETAIL LAW, mutation-proven at the route. The
    ## box's REAL pre-poll refusal is NESTED (`%{error: %{code, message}}`,
    ## relayed verbatim by BoxRelay.HTTP), and the CLI's site arms
    ## (RollbackSpawnSite → cloudError) decode FLAT strings only: a map left
    ## under "error" degrades the receipt to a 200-rune raw clamp. So the wire
    ## keeps `error` = the route's own STRING code and the box's words land in
    ## flat top-level `detail`, composed "code — message" server-side.
    test "a NESTED box refusal keeps error a STRING code and lands the box's words in flat detail" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program(
        rollback:
          {:ok, 409,
           %{
             "error" => %{
               "code" => "already_running",
               "message" => "deploy already running for blog"
             }
           }}
      )

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)
      assert conn.status == 409

      body = json_body(conn)
      assert body["ok"] == false
      # The route code, a STRING — never the box's nested map.
      assert body["error"] == "rollback_failed"
      # The box's own words, FLAT where cloudError can read them — never left
      # only inside a nested error.message.
      assert is_binary(body["detail"])
      assert body["detail"] =~ "already_running"
      assert body["detail"] =~ "deploy already running for blog"
    end

    test "a container site is not rollbackable this way → 422 (the two verbs stay unblurred)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, site} = Registry.create_site(bp, %{name: "App", slug: "app"})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "not_rollbackable"
    end
  end

  describe "site-spawner W7: kind=node is the THIRD router arm (deploy / binding / rollback)" do
    test "a content-bound NODE site deploy → 201 with a build_id and the SAME six-stage bar (not no_build_source)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = node_site(bp)
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{}, token)

      assert conn.status == 201
      d = json_body(conn)["deployment"]
      assert d["status"] == "queued"
      assert is_binary(d["build_id"])
      # A node site is content-bound — it must NEVER hear the container refusal.
      refute d["error"] == "no_build_source"
      # The SAME six-stage machine drives it — not a container/repo path.
      assert Enum.map(d["stages"], & &1["name"]) ==
               ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)
    end

    test "creating a node site with NO content binding → 422 content_binding_required (not the _kind catch-all :ok)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "ssr", kind: "node", framework: "nextjs"},
          token
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "content_binding_required"
      # No ghost row — the unbound node site was refused at the door.
      assert Registry.list_sites_for_team(team) == []
    end

    test "a node site IS rollbackable → NOT 422 not_rollbackable (it flips the Caddy upstream to the previous slot)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = node_site(bp)
      token = login_token(user)

      # The previous build FINISHED — that is what makes it previous, and what
      # the re-keyed active index (deploy-truth W1) requires: one build in
      # flight per site.
      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000001"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "building"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "pushing"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "live"})
      {:ok, live} = Registry.create_deployment(site, %{build_id: "livebuild0000001"})
      {:ok, site} = Registry.set_site_current_deployment(site, live.id)

      FakeBoxRelay.program(
        rollback: {:ok, 200, %{"status" => "rolled_back", "build_id" => "prevbuild0000001"}}
      )

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)

      # THE contract: node is NOT refused as not_rollbackable.
      refute conn.status == 422
      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true
      assert body["deployment_id"] == prev.id
      assert Registry.get_site(site.id).current_deployment_id == prev.id
    end

    test "the box receives runtime_target=node and the idle slot's target_port (deploy_payload, charter D63)" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      # No live port yet → the first deploy targets blue (port_base = 7002).
      site = node_site(bp, %{port_base: 7002})

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE))])
      assert {:ok, :live} = Sites.Deploy.run(d.id)

      [{:start_deploy, payload}] =
        Enum.filter(FakeBoxRelay.calls(), fn {kind, _} -> kind == :start_deploy end)

      assert payload.runtime_target == "node"
      assert payload.target_port == 7002
      assert payload.framework == "nextjs"
    end

    test "a STATIC deploy carries runtime_target=static and NO target_port (unchanged)" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE))])
      assert {:ok, :live} = Sites.Deploy.run(d.id)

      [{:start_deploy, payload}] =
        Enum.filter(FakeBoxRelay.calls(), fn {kind, _} -> kind == :start_deploy end)

      assert payload.runtime_target == "static"
      refute Map.has_key?(payload, :target_port)
    end
  end

  ## Exit gate — the P1 end-to-end test the plan calls for.

  describe "P1 exit gate" do
    test "create site + enqueue a build task end-to-end" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      token = login_token(user)

      # 1. Create the site.
      create =
        call(:post, "/v1/sites", %{barkpark_id: bp.id, name: "demo"}, token)

      assert create.status == 201
      site_id = json_body(create)["site"]["id"]

      # 2. Enqueue a deploy (the no-op build task — status=queued is the enqueue).
      # A build source (here an uploaded artifact) is required, else the deploy
      # is refused up front as un-buildable (422 no_build_source).
      deploy =
        call(
          :post,
          "/v1/sites/#{site_id}/deploy",
          %{git_ref: "main", artifact_url: "file:///tmp/demo.tar.gz"},
          token
        )

      assert deploy.status == 201
      assert json_body(deploy)["deployment"]["status"] == "queued"

      # 3. The deployment is visible via the deployments list.
      list = call(:get, "/v1/sites/#{site_id}/deployments", nil, token)
      assert list.status == 200
      [d] = json_body(list)["deployments"]
      assert d["status"] == "queued"
      assert d["git_ref"] == "main"
    end
  end

  describe "PATCH /v1/sites/:id (operator settings, search-template W8)" do
    test "updates theme + doc_type; infrastructural fields stay immutable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      tok = login_token(user)

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{theme: "ember", doc_type: "paper", slug: "evil"},
          tok
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["site"]["theme"] == "ember"
      # W10: the RESPONSE BODY carries doc_type. Asserting the DB reload alone
      # (below) routed around the missing echo — every reader downstream (the Go
      # CLI, the console rail) sees this body, not the row.
      assert body["site"]["doc_type"] == "paper"
      assert body["note"] =~ "next deploy"

      reloaded = Registry.get_site(site.id)
      assert reloaded.theme == "ember"
      assert reloaded.doc_type == "paper"
      # slug ignored — not in the mutable set
      assert reloaded.slug == site.slug
    end

    test "an unknown theme is a 422 invalid_settings" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      conn = call(:patch, "/v1/sites/#{site.id}", %{theme: "vaporwave"}, login_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_settings"
    end

    test "an empty body is an honest 422 naming the mutable fields" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      conn = call(:patch, "/v1/sites/#{site.id}", %{}, login_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "nothing_to_update"
    end
  end

  describe "DELETE /v1/sites/:id (site delete — tear down + deregister)" do
    test "tears the site down on the box, THEN deregisters the row (deployments cascade)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)
      {:ok, _dep} = Registry.create_deployment(site, %{build_id: "somebuild0000001"})

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 200

      body = json_body(conn)
      assert body["ok"] == true
      assert body["status"] == "deleted"
      assert body["slug"] == site.slug

      # The box was told to tear down BEFORE the row vanished.
      assert Enum.any?(FakeBoxRelay.calls(), fn
               {:teardown, p} -> p.slug == site.slug and p.mode == "teardown"
               _ -> false
             end)

      # The row is gone, and its deployments cascaded (on_delete: :delete_all).
      assert Registry.get_site(site.id) == nil
      assert Registry.list_deployments(site, 10) == []
    end

    test "the delete LANDS in the audit trail — it is the ONLY surviving record of the site" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)
      before_count = Repo.aggregate(BarkparkCloud.Accounts.AuditEvent, :count)

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 200

      # This route is the sharpest case in the audit register: `delete_site/1`
      # is a hard `Repo.delete`, so after this request NOTHING else in the
      # database can say the site existed or who removed it. Until this test
      # nothing in `cloud/test` drove the route and read the trail — the 200 was
      # the only thing anyone checked, and the 200 is also what a swallowed
      # changeset error produced.
      events = Accounts.list_audit_events(team)
      assert ev = Enum.find(events, &(&1.action == "site.deleted"))
      assert ev.team_id == team.id
      assert ev.actor_user_id == user.id
      assert ev.target_type == "site"
      assert ev.target_id == site.id
      assert ev.metadata["slug"] == site.slug
      assert ev.metadata["kind"] == site.kind

      # A team+action-scoped read cannot tell "one row" from "two"; the global
      # delta can, and it is the arm that reds if the converted `case` ever
      # writes twice or the route stamps a second verb.
      assert Repo.aggregate(BarkparkCloud.Accounts.AuditEvent, :count) == before_count + 1
    end

    ## THE AUDIT IS THE GATE, AND THESE TWO TESTS ARE WHAT "GATE" MEANS HERE.
    ##
    ## The row is written BEFORE `Sites.Deploy.teardown/2` and before
    ## `Registry.delete_site/1`, so a refused insert answers 422 with NOTHING
    ## torn down. The consequence is visible from the other side, and it is
    ## pinned rather than discovered: because the write is first, it SURVIVES a
    ## teardown that then fails. A trail that occasionally over-reports a
    ## removal was the accepted cost of never under-reporting one.

    test "the audit row is written BEFORE the teardown — a REFUSED teardown still leaves it" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # The box is unreachable: teardown refuses, nothing is deleted.
      FakeBoxRelay.program(teardown: {:error, :econnrefused})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

      assert conn.status == 502
      assert json_body(conn)["error"] == "teardown_failed"

      # The site row AND its box are untouched — the delete never ran.
      refute Registry.get_site(site.id) == nil
      refute Registry.get_barkpark(bp.id) == nil

      # And the audit row is THERE, because it gated the attempt. Under the old
      # shape — the write sitting in `delete_site/1`'s `:ok` branch — this
      # assertion finds nothing, which is exactly the ordering it pins.
      events = Accounts.list_audit_events(team)
      assert ev = Enum.find(events, &(&1.action == "site.deleted"))
      assert ev.target_id == site.id
      assert ev.actor_user_id == user.id
    end

    test "the delete stamps slug and kind — read_token moved to the response, not the row" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 200

      # `read_token` is the OUTCOME of the revoke inside `delete_site/1`. The
      # gate runs before that call, so the fact does not exist yet and
      # `audit_events` is append-only — there is no second write to add it. The
      # caller still gets it here, and `mix barkpark_cloud.site_read_tokens` is
      # the sweep for a credential nobody confirmed dead. This test states the
      # trade so a reader does not think the metadata key was lost by accident.
      assert Map.has_key?(json_body(conn), "read_token")

      events = Accounts.list_audit_events(team)
      assert ev = Enum.find(events, &(&1.action == "site.deleted"))
      assert ev.metadata["slug"] == site.slug
      assert ev.metadata["kind"] == site.kind
      refute Map.has_key?(ev.metadata, "read_token")
    end

    ## W67 S2 (charter D820) — THE TWO CASCADES NOTHING ASSERTED.
    ##
    ## Three FKs reference `sites`; until this wave only `deployments` had
    ## behavioural cover. Each test below drives the REAL route, so a regression
    ## fails the way production fails: `Repo.delete` raises `Ecto.ConstraintError`
    ## under a non-cascade FK, the router's `{:ok, _} = Registry.delete_site(site)`
    ## hard match turns that into `500 {"error":"server_error"}` with no `ok` and
    ## no `detail` — AFTER the box teardown already disarmed the Caddy route. The
    ## inverse orphan: a dead site that is still registered.
    ##
    ## Measured 2026-08-10: with `site_artifacts.site_id` flipped to ON DELETE
    ## RESTRICT, this whole file was 104 tests / 0 failures and
    ## `fk_census_test.exs` was 5/0. The structural half of the guard lives in
    ## `site_cascade_census_test.exs`; these are the behavioural half.

    test "an uploaded artifact BOUND TO A DEPLOYMENT cascades on delete" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)
      {:ok, dep} = Registry.create_deployment(site, %{build_id: "artifactbuild001"})

      Repo.insert!(%Registry.SiteArtifact{
        site_id: site.id,
        deployment_id: dep.id,
        sha256: String.duplicate("a", 64),
        byte_size: 3,
        bytes: <<1, 2, 3>>
      })

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

      # A 500 here is the regression: the artifact FK refused, and it refused
      # AFTER the teardown call above already succeeded.
      assert conn.status == 200, "site delete answered #{conn.status}: #{conn.resp_body}"
      assert json_body(conn)["ok"] == true
      assert Registry.get_site(site.id) == nil

      # Postgres checks RESTRICT IMMEDIATELY, not at end of statement, so the
      # deployments cascade does NOT rescue an artifact bound to a deployment —
      # this row's own FK has to be `on_delete: :delete_all` in its own right.
      assert Repo.aggregate(
               from(a in Registry.SiteArtifact, where: a.site_id == ^site.id),
               :count
             ) == 0
    end

    test "an uploaded artifact with NO deployment (deployment_id nil) cascades on delete" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # The site-scoped upload route's shape: bytes at rest before any build
      # claims them. Nothing else in the delete path touches this row.
      Repo.insert!(%Registry.SiteArtifact{
        site_id: site.id,
        deployment_id: nil,
        sha256: String.duplicate("b", 64),
        byte_size: 2,
        bytes: <<9, 9>>
      })

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

      assert conn.status == 200, "site delete answered #{conn.status}: #{conn.resp_body}"
      assert Registry.get_site(site.id) == nil

      assert Repo.aggregate(
               from(a in Registry.SiteArtifact, where: a.site_id == ^site.id),
               :count
             ) == 0
    end

    test "content-publish rows cascade on delete (the table that landed unasserted)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, _publish} =
        Registry.ContentPublish.record(site.id, DateTime.utc_now(), %{doc_type: "paper"})

      assert Repo.aggregate(
               from(p in Registry.ContentPublish, where: p.site_id == ^site.id),
               :count
             ) == 1

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

      assert conn.status == 200, "site delete answered #{conn.status}: #{conn.resp_body}"
      assert Registry.get_site(site.id) == nil

      assert Repo.aggregate(
               from(p in Registry.ContentPublish, where: p.site_id == ^site.id),
               :count
             ) == 0
    end

    test "a box that could NOT tear down leaves the row in place (no orphaned registration)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program(
        teardown: {:ok, 422, %{"error" => "caddy validate rejected the disarm"}}
      )

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

      refute conn.status in 200..299
      assert json_body(conn)["ok"] == false
      # The site is STILL registered — box-first means a failed teardown never
      # deregisters a still-serving box.
      refute Registry.get_site(site.id) == nil
    end

    ## W68 — THE 502 ARM, WHICH NO TEST HAD EVER REACHED, AND WHICH USED TO SAY
    ## "DEPLOY" IN A DELETE RECEIPT (charter D814, Option A).
    ##
    ## `teardown/2`'s 502 fires only on `{:error, reason}` — a programmed
    ## `{:ok, 502, …}` never reaches it, because every `{:ok, 400..599}` is
    ## mapped to the 422 above. `FakeBoxRelay` returns the programmed term
    ## verbatim, so each of the four REACHABLE reasons is driven here
    ## (`:identity_refused` is intercepted one clause earlier into the typed
    ## 409, covered below). The details are pinned EXACTLY: before this wave the
    ## `:no_admin_token` and catch-all sentences were `unreachable/2`'s deploy
    ## copy, so the deploy-vs-teardown wording is precisely what can lose.
    test "an unreachable box is a 502 whose copy narrates the TEARDOWN, never a deploy (all four reachable reasons)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      expected = [
        {:not_live, "instance #{bp.slug} has no URL yet — it is still provisioning"},
        {:no_admin_token,
         "instance #{bp.slug} has no stored admin token — the control plane cannot " <>
           "drive a teardown on it"},
        {:decrypt_failed, "instance #{bp.slug}'s admin token could not be decrypted"},
        # Any other reason (a transport error term) is the catch-all — the arm
        # production actually populates. Its "is unreachable" substring is what
        # `DeployLedger.classify/2` keys on and is preserved on purpose.
        {:econnrefused,
         "instance #{bp.slug} is unreachable — the teardown could not be delivered; " <>
           "check instance health"}
      ]

      for {reason, detail} <- expected do
        FakeBoxRelay.program(teardown: {:error, reason})

        conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

        assert conn.status == 502, "#{reason}: status #{conn.status}, expected 502"
        body = json_body(conn)
        assert body["ok"] == false
        assert body["error"] == "teardown_failed"
        assert body["detail"] == detail
        refute body["detail"] =~ "deploy", "#{reason}: a DELETE receipt said \"deploy\""

        # An unreachable box was never torn down — the row must survive it.
        refute Registry.get_site(site.id) == nil
      end
    end

    ## W68 — THE ROLLBACK-COPY LEAK. The teardown 422 used to launder the box's
    ## refusal body through `rollback_refusal/2`, so `{"error":"not_supported"}`
    ## answered a DELETE with "this site has no live release yet — there is
    ## nothing to roll back". Now the box's own word travels verbatim, and the
    ## one verb-neutral typed sentence (`lock_held`) keeps its plain words.
    test "a box refusal body never renders ROLLBACK prose in a delete receipt" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # The leak case measured in the W68 brief: before the fix this detail read
      # "this site has no live release yet — there is nothing to roll back".
      FakeBoxRelay.program(teardown: {:ok, 422, %{"error" => "not_supported"}})
      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "teardown_failed"
      assert body["detail"] == "not_supported"
      refute body["detail"] =~ "roll back"

      # The verb-neutral typed exit stays human: lock_held is a deploy running
      # on the box, and saying so is true for a teardown too.
      FakeBoxRelay.program(teardown: {:ok, 409, %{"error" => "lock_held"}})
      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 422

      assert json_body(conn)["detail"] ==
               "a deploy is running on the box — try again once it finishes"

      # A body with no typed word at all still gets the honest fallback.
      FakeBoxRelay.program(teardown: {:ok, 500, %{}})
      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 422
      assert json_body(conn)["detail"] == "the instance could not tear this site down (HTTP 500)"

      refute Registry.get_site(site.id) == nil
    end

    ## W70 (D847/D854) — the teardown twin of the rollback flat-detail proof:
    ## the nested pre-poll refusal keeps `error` = "teardown_failed" (STRING,
    ## what DeleteSpawnSite → cloudError decodes) and the box's words land in
    ## flat top-level `detail`, composed "code — message".
    test "a NESTED box refusal keeps error=teardown_failed and the box's words in flat detail" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program(
        teardown:
          {:ok, 409,
           %{
             "error" => %{
               "code" => "already_running",
               "message" => "deploy already running for blog"
             }
           }}
      )

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 422

      body = json_body(conn)
      assert body["ok"] == false
      assert body["error"] == "teardown_failed"
      assert is_binary(body["detail"])
      assert body["detail"] =~ "already_running"
      assert body["detail"] =~ "deploy already running for blog"

      # A refused teardown never deregisters the site.
      refute Registry.get_site(site.id) == nil
    end

    test "another team's site is 404, never deleted (team-scoped)" do
      {_owner, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      {other_user, _other_team} = user_with_team()
      token = login_token(other_user)

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 404
      # Untouched.
      refute Registry.get_site(site.id) == nil
    end
  end

  ## ---------------------------------------------------------------------------
  ## cloud-console-hardening W63 (D741/D763) — THE TYPED REFUSAL, AT THE WIRE.
  ##
  ## Added by the WAVE REVIEW, not the slice. cch-w63-s3 fenced the site writes
  ## at `BoxRelay` and taught both routes a 4-tuple clause that relays the code
  ## `Sites.Deploy` measured — but every assertion it shipped stops at the
  ## `Sites.Deploy` return value. Deleting either router clause therefore still
  ## sent a 409 wearing the flat `rollback_failed` / `teardown_failed` slug and
  ## NOTHING went red, which is a guard-shaped hole in a wave whose thesis is
  ## that a guard must be able to lose. These two drive the real conn.
  ##
  ## The flat slug is what makes the console unable to classify a site failure
  ## at all: router.ex stamped `rollback_failed` on EVERY error status, so a
  ## reader keying on the code learns nothing. The status still comes from
  ## `Sites.Deploy`; these tests assert the ROUTE relays both halves.
  ## ---------------------------------------------------------------------------

  describe "a box that refused our credential answers a TYPED code on the wire" do
    defp refused_barkpark(team) do
      team
      |> live_barkpark()
      |> Ecto.Changeset.change(update_unavailable_reason: "identity_refused")
      |> BarkparkCloud.Repo.update!()
    end

    test "POST /v1/sites/:id/rollback → 409 identity_refused, NOT rollback_failed, and no box call" do
      {user, team} = user_with_team()
      bp = refused_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # ARMED: `record/1` only appends under a key `program/1` created, so an
      # unprogrammed recorder answers `[]` for any traffic at all.
      FakeBoxRelay.program([])

      conn = call(:post, "/v1/sites/#{site.id}/rollback", %{}, token)

      assert conn.status == 409
      body = json_body(conn)
      assert body["ok"] == false
      assert body["error"] == "identity_refused"
      refute body["error"] == "rollback_failed"
      assert body["detail"] =~ "the instance rejected our access credential"
      # A 502 would be a claim about the network. Nothing went on the wire.
      assert FakeBoxRelay.calls() == []
    end

    test "DELETE /v1/sites/:id → 409 identity_refused, the row survives, and no box call" do
      {user, team} = user_with_team()
      bp = refused_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      FakeBoxRelay.program([])

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

      assert conn.status == 409
      body = json_body(conn)
      assert body["ok"] == false
      assert body["error"] == "identity_refused"
      refute body["error"] == "teardown_failed"
      assert body["detail"] =~ "the instance rejected our access credential"
      assert FakeBoxRelay.calls() == []
      # Box-first: a refused teardown never deregisters a still-serving box.
      refute Registry.get_site(site.id) == nil
    end
  end

  ## ---------------------------------------------------------------------------
  ## DELETE /v1/sites/:id — THE DNS HALF (task-b2c41cd0b0be41b4)
  ##
  ## The second instance of the support-remove shape (task-688ebffc4b0aa50a):
  ## creation is wired, destruction is not. `do_bind_cloudflare/5` writes an A
  ## record and persists `cf_zone_id` + `cf_record_id` on the site row; the
  ## teardown above deleted that row and never read either field, so the record
  ## outlived the only artefact that named it — dangling DNS pointing at a
  ## released address.
  ##
  ## Why the SIXTEEN delete tests above never caught it, stated so the next reader
  ## does not trust them either: every one of them builds its fixture with
  ## `static_site/1`, which sets no `cf_record_id`. They take the `:noop` arm under
  ## ANY fix and stay green against the bug forever — exactly the vacuity the
  ## sibling row warned about on the supports side. The three tests below are the
  ## ones that are NOT vacuous, and the third of them is the one that pins the
  ## `:noop` arm on purpose so the common path stays measured rather than assumed.
  ## ---------------------------------------------------------------------------

  # The state `POST /v1/sites/:id/deploy via=cloudflare` leaves behind: a real
  # record in the fake's zone, and the row that names it.
  defp cf_bound_site(team, bp, domain) do
    site = static_site(bp)

    {:ok, _} =
      Registry.connect_provider(
        team,
        "cloudflare",
        Jason.encode!(%{"api_token" => "cf_live_token", "zone_id" => "zone_acme"})
      )

    {:ok, %{record_id: record_id}} =
      BarkparkCloud.Cloudflare.upsert_dns_record("cf_live_token", "zone_acme", %{
        type: "A",
        name: domain,
        content: "203.0.113.10",
        proxied: true
      })

    {:ok, bound} =
      Registry.set_cf_binding(site, %{
        serving_mode: "cf_proxied",
        tls_mode: "cf_internal",
        cf_domain: domain,
        cf_zone_id: "zone_acme",
        cf_record_id: record_id
      })

    {bound, record_id}
  end

  describe "DELETE /v1/sites/:id — the Cloudflare A record dies with the site" do
    test "a cf-bound site's record is deleted with the STORED record id, BEFORE the row goes" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {site, record_id} = cf_bound_site(team, bp, "blog.acme.example")
      token = login_token(user)

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      # The record really is in the zone before the request — otherwise a fake
      # that never held it would let a no-op delete look like a success.
      assert Enum.any?(CfFake.records(), &(&1.record_id == record_id))

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 200

      body = json_body(conn)
      assert body["ok"] == true
      assert body["cf_record"] == "deleted"
      refute Map.has_key?(body, "cf_warning")

      # THE ASSERTION THIS ROW EXISTS FOR: the delete went out, addressed by the
      # zone + record id the ROW carried — not by a name re-derived from the
      # domain, which is the derivation that goes wrong once the row is gone.
      assert Enum.any?(CfFake.deletes(), fn d ->
               d.zone_id == "zone_acme" and d.record_id == record_id
             end)

      # The fake models a ZONE, not a call log: the record is really gone.
      refute Enum.any?(CfFake.records(), &(&1.record_id == record_id))

      # And the row — the only pointer to that record — is gone too, AFTER it.
      assert Registry.get_site(site.id) == nil
    end

    test "a Cloudflare delete that FAILS still deletes the row, and the 200 NAMES the record nothing else can find" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {site, record_id} = cf_bound_site(team, bp, "ghost.acme.example")
      token = login_token(user)

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      # The honesty-edge seam: every delete in THIS process fails, regardless of
      # token/zone validity.
      CfFake.fail_deletes(true)

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)

      # THE DEFINED TERMINAL STATE, named: the box is already torn down, so
      # refusing here would leave a dead site still registered. The row goes, and
      # the response carries the pointer out — the same contract the unconfirmed
      # read-token revoke one field over already has.
      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true
      assert body["status"] == "deleted"
      assert body["cf_record"] == "not_deleted"

      assert body["cf_warning"] =~ record_id
      assert body["cf_warning"] =~ "zone_acme"
      assert body["cf_warning"] =~ "ghost.acme.example"
      assert body["cf_warning"] =~ "may still be LIVE"

      # The read-token warning key is UNTOUCHED by the DNS one — a delete can
      # strand both leftovers and neither may clobber the other.
      refute body["cf_warning"] == body["warning"]

      assert Registry.get_site(site.id) == nil
    end

    test "a site that was never cf-bound (cf_record_id nil) deletes cleanly with ZERO Cloudflare calls" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      assert site.cf_record_id == nil

      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      conn = call(:delete, "/v1/sites/#{site.id}", %{}, token)
      assert conn.status == 200

      body = json_body(conn)
      assert body["cf_record"] == "none"
      refute Map.has_key?(body, "cf_warning")

      # The standalone path is byte-identical to before this arm existed: no
      # credential read, no DNS call, no zone touched.
      assert CfFake.deletes() == []
      assert CfFake.records() == []

      assert Registry.get_site(site.id) == nil
    end
  end

  ## ---------------------------------------------------------------------------
  ## site-spawner W9 — THE PREBUILT LANE (charter D86/D87/D91/D97)
  ##
  ## The build leaves the serving box. A prebuilt deploy MINTS first and UPLOADS
  ## second, and that order is FORCED, not preferred: `build_id` is baked INTO
  ## the bytes at build time (site-deploy.sh exports BARKPARK_BUILD_ID and HEALTH
  ## asserts the served marker BY VALUE), and `content_rev` is computed by
  ## relaying to the box with the instance admin token. Neither is knowable to an
  ## uploader, so a digest — knowable only AFTER the build — can never be an
  ## input to the build identity.
  ## ---------------------------------------------------------------------------

  describe "site-spawner W9: POST /v1/sites/:id/deploy {source: prebuilt}" do
    test "mints 201 WITHOUT starting a deploy, carrying build_id + content_rev + where to upload" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      FakeBoxRelay.program([])

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)

      assert conn.status == 201
      body = json_body(conn)
      d = body["deployment"]

      assert d["source"] == "prebuilt"
      assert d["status"] == "queued"
      # Both halves of the build identity are ALREADY in the 201 — that is the
      # whole reason the mint comes first.
      assert is_binary(d["build_id"])
      assert is_binary(d["content_rev"])
      # No bytes yet, so no digest yet. Honest, never invented.
      assert d["artifact_sha256"] == nil

      # The verb is DISCOVERABLE from the response, not only from Go source.
      assert body["upload"]["path"] == "/v1/sites/#{site.id}/deployments/#{d["id"]}/artifact"
      assert body["upload"]["content_type"] == "application/octet-stream"
      assert body["upload"]["detail"] =~ d["build_id"]

      # And NOTHING was handed to the driver: the box has not been touched.
      assert FakeBoxRelay.calls() == []
    end

    test "TWO prebuilt mints on unchanged content are TWO rows with DIFFERENT build_ids" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      first = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)

      # deploy-truth W1 (charter D10): while the first mint is still in flight,
      # a second one COALESCES onto it (200 with that row) instead of standing up
      # a second concurrent build the box would only answer 409. The uploader
      # follows the returned build_id, so its bytes still reach the row it was
      # handed — nothing is silently discarded.
      coalesced = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)
      assert coalesced.status == 200

      assert json_body(coalesced)["deployment"]["id"] ==
               json_body(first)["deployment"]["id"]

      # Once that build settles, the slot is free and the NEXT prebuilt mint is a
      # genuinely distinct row — two different dists must never hash to one
      # build_id, so a prebuilt mint stays non-idempotent by construction.
      {:ok, _} =
        Registry.get_deployment(json_body(first)["deployment"]["id"])
        |> Registry.transition_deployment(%{status: "failed"})

      second = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)

      assert first.status == 201
      assert second.status == 201

      a = json_body(first)["deployment"]
      b = json_body(second)["deployment"]

      refute a["id"] == b["id"]
      refute a["build_id"] == b["build_id"]
      assert length(Registry.list_deployments(site, 10)) == 2
    end

    test "a box build on the SAME site still dedupes — the nonce is prebuilt-only" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      first = call(:post, "/v1/sites/#{site.id}/deploy", %{}, token)
      second = call(:post, "/v1/sites/#{site.id}/deploy", %{}, token)

      assert first.status == 201
      # The pre-W9 idempotent no-op is untouched: prebuilt widened nothing else.
      assert second.status == 200
    end

    test "prebuilt on a site that has NOT opted in → 422 prebuilt_not_enabled, no row" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "prebuilt_not_enabled"
      assert json_body(conn)["detail"] =~ "prebuilt_enabled"
      assert Registry.list_deployments(site, 10) == []
    end

    test "an unknown source is REFUSED, never silently treated as a box build" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt-v2"}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "unknown_source"
      assert Registry.list_deployments(site, 10) == []
    end
  end

  describe "site-spawner W9: POST /v1/sites/:id/deployments/:dep_id/artifact" do
    test "stores the bytes + digest and starts the driver ONLY AFTER the digest is recorded" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      dep = mint_prebuilt(site, token)

      payload = :crypto.strong_rand_bytes(4096)
      sha = sha256_hex(payload)

      conn =
        call_binary(
          :post,
          "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact",
          payload,
          token
        )

      assert conn.status == 201
      body = json_body(conn)
      assert body["artifact_sha256"] == sha
      assert body["bytes"] == byte_size(payload)
      assert body["deployment"]["artifact_sha256"] == sha

      # The bytes are in Postgres, keyed to THIS deployment.
      stored = Sites.Deploy.artifact_for(dep["id"])
      assert stored.bytes == payload
      assert stored.sha256 == sha

      # ORDERING. The snapshot is what the row looked like AT THE MOMENT the
      # driver was started: a driver started before the digest committed could
      # reach the box with a deployment the control plane cannot describe.
      assert started_snapshot(dep["id"]) == %{artifact_sha256: sha, artifact_present: true}
    end

    test "the SAME digest again is a 200 no-op — the driver is NOT started twice" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      dep = mint_prebuilt(site, token)
      path = "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact"

      assert call_binary(:post, path, "same-bytes", token).status == 201
      assert started_snapshot(dep["id"])

      # A client retry after a dropped response must not run the deploy twice.
      Process.delete({:deploy_started, dep["id"]})
      again = call_binary(:post, path, "same-bytes", token)

      assert again.status == 200
      assert json_body(again)["status"] == "already_uploaded"
      assert started_snapshot(dep["id"]) == nil
    end

    test "a DIFFERENT digest for an already-uploaded deployment → 409, bytes untouched" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      dep = mint_prebuilt(site, token)
      path = "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact"

      assert call_binary(:post, path, "first-bytes", token).status == 201

      conn = call_binary(:post, path, "second-bytes", token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "artifact_conflict"

      # build_id is already baked into the first bytes — swapping them under it
      # would be a lie about what is live.
      assert Sites.Deploy.artifact_for(dep["id"]).sha256 == sha256_hex("first-bytes")
    end

    test "a BOX-BUILD deployment refuses the upload → 422 not_prebuilt" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      {:ok, d} = Registry.create_deployment(site, %{build_id: "boxb1"})

      conn =
        call_binary(:post, "/v1/sites/#{site.id}/deployments/#{d.id}/artifact", "bytes", token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "not_prebuilt"
      assert Sites.Deploy.artifact_for(d.id) == nil
    end

    test "a deployment that already left queued → 409 deployment_not_queued" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      {:ok, d} = Registry.create_deployment(site, %{build_id: "pb1", source: "prebuilt"})

      d
      |> Ecto.Changeset.change(status: "building")
      |> BarkparkCloud.Repo.update!()

      conn =
        call_binary(:post, "/v1/sites/#{site.id}/deployments/#{d.id}/artifact", "bytes", token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "deployment_not_queued"
    end

    test "over the cap → 413, and nothing is stored" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      dep = mint_prebuilt(site, token)

      big = :binary.copy(<<0>>, 2 * 1024 * 1024)

      conn =
        call_binary(:post, "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact", big, token)

      assert conn.status == 413
      assert json_body(conn)["error"] == "artifact_too_large"
      assert Sites.Deploy.artifact_for(dep["id"]) == nil
    end

    test "a declared X-Artifact-Sha256 that does not match the body → 422, nothing stored" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      dep = mint_prebuilt(site, token)

      conn =
        conn(:post, "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact", "real-bytes")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("x-artifact-sha256", sha256_hex("other-bytes"))
        |> Router.call(@opts)

      assert conn.status == 422
      assert json_body(conn)["error"] == "artifact_digest_mismatch"
      assert Sites.Deploy.artifact_for(dep["id"]) == nil
      assert started_snapshot(dep["id"]) == nil
    end

    test "a MATCHING X-Artifact-Sha256 is accepted" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      dep = mint_prebuilt(site, token)

      conn =
        conn(:post, "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact", "real-bytes")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("x-artifact-sha256", String.upcase(sha256_hex("real-bytes")))
        |> Router.call(@opts)

      assert conn.status == 201
      assert Sites.Deploy.artifact_for(dep["id"]).sha256 == sha256_hex("real-bytes")
    end

    test "an EMPTY body → 422 empty_artifact, and the driver is NOT started" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)
      dep = mint_prebuilt(site, token)

      conn =
        call_binary(:post, "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact", "", token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "empty_artifact"
      assert Sites.Deploy.artifact_for(dep["id"]) == nil
      assert started_snapshot(dep["id"]) == nil
    end

    test "another team's site → 404, and a foreign deployment id → 404" do
      {_o, other_team} = user_with_team()
      # A plain (not "live") instance: `live_barkpark/1` pins one fixed URL, and
      # two of them in the same test collide on the barkparks URL unique index.
      other_bp = barkpark_fixture(other_team)
      other_site = prebuilt_site(other_bp)

      {:ok, foreign} =
        Registry.create_deployment(other_site, %{build_id: "f1", source: "prebuilt"})

      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      assert call_binary(
               :post,
               "/v1/sites/#{other_site.id}/deployments/#{foreign.id}/artifact",
               "b",
               token
             ).status == 404

      # Right team, wrong deployment: still 404 (existence-leak protection).
      assert call_binary(
               :post,
               "/v1/sites/#{site.id}/deployments/#{foreign.id}/artifact",
               "b",
               token
             ).status == 404
    end

    ## AUTH-AXIS FLIP (charter D97) on the NEW route too — it ships gated on the
    ## same axis as /deploy, and these three tests are what pin it.

    test "AUTH FLIP: a WRITE PAT can upload → 201" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      session = login_token(user)
      dep = mint_prebuilt(site, session)

      {:ok, pat, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "ci-runner",
          abilities: ["write"]
        })

      conn =
        call_binary(:post, "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact", "b", pat)

      assert conn.status == 201
    end

    test "AUTH FLIP: a READ-only PAT → 403, and nothing is stored" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      session = login_token(user)
      dep = mint_prebuilt(site, session)

      {:ok, pat, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "read-only",
          abilities: ["read"]
        })

      conn =
        call_binary(:post, "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact", "b", pat)

      assert conn.status == 403
      assert Sites.Deploy.artifact_for(dep["id"]) == nil
    end

    test "AUTH FLIP: no credential at all → 401" do
      conn = call_binary(:post, "/v1/sites/x/deployments/y/artifact", "b", nil)
      assert conn.status == 401
    end
  end

  describe "site-spawner W9: PATCH /v1/sites/:id {prebuilt_enabled}" do
    test "the flip LANDS — on the row and in the response" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      refute site.prebuilt_enabled

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: true}, token)

      assert conn.status == 200
      # The router keeps its OWN Map.take allow-list, independent of the
      # changeset's cast list. Widening only one of the two is a green-looking
      # no-op: 200, an unchanged row, and no error anywhere.
      assert json_body(conn)["site"]["prebuilt_enabled"] == true
      assert Registry.get_site(site.id).prebuilt_enabled
    end

    test "and back off again" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: false}, token)

      assert conn.status == 200
      refute Registry.get_site(site.id).prebuilt_enabled
    end
  end

  # Turning the prebuilt lane ON is a CAPABILITY GRANT: afterwards this site will
  # serve bytes its box never built. Wave 9's D97 gated the artifact UPLOAD on
  # `write` and justified it by asserting ability tiers are flat
  # (read/write/root) — but `@abilities ~w(read write deploy root)` has FOUR, and
  # `deploy` already gates domain bind/unbind. So a single `write` PAT both
  # ENABLED the lane and USED it, and the per-site opt-in gated nothing against
  # exactly the credential most likely to be over-scoped.
  describe "PATCH /v1/sites/:id {prebuilt_enabled} credential gating" do
    test "a write-only PAT cannot ENABLE off-box builds → 403, the row is untouched" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "write-key",
          abilities: ["write"]
        })

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: true}, write_token)

      assert conn.status == 403
      assert json_body(conn)["error"] == "deploy_ability_required"
      refute Registry.get_site(site.id).prebuilt_enabled
    end

    # A SESSION carries ["root"], which is `require_ability/2`'s documented
    # superset, so the dashboard toggle keeps working. This is the ONLY credential
    # that can enable the lane today, and that is a consequence of a PRE-EXISTING
    # defect this gate merely exposes — see the deploy-PAT test below.
    test "a session (root) CAN enable it → 200 and the row flips" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: true}, login_token(user))

      assert conn.status == 200
      assert Registry.get_site(site.id).prebuilt_enabled
    end

    # PINS A PRE-EXISTING DEFECT, deliberately, rather than papering over it.
    # The ability model is HIERARCHICAL when minting and FLAT when checking:
    # `UserToken.normalize_abilities/1` collapses ["write","deploy"] to ["deploy"]
    # (treating deploy as ranking above write), but `Auth.require_ability/2`
    # special-cases only "root". So a deploy PAT holds ["deploy"], fails every
    # `write`-gated route — patch, delete, deploy, rollback, promote — and can
    # therefore never reach the gate above. You cannot hold write AND deploy
    # either; normalization removes the write.
    #
    # This assertion documents TODAY's behaviour so the defect is visible instead
    # of folklore. When the model is reconciled, this test should flip to 200 and
    # that flip is the proof the reconciliation worked.
    test "a deploy PAT is refused — the mint/check hierarchy mismatch, pinned" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, deploy_pat, token_row} =
        Accounts.create_personal_access_token(user, team, %{
          name: "deploy-key",
          abilities: ["write", "deploy"]
        })

      # The mint collapsed the pair — this is the hierarchy half of the mismatch.
      assert token_row.abilities == ["deploy"]

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: true}, deploy_pat)

      # ...and the check half refuses it, because only "root" is a superset there.
      assert conn.status == 403
      refute Registry.get_site(site.id).prebuilt_enabled
    end

    # De-escalation is never trapped: whoever may mutate the site may take it
    # back OUT of the riskier mode. Gating the OFF transition too would leave a
    # site stuck accepting off-box bytes with no way for its operator to stop it.
    test "a write-only PAT CAN still turn it off — de-escalation is not gated" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "write-key",
          abilities: ["write"]
        })

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: false}, write_token)

      assert conn.status == 200
      refute Registry.get_site(site.id).prebuilt_enabled
    end

    # This adds ONE gate; it does not re-tier the settings family.
    test "a write-only PAT still patches theme — the family is not re-tiered" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "write-key",
          abilities: ["write"]
        })

      conn = call(:patch, "/v1/sites/#{site.id}", %{theme: "ember"}, write_token)

      assert conn.status == 200
    end
  end

  ## ---------------------------------------------------------------------------
  ## deploy-reliability W17 S5: a driver that never started is not a 201
  ## ---------------------------------------------------------------------------

  # The supervisor refuses the child. Both deploy arms used to run this through
  # `:ok = Sites.Deploy.start(row)` — a wrapper spec'd `:: :ok`, so the match
  # could not fail and the refusal became a `201 created` for a build that does
  # not exist.
  defmodule RefusingStarter do
    @moduledoc false
    @behaviour BarkparkCloud.Sites.Deploy.Starter

    # Mirrors the PRODUCTION refusal shape: `TaskStarter` wraps the
    # `Task.Supervisor.start_child` result, so a `max_children` refusal reaches
    # `start_reported/1` as `{:error, {:error, :max_children}}`. The site unwraps
    # once, so `transport_reason/1` sees `{:error, :max_children}` and answers the
    # bounded busy-box message (transport-leak wave D93).
    @impl true
    def start(_deployment_id), do: {:error, {:error, :max_children}}
  end

  describe "deploy-reliability W17 S5: a refused driver spawn answers 503, not 201" do
    test "POST /v1/sites/:id/deploy (box build) → 503 deploy_not_started, row left queued" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      Process.put(:site_deploy_starter, RefusingStarter)

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{}, token)

      # The 201 is DOWNSTREAM of the start call, so nothing had been sent and the
      # route can still tell the truth.
      assert conn.status == 503
      body = json_body(conn)
      assert body["error"] == "deploy_not_started"
      assert body["detail"] =~ "nothing is building"
      # Redacted (D93): the client sees the bounded busy-box message, never the
      # raw refusal term. The full term is Logger.error'd server-side.
      assert body["reason"] == "the deploy could not be started — the box is busy; retry shortly"
      refute body["reason"] =~ "max_children"

      # The row IS minted and audited — the attempt is on the record, reapable,
      # and named in the body so the operator can go look at it.
      assert dep_id = body["deployment"]["id"]
      assert Registry.get_deployment(dep_id).status == "queued"
    end

    test "POST …/deployments/:dep_id/artifact → 503 telling the caller to MINT A NEW deployment" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      # The mint itself starts no driver (mint-then-upload, charter D86), so it
      # still answers 201 even with a refusing starter installed.
      dep = mint_prebuilt(site, token)
      Process.put(:site_deploy_starter, RefusingStarter)

      payload = :crypto.strong_rand_bytes(1024)
      sha = sha256_hex(payload)

      conn =
        call_binary(
          :post,
          "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact",
          payload,
          token
        )

      assert conn.status == 503
      body = json_body(conn)
      assert body["error"] == "deploy_not_started"
      assert body["artifact_sha256"] == sha
      # Redacted (D93): bounded busy-box message client-side, full term logged.
      assert body["reason"] == "the deploy could not be started — the box is busy; retry shortly"
      refute body["reason"] =~ "max_children"

      # THE INSTRUCTION MUST NOT BE "RE-POST". The bytes are stored, so the
      # retry the caller would reach for is answered `already_uploaded` WITHOUT
      # starting a driver — proven below.
      assert body["detail"] =~ "Mint a NEW prebuilt deployment"
      refute body["detail"] =~ "retry the upload"

      # The stored bytes are retained (that is why the re-POST is a dead end).
      assert Sites.Deploy.artifact_for(dep["id"]).sha256 == sha

      # Proof the copy is honest: the same bytes again → 200 already_uploaded,
      # and the row is STILL queued. Nothing was started by the retry.
      retry =
        call_binary(
          :post,
          "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact",
          payload,
          token
        )

      assert retry.status == 200
      assert json_body(retry)["status"] == "already_uploaded"
      assert Registry.get_deployment(dep["id"]).status == "queued"
    end
  end
end
