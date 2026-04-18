defmodule BarkparkWeb.MetaController do
  @moduledoc """
  Handshake endpoint for SDK clients. No auth, rate-limit exempt.

  Returns API version window, server time, and schema hash(es) so clients
  can detect schema drift without reading every schema.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Content

  @min_api_version "2026-04-01"
  @max_api_version "2026-04-17"

  def index(conn, params) do
    hash =
      case Map.get(params, "dataset") do
        ds when is_binary(ds) -> Content.schema_hash_for_dataset(ds)
        _ -> Content.schema_hash_for_all_datasets()
      end

    json(conn, %{
      minApiVersion: @min_api_version,
      maxApiVersion: @max_api_version,
      serverTime: DateTime.utc_now() |> DateTime.to_iso8601(),
      currentDatasetSchemaHash: hash
    })
  end
end
