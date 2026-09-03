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

  `grep -rn 'put_resp_header("cache-control"' api/lib` finds THIRTEEN sites
  (reconciled again by `het-bl-sharelink-local-cache-policy`, which ADDED one —
  see section 5b — and found the count had drifted from ELEVEN meanwhile).
  THREE are already pinned elsewhere and are deliberately NOT re-pinned here:

    * `media/delivery/urls.ex` — the immutable rendition policy, pinned by
      `BarkparkWeb.Integration.MediaDeliveryTest`. It is ALSO in flight in this
      wave's visibility-aware media-cache slice, which owns it.
    * `session_controller.ex` — pinned by the session-controller suite.
    * `plugs/paper_revision_headers.ex` — the revision-validator policy, pinned
      by `BarkparkWeb.PaperRevisionHeadersTest` with the same full-list equality
      on BOTH the 200 and its 304 replay.

  The other TEN are this file's charge, and ALL TEN are pinned below.

  Section headers below carry the line numbers they were written against; those
  drift and are NOT the index — the describe string names the action, and that
  is what a reader should match on.

  ## The three SSE sites go through a real streaming client

  Three of the ten sit on Server-Sent-Events actions that call `send_chunked/2`
  and then never return — the action blocks in a `receive` loop for the life of
  the connection, so a `get/2` through `Phoenix.ConnTest` never yields a conn to
  assert against:

    * `chat_controller.ex` — `ChatController.events/2` (per-session SSE)
    * `chat_controller.ex` — `ChatController.fleet_events/2` (herd SSE)
    * `listen_controller.ex` — `ListenController.listen/2` (document SSE)

  Nothing about the HEADER is unreachable, only the ConnTest ADAPTER: the
  headers are on the wire the instant `send_chunked/2` flushes them. So the
  "SSE cache-control" describe below boots a real `Bandit` leg serving
  `BarkparkWeb.Endpoint` on an EPHEMERAL port and dials it with a raw
  `:gen_tcp` client that reads ONLY the response HEAD (Erlang's own
  `packet: :http_bin` framing) and then closes — it never touches the body, so
  the blocking `receive` loop can never stall it. No site in the census is
  left to an honest gap any more.
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
  @no_cache ["no-cache"]
  @redirect_policy ["private, max-age=0, must-revalidate"]
  # The same literal on a 200 that sends bytes (share-link LOCAL branch,
  # section 5b) — one policy, two names, so neither assertion reads as a
  # copy of the other by accident.
  @private_policy @redirect_policy

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
      conn = get(scoped_conn(), "/grant/not-a-real-token")

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

      conn = get(scoped_conn(), "/media/files/" <> file.path)

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

      conn = get(scoped_conn(), "/s/#{minted["token"]}")

      assert conn.status == 302
      assert get_resp_header(conn, "cache-control") == @redirect_policy
    end
  end

  # ── 5b. share_link_controller.ex {:file, full} — private, max-age=0, … ─────

  describe "GET /s/:token for a MEDIA link under the LOCAL (default) backend" do
    test "the 200 that sends the bytes states the SAME private policy as its redirect sibling",
         %{conn: conn} do
      # The sibling pin above (section 5) covers the object-storage `{:redirect,
      # url}` arm. This one covers the `{:file, full}` arm, which used to send
      # the bytes with NO `cache-control` at all — the same anonymous capability
      # URL got a different, unstated storage policy purely because of which
      # backend was configured. No `use_s3_backend!/0` here: that IS the
      # difference between the two tests.
      admin = "cache-policy-sl-local-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, admin_tok} =
        Auth.create_token(admin, "cache-policy-sl-local", "production", ["read", "write", "admin"])

      ws = create_workspace!("cache-policy-ws-#{System.unique_integer([:positive])}")
      project = create_project!(ws, "cache-policy-proj-#{System.unique_integer([:positive])}")
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_tok.id, "admin")
      file = insert_media_file!(ws, project, "share-link-local")

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

      conn = get(scoped_conn(), "/s/#{minted["token"]}")

      # A 200 with the real bytes — the LOCAL branch actually ran.
      assert conn.status == 200
      assert response(conn, 200) == "PNG-BYTES"

      # FULL-LIST equality, the file's convention: a second, weaker
      # `cache-control` appended downstream must red this, not hide behind hd/1.
      assert get_resp_header(conn, "cache-control") == @private_policy

      # The stored-XSS seal on this branch is unchanged by the policy addition.
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
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
          assign(scoped_conn(), :ticket_key, key),
          %{"id" => ticket, "file" => png_upload()}
        )
        |> json_response(201)
        |> get_in(["attachment", "asset_id"])

      use_s3_backend!()

      conn =
        scoped_conn()
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

  # ── The three SSE sites, pinned through a REAL streaming client ───────────
  #
  # HARNESS. `BarkparkWeb.Endpoint` is a Plug, so a `Bandit` child serves the
  # WHOLE real pipeline (router + every plug the route's pipelines run). The
  # port is EPHEMERAL — bind 0, read the assigned port back, close the probe
  # socket — because this box runs many suites at once and a fixed port is a
  # cross-agent collision, not a test.
  #
  # WHY IT CANNOT HANG. The client is raw `:gen_tcp` in `packet: :http_bin`
  # mode: the BEAM itself frames the status line and each header, and we stop
  # at `:http_eoh` — the blank line that ends the HEAD. The SSE body is never
  # read, so the action's endless `receive` loop is irrelevant to us, and every
  # `recv` carries the remaining slice of one absolute deadline, so a stalled
  # or silent server fails with a NAMED message instead of blocking the suite.
  #
  # Header list equality, not `hd/1`: the same discipline as the pins above —
  # a second, weaker `cache-control` appended by a later plug must red the pin.
  @sse_head_timeout_ms 15_000

  describe "SSE cache-control (real streaming client, not ConnTest)" do
    setup do
      previous = Application.get_env(:barkpark, :public_demo_studio)
      Application.put_env(:barkpark, :public_demo_studio, false)
      on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, previous) end)

      %{port: start_streaming_endpoint!()}
    end

    test "ListenController.listen/2 (document SSE) pins cache-control: no-cache", %{port: port} do
      raw = "sse-listen-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, _} = Auth.create_token(raw, "sse-cache-listen", "production", ["read"])

      {status, headers} =
        stream_head!(
          port,
          "/v1/data/listen/production",
          [{"authorization", "Bearer " <> raw}, {"accept", "text/event-stream"}],
          "ListenController.listen/2"
        )

      assert status == 200,
             "ListenController.listen/2: expected a 200 chunked SSE response, got #{status} " <>
               "(headers: #{inspect(headers)}) — the pin below would be vacuous"

      assert header_values(headers, "cache-control") == @no_cache,
             "ListenController.listen/2 must send EXACTLY #{inspect(@no_cache)}; " <>
               "got #{inspect(header_values(headers, "cache-control"))}"
    end

    test "ChatController.fleet_events/2 (herd SSE) pins cache-control: no-cache", %{port: port} do
      raw = "sse-fleet-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, _} =
        Auth.create_token(raw, "sse-cache-fleet", "production", ["read", "write", "admin"])

      {status, headers} =
        stream_head!(
          port,
          "/v1/chat/events",
          [{"authorization", "Bearer " <> raw}, {"accept", "text/event-stream"}],
          "ChatController.fleet_events/2"
        )

      assert status == 200,
             "ChatController.fleet_events/2: expected a 200 chunked SSE response, got #{status} " <>
               "(headers: #{inspect(headers)}) — the pin below would be vacuous"

      assert header_values(headers, "cache-control") == @no_cache,
             "ChatController.fleet_events/2 must send EXACTLY #{inspect(@no_cache)}; " <>
               "got #{inspect(header_values(headers, "cache-control"))}"
    end

    test "ChatController.events/2 (per-session SSE) pins cache-control: no-cache", %{port: port} do
      raw = "sse-session-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, _} =
        Auth.create_token(raw, "sse-cache-session", "production", ["read", "write", "admin"])

      # The action 404s an unknown/foreign id BEFORE send_chunked/2 (Connectors
      # D18/D19a), so the pin needs a session the `:global` admin scope can see.
      {:ok, session} =
        Barkpark.StudioChat.create_session(
          %{
            id: Ecto.UUID.generate(),
            cwd: BarkparkWeb.Studio.ClaudeChat.cwd(),
            mode: "plan"
          },
          :global
        )

      {status, headers} =
        stream_head!(
          port,
          "/v1/chat/sessions/#{session.id}/events",
          [{"authorization", "Bearer " <> raw}, {"accept", "text/event-stream"}],
          "ChatController.events/2"
        )

      assert status == 200,
             "ChatController.events/2: expected a 200 chunked SSE response, got #{status} " <>
               "(headers: #{inspect(headers)}) — a 404 here means the session was not in scope " <>
               "and the pin below would be vacuous"

      assert header_values(headers, "cache-control") == @no_cache,
             "ChatController.events/2 must send EXACTLY #{inspect(@no_cache)}; " <>
               "got #{inspect(header_values(headers, "cache-control"))}"
    end
  end

  # Bind :0, read the kernel-assigned port back, release it, then hand it to
  # Bandit. `start_supervised!` ties the listener's life to this test, so the
  # long-lived SSE connection processes are torn down with it.
  defp start_streaming_endpoint! do
    {:ok, probe} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port_num} = :inet.port(probe)
    :ok = :gen_tcp.close(probe)

    start_supervised!({
      Bandit,
      # The SSE actions block in `receive` for the life of the connection, so at
      # teardown ThousandIsland waits its default `shutdown_timeout` (15_000 ms)
      # for each to drain before killing it: 3 tests x 15.0 s of pure wait in the
      # Elixir Test job (main run 33797686877, ci-log-gap-census.sh). Nothing is
      # in flight worth draining here — the assertion already passed on the
      # response HEAD — so give the acceptors a quarter second and move on.
      plug: BarkparkWeb.Endpoint,
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: port_num,
      thousand_island_options: [shutdown_timeout: 250]
    })

    port_num
  end

  # Read ONLY the response HEAD, then close. Returns `{status, headers}` with
  # every header kept in wire order and duplicates PRESERVED — that is what
  # makes the full-list equality above able to see a second `cache-control`.
  defp stream_head!(port_num, path, req_headers, label) do
    {:ok, sock} =
      :gen_tcp.connect(
        ~c"127.0.0.1",
        port_num,
        [:binary, active: false, packet: :http_bin],
        @sse_head_timeout_ms
      )

    request = [
      "GET ",
      path,
      " HTTP/1.1\r\nhost: 127.0.0.1:",
      Integer.to_string(port_num),
      "\r\n",
      Enum.map(req_headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]

    :ok = :gen_tcp.send(sock, request)

    deadline = System.monotonic_time(:millisecond) + @sse_head_timeout_ms

    try do
      recv_head(sock, label, nil, [], deadline)
    after
      :gen_tcp.close(sock)
    end
  end

  defp recv_head(sock, label, status, headers, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk(
        "#{label}: no complete response HEAD within #{@sse_head_timeout_ms}ms " <>
          "(status so far: #{inspect(status)}, headers so far: #{inspect(Enum.reverse(headers))})"
      )
    end

    case :gen_tcp.recv(sock, 0, remaining) do
      {:ok, {:http_response, _version, code, _reason}} ->
        recv_head(sock, label, code, headers, deadline)

      {:ok, {:http_header, _len, name, _reserved, value}} ->
        recv_head(sock, label, status, [{header_name(name), value} | headers], deadline)

      {:ok, :http_eoh} ->
        {status, Enum.reverse(headers)}

      {:ok, {:http_error, line}} ->
        flunk("#{label}: unparsable HTTP in the response HEAD: #{inspect(line)}")

      {:ok, other} ->
        flunk(
          "#{label}: unexpected packet before the end of the response HEAD: #{inspect(other)}"
        )

      {:error, reason} ->
        flunk(
          "#{label}: socket error #{inspect(reason)} before the response HEAD completed " <>
            "(status so far: #{inspect(status)})"
        )
    end
  end

  # `packet: :http_bin` hands back well-known header names as ATOMS
  # (`:"Cache-Control"`) and everything else as a binary. Normalise both.
  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(name) when is_binary(name), do: String.downcase(name)

  defp header_values(headers, name), do: for({^name, value} <- headers, do: value)
end
