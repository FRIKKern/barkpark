defmodule BarkparkCloud.Web.RouterGithubConnectTest do
  @moduledoc """
  The "Import Git Repository" surface (gh-4):

      GET   /v1/github/repos                the installation's repo picker
      POST  /v1/sites/:id/github/connect    auto-register the push webhook on GitHub

  Fake-backed end-to-end: connect installation → list repos → connect the repo to
  a Site → the fake records EXACTLY ONE webhook with the right url + secret +
  events → a simulated SIGNED push to the linked branch enqueues a Deployment →
  a wrong-branch push does not → a bad signature is 401. Plus the honest error
  surface (503 unconfigured / 409 no_installation / 422 repo_not_in_installation),
  RBAC (admin-only), cross-team isolation, and re-connect idempotency.

  `async: false` — the connect path toggles the global `BarkparkCloud.GitHub` app
  env to simulate a wired App (the client stays the in-memory Fake, so €0).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, GitHub, Registry}
  alias BarkparkCloud.GitHub.Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures ────────────────────────────────────────────────────────────────

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

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(team) do
    bp = barkpark_fixture(team)

    {:ok, site} =
      Registry.create_site(bp, %{name: "X", slug: "x-#{System.unique_integer([:positive])}"})

    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # Simulate a wired GitHub App so `configured?/0` is true. The client stays the
  # in-memory Fake — validation + registration are €0.
  defp configure_github do
    base = Application.get_env(:barkpark_cloud, GitHub, [])

    Application.put_env(
      :barkpark_cloud,
      GitHub,
      Keyword.merge(base, app_id: "test-app-id", private_key: "dummy-pem", app_slug: "bp-deploy")
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)
  end

  ## Request helpers ──────────────────────────────────────────────────────────

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

  # A push POST to the inbound webhook, signed with `secret` (or an override sig).
  defp webhook_call(site_id, event, body_map, secret, opts \\ []) do
    raw = Jason.encode!(body_map)

    sig =
      case Keyword.get(opts, :sig) do
        nil ->
          "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower))

        s ->
          s
      end

    conn(:post, "/v1/webhooks/github/#{site_id}", raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-hub-signature-256", sig)
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  ## GET /v1/github/repos ──────────────────────────────────────────────────────

  describe "GET /v1/github/repos" do
    test "unauthenticated → 401" do
      assert call(:get, "/v1/github/repos", nil, nil).status == 401
    end

    test "not configured → 503 feature_not_configured" do
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")

      conn = call(:get, "/v1/github/repos", nil, login_token(user))
      assert conn.status == 503
      assert body(conn)["error"] == "feature_not_configured"
    end

    test "configured but no installation → 409 no_installation" do
      configure_github()
      {user, _team} = user_with_team("owner")

      conn = call(:get, "/v1/github/repos", nil, login_token(user))
      assert conn.status == 409
      assert body(conn)["error"] == "no_installation"
    end

    test "connected → lists the installation's repos (full_name + private only)" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")

      conn = call(:get, "/v1/github/repos", nil, login_token(user))
      assert conn.status == 200
      assert body(conn)["repos"] == [%{"full_name" => "octo-4242/example", "private" => false}]
    end

    test "a plain member can read the picker" do
      configure_github()
      {_owner, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      conn = call(:get, "/v1/github/repos", nil, login_token(member))
      assert conn.status == 200
    end
  end

  ## POST /v1/sites/:id/github/connect ─────────────────────────────────────────

  describe "POST /v1/sites/:id/github/connect — guards" do
    test "unauthenticated → 401" do
      site_id = Ecto.UUID.generate()

      assert call(:post, "/v1/sites/#{site_id}/github/connect", %{repo_full_name: "a/b"}, nil).status ==
               401
    end

    test "not configured → 503" do
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github/connect",
          %{repo_full_name: "octo-4242/example"},
          login_token(user)
        )

      assert conn.status == 503
      assert body(conn)["error"] == "feature_not_configured"
    end

    test "member (not admin) → 403" do
      configure_github()
      {_owner, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github/connect",
          %{repo_full_name: "octo-4242/example"},
          login_token(member)
        )

      assert conn.status == 403
    end

    test "no installation → 409 no_installation" do
      configure_github()
      {user, team} = user_with_team("owner")
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github/connect",
          %{repo_full_name: "octo-4242/example"},
          login_token(user)
        )

      assert conn.status == 409
      assert body(conn)["error"] == "no_installation"
    end

    test "repo not in the installation → 422 repo_not_in_installation" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github/connect",
          %{repo_full_name: "someone-else/private"},
          login_token(user)
        )

      assert conn.status == 422
      assert body(conn)["error"] == "repo_not_in_installation"
    end

    test "missing repo_full_name → 422" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)

      conn = call(:post, "/v1/sites/#{site.id}/github/connect", %{}, login_token(user))
      assert conn.status == 422
      assert body(conn)["error"] == "repo_full_name_required"
    end

    test "another team's site → 404 (no existence leak)" do
      configure_github()
      {_o, other_team} = user_with_team("owner")
      other_site = site_fixture(other_team)

      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")

      conn =
        call(
          :post,
          "/v1/sites/#{other_site.id}/github/connect",
          %{repo_full_name: "octo-4242/example"},
          login_token(user)
        )

      assert conn.status == 404
    end
  end

  ## The full Vercel "Import Git Repository" loop ──────────────────────────────

  describe "end-to-end: connect → one webhook → signed push deploys" do
    test "connect registers exactly one push webhook with the right url + secret" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github/connect",
          %{repo_full_name: "octo-4242/example", branch: "main"},
          login_token(user)
        )

      assert conn.status == 200
      b = body(conn)
      assert b["repo_full_name"] == "octo-4242/example"
      assert b["branch"] == "main"
      assert b["site"]["github_repo"] == "octo-4242/example"
      assert b["site"]["github_webhook_configured"] == true
      # The secret is NEVER echoed on this path (auto-registered, not pasted).
      refute Map.has_key?(b, "webhook_secret")

      expected_url = "http://www.example.com/v1/webhooks/github/#{site.id}"
      assert b["webhook_url"] == expected_url

      # EXACTLY ONE webhook registered on GitHub (the fake), events: push, and the
      # registered secret === the secret persisted for inbound verification.
      {:ok, stored_secret} = Registry.reveal_site_github_secret(Registry.get_site(site.id))

      assert [%{repo: "octo-4242/example", url: ^expected_url, secret: ^stored_secret}] =
               Fake.registered_webhooks()

      assert is_binary(stored_secret) and byte_size(stored_secret) >= 32
    end

    test "a SIGNED push to the linked branch records a born-FAILED Deployment (fail-fast interim)" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)

      assert call(
               :post,
               "/v1/sites/#{site.id}/github/connect",
               %{repo_full_name: "octo-4242/example", branch: "main"},
               login_token(user)
             ).status == 200

      {:ok, secret} = Registry.reveal_site_github_secret(Registry.get_site(site.id))

      sha = "abc123abc123abc123abc123abc123abc123abcd"
      push = %{"ref" => "refs/heads/main", "after" => sha}

      conn = webhook_call(site.id, "push", push, secret)
      assert conn.status == 201
      assert body(conn)["branch"] == "main"
      # dwb-webhook fail-fast interim: building a push from source needs gh-1 (the
      # GitHub App integration), which isn't wired yet — recording an installation
      # id does NOT enable source builds. So the row is born terminal-FAILED with a
      # human reason instead of a source-less "queued" zombie the builder never
      # claims. gh-1 flips github_build_available?/1 back to the enqueue path.
      assert body(conn)["status"] == "failed"

      [dep] = Registry.list_deployments(site)
      assert dep.git_ref == sha
      assert dep.status == "failed"
      assert dep.failure_reason =~ "github push builds"
    end

    test "gh-6: a push to a NON-production branch creates a PREVIEW, not a production deploy" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)

      assert call(
               :post,
               "/v1/sites/#{site.id}/github/connect",
               %{repo_full_name: "octo-4242/example", branch: "main"},
               login_token(user)
             ).status == 200

      {:ok, secret} = Registry.reveal_site_github_secret(Registry.get_site(site.id))

      push = %{"ref" => "refs/heads/dev", "after" => String.duplicate("f", 40)}
      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 201
      assert body(conn)["environment"] == "preview"
      assert body(conn)["branch"] == "dev"

      # A preview exists; the PRODUCTION slot has no deployment.
      assert Registry.list_deployments(site, 100, environment: "production") == []
      assert [%{environment: "preview", branch: "dev"}] = Registry.list_preview_deployments(site)
      assert Registry.get_site(site.id).current_deployment_id == nil
    end

    test "a BAD signature is 401 and creates no Deployment" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)

      assert call(
               :post,
               "/v1/sites/#{site.id}/github/connect",
               %{repo_full_name: "octo-4242/example"},
               login_token(user)
             ).status == 200

      push = %{"ref" => "refs/heads/main", "after" => String.duplicate("a", 40)}

      conn =
        webhook_call(site.id, "push", push, "not-the-secret",
          sig: "sha256=" <> String.duplicate("0", 64)
        )

      assert conn.status == 401
      assert Registry.list_deployments(site) == []
    end

    test "re-connect replaces the hook (no duplicate) and rotates the secret" do
      configure_github()
      {user, team} = user_with_team("owner")
      {:ok, _} = GitHub.record_installation(team, "4242")
      site = site_fixture(team)
      token = login_token(user)

      assert call(
               :post,
               "/v1/sites/#{site.id}/github/connect",
               %{repo_full_name: "octo-4242/example"},
               token
             ).status == 200

      {:ok, first_secret} = Registry.reveal_site_github_secret(Registry.get_site(site.id))

      assert call(
               :post,
               "/v1/sites/#{site.id}/github/connect",
               %{repo_full_name: "octo-4242/example"},
               token
             ).status == 200

      {:ok, second_secret} = Registry.reveal_site_github_secret(Registry.get_site(site.id))

      # Secret rotated, but STILL exactly one webhook registered on GitHub.
      refute second_secret == first_secret
      assert length(Fake.registered_webhooks()) == 1
      assert [%{secret: ^second_secret}] = Fake.registered_webhooks()

      # The old secret no longer verifies; the new one does.
      sha = "cafebabecafebabecafebabecafebabecafebabe"
      push = %{"ref" => "refs/heads/main", "after" => sha}

      assert webhook_call(site.id, "push", push, first_secret).status == 401
      assert webhook_call(site.id, "push", push, second_secret).status == 201
    end
  end
end
