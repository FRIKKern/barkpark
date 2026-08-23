defmodule BarkparkWeb.V1.MediaCollectionsController do
  @moduledoc """
  Collections, membership, and share links at `/v1/media/:dataset/collections`.
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Media
  alias Barkpark.Media.Storage.{Collections, Share}
  alias Barkpark.Media.Delivery.AssetResponse
  alias Barkpark.Media.Delivery.SearchParams, as: MediaSearchParams
  alias BarkparkWeb.Plugs.RequireWritePermission

  action_fallback BarkparkWeb.FallbackController

  @default_limit 50
  @max_limit 500

  def index(conn, %{"dataset" => dataset} = params) do
    limit = parse_int(params["limit"], 200) |> min(1000)
    offset = parse_int(params["offset"], 0)

    collections =
      dataset
      |> Collections.list([limit: limit, offset: offset] ++ scope_opts(conn))
      |> Enum.map(&Collections.render/1)

    json(conn, %{
      result: %{
        collections: collections,
        count: length(collections),
        limit: limit,
        offset: offset
      },
      syncTags: ["bp:ds:#{dataset}:media:collections"]
    })
  end

  def show(conn, %{"dataset" => dataset, "id" => id}) do
    with {:ok, collection} <- Collections.get(id, dataset, scope_opts(conn)) do
      json(conn, %{
        result: Collections.render(collection),
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def assets(conn, %{"dataset" => dataset, "id" => id} = params) do
    t0 = System.monotonic_time(:microsecond)

    with {:ok, _collection} <- Collections.get(id, dataset, scope_opts(conn)) do
      opts = MediaSearchParams.parse(params) ++ scope_opts(conn)

      {files, total, facets} = Collections.assets(id, dataset, opts)
      docs = Media.asset_docs_for_files(files, dataset, scope_opts(conn))
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
         {:ok, share} <- Share.create(id, dataset, [ttl: ttl] ++ scope_opts(conn)) do
      json(conn, %{
        result: share,
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def revoke_share(conn, %{"dataset" => dataset, "id" => id}) do
    with :ok <- require_write(conn),
         {:ok, doc} <- Share.revoke(id, dataset, scope_opts(conn)) do
      # RECEIPT LAW (pds w40): `Share.revoke/3` (share.ex:69-82) tail-calls
      # `Content.upsert_document/4` and so returns `{:ok, %Document{}}` — the
      # UPDATED row, not a literal. This used to discard it and echo the `:id`
      # path param, which is true whether or not the flip landed. `shareEnabled`
      # is read off the returned document's own persisted content, so a write
      # that silently failed to flip the flag can no longer answer "revoked".
      json(conn, %{
        result: %{
          revoked: doc.doc_id,
          shareEnabled: get_in(doc.content, ["shareLink", "enabled"])
        },
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
      docs = Media.asset_docs_for_files(files, dataset, scope_opts(conn))
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
         {:ok, file} <- Media.get_file(asset_id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         {:ok, doc} <- Collections.add_member(id, file, dataset, scope_opts(conn)) do
      json(conn, %{
        result: AssetResponse.render(file, doc, dataset: dataset, conn: conn),
        syncTags: [
          "bp:ds:#{dataset}:media:collections:#{id}",
          "bp:ds:#{dataset}:media:#{asset_id}"
        ]
      })
    end
  end

  def remove_member(conn, %{"dataset" => dataset, "id" => id, "asset_id" => asset_id}) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(asset_id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         {:ok, doc} <- Collections.remove_member(id, file, dataset, scope_opts(conn)) do
      json(conn, %{
        result: AssetResponse.render(file, doc, dataset: dataset, conn: conn),
        syncTags: [
          "bp:ds:#{dataset}:media:collections:#{id}",
          "bp:ds:#{dataset}:media:#{asset_id}"
        ]
      })
    end
  end

  # ONE JUDGMENT, ONE OWNER (task-6e22b3922dc42e8c) — the SECOND instance of the
  # class, collapsed with its media_controller.ex twin. This arm re-derived the
  # write judgment `BarkparkWeb.Plugs.RequireWritePermission` had already made on
  # the same request, and diverged from it harder than the twin did: it carried
  # NEITHER a `share_writer` arm NOR an account arm, so a principal the gate
  # admits on either of those grounds collected a 401 here. It now reads the
  # gate's verdict. Still fails CLOSED on a route that ever loses the plug: no
  # grant assign, no write.
  defp require_write(conn) do
    if RequireWritePermission.granted?(conn), do: :ok, else: {:error, :forbidden}
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
