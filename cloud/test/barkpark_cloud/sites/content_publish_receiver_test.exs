defmodule BarkparkCloud.Sites.ContentPublishReceiverTest do
  @moduledoc """
  site-spawner W5 (charter D45/D46/D47) — the publish-to-live receiver, end to end:

      POST /v1/sites/webhooks/content-publish/:site_id   NO auth — HMAC IS the auth

  The route is the sensitive one; it must:
    * verify `x-barkpark-signature` (`t=<unix>,v1=<hex>` = HMAC-SHA256 over
      "<t>.<raw-body>", ±300s) against the site's OWN stored secret — the
      StripeGateway-clone scheme, NOT the GitHub sha256= scheme;
    * 401 on a forged OR an expired signature (no detail);
    * 404 on an unknown site AND on a site with no content webhook configured
      (a probe can't tell them apart);
    * on a valid delivery, enqueue the DEBOUNCED per-site auto-deploy and 202.

  And (charter D47) `create_site` registers a dataset-scoped webhook on the box via
  the admin relay, carrying events/url/secret, and stores the ciphertext.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Sites.AutoDeployWorker
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @instance_url "https://acme.barkpark.cloud"

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

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
          read_token: "bpt_read_#{n}"
        })
      )

    site
  end

  # Sign a body the way the box's Webhooks.Dispatcher does: HMAC-SHA256 over
  # "<timestamp>.<body>", lower-hex, in a `t=<unix>,v1=<hex>` header.
  defp sign(secret, ts, body) do
    v1 = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{v1}"
  end

  defp deliver(site_id, body, sig) do
    conn(:post, "/v1/sites/webhooks/content-publish/#{site_id}", body)
    |> put_req_header("content-type", "application/json")
    |> maybe_sig(sig)
    |> Router.call(@opts)
  end

  defp maybe_sig(conn, nil), do: conn
  defp maybe_sig(conn, sig), do: put_req_header(conn, "x-barkpark-signature", sig)

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## ---------------------------------------------------------------------------

  describe "POST /v1/sites/webhooks/content-publish/:site_id — signature verification" do
    test "a valid signature 202s AND enqueues the debounced auto-deploy" do
      site = team_fixture() |> live_barkpark() |> static_site()
      {:ok, secret} = Registry.reveal_site_content_secret(site)
      assert is_binary(secret)

      body = Jason.encode!(%{"event" => "publish", "documentId" => "p42"})
      ts = System.system_time(:second)

      conn = deliver(site.id, body, sign(secret, ts, body))

      assert conn.status == 202
      assert json_body(conn)["trigger"] == "content-auto"

      # The publish enqueued the per-site debounced rebuild (charter D44/D45).
      assert_enqueued(worker: AutoDeployWorker, args: %{site_id: site.id})
    end

    test "a FORGED signature 401s and enqueues nothing" do
      site = team_fixture() |> live_barkpark() |> static_site()

      body = Jason.encode!(%{"event" => "publish"})
      ts = System.system_time(:second)
      forged = "t=#{ts},v1=#{String.duplicate("0", 64)}"

      conn = deliver(site.id, body, forged)

      assert conn.status == 401
      assert json_body(conn)["error"] == "bad_signature"
      refute_enqueued(worker: AutoDeployWorker)
    end

    test "an EXPIRED (>300s) signature 401s even though the HMAC itself is correct" do
      site = team_fixture() |> live_barkpark() |> static_site()
      {:ok, secret} = Registry.reveal_site_content_secret(site)

      body = Jason.encode!(%{"event" => "publish"})
      # A correct HMAC over a stale timestamp — replay defense must still reject it.
      stale_ts = System.system_time(:second) - 400

      conn = deliver(site.id, body, sign(secret, stale_ts, body))

      assert conn.status == 401
      refute_enqueued(worker: AutoDeployWorker)
    end

    test "a REPLAY (a valid signature for a different body) 401s" do
      site = team_fixture() |> live_barkpark() |> static_site()
      {:ok, secret} = Registry.reveal_site_content_secret(site)

      original = Jason.encode!(%{"event" => "publish", "documentId" => "a"})
      ts = System.system_time(:second)
      good_sig = sign(secret, ts, original)

      tampered = Jason.encode!(%{"event" => "publish", "documentId" => "b"})
      conn = deliver(site.id, tampered, good_sig)

      assert conn.status == 401
      refute_enqueued(worker: AutoDeployWorker)
    end

    test "a missing signature header 401s" do
      site = team_fixture() |> live_barkpark() |> static_site()
      conn = deliver(site.id, Jason.encode!(%{"event" => "publish"}), nil)
      assert conn.status == 401
    end

    test "an unknown site id → 404" do
      body = Jason.encode!(%{"event" => "publish"})
      ts = System.system_time(:second)
      conn = deliver(Ecto.UUID.generate(), body, sign("whatever", ts, body))
      assert conn.status == 404
      refute_enqueued(worker: AutoDeployWorker)
    end

    test "a site with no content webhook configured → 404 (does not leak the difference)" do
      bp = team_fixture() |> live_barkpark()
      # A container site mints no content secret.
      {:ok, container} = Registry.create_site(bp, %{name: "App", slug: "app", kind: "container"})
      assert {:ok, nil} = Registry.reveal_site_content_secret(container)

      body = Jason.encode!(%{"event" => "publish"})
      ts = System.system_time(:second)
      conn = deliver(container.id, body, sign("whatever", ts, body))

      assert conn.status == 404
      refute_enqueued(worker: AutoDeployWorker)
    end
  end

  describe "create_site registration (charter D47)" do
    test "a content-bound static site on a live box registers the box webhook and stores the ciphertext" do
      bp = team_fixture() |> live_barkpark()
      # Establish this pid as the studio-link fake's owner so requests/0 sees the
      # relay call create_site makes.
      StudioLinkFakeHttpClient.program([])

      site = static_site(bp)

      # The secret is stored ENCRYPTED (never plaintext), and reveals cleanly.
      assert is_binary(site.content_webhook_secret_encrypted)
      {:ok, secret} = Registry.reveal_site_content_secret(site)
      assert is_binary(secret)
      assert site.content_webhook_secret_encrypted != secret

      # The box was asked to register a dataset-scoped webhook pointed at THIS
      # site's per-site receiver, carrying the three lifecycle events + the secret.
      reg =
        StudioLinkFakeHttpClient.requests()
        |> Enum.find(fn r ->
          r.method == :post and String.ends_with?(r.url, "/v1/webhooks/production")
        end)

      assert reg, "expected a POST /v1/webhooks/production registration call"
      payload = Jason.decode!(reg.body)
      assert payload["events"] == ["publish", "unpublish", "delete"]
      assert payload["secret"] == secret
      assert String.ends_with?(payload["url"], "/v1/sites/webhooks/content-publish/#{site.id}")
    end

    test "a container site mints no secret and registers nothing" do
      bp = team_fixture() |> live_barkpark()
      StudioLinkFakeHttpClient.program([])

      {:ok, container} =
        Registry.create_site(bp, %{name: "App", slug: "app-c", kind: "container"})

      assert is_nil(container.content_webhook_secret_encrypted)

      refute Enum.any?(StudioLinkFakeHttpClient.requests(), fn r ->
               String.contains?(r.url, "/v1/webhooks/")
             end)
    end
  end
end
