defmodule BarkparkCloud.Web.RouterGithubWebhookTest do
  @moduledoc """
  Drives the P7 stream B (github-webhook) surface added to the control plane:

      POST   /v1/sites/:id/github           user-auth — link repo + branch + secret
      POST   /v1/webhooks/github/:site_id   NO auth — verified via HMAC-SHA256

  The webhook route is the sensitive one — it has to:
    * verify the X-Hub-Signature-256 in constant time (no timing oracle)
    * 401 on a bad signature
    * 200 + no-op for events != "push" or pushes to the wrong branch
    * create a Deployment with git_ref = the pushed commit sha on a valid
      push to the configured branch
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

    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp site_with_github(team, attrs \\ %{}) do
    bp = barkpark_fixture(team)

    {:ok, site} =
      Registry.create_site(bp, %{name: "X", slug: "x-#{System.unique_integer([:positive])}"})

    repo = Map.get(attrs, :repo, "owner/repo")
    branch = Map.get(attrs, :branch, "main")
    secret = Map.get(attrs, :secret, "the-secret")

    {:ok, site} = Registry.set_site_github(site, repo, branch, secret)
    {site, secret}
  end

  ## Request helpers

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

  # Calls the webhook route with a raw JSON body + the GitHub headers, signed
  # with `secret`. When `sig` is given it overrides the computed signature
  # (used to test bad-signature paths).
  defp webhook_call(site_id, event, body_map, secret, opts \\ []) do
    raw = Jason.encode!(body_map)

    sig =
      case Keyword.get(opts, :sig) do
        nil ->
          "sha256=" <>
            (:crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower))

        s ->
          s
      end

    conn(:post, "/v1/webhooks/github/#{site_id}", raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-hub-signature-256", sig)
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## POST /v1/sites/:id/github — configure

  describe "POST /v1/sites/:id/github" do
    test "valid body → 200 {site, webhook_url, webhook_secret}" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github",
          %{repo: "FRIKKern/barkpark", branch: "main"},
          token
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["site"]["github_repo"] == "FRIKKern/barkpark"
      assert body["site"]["github_branch"] == "main"
      assert body["site"]["github_webhook_configured"] == true
      assert is_binary(body["webhook_secret"])
      assert byte_size(body["webhook_secret"]) >= 32
      assert String.ends_with?(body["webhook_url"], "/v1/webhooks/github/#{site.id}")
      # The secret column NEVER carries plaintext.
      reloaded = Registry.get_site(site.id)
      assert reloaded.github_webhook_secret_encrypted != body["webhook_secret"]
      assert is_binary(reloaded.github_webhook_secret_encrypted)
      {:ok, plaintext} = Registry.reveal_site_github_secret(reloaded)
      assert plaintext == body["webhook_secret"]
    end

    test "user-supplied webhook_secret is honoured" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      mine = "my-own-rotation-secret-1234567890"

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github",
          %{repo: "FRIKKern/barkpark", webhook_secret: mine},
          token
        )

      assert conn.status == 200
      assert json_body(conn)["webhook_secret"] == mine
      {:ok, plain} = Registry.reveal_site_github_secret(Registry.get_site(site.id))
      assert plain == mine
    end

    test "missing repo → 422" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn = call(:post, "/v1/sites/#{site.id}/github", %{}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "repo_required"
    end

    test "malformed repo → 422" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn =
        call(:post, "/v1/sites/#{site.id}/github", %{repo: "not-a-valid-shape"}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
    end

    test "another team's site → 404 (no existence leak)" do
      {_o, other_team} = user_with_team()
      other_bp = barkpark_fixture(other_team)
      {:ok, other_site} = Registry.create_site(other_bp, %{name: "S", slug: "s"})

      {user, _team} = user_with_team()
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites/#{other_site.id}/github",
          %{repo: "FRIKKern/barkpark"},
          token
        )

      assert conn.status == 404
    end

    test "branch defaults to main when omitted" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})
      token = login_token(user)

      conn =
        call(:post, "/v1/sites/#{site.id}/github", %{repo: "FRIKKern/barkpark"}, token)

      assert conn.status == 200
      assert json_body(conn)["site"]["github_branch"] == "main"
    end
  end

  ## POST /v1/webhooks/github/:site_id — verify HMAC

  describe "POST /v1/webhooks/github/:site_id — signature verification" do
    test "valid HMAC over push payload on the right branch → creates Deployment" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      push = %{
        "ref" => "refs/heads/main",
        "after" => "abc123abc123abc123abc123abc123abc123abcd",
        "head_commit" => %{"id" => "abc123abc123abc123abc123abc123abc123abcd"}
      }

      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 201
      body = json_body(conn)
      assert body["ok"] == true
      assert body["sha"] == "abc123abc123abc123abc123abc123abc123abcd"
      assert body["branch"] == "main"
      assert is_binary(body["deployment_id"])

      # A Deployment row exists for this site with git_ref = the sha.
      [dep] = Registry.list_deployments(site)
      assert dep.git_ref == "abc123abc123abc123abc123abc123abc123abcd"
      assert dep.status == "queued"
      # MVP: no artifact yet — the row is the pure "this commit happened" signal.
      assert dep.artifact_url == nil
    end

    test "BAD signature → 401, no Deployment" do
      {_user, team} = user_with_team()
      {site, _secret} = site_with_github(team)

      push = %{"ref" => "refs/heads/main", "after" => "deadbeef" |> String.duplicate(5)}

      conn =
        webhook_call(site.id, "push", push, "the-secret",
          sig: "sha256=" <> String.duplicate("0", 64)
        )

      assert conn.status == 401
      assert json_body(conn)["error"] == "bad_signature"
      assert Registry.list_deployments(site) == []
    end

    test "missing X-Hub-Signature-256 header → 401" do
      {_user, team} = user_with_team()
      {site, _secret} = site_with_github(team)

      raw = Jason.encode!(%{"ref" => "refs/heads/main", "after" => "xx"})

      conn =
        conn(:post, "/v1/webhooks/github/#{site.id}", raw)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> Router.call(@opts)

      assert conn.status == 401
    end

    test "site without github config → 404 (does not leak the difference)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x"})

      push = %{"ref" => "refs/heads/main", "after" => "deadbeef"}

      conn = webhook_call(site.id, "push", push, "any-secret")

      assert conn.status == 404
      assert Registry.list_deployments(site) == []
    end

    test "unknown site id → 404" do
      conn = webhook_call(Ecto.UUID.generate(), "push", %{}, "secret")
      assert conn.status == 404
    end

    test "REPLAY: a signature valid for one body must NOT validate a tampered body" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      original = %{"ref" => "refs/heads/main", "after" => "aaaaaaaaaaaaaaaa"}
      original_raw = Jason.encode!(original)

      good_sig =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, secret, original_raw) |> Base.encode16(case: :lower))

      # Now send a DIFFERENT body with the original signature — must 401.
      tampered_raw = Jason.encode!(%{"ref" => "refs/heads/main", "after" => "bbbbbbbb"})

      conn =
        conn(:post, "/v1/webhooks/github/#{site.id}", tampered_raw)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", good_sig)
        |> Router.call(@opts)

      assert conn.status == 401
      assert Registry.list_deployments(site) == []
    end

    test "RE-DELIVER: the same valid body+signature ACCEPTED twice (GitHub redelivery)" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      push = %{
        "ref" => "refs/heads/main",
        "after" => "cafebabecafebabecafebabecafebabecafebabe"
      }

      c1 = webhook_call(site.id, "push", push, secret)
      c2 = webhook_call(site.id, "push", push, secret)

      assert c1.status == 201
      assert c2.status == 201
      # Two Deployments, one per delivery — re-delivery is by design accepted.
      assert length(Registry.list_deployments(site)) == 2
    end
  end

  ## Event + branch filtering (still HMAC-verified, but 200 no-op)

  describe "POST /v1/webhooks/github/:site_id — event + branch filtering" do
    test "X-GitHub-Event: ping → 200 pong (HMAC must still pass)" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      conn =
        webhook_call(
          site.id,
          "ping",
          %{"zen" => "Half measures are as bad as nothing at all."},
          secret
        )

      assert conn.status == 200
      assert json_body(conn)["pong"] == true
      assert Registry.list_deployments(site) == []
    end

    test "unsupported event (pull_request) → 200 ignored, no Deployment" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      conn = webhook_call(site.id, "pull_request", %{"action" => "opened"}, secret)

      assert conn.status == 200
      assert json_body(conn)["ignored"] == true
      assert json_body(conn)["reason"] == "unsupported_event"
      assert Registry.list_deployments(site) == []
    end

    test "push to the WRONG branch → 200 ignored (branch_mismatch), no Deployment" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      push = %{
        "ref" => "refs/heads/dev",
        "after" => "feedface" |> String.duplicate(5)
      }

      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 200
      body = json_body(conn)
      assert body["ignored"] == true
      assert body["reason"] == "branch_mismatch"
      assert body["pushed_ref"] == "refs/heads/dev"
      assert body["expected_ref"] == "refs/heads/main"
      assert Registry.list_deployments(site) == []
    end

    test "push to a configured non-main branch → creates Deployment" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "production"})

      sha = "1234567890abcdef1234567890abcdef12345678"
      push = %{"ref" => "refs/heads/production", "after" => sha}

      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 201
      assert json_body(conn)["branch"] == "production"
      assert json_body(conn)["sha"] == sha
      [dep] = Registry.list_deployments(site)
      assert dep.git_ref == sha
    end

    test "push without a head sha → 200 ignored (missing_sha)" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      conn = webhook_call(site.id, "push", %{"ref" => "refs/heads/main"}, secret)

      assert conn.status == 200
      assert json_body(conn)["ignored"] == true
      assert json_body(conn)["reason"] == "missing_sha"
      assert Registry.list_deployments(site) == []
    end
  end
end
