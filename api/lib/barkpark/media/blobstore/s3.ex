defmodule Barkpark.Media.Blobstore.S3 do
  @moduledoc """
  S3-compatible object-storage backend — originals live in a bucket
  (Cloudflare R2, AWS S3, MinIO, Backblaze B2, …); local disk is demoted to a
  regenerable write-through cache.

  Design invariants:

    * The bucket is the SOURCE OF TRUTH for original bytes. The local copy
      under `Media.upload_dir/0` is a pure cache: `put_file/3` warms it so the
      post-upload pipeline (probe + renditions) never re-downloads what it just
      received, and `ensure_local/1` refills it on demand. Losing the disk
      loses nothing that cannot be re-fetched or regenerated.
    * ONE signing path. Every verb (GET/PUT/DELETE) goes through
      `Presign.url/4`; the HTTP client (`Req`, already a dep) sends plain
      requests against presigned URLs and never holds signing logic.
    * Serve = redirect. `serve_strategy/2` answers `{:redirect, presigned_url}`
      so the app never proxies original bytes. The serve edge's stored-XSS
      defenses (type collapse + attachment disposition for dangerous mimes —
      see `MediaController.maybe_send_file/3`) are preserved by baking
      `response-content-type` / `response-content-disposition` INTO the signed
      query: the bucket echoes exactly the headers the local path would set.
      With `:public_base_url` configured (a public bucket behind a CDN), the
      redirect is an unsigned, cache-friendly CDN URL instead — but ONLY for
      blobs a caller marked safe (`:public` opt); dangerous-mime and
      access-gated serves stay on the presigned path where the header
      overrides hold.
    * A write ACK is not a storage fact. Both write verbs follow the PUT with
      `stat_blob/1` — a presigned HEAD straight at the bucket — and answer a
      `t:Barkpark.Media.Blobstore.receipt/0` carrying RECEIVED and STORED as
      separate numbers. COST: one extra round trip per blob, so a bundle
      import's blob phase makes 2 requests per file instead of 1 (the crown
      proof moves 34 blobs → 68 requests).
    * Failures collapse to `{:error, :storage_unavailable}` — the same typed
      503 the local backend reports on a disk fault, so callers cannot tell
      the backends apart by error shape.

  Uploads are read into memory before the PUT (bounded by the endpoint's
  100 MB body cap; typical media is a few MB). S3 requires a Content-Length —
  chunked streaming would need the aws-chunked payload encoding, deliberately
  out of scope for this seam.

  Config (all read at call time; see runtime.exs for the env wiring):

      config :barkpark, :media_storage,
        backend: :s3,
        s3: [
          endpoint: "https://<account>.r2.cloudflarestorage.com",
          bucket: "barkpark-media",
          region: "auto",                # R2: "auto"; AWS: a real region
          access_key_id: "…",
          secret_access_key: "…",
          key_prefix: "",                # optional namespace inside the bucket
          presign_ttl: 3600,             # optional, seconds
          public_base_url: nil,          # optional public/CDN origin
          req_options: []                # test seam: [plug: {Req.Test, …}]
        ]
  """

  @behaviour Barkpark.Media.Blobstore

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Blobstore.S3.Presign

  require Logger

  # The per-receive HTTP timeout, in ms, threaded onto every blob request in
  # req/1. Matches the sync/worker precedent (60s) — generous headroom for a
  # multi-MB original crossing a saturated link, but a hard ceiling so a bucket
  # that goes silent mid-transfer cannot pin a request forever. See the failure
  # note at req/1 for why this is a spurious-503 guard, never a truncation guard.
  @receive_timeout 60_000

  # The hard ceiling, in bytes, on the response body `download/2` will buffer
  # off the bucket. Tied to the 100 MB upload cap that bounds every
  # legitimately-written object: the `Plug.Parsers` body cap in
  # `BarkparkWeb.Endpoint` (`length: 100_000_000`) and the raw
  # `Plug.Conn.read_body/2` in `BarkparkWeb.MediaController`'s `put_blob/2`
  # (`length:` and `read_length:` both `100_000_000`). That is the LEGACY
  # controller, NOT `BarkparkWeb.V1.MediaController` — two files share the
  # basename `media_controller.ex`, which is one more reason a bare
  # `<basename>:<line>` pin is unsafe here.
  # Every bucket object was written through one of those two capped writers, so
  # a body OVER this cap did not come from a normal upload — it is an
  # out-of-band bucket writer or a redirect to a hostile origin. Req 0.6.3 has
  # NO `max_response_size`, so `download/2` enforces the ceiling itself with an
  # `into:` streaming collector (`download_collector/0`) that halts past the cap
  # rather than stream an unbounded body into memory. A fail-safe default: the
  # bucket is the source of truth, and no legitimate original exceeds it.
  @max_download_bytes 100_000_000

  # ── PATH PROVENANCE ────────────────────────────────────────────────────────
  #
  # The TWO-CLAUSE reachability verdict behind every
  # `sobelow_skip ["Traversal.FileModule"]` in this module. Both clauses hold
  # and neither alone is the answer, so neither may be dropped: clause (1)
  # says the upload path cannot traverse, clause (2) says the import path CAN
  # and names what actually stops it. Shortening this to "server-generated,
  # safe" would be false. The File calls here act on the local write-through
  # CACHE (`Media.file_path/1`), not on the bucket — the bucket key is derived
  # from the same `relative_path` by `key_for/1`.
  #
  # CITED BY SYMBOL, NOT BY LINE. This block used to carry twelve `file.ex:NNN`
  # pins and NINE of them had drifted — `import_member/3` by 342 lines, and the
  # router pin onto a comment reading "a `:media`-shared scope is public here",
  # the OPPOSITE of the premise it was cited for. A reviewer
  # re-validating these skips was walked to the wrong place. Symbols survive
  # insertion and a `Module.func/arity` in backticks is a claim
  # tooling/doc-truth actually verifies; a line number is verified by nobody.
  # Grep the name. Every claim below was re-derived against origin/main and
  # every one still HOLDS — only the pointers had rotted.
  #
  # (1) Every UPLOAD path is server-generated. `Media.upload/3` is the ONLY
  #     changeset writer of `media_files.path` in `lib/` — `MediaFile.changeset/2`
  #     has exactly one call site in `lib/`, inside `Media.upload/3`, fed the
  #     attrs map built there — and the value it writes is
  #     `"<yyyy>/<mm>/" <> unique_filename(original_name)`. `unique_filename/1`
  #     runs the client filename through `Path.basename/2`, which discards every
  #     directory component, then slugs the base with `~r/[^a-z0-9-]/`, so no
  #     separator survives; the only `.` that can is the one `Path.extname/1`
  #     re-appends as the extension:
  #     `"../../../etc/passwd"` becomes `"passwd-<hex>"` and `".."` becomes
  #     `"-<hex>."`. A client-supplied filename cannot steer these calls out of
  #     `Media.upload_dir/0`.
  #
  # (2) The IMPORT path is admin-gated, and clause (1) does NOT cover it.
  #     `import_member/3` in `Barkpark.Tenancy.WorkspaceBundle` COPYs the
  #     manifest-named tables verbatim — `media_files` is a copy-strategy bundle
  #     member, pinned in `@pinned_e1` in
  #     `Barkpark.Tenancy.WorkspaceBundle.Catalog` — straight into the real table
  #     with `COPY … FROM STDIN`, past `MediaFile.changeset/2` entirely. So an
  #     admin bundle CAN plant `../../..` in `media_files.path`, and that value
  #     reaches `Media.file_path/1` and the calls below. What bounds it is
  #     AUTHORIZATION, not sanitisation: the sole route is
  #     `BarkparkWeb.WorkspaceController`'s `:import` action, mounted in the
  #     router's `scope "/api"` that pipes through `[:api, :require_admin]`, and
  #     no HTTP token mint issues the `admin` permission — the mint allowlists
  #     cap at `public-read`/`read`/`write`/`chat` (`@allowed_permissions` in
  #     `BarkparkWeb.TokenController`, `@app_token_permissions` in
  #     `BarkparkWeb.AppTokenController`, the inline `["read", "write"]` in
  #     `BarkparkWeb.PlaygroundController`, `@support_permissions` in
  #     `BarkparkWeb.FleetSupportTokenController`, `@claude_session_permissions`
  #     in `Barkpark.Auth`) and the one HTTP-reachable personal-access-token mint
  #     — `BarkparkWeb.AuthController`, the sole caller of
  #     `Auth.create_personal_access_token/3` outside `Barkpark.Auth` — hardcodes
  #     `["read"]`. A caller who can plant that path already holds admin and can
  #     already restore an arbitrary workspace.

  @impl true
  # `source_path` is the `%Plug.Upload{path: …}` temp file chosen by Plug —
  # `Media.upload/3` is the only caller of this verb — never client text, so this
  # `File.read` is bounded independently of both clauses above.
  # sobelow_skip ["Traversal.FileModule"]
  def put_file(relative_path, source_path, opts) do
    case File.read(source_path) do
      {:ok, body} ->
        with {:ok, receipt} <- put_bytes(relative_path, body, opts) do
          # Warm the local cache so the post-upload pipeline (probe +
          # renditions) reads the bytes it just received instead of
          # re-downloading. Best-effort: a full cache disk must not fail an
          # upload the bucket already accepted.
          #
          # ORDER IS LOAD-BEARING: the receipt's read-back already ran inside
          # put_bytes/3, against the BUCKET, before this line put a copy of the
          # source at exactly the path a naive File.stat would check.
          _ = warm_cache(relative_path, source_path)
          {:ok, receipt}
        end

      {:error, _reason} ->
        {:error, :storage_unavailable}
    end
  end

  @impl true
  def put_bytes(relative_path, body, opts) do
    key = key_for(relative_path)
    content_type = Keyword.get(opts, :content_type) || MIME.from_path(relative_path)
    url = Presign.url("PUT", key, presign_config(), expires_in: presign_ttl())

    # A 2xx is a WRITE ACK — the bucket says it took the bytes. It is not a
    # storage fact: a proxy or a misconfigured bucket can ACK and store
    # nothing. stat_blob/1 is the post-condition read that turns the ACK into
    # a claim, at the cost of one extra round trip per blob.
    with :ok <- request(:put, url, body: body, headers: [{"content-type", content_type}]) do
      Blobstore.receipt(byte_size(body), :head, stat_blob(relative_path))
    end
  end

  @impl true
  def stat_blob(relative_path) do
    url = Presign.url("HEAD", key_for(relative_path), presign_config(), expires_in: presign_ttl())

    # Straight at the bucket. NOT ensure_local/1 (short-circuits on
    # File.regular? — zero bucket requests when the cache is warm) and NOT
    # File.stat on Media.file_path/1 (put_file/3 warm-caches the SOURCE there,
    # so it reports the expected size for an object the bucket never took).
    case req(:head, url, []) do
      {:ok, %Req.Response{status: 200} = response} ->
        case content_length(response) do
          nil -> {:error, :no_content_length}
          size -> {:ok, %{size: size}}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp content_length(response) do
    with [value | _] <- Req.Response.get_header(response, "content-length"),
         {size, ""} <- Integer.parse(value) do
      size
    else
      _ -> nil
    end
  end

  @impl true
  # The `File.rm` drops the local CACHE copy at `Media.file_path/1` — see PATH
  # PROVENANCE above. Like the local backend's `delete/1` this verb is reached
  # with a path read BACK off a `media_files` row — `Media.delete_file/2` passes
  # `file.path` to `Blobstore.delete/1` — so clause (2) is the operative clause
  # here, not clause (1).
  # sobelow_skip ["Traversal.FileModule"]
  def delete(relative_path) do
    url =
      Presign.url("DELETE", key_for(relative_path), presign_config(), expires_in: presign_ttl())

    # Local cache copy goes regardless of the remote outcome — a stale cached
    # original must not outlive its deleted row. The remote delete is
    # best-effort like the local backend's File.rm (an orphaned object is
    # harmless; a failed delete_file/2 flow is not).
    _ = File.rm(Media.file_path(relative_path))

    case request(:delete, url, []) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Barkpark.Media.Blobstore.S3.delete #{relative_path}: #{inspect(reason)}")

        :ok
    end
  end

  @impl true
  def ensure_local(relative_path) do
    full_path = Media.file_path(relative_path)

    if File.regular?(full_path) do
      {:ok, full_path}
    else
      download(relative_path, full_path)
    end
  end

  @impl true
  def serve_strategy(relative_path, opts) do
    cfg = config!()
    public_base = Keyword.get(cfg, :public_base_url)

    if public_base && Keyword.get(opts, :public, false) do
      # Public bucket / CDN origin: unsigned, immutable-cacheable URL. Only
      # offered when the CALLER vouched the blob is safe to serve with the
      # bucket's own headers — dangerous mimes stay on the presigned path
      # below, where the signed response-header overrides enforce download.
      {:redirect, String.trim_trailing(public_base, "/") <> "/" <> key_for(relative_path)}
    else
      extra_query =
        Enum.reject(
          [
            {"response-content-type", Keyword.get(opts, :response_content_type)},
            {"response-content-disposition", Keyword.get(opts, :response_content_disposition)}
          ],
          fn {_k, v} -> is_nil(v) end
        )

      url =
        Presign.url("GET", key_for(relative_path), presign_config(),
          expires_in: presign_ttl(),
          extra_query: extra_query
        )

      # A blind redirect: the row was resolved and access-checked upstream; a
      # bucket-side miss (row outlived its blob) answers at the bucket. A HEAD
      # probe here would double per-serve latency to buy a prettier 404.
      {:redirect, url}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # `full_path` is `ensure_local/1`'s `Media.file_path/1` — see PATH PROVENANCE
  # above; both callers of `Blobstore.ensure_local/1` — in
  # `Barkpark.Media.Processing` and `Barkpark.Media.Renditions` — pass
  # `file.path` read back off a `media_files` row, so clause (2) is the
  # operative clause.
  # `tmp_path` only ever appends a server-generated
  # `".part-<System.unique_integer>"` suffix to that same `full_path`, so it
  # cannot reach a directory `full_path` could not.
  # sobelow_skip ["Traversal.FileModule"]
  defp download(relative_path, full_path) do
    url = Presign.url("GET", key_for(relative_path), presign_config(), expires_in: presign_ttl())
    tmp_path = full_path <> ".part-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         # `into: download_collector()` streams the body through the size cap
         # (@max_download_bytes). An over-cap body HALTs the collector, which
         # stamps an overflow flag on the response — refuse_over_cap/1 turns
         # that into {:error, :too_large} BEFORE any File.write, so the
         # truncated partial body never reaches the cache and the error falls
         # to the `other ->` clause -> {:error, :storage_unavailable}.
         {:ok, %Req.Response{status: 200} = response} <-
           req(:get, url, into: download_collector()),
         :ok <- refuse_over_cap(response),
         :ok <- File.write(tmp_path, response.body),
         # rename is atomic on one filesystem — concurrent readers see either
         # no file (→ re-download) or the complete blob, never a torn write.
         :ok <- File.rename(tmp_path, full_path) do
      {:ok, full_path}
    else
      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      other ->
        _ = File.rm(tmp_path)
        Logger.warning("Barkpark.Media.Blobstore.S3.download #{relative_path}: #{inspect(other)}")

        {:error, :storage_unavailable}
    end
  end

  # The `into:` streaming collector for download/2's GET. Req delivers the body
  # in chunks and folds each through this fun; we accumulate into `resp.body`
  # and HALT the instant the running total crosses @max_download_bytes,
  # stamping an overflow flag the caller converts to an error. In real (Finch)
  # streaming this aborts mid-transfer — the unbounded body never fully lands
  # in memory. HONESTY LIMIT: under the Req.Test plug seam (steps.ex run_plug)
  # the stub PRE-BUFFERS and delivers the whole body as ONE {:data} chunk, so
  # the suite proves the over-cap REFUSAL, not a true mid-stream memory abort.
  defp download_collector do
    fn {:data, chunk}, {req, resp} ->
      resp = update_in(resp.body, &(&1 <> chunk))

      if byte_size(resp.body) > @max_download_bytes do
        {:halt, {req, Req.Response.put_private(resp, :bp_download_over_cap, true)}}
      else
        {:cont, {req, resp}}
      end
    end
  end

  # Reads the overflow flag download_collector/0 stamps when it halts past the
  # cap. Returns an error tuple so the `with` in download/2 short-circuits
  # BEFORE File.write — a truncated over-cap body is never cached.
  defp refuse_over_cap(%Req.Response{} = response) do
    if Req.Response.get_private(response, :bp_download_over_cap, false) do
      {:error, :too_large}
    else
      :ok
    end
  end

  # `full_path` is `Media.file_path/1` — see PATH PROVENANCE above. `source_path`
  # is threaded straight through from `put_file/3`, i.e. the `%Plug.Upload{}`
  # temp file, never client text.
  # sobelow_skip ["Traversal.FileModule"]
  defp warm_cache(relative_path, source_path) do
    full_path = Media.file_path(relative_path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)) do
      File.cp(source_path, full_path)
    end
  end

  defp request(method, url, req_opts) do
    case req(method, url, req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc """
  The per-receive HTTP timeout, in ms, that req/1 threads onto every blob
  request. Public so a test can pin the assembled opts against a single source
  of truth instead of a duplicated literal (self_update/client/github.ex).
  """
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms, do: @receive_timeout

  defp req(method, url, req_opts) do
    # `retry: false` — the callers own their failure semantics (upload answers
    # a typed 503; delete is best-effort). `req_options` is the test seam:
    # `[plug: {Req.Test, stub}]` routes requests to an in-process stub.
    #
    # `receive_timeout: @receive_timeout` — CORRECTED FAILURE MODE: without an
    # explicit timeout every verb inherited Req's 15s default, and a bucket that
    # goes SILENT mid-transfer (an idle socket, not a slow one — receive_timeout
    # is per-receive) would stall the request. The read path streams through
    # download_collector/0 (the @max_download_bytes cap) but still writes a
    # `.part` tmp file and ATOMIC-renames, so a stall yields an error tuple that
    # falls to the `other ->` clause -> {:error, :storage_unavailable} — a
    # spurious 503 on a HEALTHY transfer, NEVER a truncated or torn cache
    # write. The 60s ceiling is
    # the guard: a genuinely-hung bucket fails LOUD and bounded instead of
    # pinning the request on the silent default.
    opts =
      [method: method, url: url, retry: false, receive_timeout: @receive_timeout] ++
        req_opts ++ req_options()

    Req.request(opts)
  end

  defp key_for(relative_path) do
    case Keyword.get(config!(), :key_prefix, "") do
      "" -> relative_path
      nil -> relative_path
      prefix -> String.trim_trailing(prefix, "/") <> "/" <> relative_path
    end
  end

  defp presign_ttl, do: Keyword.get(config!(), :presign_ttl, 3600)

  defp req_options, do: Keyword.get(config!(), :req_options, [])

  defp config! do
    cfg = Application.get_env(:barkpark, :media_storage, [])[:s3] || []

    missing =
      Enum.filter([:endpoint, :bucket, :region, :access_key_id, :secret_access_key], fn key ->
        value = Keyword.get(cfg, key)
        is_nil(value) or value == ""
      end)

    if missing != [] do
      raise ArgumentError, """
      media storage backend is :s3 but its config is incomplete — missing #{inspect(missing)}.

      Set the BARKPARK_S3_* environment variables (see config/runtime.exs) or
      configure :barkpark, :media_storage, s3: [...] directly.
      """
    end

    cfg
  end

  @doc false
  # Presign.url/4 takes a map; the keyword config converts here so config!/0
  # stays a keyword list like every other :barkpark config block.
  def presign_config do
    cfg = config!()

    %{
      endpoint: Keyword.fetch!(cfg, :endpoint),
      bucket: Keyword.fetch!(cfg, :bucket),
      region: Keyword.fetch!(cfg, :region),
      access_key_id: Keyword.fetch!(cfg, :access_key_id),
      secret_access_key: Keyword.fetch!(cfg, :secret_access_key)
    }
  end
end
