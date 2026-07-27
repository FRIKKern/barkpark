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
      {:ok, _d1} = Registry.create_deployment(site, %{git_ref: "a"})
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
      {:ok, _d1} = Registry.create_deployment(site, %{git_ref: "a"})
      {:ok, _d2} = Registry.create_deployment(site, %{git_ref: "b"})
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

  ## POST /v1/sites/:id/artifact — tarball upload (P7).

  describe "POST /v1/sites/:id/artifact" do
    test "writes the body to disk and returns a file:// URL → 201" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "Demo", slug: "demo"})
      token = login_token(user)

      payload = :crypto.strong_rand_bytes(2048)

      conn =
        call_binary(:post, "/v1/sites/#{site.id}/artifact", payload, token)

      assert conn.status == 201
      body = json_body(conn)
      url = body["artifact_url"]
      assert is_binary(url)
      assert String.starts_with?(url, "file://")
      assert body["bytes"] == byte_size(payload)
      filename = body["filename"]
      assert String.starts_with?(filename, "demo-")
      assert String.ends_with?(filename, ".tar.gz")

      # And the file on disk has the exact bytes that came in.
      "file://" <> path = url
      assert File.read!(path) == payload

      # Clean up.
      _ = File.rm(path)
    end

    test "another team's site → 404 (no existence leak)" do
      {_o, other_team} = user_with_team()
      other_bp = barkpark_fixture(other_team)
      {:ok, other_site} = Registry.create_site(other_bp, %{name: "S", slug: "s"})

      {user, _team} = user_with_team()
      token = login_token(user)

      conn = call_binary(:post, "/v1/sites/#{other_site.id}/artifact", "ignored", token)
      assert conn.status == 404
    end

    test "body larger than the cap → 413 + no partial file" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "Big", slug: "big"})
      token = login_token(user)

      # test.exs caps max_artifact_bytes at 1 MiB; ship 2 MiB.
      big = :binary.copy(<<0>>, 2 * 1024 * 1024)
      conn = call_binary(:post, "/v1/sites/#{site.id}/artifact", big, token)
      assert conn.status == 413
      assert json_body(conn)["error"] == "artifact_too_large"
    end

    test "without auth → 401" do
      conn = call_binary(:post, "/v1/sites/x/artifact", "x", nil)
      assert conn.status == 401
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
      # A site that cannot read its content is not a site. Nothing was written.
      assert Registry.list_sites_for_team(team) == []
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

      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000001"})
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

      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000001"})
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
end
