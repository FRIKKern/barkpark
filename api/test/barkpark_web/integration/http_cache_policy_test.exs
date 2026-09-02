defmodule BarkparkWeb.Integration.HttpCachePolicyTest do
  @moduledoc """
  Exact-string pins for every FREE-FLOATING `cache-control` override in
  `api/lib` (http-edge-truth W1 slice 6).

  ## Why this file exists

  A cache-control string set inline in a controller is a policy decision with no
  home: nothing names it, nothing tests it, and a well-meaning edit ("surely
  `no-cache` is fine here") silently downgrades a `no-store` on a
  credential-bearing response. This file is that home. Each pin asserts the
  FULL header list — `get_resp_header(conn, "cache-control") == ["<exact>"]` —
  the `MediaDeliveryTest` convention, deliberately NOT a first-header helper: a
  second, weaker `cache-control` appended by a later plug would slip past
  `hd/1` and be the one an intermediary honours.

  ## Census (reconciled by the wave's verify pass)

  `grep -rn 'put_resp_header("cache-control"' api/lib` finds ELEVEN sites. Two
  are already pinned elsewhere and are deliberately NOT re-pinned here:

    * `media/delivery/urls.ex:58` — the immutable rendition policy, pinned by
      `BarkparkWeb.Integration.MediaDeliveryTest`. It is ALSO in flight in this
      wave's visibility-aware media-cache slice, which owns it.
    * `session_controller.ex:436` — pinned by the session-controller suite.

  The other NINE are this file's charge. SIX are pinned below. THREE are an
  HONEST, NAMED GAP — see "Unreachable in ConnCase".

  ## Unreachable in ConnCase (documented, not skipped)

  Three sites sit on Server-Sent-Events actions that call `send_chunked/2` and
  then never return — the action blocks in a `receive` loop for the life of the
  connection, so a `get/2` through `Phoenix.ConnTest` never yields a conn to
  assert against. This is the same limitation `ListenControllerTest` and
  `ChatFleetEventsTest` document in their own moduledocs ("the long-lived
  `receive` loop is un-assertable through a blocking `get/2`"), and it is a
  property of the test adapter, not of the header:

    * `chat_controller.ex:413` — `ChatController.events/2` (per-session SSE),
      `cache-control: no-cache`.
    * `chat_controller.ex:470` — `ChatController.fleet_events/2` (herd SSE),
      `cache-control: no-cache`.
    * `listen_controller.ex:58` — `ListenController.listen/2` (document SSE),
      `cache-control: no-cache`.

  Pinning these needs a streaming-capable client (a real `Bandit`/`Finch` leg
  against a booted endpoint, or a controller-level chunked-response harness) —
  out of scope for a test-only slice. Left honestly open rather than covered by
  a pin that cannot fail.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @no_store ["no-store"]
  @redirect_policy ["private, max-age=0, must-revalidate"]

  # The presigned-redirect branches (`{:redirect, url}` from
  # `Blobstore.serve_strategy/2`) only exist under an object-storage backend.
  # `:media_storage` is process-GLOBAL VM state, which is why this module is
  # `async: false` — the same reasoning `Blobstore.S3Test` spells out. No
  # network is involved: `S3.serve_strategy/2` only SIGNS a URL.
  defp use_s3_backend! do
    previous = Application.get_env(:barkpark, :media_storage)

    Application.put_env(:barkpark, :media_storage,
      backend: :s3,
      s3: [
        endpoint: "https://test.r2.example.com",
        bucket: "bp-cache-policy-test",
        region: "auto",
        access_key_id: "test-access-key",
        secret_access_key: "test-secret-key"
      ]
    )

    on_exit(fn -> Application.put_env(:barkpark, :media_storage, previous) end)
    :ok
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  # ── 1. metrics_controller.ex:26 — no-store ─────────────────────────────────

  describe "GET /v1/instance/metrics (MetricsController.scrape/2)" do
    test "the Prometheus scrape is never stored by any cache", %{conn: conn} do
      # ADMIN: the route moved to `[:api, :require_admin]` in
      # task-d7ac954aa57aa522 (its Prometheus label set carries `workspace_id`).
      # A `["read"]` token now 403s, and this test is about the cache header on
      # the 200.
      raw = "cache-policy-metrics-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, _} =
        Auth.create_token(raw, "cache-policy-metrics", "test", ["read", "write", "admin"])

      conn = conn |> bearer(raw) |> get("/v1/instance/metrics")

      assert response(conn, 200)
      assert get_resp_header(conn, "cache-control") == @no_store
    end
  end

  # ── 2. grant_controller.ex:111 — no-store ──────────────────────────────────

  describe "GET /grant/:token (GrantController.claim/2)" do
    test "the one-time airdrop claim is never stored, even on the anonymous bounce" do
      # Anonymous → the /login bounce. `no_store/1` runs BEFORE the branch, so
      # this reaches the header without needing a real grant or a session.
      conn = get(build_conn(), "/grant/not-a-real-token")

      assert redirected_to(conn) =~ "/login"
      assert get_resp_header(conn, "cache-control") == @no_store
    end
  end

  # ── 3. access_controller.ex:223 — no-store ─────────────────────────────────

  describe "AccessController grantee surface (the shared no_store/1 helper)" do
    setup do
      user =
        register_user("cache-policy-#{System.unique_integer([:positive])}@example.com")

      {:ok, session} =
        Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "test")

      %{session: session}
    end

    test "GET /v1/access/mine — the grantee's own grant list is never stored", %{
      conn: conn,
      session: session
    } do
      conn = conn |> bearer(session) |> get("/v1/access/mine")

      assert %{"grants" => _} = json_response(conn, 200)
      assert get_resp_header(conn, "cache-control") == @no_store
    end

    test "POST /v1/access/claim — the one-time claim response is never stored", %{
      conn: conn,
      session: session
    } do
      conn =
        conn
        |> bearer(session)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/access/claim", %{"token" => "this-token-never-existed"})

      # `no_store/1` runs BEFORE the claim branches, so the no-oracle failure
      # carries the identical policy a success does — which is the point: the
      # two responses must be indistinguishable down to their headers.
      assert conn.status == 422
      assert get_resp_header(conn, "cache-control") == @no_store
    end
  end

  # ── 4. media_controller.ex:201 — private, max-age=0, must-revalidate ───────

  describe "GET /media/files/*path under an object-storage backend" do
    test "the 302 to a presigned blob URL is private and revalidated" do
      {ws, project} = ensure_default_scope!()
      file = insert_media_file!(ws, project, "media-ctl")
      use_s3_backend!()

      conn = get(build_conn(), "/media/files/" <> file.path)

      assert conn.status == 302
      assert [location] = get_resp_header(conn, "location")
      assert location =~ "bp-cache-policy-test"
      assert get_resp_header(conn, "cache-control") == @redirect_policy
    end
  end

  # ── 5. share_link_controller.ex:153 — private, max-age=0, must-revalidate ──

  describe "GET /s/:token for a MEDIA link under an object-storage backend" do
    test "the 302 to a presigned blob URL is private and revalidated", %{conn: conn} do
      admin = "cache-policy-sl-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, admin_tok} =
        Auth.create_token(admin, "cache-policy-sl", "production", ["read", "write", "admin"])

      ws = create_workspace!("cache-policy-ws-#{System.unique_integer([:positive])}")
      project = create_project!(ws, "cache-policy-proj-#{System.unique_integer([:positive])}")

      # FIXTURE REPAIR (arpss-w8): minting a share link now requires an ADMIN
      # MEMBERSHIP in the target workspace. `create_token/4` homes the token in
      # the seeded `default` workspace and `create_workspace!/1` writes no
      # membership, so this admin was a stranger to the workspace it mints into.
      # Zero production change — this is a cache-header pin, not a tenancy test.
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_tok.id, "admin")
      file = insert_media_file!(ws, project, "share-link")

      minted =
        conn
        |> bearer(admin)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/shares/links", %{
          "scope" => "#{ws.slug}/#{project.slug}/production",
          "kind" => "media",
          "ref_id" => file.id
        })
        |> json_response(201)

      use_s3_backend!()

      conn = get(build_conn(), "/s/#{minted["token"]}")

      assert conn.status == 302
      assert get_resp_header(conn, "cache-control") == @redirect_policy
    end
  end

  # ── 6. tickets_attachments_controller.ex:239 — private, max-age=0, … ───────

  describe "GET /v1/tickets/inbox/:id/attachments/:asset_id under an object-storage backend" do
    test "the 302 to a presigned blob URL is private and revalidated" do
      :ok =
        Barkpark.Plugins.Registry.register(
          Barkpark.Plugins.Media,
          Barkpark.Plugins.Media.manifest()
        )

      {:ok, _} =
        Barkpark.Plugins.Bootstrap.install_for_plugin(%{
          name: "media",
          module: Barkpark.Plugins.Media
        })

      Barkpark.Plugins.Media.Codelists.seed_all()
      :ets.delete_all_objects(:barkpark_rate_limiter)

      {ws, project} = ensure_default_scope!()

      operator = "cache-policy-op-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, _} = Auth.create_token(operator, "cache-policy-op", "production", ["read"], ws.id)

      key = %{
        id: "cache-policy-key",
        dataset: "production",
        workspace_id: ws.id,
        project_id: project.id
      }

      ticket = insert_ticket!(key.id, ws, project)

      # The attachment is written under the DEFAULT (local) backend — the blob
      # really lands on disk — so the redirect asserted below is the S3
      # backend's serve decision, not a missing-file fallback.
      asset_id =
        BarkparkWeb.TicketsAttachmentsController.create(
          assign(build_conn(), :ticket_key, key),
          %{"id" => ticket, "file" => png_upload()}
        )
        |> json_response(201)
        |> get_in(["attachment", "asset_id"])

      use_s3_backend!()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"api_token" => operator})
        |> get("/v1/tickets/inbox/#{ticket}/attachments/#{asset_id}")

      assert conn.status == 302
      assert get_resp_header(conn, "cache-control") == @redirect_policy
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  # A media_files row whose blob also exists on local disk, so the LOCAL branch
  # is a genuine alternative — the redirect the pins assert is the backend's
  # choice, not a fallback from a missing file.
  defp insert_media_file!(ws, project, tag) do
    name = "#{tag}-#{System.unique_integer([:positive])}.png"
    rel = "uploads/http-cache-policy-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "PNG-BYTES")
    on_exit(fn -> File.rm(full) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: 9,
      dataset: "production",
      workspace_id: ws.id,
      project_id: project.id
    })
    |> Repo.insert!()
  end

  defp insert_ticket!(key_id, ws, project) do
    doc_id = "cache-policy-ticket-" <> Integer.to_string(System.unique_integer([:positive]))

    Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "ticket",
      dataset: "production",
      status: "open",
      rev: "1",
      workspace_id: ws.id,
      project_id: project.id,
      content: %{"key_id" => key_id, "status" => "open", "messages" => []}
    })

    doc_id
  end

  # A real PNG by magic bytes — the attachment allowlist sniffs content, not the
  # declared type.
  defp png_upload do
    bytes = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR">>

    tmp =
      Path.join(
        System.tmp_dir!(),
        "http-cache-policy-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)
    %Plug.Upload{path: tmp, filename: "pixel.png", content_type: "image/png"}
  end
end
