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

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

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
end
