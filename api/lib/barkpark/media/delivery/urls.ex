defmodule Barkpark.Media.Delivery.Urls do
  @moduledoc """
  Delivery URL builders and HTTP cache headers for media binaries.
  """

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Cdn
  alias Barkpark.Media.{Access, MediaFile, Renditions, SignedUrl}

  @immutable_cache "public, max-age=31536000, immutable"

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

  @doc "Apply long-lived cache + ETag headers for immutable media bytes."
  @spec put_file_cache_headers(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_file_cache_headers(conn, full_path) do
    etag = etag_for(full_path)

    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", @immutable_cache)
      |> Plug.Conn.put_resp_header("etag", etag)

    case Plug.Conn.get_req_header(conn, "if-none-match") do
      [^etag | _] -> Plug.Conn.send_resp(conn, 304, "")
      _ -> conn
    end
  end

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
