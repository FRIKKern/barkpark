defmodule Barkpark.Media.SearchAnalytics do
  @moduledoc """
  Media search history and query suggestions (Algolia / Typesense patterns).

  * **Recent** — per-actor last distinct queries (session or API token).
  * **Popular** — dataset-wide successful searches (non-zero hits), 30-day window.
  * **Nohits** — repeated zero-result queries (content-gap signals).

  Events are recorded on first-page `/search` only. Postgres `pg_trgm` indexes
  power prefix matching on suggestion lookup; ParadeDB/pg_search remains a
  future upgrade path for asset full-text (see `docs/media/DISCOVERY.md`).
  """

  import Ecto.Query
  alias Barkpark.Media.SearchEvent
  alias Barkpark.Repo
  alias BarkparkWeb.V1.MediaSearchParams

  @popular_window_days 30
  @default_limit 8

  @doc "Record a search event. Never raises — analytics must not break search."
  @spec record(String.t(), map(), non_neg_integer(), non_neg_integer(), keyword()) :: :ok
  def record(dataset, params, total, duration_ms, opts \\ []) when is_binary(dataset) do
    offset = parse_offset(params)

    if offset > 0 do
      :ok
    else
      do_record(dataset, params, total, duration_ms, opts)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Suggestions for autocomplete. Returns `%{recent: [], popular: [], nohits: []}`.
  """
  @spec suggestions(String.t(), String.t(), String.t() | nil, keyword()) :: map()
  def suggestions(dataset, actor_key, prefix \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    prefix = normalize_prefix(prefix)

    %{
      recent: recent_queries(dataset, actor_key, prefix, limit),
      popular: popular_queries(dataset, prefix, limit),
      nohits: nohits_queries(dataset, prefix, min(limit, 5))
    }
  end

  defp do_record(dataset, params, total, duration_ms, opts) do
    actor_key = Keyword.get(opts, :actor_key, "anon")
    parsed = MediaSearchParams.parse(params)
    filters = filters_snapshot(parsed)
    query = display_query(parsed, filters)

    if meaningful?(query, filters) do
      %SearchEvent{}
      |> Ecto.Changeset.change(%{
        dataset: dataset,
        query: query,
        filters: filters,
        result_count: total,
        zero_hits: total == 0,
        actor_key: actor_key,
        duration_ms: duration_ms
      })
      |> Repo.insert()
    end

    :ok
  end

  defp meaningful?(query, filters) do
    query != "" or filters != %{}
  end

  defp display_query(parsed, filters) do
    case parsed[:q] do
      q when is_binary(q) ->
        String.trim(q)

      _ ->
        case Map.get(filters, "kind") do
          k when is_binary(k) and k != "" -> ""
          _ -> ""
        end
    end
  end

  defp filters_snapshot(parsed) do
    selections = parsed[:facet_selections] || %{}

    base =
      %{
        "kind" => first_present([parsed[:kind], selections["kind"]]),
        "collection" => parsed[:collection],
        "facets" =>
          selections
          |> Map.drop(["kind"])
          |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
          |> Map.new()
      }

    base
    |> Enum.reject(fn {_k, v} ->
      v in [nil, ""] or (is_map(v) and map_size(v) == 0)
    end)
    |> Map.new()
  end

  defp first_present(values) do
    Enum.find(values, fn v -> v not in [nil, ""] end)
  end

  defp parse_offset(params) when is_map(params) do
    case params["offset"] do
      nil ->
        0

      value ->
        case Integer.parse(to_string(value)) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end
    end
  end

  defp recent_queries(dataset, actor_key, prefix, limit) do
    base =
      from(e in SearchEvent,
        where: e.dataset == ^dataset and e.actor_key == ^actor_key,
        order_by: [desc: e.inserted_at],
        limit: ^(limit * 4)
      )

    base
    |> maybe_prefix(prefix)
    |> Repo.all()
    |> dedupe_recent(limit)
  end

  defp dedupe_recent(rows, limit) do
    rows
    |> Enum.reduce({[], MapSet.new()}, fn row, {acc, seen} ->
      key = recent_key(row)

      if MapSet.member?(seen, key) or length(acc) >= limit do
        {acc, seen}
      else
        {[row | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(&recent_payload/1)
  end

  defp recent_key(%SearchEvent{query: q, filters: f}), do: {q, f}

  defp recent_payload(%SearchEvent{} = e) do
    %{
      query: e.query,
      filters: e.filters || %{},
      resultCount: e.result_count,
      zeroHits: e.zero_hits,
      at: e.inserted_at
    }
  end

  defp popular_queries(dataset, prefix, limit) do
    cutoff = DateTime.add(DateTime.utc_now(), -@popular_window_days, :day)

    from(e in SearchEvent,
      where:
        e.dataset == ^dataset and e.inserted_at >= ^cutoff and e.zero_hits == false and
          e.query != "",
      group_by: e.query,
      select: %{
        query: e.query,
        count: count(e.id),
        lastResultCount: max(e.result_count)
      },
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> maybe_prefix_on_query(prefix)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{query: row.query, count: row.count, resultCount: row.lastResultCount}
    end)
  end

  defp nohits_queries(dataset, prefix, limit) do
    cutoff = DateTime.add(DateTime.utc_now(), -@popular_window_days, :day)

    from(e in SearchEvent,
      where:
        e.dataset == ^dataset and e.inserted_at >= ^cutoff and e.zero_hits == true and
          e.query != "",
      group_by: e.query,
      select: %{query: e.query, count: count(e.id)},
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> maybe_prefix_on_query(prefix)
    |> Repo.all()
  end

  defp maybe_prefix(queryable, nil), do: queryable

  defp maybe_prefix(queryable, prefix) do
    pattern = prefix <> "%"
    from(e in queryable, where: ilike(e.query, ^pattern))
  end

  defp maybe_prefix_on_query(queryable, nil), do: queryable

  defp maybe_prefix_on_query(queryable, prefix) do
    pattern = prefix <> "%"

    from(e in queryable,
      where: ilike(e.query, ^pattern)
    )
  end

  defp normalize_prefix(nil), do: nil
  defp normalize_prefix(""), do: nil

  defp normalize_prefix(prefix) when is_binary(prefix) do
    prefix |> String.trim() |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
