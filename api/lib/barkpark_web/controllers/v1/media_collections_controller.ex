defmodule BarkparkWeb.V1.MediaCollectionsController do
  @moduledoc """
  Collections, membership, and share links at `/v1/media/:dataset/collections`.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Media.{AssetResponse, Collections, Share}
  alias BarkparkWeb.V1.MediaSearchParams

  action_fallback BarkparkWeb.FallbackController

  @default_limit 50
  @max_limit 500

  def index(conn, %{"dataset" => dataset} = params) do
    limit = parse_int(params["limit"], 200) |> min(1000)
    offset = parse_int(params["offset"], 0)

    collections =
      dataset
      |> Collections.list(limit: limit, offset: offset)
      |> Enum.map(&Collections.render/1)

    json(conn, %{
      result: %{collections: collections, count: length(collections), limit: limit, offset: offset},
      syncTags: ["bp:ds:#{dataset}:media:collections"]
    })
  end

  def show(conn, %{"dataset" => dataset, "id" => id}) do
    with {:ok, collection} <- Collections.get(id, dataset) do
      json(conn, %{
        result: Collections.render(collection),
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def assets(conn, %{"dataset" => dataset, "id" => id} = params) do
    t0 = System.monotonic_time(:microsecond)

    with {:ok, _collection} <- Collections.get(id, dataset) do
      opts = MediaSearchParams.parse(params)

      {files, total, facets} = Collections.assets(id, dataset, opts)
      docs = Media.asset_docs_for_files(files, dataset)
      render_opts = render_opts(conn, params, dataset)

      hits =
        Enum.map(files, fn file ->
          AssetResponse.render(file, Map.get(docs, file.id), render_opts)
        end)

      ms = div(System.monotonic_time(:microsecond) - t0, 1000)

      json(conn, %{
        result: %{
          collectionId: id,
          hits: hits,
          total: total,
          limit: opts[:limit],
          offset: opts[:offset],
          facets: facets
        },
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"],
        ms: ms
      })
    end
  end

  def share(conn, %{"dataset" => dataset, "id" => id} = params) do
    ttl = parse_int(params["ttl"], 60 * 60 * 24 * 7)

    with :ok <- require_write(conn),
         {:ok, share} <- Share.create(id, dataset, ttl: ttl) do
      json(conn, %{
        result: share,
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def revoke_share(conn, %{"dataset" => dataset, "id" => id}) do
    with :ok <- require_write(conn),
         {:ok, _} <- Share.revoke(id, dataset) do
      json(conn, %{
        result: %{revoked: id},
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def share_view(conn, %{"dataset" => dataset, "token" => token} = params) do
    t0 = System.monotonic_time(:microsecond)

    with {:ok, collection} <- Share.resolve(token, dataset) do
      opts =
        params
        |> MediaSearchParams.parse()
        |> Keyword.put(:limit, parse_int(params["limit"], @default_limit) |> min(@max_limit))

      {files, total, _facets} = Collections.assets(collection.doc_id, dataset, opts)
      docs = Media.asset_docs_for_files(files, dataset)
      render_opts = render_opts(conn, params, dataset, sign_urls: true)

      hits =
        Enum.map(files, fn file ->
          AssetResponse.render(file, Map.get(docs, file.id), render_opts)
        end)

      ms = div(System.monotonic_time(:microsecond) - t0, 1000)

      json(conn, %{
        result: %{
          collection: Collections.render(collection),
          hits: hits,
          total: total,
          limit: opts[:limit],
          offset: opts[:offset]
        },
        syncTags: ["bp:ds:#{dataset}:media:share:#{token}"],
        ms: ms
      })
    else
      {:error, :expired} ->
        conn
        |> put_status(:gone)
        |> json(%{
          error: %{
            code: "share_expired",
            message: "share link has expired or been revoked"
          }
        })

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def add_member(conn, %{"dataset" => dataset, "id" => id, "assetId" => asset_id}) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(asset_id),
         :ok <- ensure_dataset(file, dataset),
         {:ok, doc} <- Collections.add_member(id, file, dataset) do
      json(conn, %{
        result: AssetResponse.render(file, doc, dataset: dataset, conn: conn),
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}", "bp:ds:#{dataset}:media:#{asset_id}"]
      })
    end
  end

  def remove_member(conn, %{"dataset" => dataset, "id" => id, "asset_id" => asset_id}) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(asset_id),
         :ok <- ensure_dataset(file, dataset),
         {:ok, doc} <- Collections.remove_member(id, file, dataset) do
      json(conn, %{
        result: AssetResponse.render(file, doc, dataset: dataset, conn: conn),
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}", "bp:ds:#{dataset}:media:#{asset_id}"]
      })
    end
  end

  defp require_write(conn) do
    case conn.assigns[:api_token] do
      token when not is_nil(token) ->
        if Auth.has_permission?(token, "write") or Auth.has_permission?(token, "admin") do
          :ok
        else
          {:error, :forbidden}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp ensure_dataset(%{dataset: ds}, ds), do: :ok
  defp ensure_dataset(_, _), do: {:error, :not_found}

  defp render_opts(conn, params, dataset, extra \\ []) do
    [
      conn: conn,
      dataset: dataset,
      sign_urls:
        Keyword.get(extra, :sign_urls, false) or params["appendRequestSecret"] in ["true", "1"]
    ]
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_int(_, default), do: default
end
