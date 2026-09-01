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

    site_attrs = %{name: "X", slug: "x-#{System.unique_integer([:positive])}"}

    site_attrs =
      case Map.fetch(attrs, :previews_enabled) do
        {:ok, v} -> Map.put(site_attrs, :previews_enabled, v)
        :error -> site_attrs
      end

    {:ok, site} = Registry.create_site(bp, site_attrs)

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
  # (used to test bad-signature paths). `delivery` sets X-GitHub-Delivery (the
  # dwb-18 idempotency key).
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
    |> maybe_put_delivery(Keyword.get(opts, :delivery))
    |> Router.call(@opts)
  end

  defp maybe_put_delivery(conn, nil), do: conn
  defp maybe_put_delivery(conn, id), do: put_req_header(conn, "x-github-delivery", id)

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

    # The secret is the HMAC key for POST /v1/webhooks/github/:site_id, a route
    # with no bearer auth by design. A caller who CHOSE it would hold a deploy
    # trigger that is not team-scoped, not session-tied, not revoked when they
    # lose access, and not visible in the audit log. So the server mints it and
    # the request body cannot override that. This inverts an earlier decision
    # ("user-supplied webhook_secret is honoured"); the field is now ignored.
    test "a caller-supplied webhook_secret is IGNORED — the server mints it" do
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

      returned = json_body(conn)["webhook_secret"]
      assert returned != mine
      assert byte_size(returned) >= 32

      # And the caller's value never reaches the store either — a member who
      # posts a secret must not be able to predict the persisted HMAC key.
      {:ok, plain} = Registry.reveal_site_github_secret(Registry.get_site(site.id))
      assert plain != mine
      assert plain == returned
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
    test "valid HMAC over push payload on the right branch → QUEUED buildable Deployment (git-ref clone lane)" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      push = %{
        "ref" => "refs/heads/main",
        "after" => "abc123abc123abc123abc123abc123abc123abcd",
        "head_commit" => %{"id" => "abc123abc123abc123abc123abc123abc123abcd"}
      }

      conn = webhook_call(site.id, "push", push, secret)

      # git-ref clone lane: the site is repo-backed (github_build_available?/1),
      # so the push mints a QUEUED artifact-less deployment the builder claims —
      # push-to-deploy is real. No failure, no reason.
      assert conn.status == 201
      body = json_body(conn)
      assert body["ok"] == true
      assert body["sha"] == "abc123abc123abc123abc123abc123abc123abcd"
      assert body["branch"] == "main"
      assert body["environment"] == "production"
      assert body["status"] == "queued"
      assert body["reason"] == nil

      assert is_binary(body["deployment_id"])

      # A Deployment row exists, born QUEUED, with git_ref = the pushed sha and
      # no failure reason.
      [dep] = Registry.list_deployments(site)
      assert dep.git_ref == "abc123abc123abc123abc123abc123abc123abcd"
      assert dep.status == "queued"
      assert dep.failure_reason == nil
      # No artifact — the builder clones the repo at git_ref via the
      # claim-envelope source instead of pulling an uploaded artifact.
      assert dep.artifact_url == nil

      # The queued row IS active — claimable by the builder, and the dedup gate
      # a same-sha redelivery lands on.
      assert Registry.find_active_deployment(site.id, dep.git_ref).id == dep.id
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

    test "RE-DELIVER: a real redelivery (same X-GitHub-Delivery) is deduped (one row per commit)" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      push = %{
        "ref" => "refs/heads/main",
        "after" => "cafebabecafebabecafebabecafebabecafebabe"
      }

      # A REAL GitHub redelivery carries the SAME X-GitHub-Delivery header, so it
      # dedups via gate 1 (find_deployment_by_delivery_id) — which is NOT
      # status-scoped, so it points back at the queued build regardless of where
      # its state machine has moved since.
      delivery = "delivery-#{System.unique_integer([:positive])}"
      c1 = webhook_call(site.id, "push", push, secret, delivery: delivery)
      c2 = webhook_call(site.id, "push", push, secret, delivery: delivery)

      assert c1.status == 201
      first_id = json_body(c1)["deployment_id"]

      # The redelivery 200s (so GitHub stops retrying) but does NOT mint a second
      # row — it points back at the deployment minted for this delivery.
      assert c2.status == 200
      body2 = json_body(c2)
      assert body2["ignored"] == true
      assert body2["reason"] == "duplicate_delivery"
      assert body2["deployment_id"] == first_id

      # Exactly one Deployment exists — no duplicate.
      assert length(Registry.list_deployments(site)) == 1
    end

    test "dwb-18 REDELIVER-AFTER-LIVE: same X-GitHub-Delivery after the build went live → the existing row, no second build" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      push = %{
        "ref" => "refs/heads/main",
        "after" => "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
      }

      delivery = "delivery-#{System.unique_integer([:positive])}"

      c1 = webhook_call(site.id, "push", push, secret, delivery: delivery)
      assert c1.status == 201
      first_id = json_body(c1)["deployment_id"]

      # Walk the deployment all the way to live so find_active_deployment would
      # NOT match it — only the delivery_id gate can dedup now.
      dep = Registry.get_deployment(first_id)
      {:ok, dep} = Registry.transition_deployment(dep, %{status: "building"})
      {:ok, dep} = Registry.transition_deployment(dep, %{status: "pushing"})
      {:ok, _dep} = Registry.transition_deployment(dep, %{status: "live"})

      c2 = webhook_call(site.id, "push", push, secret, delivery: delivery)
      assert c2.status == 200
      body2 = json_body(c2)
      assert body2["ignored"] == true
      assert body2["reason"] == "duplicate_delivery"
      assert body2["deployment_id"] == first_id

      # No second row — the live build was NOT rebuilt.
      assert length(Registry.list_deployments(site)) == 1
    end

    test "dwb-18 CONCURRENT: two POSTs with the same X-GitHub-Delivery → exactly one Deployment, both 2xx" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      push = %{
        "ref" => "refs/heads/main",
        "after" => "1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a"
      }

      delivery = "delivery-concurrent-#{System.unique_integer([:positive])}"

      # Share the sandbox connection so both Tasks see the same DB transaction.
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(BarkparkCloud.Repo, parent, self())
            webhook_call(site.id, "push", push, secret, delivery: delivery)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # Both requests are 2xx (201 for the winner, 200 duplicate for the loser).
      assert Enum.all?(results, &(&1.status in [200, 201]))
      # Exactly one succeeded with 201; the other deduped.
      assert Enum.count(results, &(&1.status == 201)) == 1
      assert Enum.count(results, &(&1.status == 200)) == 1

      # And exactly one row exists.
      assert length(Registry.list_deployments(site)) == 1
    end

    test "git-ref clone lane SAME-SHA DIFFERENT-DELIVERY: the live queued build dedups the second delivery → one row" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      push = %{
        "ref" => "refs/heads/main",
        "after" => "2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b"
      }

      c1 = webhook_call(site.id, "push", push, secret, delivery: "delivery-A")
      assert c1.status == 201
      first_id = json_body(c1)["deployment_id"]

      # A fresh delivery id for the same commit: the first row was born QUEUED —
      # an ACTIVE build — so gate 2 (find_active_deployment, the site+ref gate)
      # dedups the second delivery against it. 200 (GitHub stops retrying),
      # ONE row: one commit is never built twice.
      c2 = webhook_call(site.id, "push", push, secret, delivery: "delivery-B")
      assert c2.status == 200
      body2 = json_body(c2)
      assert body2["ignored"] == true
      assert body2["reason"] == "duplicate_delivery"
      assert body2["deployment_id"] == first_id

      # Exactly one row exists — still queued, still the builder's to claim.
      [dep] = Registry.list_deployments(site)
      assert dep.id == first_id
      assert dep.status == "queued"
    end

    test "dwb-webhook REDELIVER (same delivery id) dedups via the delivery gate → one row" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team)

      push = %{
        "ref" => "refs/heads/main",
        "after" => "3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c"
      }

      delivery = "delivery-redeliver-#{System.unique_integer([:positive])}"

      c1 = webhook_call(site.id, "push", push, secret, delivery: delivery)
      assert c1.status == 201
      first_id = json_body(c1)["deployment_id"]

      # gate 1 (find_deployment_by_delivery_id) is NOT status-scoped — the
      # delivery_id partial unique index points at the row whatever its status,
      # so a redelivery of the SAME delivery id 200s the existing row, no
      # second row.
      c2 = webhook_call(site.id, "push", push, secret, delivery: delivery)
      assert c2.status == 200
      body2 = json_body(c2)
      assert body2["ignored"] == true
      assert body2["reason"] == "duplicate_delivery"
      assert body2["deployment_id"] == first_id

      assert length(Registry.list_deployments(site)) == 1
    end

    test "BRANCH DELETE (deleted:true, after 40 zeros, head_commit nil) → 200 branch_deleted, no build" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      push = %{
        "ref" => "refs/heads/main",
        "deleted" => true,
        "after" => String.duplicate("0", 40),
        "head_commit" => nil
      }

      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 200
      body = json_body(conn)
      assert body["ignored"] == true
      assert body["reason"] == "branch_deleted"
      assert Registry.list_deployments(site) == []
    end

    test "non-hex after → 200 invalid_sha, no build" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      push = %{"ref" => "refs/heads/main", "after" => "not-hex"}

      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 200
      body = json_body(conn)
      assert body["ignored"] == true
      assert body["reason"] == "invalid_sha"
      assert Registry.list_deployments(site) == []
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

    test "gh-6: push to a NON-production branch → 201 preview (previews on by default)" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      push = %{
        "ref" => "refs/heads/dev",
        "after" => "feedface" |> String.duplicate(5)
      }

      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 201
      body = json_body(conn)
      assert body["environment"] == "preview"
      assert body["branch"] == "dev"
      assert String.starts_with?(body["preview_url"], "https://")
      assert String.ends_with?(body["preview_host"], ".barkpark.cloud")
      # A PREVIEW deployment exists; the production slot is untouched.
      [dep] = Registry.list_deployments(site)
      assert dep.environment == "preview"
      assert dep.branch == "dev"
      assert Registry.get_site(site.id).current_deployment_id == nil
    end

    test "gh-6: NON-production branch push with previews disabled → 200 ignored" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main", previews_enabled: false})

      push = %{
        "ref" => "refs/heads/dev",
        "after" => "feedface" |> String.duplicate(5)
      }

      conn = webhook_call(site.id, "push", push, secret)

      assert conn.status == 200
      body = json_body(conn)
      assert body["ignored"] == true
      assert body["reason"] == "previews_disabled"
      assert body["branch"] == "dev"
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

  ## gh-6 — branch previews: routing, replace-per-branch, cap, teardown, TLS-ask.

  # A deterministic 40-hex-char object name from a seed (sha1 → 40 hex chars).
  defp sha(seed), do: :crypto.hash(:sha, seed) |> Base.encode16(case: :lower)

  defp push_branch(site, secret, branch, sha, opts \\ []) do
    webhook_call(
      site.id,
      "push",
      %{"ref" => "refs/heads/#{branch}", "after" => sha},
      secret,
      opts
    )
  end

  describe "gh-6 branch previews" do
    test "a new push to the same branch REPLACES the branch's preview" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      c1 = push_branch(site, secret, "feature/login", sha("c1"))
      assert c1.status == 201
      first_id = json_body(c1)["deployment_id"]

      c2 = push_branch(site, secret, "feature/login", sha("c2"))
      assert c2.status == 201
      second_id = json_body(c2)["deployment_id"]
      refute second_id == first_id

      # Same branch → same preview host (blue/green replace in place).
      assert json_body(c1)["preview_host"] == json_body(c2)["preview_host"]

      # Only the latest push is an ACTIVE preview for the branch; the first is
      # cancelled (superseded).
      previews = Registry.list_preview_deployments(site)
      assert length(previews) == 1
      assert hd(previews).id == second_id

      superseded = Registry.get_deployment(first_id)
      assert superseded.status == "cancelled"
      assert Enum.any?(superseded.console, &(&1["line"] =~ "superseded"))
    end

    test "a preview activation NEVER touches the production slot" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      assert push_branch(site, secret, "dev", sha("x")).status == 201

      reloaded = Registry.get_site(site.id)
      assert reloaded.current_deployment_id == nil
      assert reloaded.port == nil
    end

    test "concurrent previews are capped per site — oldest branch evicted" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      cap = Registry.max_previews_per_site()

      # Push cap+1 DISTINCT branches; the first (oldest) must be evicted.
      branches = for i <- 0..cap, do: "b#{i}"

      for b <- branches do
        assert push_branch(site, secret, b, sha(b)).status == 201
      end

      active = Registry.list_preview_deployments(site)
      assert length(active) == cap
      active_branches = MapSet.new(Enum.map(active, & &1.branch))

      # The oldest branch (b0) is gone; the newest (b<cap>) is present.
      refute MapSet.member?(active_branches, "b0")
      assert MapSet.member?(active_branches, "b#{cap}")
    end

    test "branch DELETE tears down that branch's preview" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      create = push_branch(site, secret, "temp", sha("t"))
      assert create.status == 201
      dep_id = json_body(create)["deployment_id"]

      del =
        webhook_call(
          site.id,
          "push",
          %{
            "ref" => "refs/heads/temp",
            "deleted" => true,
            "after" => String.duplicate("0", 40),
            "head_commit" => nil
          },
          secret
        )

      assert del.status == 200
      body = json_body(del)
      assert body["preview_torn_down"] == true
      assert body["branch"] == "temp"
      assert body["count"] == 1

      assert Registry.get_deployment(dep_id).status == "cancelled"
      assert Registry.list_preview_deployments(site) == []
    end

    test "GET /v1/tls/ask accepts a live preview host, 404s a stranger" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      create = push_branch(site, secret, "dev", sha("d"))
      host = json_body(create)["preview_host"]

      ok = call(:get, "/v1/tls/ask?domain=#{host}", nil, nil)
      assert ok.status == 200

      nope = call(:get, "/v1/tls/ask?domain=not-a-preview.barkpark.cloud", nil, nil)
      assert nope.status == 404
    end

    test "a torn-down preview host is no longer TLS-allowlisted" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      create = push_branch(site, secret, "dev", sha("d"))
      host = json_body(create)["preview_host"]
      assert call(:get, "/v1/tls/ask?domain=#{host}", nil, nil).status == 200

      Registry.teardown_branch_previews(site, "dev")
      assert call(:get, "/v1/tls/ask?domain=#{host}", nil, nil).status == 404
    end

    test "a tag push (non-branch ref) is ignored" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      conn =
        webhook_call(
          site.id,
          "push",
          %{"ref" => "refs/tags/v1.0.0", "after" => sha("tag")},
          secret
        )

      assert conn.status == 200
      assert json_body(conn)["reason"] == "non_branch_ref"
      assert Registry.list_deployments(site) == []
    end

    test "a preview at the same sha does NOT mask a production deploy" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      shared = sha("shared-head")

      # A feature branch preview lands first at this sha (still ACTIVE — this is
      # also the regression test for the dwb-18 active-site-ref index re-scope:
      # unscoped, the production INSERT below would violate it)...
      assert push_branch(site, secret, "feature", shared).status == 201
      # ...then main is pushed at the SAME sha — must still create production.
      prod = push_branch(site, secret, "main", shared)
      assert prod.status == 201
      assert json_body(prod)["environment"] == "production"

      assert length(Registry.list_deployments(site, 100, environment: "production")) == 1
      # Both are ACTIVE simultaneously — one production build + one preview.
      assert [%{status: "queued"}] = Registry.list_preview_deployments(site)
    end

    test "an active production build at the same sha does not block a preview" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      shared = sha("prod-first")

      assert push_branch(site, secret, "main", shared).status == 201
      prev = push_branch(site, secret, "feature", shared)
      assert prev.status == 201
      assert json_body(prev)["environment"] == "preview"
    end

    test "two DIFFERENT preview branches at the same sha are both active" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      shared = sha("two-branches-one-head")

      assert push_branch(site, secret, "feat/a", shared).status == 201
      assert push_branch(site, secret, "feat/b", shared).status == 201

      branches = Registry.list_preview_deployments(site) |> Enum.map(& &1.branch) |> Enum.sort()
      assert branches == ["feat/a", "feat/b"]
    end

    test "dwb-18: preview redelivery by X-GitHub-Delivery after the preview went live → existing row" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      delivery = "preview-delivery-#{System.unique_integer([:positive])}"

      c1 = push_branch(site, secret, "dev", sha("d1"), delivery: delivery)
      assert c1.status == 201
      first_id = json_body(c1)["deployment_id"]

      # Walk the preview to live so find_active_preview (queued/building/pushing
      # + live matches, but prove the delivery gate alone suffices) — go further:
      # CANCEL it via teardown, so ONLY the delivery_id gate can dedup.
      assert Registry.teardown_branch_previews(site, "dev") == 1

      c2 = push_branch(site, secret, "dev", sha("d1"), delivery: delivery)
      assert c2.status == 200
      body2 = json_body(c2)
      assert body2["ignored"] == true
      assert body2["reason"] == "duplicate_delivery"
      assert body2["deployment_id"] == first_id

      # No second row was minted for the redelivered push.
      assert length(Registry.list_deployments(site)) == 1
    end

    test "dwb-18: the (site, branch) active-preview index backstops a lost race at the DB" do
      {_user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})

      assert push_branch(site, secret, "racy", sha("r1")).status == 201

      # Simulate the lost race: a second INSERT for the same branch that skipped
      # the supersede path (as a concurrent transaction would have — its snapshot
      # predated the winner's commit). The partial unique index must reject it as
      # a changeset error on :branch, never a raised ConstraintError.
      attrs = %{
        site_id: site.id,
        environment: "preview",
        branch: "racy",
        preview_slug: Registry.preview_slug_for(site.slug, "racy"),
        preview_host: Registry.preview_host_for(site.slug, "racy"),
        git_ref: sha("r2")
      }

      assert {:error, cs} =
               %Registry.Deployment{}
               |> Registry.Deployment.preview_changeset(attrs)
               |> BarkparkCloud.Repo.insert()

      assert {"already has an active preview", _} = cs.errors[:branch]
    end

    test "GET /v1/sites/:id/previews lists previews distinctly from production" do
      {user, team} = user_with_team()
      {site, secret} = site_with_github(team, %{branch: "main"})
      token = login_token(user)

      # One production push + one preview push.
      assert push_branch(site, secret, "main", sha("prod")).status == 201
      assert push_branch(site, secret, "dev", sha("dev")).status == 201

      prod = call(:get, "/v1/sites/#{site.id}/deployments", nil, token)
      assert prod.status == 200
      prod_list = json_body(prod)["deployments"]
      assert Enum.all?(prod_list, &(&1["environment"] == "production"))
      assert length(prod_list) == 1

      prev = call(:get, "/v1/sites/#{site.id}/previews", nil, token)
      assert prev.status == 200
      prev_list = json_body(prev)["previews"]
      assert length(prev_list) == 1
      assert hd(prev_list)["environment"] == "preview"
      assert hd(prev_list)["branch"] == "dev"
      assert String.starts_with?(hd(prev_list)["preview_url"], "https://")
    end
  end
end
