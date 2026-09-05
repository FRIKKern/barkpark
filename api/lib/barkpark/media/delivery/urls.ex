defmodule Barkpark.Media.Delivery.Urls do
  @moduledoc """
  Delivery URL builders and HTTP cache headers for media binaries.
  """

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Cdn
  alias Barkpark.Media.Renditions
  alias Barkpark.Media.Storage.{Access, MediaFile, SignedUrl}

  # Visibility-aware local-file cache policy (charter http-edge-truth D12).
  # A public asset is still cacheable, but for a DAY and only with a
  # revalidation contract — the old year-long `immutable` policy was applied
  # visibility-BLIND, so a shared cache could hold gated bytes (and any byte
  # change under a stable URL was unrecallable for a year).
  @public_cache "public, max-age=86400, must-revalidate"

  # Anything not provably public ("token", "private", and any UNKNOWN value —
  # fail-closed, mirroring Access.delivery_ok?/3's catch-all) is never stored
  # anywhere: no shared-cache entry, no browser disk copy, and no ETag at all,
  # so a client cannot revalidate its way back to gated bytes.
  @no_store_cache "no-store"

  @doc "Original binary URL (WoodWing `originalUrl`)."
  @spec original_url(%MediaFile{}, keyword()) :: String.t()
  def original_url(%MediaFile{} = file, opts \\ []) do
    maybe_sign("/media/files/#{file.path}", file, opts)
  end

  @doc "Thumbnail URL — rendition for images, original otherwise."
  @spec thumbnail_url(%MediaFile{}, keyword()) :: String.t()
  def thumbnail_url(%MediaFile{} = file, opts \\ []) do
    if image?(file) do
      maybe_sign(Renditions.url(file, "thumb"), file, opts)
    else
      original_url(file, opts)
    end
  end

  @doc "Preview URL — rendition for images, original otherwise."
  @spec preview_url(%MediaFile{}, keyword()) :: String.t()
  def preview_url(%MediaFile{} = file, opts \\ []) do
    if image?(file) do
      maybe_sign(Renditions.url(file, "preview"), file, opts)
    else
      original_url(file, opts)
    end
  end

  @doc """
  Absolute (scheme + host) form of an already-built delivery URL.

  The relative fields (`url`, `originalUrl`, `renditions.*`, `cdnUrls.*`) are
  documented delivery PATHS and persisted webhook/SDK payloads, so they never
  move. But a client that receives one has nothing in the response telling it
  which origin serves it, and a bare `/media/files/...` pasted anywhere
  cross-origin silently 404s (jf-backlog-media-absolute-url).

  Resolution order, and it is exactly two steps:

    * the URL is ALREADY absolute — `Cdn.public_url/1` prefixed it because
      `:media_cdn, :base_url` is configured, or the caller handed us one —
      return it untouched, so a configured CDN keeps owning the origin;
    * otherwise prefix the app's own public origin, `BarkparkWeb.Endpoint.url/0`
      (PHX_HOST / PHX_SCHEME in prod — the same source `saml.ex`,
      `share_meta.ex` and the social/OIDC callback URIs already use).

  The input is whatever `original_url/2` and friends produced, so the request's
  `:scope_prefix` is already baked in: a scoped request gets
  `https://host/w/:ws/p/:proj/media/...`, not a flat path that 404s under it.
  """
  @spec absolutize(String.t() | nil) :: String.t() | nil
  def absolutize(nil), do: nil

  def absolutize(url) when is_binary(url) do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      url
    else
      BarkparkWeb.Endpoint.url() <> url
    end
  end

  @doc "Map of preset → public URL for image assets."
  @spec rendition_urls(%MediaFile{}, keyword()) :: map()
  def rendition_urls(%MediaFile{} = file, opts \\ []) do
    if image?(file) do
      Map.new(Renditions.presets(), fn preset ->
        {preset, maybe_sign(Renditions.url(file, preset), file, opts)}
      end)
    else
      %{}
    end
  end

  @doc """
  Apply the visibility-aware cache policy for local media bytes.

  `visibility` is the asset document's `bp_visibility`, threaded from the
  caller as `Access.visibility(doc)` — the doc is already in scope at both
  call sites, so this costs no extra query.

    * `"public"` — `#{@public_cache}` + a strong ETag, and a conditional
      request that matches short-circuits to `304`.
    * anything else (`"token"`, `"private"`, any unknown string, `nil`) —
      `#{@no_store_cache}`, NO ETag, and NO 304: a non-public asset must
      never be revalidated off a client-held validator, because the answer
      "unchanged" is itself a disclosure about bytes the caller may since
      have lost access to.
  """
  @spec put_file_cache_headers(Plug.Conn.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  def put_file_cache_headers(conn, full_path, visibility)

  def put_file_cache_headers(conn, full_path, "public") do
    etag = etag_for(full_path)

    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", @public_cache)
      |> Plug.Conn.put_resp_header("etag", etag)

    if if_none_match_hit?(conn, etag) do
      Plug.Conn.send_resp(conn, 304, "")
    else
      conn
    end
  end

  # Fail-closed catch-all: "token", "private", nil, and every unknown value.
  # Returns BEFORE any ETag/304 machinery — the full body is always sent.
  def put_file_cache_headers(conn, _full_path, _visibility) do
    Plug.Conn.put_resp_header(conn, "cache-control", @no_store_cache)
  end

  # ── If-None-Match conformance (charter http-edge-truth D11) ───────────────
  # ONE matcher for the whole app: `BarkparkWeb.Http.IfNoneMatch.match?/2`
  # (@canonical capability:if-none-match-compare) folds every header line,
  # splits on commas, drops empty entries, honours `*` and compares weakly.
  # This used to be a private copy with the same semantics minus the
  # empty-entry drop; a copy is a mirror nobody locks, so it delegates.
  defp if_none_match_hit?(conn, etag), do: BarkparkWeb.Http.IfNoneMatch.match?(conn, etag)

  @doc "Strong ETag from size + mtime."
  @spec etag_for(String.t()) :: String.t()
  def etag_for(full_path) do
    case File.stat(full_path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        mtime_unix = :calendar.datetime_to_gregorian_seconds(mtime) |> Integer.to_string(36)
        "\"#{size}-#{mtime_unix}\""

      _ ->
        "\"unknown\""
    end
  end

  defp maybe_sign(nil, _file, _opts), do: nil

  defp maybe_sign(path, file, opts) when is_binary(path) do
    # Scoped emission (P4 of Scoped-by-URL): URLs key off the REQUEST's
    # scope, never the asset row — a scoped API response emits
    # /w/<ws>/p/<proj>/media/... so the link resolves in the workspace the
    # caller is reading, while flat responses stay byte-identical
    # (prefix "") for every persisted-URL consumer. Prefix applied BEFORE
    # signing so a signed URL verifies against the path actually requested
    # on the scoped serve route.
    path = Keyword.get(opts, :scope_prefix, "") <> path

    signed =
      if Keyword.get(opts, :sign_urls, false) and token_visibility?(Keyword.get(opts, :asset_doc)) do
        SignedUrl.sign(path, file.id)
      else
        path
      end

    Cdn.public_url(signed)
  end

  defp token_visibility?(%Document{content: content}) when is_map(content) do
    Access.visibility(%Document{content: content}) == "token"
  end

  defp token_visibility?(_), do: false

  defp image?(%MediaFile{mime_type: mime}) when is_binary(mime),
    do: String.starts_with?(mime, "image/")

  defp image?(_), do: false
end
