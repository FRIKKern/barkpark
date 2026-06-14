defmodule BarkparkWeb.SearchController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Errors, SearchIntelligence}
  alias Barkpark.Search.{SurfaceConfigs, Synonyms}
  alias BarkparkWeb.SearchIntel

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def search(conn, %{"dataset" => dataset} = params) do
    case params["q"] do
      nil ->
        missing_q(conn)

      "" ->
        missing_q(conn)

      query ->
        t0 = System.monotonic_time(:microsecond)

        opts =
          [
            type: params["type"],
            types: parse_types(params["types"]),
            perspective: parse_perspective(params["perspective"]),
            limit: parse_int(params["limit"], 50),
            offset: parse_int(params["offset"], 0),
            engine: params["engine"] || "postgres"
          ] ++ scope_opts(conn)

        {docs, count, meta} = Content.search_documents(query, dataset, opts)
        ms = div(System.monotonic_time(:microsecond) - t0, 1000)

        record_opts = [
          actor_key: SearchIntel.actor_key(conn),
          parent_event_id: SearchIntel.parent_event_id(conn),
          session_key: SearchIntel.session_key(conn),
          source: SearchIntel.source(conn, "documents-api"),
          record: SearchIntel.should_record?(conn),
          tags: SearchIntel.tags(conn),
          metadata: search_metadata(meta)
        ]

        record_result =
          SearchIntelligence.record(dataset, params, count, ms, record_opts)

        search_event_id =
          case record_result do
            {:ok, id} -> id
            _ -> nil
          end

        json(conn, %{
          documents: Envelope.render_many(docs),
          count: count,
          query: query,
          parsedQuery: meta[:parsed],
          highlights: meta[:highlights] || %{},
          recovery: meta[:recovery],
          # Indx-only (null for Postgres): dataset-wide facet buckets +
          # coverage truncation boundary.
          facets: meta[:facets],
          truncation: meta[:truncation],
          searchEventId: search_event_id,
          ms: ms
        })
    end
  end

  # Default content types reindexed when the caller doesn't pass `types`.
  @reindex_types ~w(post page author category project paper)

  @doc """
  Enqueue an Indx blue/green rebuild for the scope. Token-gated (router); any
  member token works. Oban-unique per scope, so spamming collapses to one
  rebuild. Returns immediately with the enqueued job id — the live node's
  `:indx` queue runs the rebuild (~30s) and atomically swaps the dataset.
  """
  def reindex(conn, %{"dataset" => dataset} = params) do
    types =
      case parse_types(params["types"]) do
        nil -> @reindex_types
        list -> list
      end

    opts = [types: types, perspective: :published] ++ scope_opts(conn)

    case Barkpark.Plugins.Indx.IndexerWorker.enqueue(dataset, opts) do
      {:ok, job} ->
        json(conn, %{ok: true, scope: dataset, jobId: job.id, types: types})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "reindex_failed", message: inspect(reason)}})
    end
  end

  def search_suggestions(conn, %{"dataset" => dataset} = params) do
    prefix = params["q"] || params["prefix"]
    limit = parse_int(params["limit"], 8) |> min(20)

    result =
      SearchIntelligence.suggestions(
        dataset,
        SearchIntel.actor_key(conn),
        prefix,
        limit: limit
      )

    json(conn, %{
      result: result,
      syncTags: ["bp:ds:#{dataset}:documents:search"]
    })
  end

  def search_insights(conn, %{"dataset" => dataset} = params) do
    period = params["period"] || "week"

    opts = [period: period]

    opts =
      case SearchIntel.parse_period_start(params["periodStart"]) do
        %Date{} = date -> Keyword.put(opts, :period_start, date)
        _ -> opts
      end

    result = SearchIntelligence.insights(dataset, opts)

    json(conn, %{
      result: result,
      syncTags: ["bp:ds:#{dataset}:documents:search:insights"]
    })
  end

  def search_synonyms(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: Synonyms.list("documents", dataset),
      syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]
    })
  end

  def create_search_synonym(conn, %{"dataset" => dataset} = params) do
    case Synonyms.create("documents", dataset, params) do
      {:ok, row} ->
        json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def promote_search_synonym(conn, %{"dataset" => dataset} = params) do
    case Synonyms.promote("documents", dataset, params) do
      {:ok, row} ->
        json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]})

      {:error, reason} when reason in [:invalid, :missing_fields] ->
        conn |> put_status(422) |> json(%{error: %{message: "from and to are required"}})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def preview_search_synonym(conn, %{"dataset" => dataset} = params) do
    q = params["q"] || params["from"]

    result = Synonyms.preview("documents", dataset, q, params)
    json(conn, %{result: result})
  end

  def search_settings(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: SurfaceConfigs.get("documents", dataset),
      syncTags: ["bp:ds:#{dataset}:documents:search:settings"]
    })
  end

  def update_search_settings(conn, %{"dataset" => dataset} = params) do
    case SurfaceConfigs.upsert("documents", dataset, params) do
      {:ok, row} ->
        json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:documents:search:settings"]})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def delete_search_synonym(conn, %{"dataset" => dataset, "id" => id}) do
    case Synonyms.delete(id, "documents", dataset) do
      :ok ->
        json(conn, %{ok: true, syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "synonym not found"}})
    end
  end

  def search_interaction(conn, %{"dataset" => dataset} = params) do
    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "documents-api"),
      disabled: SearchIntel.recording_disabled?(conn)
    ]

    case SearchIntelligence.record_interaction(dataset, params, record_opts) do
      {:ok, id} -> json(conn, %{ok: true, interactionEventId: id})
      _ -> json(conn, %{ok: true})
    end
  end

  defp missing_q(conn) do
    env =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, "missing required parameter: q")

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published

  # Optional comma-separated allowlist restricting results + facets to a set of
  # document types (the finder passes its content types). nil = no restriction.
  defp parse_types(nil), do: nil

  defp parse_types(csv) when is_binary(csv) do
    case csv |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      types -> types
    end
  end

  defp parse_types(_), do: nil

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 0)
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp search_metadata(meta) when is_map(meta) do
    %{}
    |> maybe_put_meta("recovery", meta[:recovery])
    |> maybe_put_meta("parsed", meta[:parsed])
  end

  defp search_metadata(_), do: %{}

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  defp validation_error(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    conn
    |> put_status(422)
    |> json(%{error: %{message: "validation failed", details: errors}})
  end
end
