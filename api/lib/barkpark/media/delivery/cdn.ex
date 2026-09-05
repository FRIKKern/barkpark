defmodule Barkpark.Media.Delivery.Cdn do
  @moduledoc """
  CDN delivery URL prefixing and cache invalidation (WoodWing-style publish plane).

  When `:media_cdn, :base_url` is configured, public delivery URLs are emitted
  with the CDN origin. An optional HTTP invalidation adapter purges edge cache
  on update/delete.
  """

  alias Barkpark.Content
  alias Barkpark.Media.Delivery.Urls
  alias Barkpark.Media.Renditions
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Webhooks.Dispatcher

  @asset_type "mediaAsset"

  @doc "Prefix a relative delivery path with the configured CDN base URL."
  @spec public_url(String.t() | nil) :: String.t() | nil
  def public_url(nil), do: nil

  def public_url(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        path

      base = base_url() ->
        base <> path

      true ->
        path
    end
  end

  @doc "Relative paths that should be purged when an asset changes."
  @spec invalidation_paths(%MediaFile{}) :: [String.t()]
  def invalidation_paths(%MediaFile{} = file) do
    original = "/media/files/#{file.path}"

    renditions =
      if image?(file) do
        Enum.map(Renditions.presets(), fn preset -> "/media/renditions/#{file.id}/#{preset}" end)
      else
        []
      end

    [original | renditions]
  end

  @doc """
  Public CDN URLs for an asset (for webhook payloads and API receipts).

  `opts` is threaded straight into `Urls.*` — in practice only
  `:scope_prefix`. THAT ARGUMENT IS WHY THIS FUNCTION HAS AN ARITY-2 CLAUSE
  (task-57ee9fff4aae9217 #11): with no prefix every entry here is the FLAT
  `/media/files/...` path, and a flat media path 404s for a caller whose
  request was resolved under `/w/:ws/p/:proj`. A receipt whose `cdnUrls.original`
  cannot be fetched by the client that just uploaded the file is not a receipt.

  Callers that have no request scope (the webhook payload in `Events`, the
  `delivery.ex` delegate) keep calling the arity-1 form and get exactly the flat
  URLs they got before — persisted webhook consumers are unaffected.
  """
  @spec url_map(%MediaFile{}, keyword()) :: map()
  def url_map(%MediaFile{} = file, opts \\ []) do
    %{
      original: public_url(Urls.original_url(file, opts)),
      thumbnail: public_url(Urls.thumbnail_url(file, opts)),
      preview: public_url(Urls.preview_url(file, opts)),
      renditions:
        Map.new(Urls.rendition_urls(file, opts), fn {preset, url} -> {preset, public_url(url)} end)
    }
  end

  @doc "Mark asset CDN publish complete and purge stale edge cache."
  @spec publish(%MediaFile{}, struct() | nil) :: :ok
  def publish(%MediaFile{} = file, doc) do
    # Fire the edge purge in the BACKGROUND so a slow or hung third-party CDN
    # never stalls the upload/callback response. Both publish-path callers —
    # Processing.process/1 (media/processing.ex) and the transcoder "ready"
    # callback (media_processing_controller.ex) — return to their caller
    # immediately; the purge itself keeps its bounded Dispatcher.http_post
    # (10s timeout + SSRF guard) inside the supervised task.
    #
    # Fire-and-forget is safe: every caller discards publish's return, the
    # invalidate chain unconditionally returns :ok (network/HTTP failures are
    # logged, never raised), so a backgrounded purge cannot change an outcome
    # the caller observes. The delete-path Cdn.invalidate (media.ex, D36
    # after-commit deferral) is unaffected — it still runs inline under its own
    # transaction-boundary policy.
    purge_edge_cache_async(file)

    status =
      if base_url() do
        "published"
      else
        "skipped"
      end

    if doc, do: patch_cdn_status(doc, file, status)
    :ok
  end

  # Background the CDN round-trip on the general-purpose supervised task pool
  # (mirrors Media.Delivery.Events.dispatch/4's fire-and-forget seam). The task
  # is unlinked from the caller, so a purge crash can never take down the upload
  # process; a lost result is acceptable — the next asset change re-purges.
  defp purge_edge_cache_async(%MediaFile{} = file) do
    Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn -> invalidate(file) end)
    :ok
  end

  @doc "Purge CDN paths for a blob."
  @spec invalidate(%MediaFile{}) :: :ok
  def invalidate(%MediaFile{} = file) do
    invalidate_paths(invalidation_paths(file))
  end

  @doc "Purge explicit relative paths via the configured adapter."
  @spec invalidate_paths([String.t()]) :: :ok
  def invalidate_paths(paths) when is_list(paths) do
    paths = Enum.uniq(paths)

    case invalidation_adapter() do
      :http -> invalidate_http(paths)
      _ -> :ok
    end
  end

  defp invalidate_http(paths) do
    cfg = invalidation_config()
    url = Keyword.get(cfg, :url)

    if is_binary(url) and url != "" do
      secret = Keyword.get(cfg, :secret, "")

      body =
        Jason.encode!(%{paths: paths, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})

      headers =
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{secret}"}
        ]

      # Route through the webhook adapter seam (Dispatcher.http_post/3) so CDN
      # invalidation shares document webhooks' outbound policy. The adapter
      # returns `{:ok, status}` (no body), so non-2xx logs the status only.
      case Dispatcher.http_post(url, body, headers) do
        {:ok, status} when status in 200..299 ->
          :ok

        {:ok, status} ->
          log_warning("CDN invalidation HTTP #{status}")
          :ok

        {:error, reason} ->
          log_warning("CDN invalidation failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp patch_cdn_status(doc, %MediaFile{} = file, status) do
    content = Map.put(doc.content || %{}, "bp_cdn_status", status)

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" => content
    }

    case Content.upsert_document(@asset_type, attrs, file.dataset, source: :worker) do
      {:ok, _} -> :ok
      {:error, reason} -> log_warning("CDN status patch failed: #{inspect(reason)}")
    end

    :ok
  end

  defp base_url do
    Application.get_env(:barkpark, :media_cdn, [])
    |> Keyword.get(:base_url)
    |> case do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  defp invalidation_config do
    Application.get_env(:barkpark, :media_cdn, [])
    |> Keyword.get(:invalidation, adapter: :noop)
  end

  defp invalidation_adapter do
    invalidation_config() |> Keyword.get(:adapter, :noop)
  end

  defp image?(%MediaFile{mime_type: mime}) when is_binary(mime),
    do: String.starts_with?(mime, "image/")

  defp image?(_), do: false

  defp log_warning(message) do
    require Logger
    Logger.warning("Barkpark.Media.Delivery.Cdn: #{message}")
  end
end
