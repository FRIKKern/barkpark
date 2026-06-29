defmodule BarkparkWeb.FederatedSearchController do
  @moduledoc """
  Unified discovery across documents and media via GET /v1/search/:dataset.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Envelope
  alias Barkpark.Media
  alias Barkpark.Search.Intelligence
  alias BarkparkWeb.SearchIntel

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @default_surfaces ["documents", "media"]

  def search(conn, %{"dataset" => dataset} = params) do
    t0 = System.monotonic_time(:microsecond)
    q = params["q"] || ""
    limit = parse_int(params["limit"], 10)
    surfaces = parse_surfaces(params["surfaces"])
    scope = scope_opts(conn)

    results =
      surfaces
      |> Enum.map(fn surface ->
        Task.async(fn -> search_surface(surface, dataset, q, limit, params, scope) end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    ms = div(System.monotonic_time(:microsecond) - t0, 1000)
    total_hits = Enum.reduce(results, 0, fn r, acc -> acc + r.total end)

    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      parent_event_id: SearchIntel.parent_event_id(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "federated"),
      record: SearchIntel.should_record?(conn),
      tags: SearchIntel.tags(conn) ++ ["federated"]
    ]

    context = %{
      query: q,
      offset: 0,
      filters: %{"surfaces" => Enum.join(surfaces, ",")}
    }

    record_result =
      Intelligence.record("federated", dataset, context, total_hits, ms, record_opts)

    search_event_id =
      case record_result do
        {:ok, id} -> id
        _ -> nil
      end

    json(conn, %{
      query: q,
      surfaces: surfaces,
      results:
        Map.new(results, fn r ->
          {r.surface, surface_payload(r, CallerContext.from_conn(conn))}
        end),
      searchEventId: search_event_id,
      ms: ms
    })
  end

  defp surface_payload(
         %{surface: "documents", hits: hits, total: total, meta: meta},
         caller_context
       ) do
    # Multi-type federated hits => no single schema; the schema-free
    # encrypted-field guard in Envelope.render still applies for non-admins.
    %{
      hits: Envelope.render_many(hits, nil, caller_context),
      total: total,
      parsedQuery: meta[:parsed],
      highlights: meta[:highlights] || %{},
      recovery: meta[:recovery]
    }
  end

  defp surface_payload(
         %{
           surface: "media",
           hits: files,
           total: total,
           meta: meta,
           dataset: dataset,
           scope: scope
         },
         _caller_context
       ) do
    docs = Media.asset_docs_for_files(files, dataset, scope)
    render_opts = [include_urls: true]

    hits =
      Enum.map(files, fn file ->
        Barkpark.Media.Delivery.AssetResponse.render(file, Map.get(docs, file.id), render_opts)
      end)

    %{
      hits: hits,
      total: total,
      parsedQuery: meta[:parsed],
      highlights: meta[:highlights] || %{},
      recovery: meta[:recovery]
    }
  end

  defp surface_payload(
         %{surface: _surface, hits: hits, total: total, meta: meta},
         _caller_context
       ) do
    %{
      hits: hits,
      total: total,
      parsedQuery: meta[:parsed],
      highlights: meta[:highlights] || %{},
      recovery: meta[:recovery]
    }
  end

  defp search_surface("documents", dataset, q, limit, params, scope) do
    perspective = params["perspective"] || "published"
    type = params["type"]

    opts =
      [
        limit: limit,
        offset: 0,
        perspective: perspective,
        type: type
      ] ++ scope

    {docs, total, meta} = Content.search_documents(q, dataset, opts)

    %{
      surface: "documents",
      hits: docs,
      total: total,
      meta: meta
    }
  end

  defp search_surface("media", dataset, q, limit, params, scope) do
    opts =
      [
        q: q,
        limit: limit,
        offset: 0,
        sort: params["sort"] || "relevance"
      ] ++ scope

    {files, total, _facets, meta} = Media.search_files(dataset, opts)

    %{
      surface: "media",
      hits: files,
      total: total,
      meta: meta,
      dataset: dataset,
      scope: scope
    }
  end

  defp search_surface(surface, _dataset, _q, _limit, _params, _scope) do
    %{surface: surface, hits: [], total: 0, meta: %{}}
  end

  defp parse_surfaces(nil), do: @default_surfaces

  defp parse_surfaces(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 in @default_surfaces))
    |> case do
      [] -> @default_surfaces
      list -> list
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(n, _default) when is_integer(n) and n > 0, do: n
  defp parse_int(_, default), do: default
end
