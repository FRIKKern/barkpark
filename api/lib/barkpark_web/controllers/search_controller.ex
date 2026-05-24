defmodule BarkparkWeb.SearchController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Errors, SearchIntelligence}
  alias BarkparkWeb.SearchIntel

  def search(conn, %{"dataset" => dataset} = params) do
    case params["q"] do
      nil ->
        missing_q(conn)

      "" ->
        missing_q(conn)

      query ->
        t0 = System.monotonic_time(:microsecond)

        opts = [
          type: params["type"],
          perspective: parse_perspective(params["perspective"]),
          limit: parse_int(params["limit"], 50),
          offset: parse_int(params["offset"], 0)
        ]

        {docs, count} = Content.search_documents(query, dataset, opts)
        ms = div(System.monotonic_time(:microsecond) - t0, 1000)

        record_opts = [
          actor_key: SearchIntel.actor_key(conn),
          parent_event_id: SearchIntel.parent_event_id(conn),
          session_key: SearchIntel.session_key(conn),
          source: SearchIntel.source(conn, "documents-api"),
          disabled: SearchIntel.recording_disabled?(conn)
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
          searchEventId: search_event_id,
          ms: ms
        })
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

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 0)
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
