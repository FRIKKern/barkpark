defmodule BarkparkWeb.MetaController do
  @moduledoc """
  Handshake endpoint for SDK clients. No auth, rate-limit exempt.

  Returns API version window, server time, and schema hash(es) so clients
  can detect schema drift without reading every schema.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Content

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @min_api_version "2026-04-01"
  @max_api_version "2026-04-17"

  # Server-authoritative production signal for the CLI's destructive-write
  # guard (onb-backlog-isprod-custom-host-write-confirm): the client's
  # isProd/isProdServer heuristics fail CLOSED on any non-local host, and
  # `production: false` here is the one server-side signal that lets a genuine
  # non-prod instance (LAN dev box, staging on a dev build) skip the confirm.
  # Compile-time on purpose — only the deployment knows its role, and a prod
  # build can never talk itself out of the guard at runtime. Rides /v1/meta
  # (tolerant plain-map JSON both directions) and must NEVER move into the
  # capabilities manifest: CLI manifest decoding is strict
  # (DisallowUnknownFields), so an unknown manifest key bricks older CLIs.
  @production Mix.env() == :prod

  def index(conn, params) do
    hash =
      case Map.get(params, "dataset") do
        ds when is_binary(ds) -> Content.schema_hash_for_dataset(ds, scope_opts(conn))
        _ -> Content.schema_hash_for_all_datasets()
      end

    json(conn, %{
      minApiVersion: @min_api_version,
      maxApiVersion: @max_api_version,
      serverTime: DateTime.utc_now() |> DateTime.to_iso8601(),
      currentDatasetSchemaHash: hash,
      production: @production
    })
  end
end
