defmodule Barkpark.Media.Delivery do
  @moduledoc """
  media-delivery layer — the CDN / serving edge.

  Turns an asset + a request into a served, cached response. This context
  module re-exports the layer's four sub-modules so callers depend on the
  layer, not its internals:

    * `Barkpark.Media.Delivery.Urls`          — delivery URL builders + cache headers
    * `Barkpark.Media.Delivery.Cdn`           — CDN URL prefixing + invalidation
    * `Barkpark.Media.Delivery.AssetResponse` — unified asset JSON response shape
    * `Barkpark.Media.Delivery.Events`        — media-lifecycle outbound webhooks

  This is the TOP media layer: it depends downward on `media-storage` and
  `media-processing` plus the content/tenancy kernel; nothing in those lower
  layers may call up into it.
  """

  alias Barkpark.Media.Delivery.{AssetResponse, Cdn, Events, Urls}

  # ── delivery URLs + cache headers (Urls) ──────────────────────────────────
  # Functions carrying default args (\\) are exposed as explicit thin wrappers
  # rather than bare defdelegate so every external arity stays callable.

  def original_url(file, opts \\ []), do: Urls.original_url(file, opts)
  def thumbnail_url(file, opts \\ []), do: Urls.thumbnail_url(file, opts)
  def preview_url(file, opts \\ []), do: Urls.preview_url(file, opts)
  def rendition_urls(file, opts \\ []), do: Urls.rendition_urls(file, opts)

  defdelegate put_file_cache_headers(conn, full_path), to: Urls
  defdelegate etag_for(full_path), to: Urls

  # ── CDN prefixing + invalidation (Cdn) ────────────────────────────────────

  defdelegate public_url(path), to: Cdn
  defdelegate invalidation_paths(file), to: Cdn
  defdelegate url_map(file), to: Cdn
  defdelegate publish(file, doc), to: Cdn
  defdelegate invalidate(file), to: Cdn
  defdelegate invalidate_paths(paths), to: Cdn

  # ── unified asset response shape (AssetResponse) ──────────────────────────

  def render(file, asset_doc \\ nil, opts \\ []), do: AssetResponse.render(file, asset_doc, opts)

  # ── media-lifecycle webhooks (Events) ─────────────────────────────────────

  def dispatch(dataset, event, file, doc \\ nil), do: Events.dispatch(dataset, event, file, doc)
  defdelegate build_payload(event, dataset, file, doc), to: Events
end
