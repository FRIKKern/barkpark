defmodule Barkpark.Media.SearchAnalytics do
  @moduledoc """
  Media search history, quality gates, crystallized rollups, and merge patterns.

  * **Recent** — per-actor last distinct queries (session or API token).
  * **Popular** — dataset-wide successful searches (non-zero hits), 30-day window.
  * **Nohits** — repeated zero-result queries (content-gap signals).
  * **Crystals** — day / week / month aggregates (survive raw prune).
  * **Merge patterns** — refinement chains for search improvement.

  Bad queries (profanity, spam, injection-ish) are rejected and never stored verbatim.
  """

  import Ecto.Query
  alias Barkpark.Media.{
    SearchCrystal,
    SearchEvent,
    SearchMergePattern,
    SearchQuerySanitizer
  }

  alias Barkpark.Repo
  alias BarkparkWeb.V1.MediaSearchParams

  @popular_window_days 30
  @retention_days 90
  @default_limit 8

  @doc "Default retention for raw search events (days)."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  Record a search event. Returns `{:ok, event_id}`, `:skipped`, or `{:rejected, reason}`.
  Never raises — analytics must not break search.
  """
  @spec record(String.t(), map(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, Ecto.UUID.t()} | :skipped | {:rejected, atom()}
  def record(dataset, params, total, duration_ms, opts \\ []) when is_binary(dataset) do
    offset = parse_offset(params)

    if offset > 0 do
      :skipped
    else
      safe_record(dataset, params, total, duration_ms, opts)
    end
  rescue
    _ -> :skipped
  catch
    _, _ -> :skipped
  end

  @doc """
  Delete search events older than `retention_days` (default #{@retention_days}).
  Returns the number of rows deleted.
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    days = Keyword.get(opts, :retention_days, @retention_days)
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    {count, _} =
      from(e in SearchEvent, where: e.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
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

  @doc """
  Crystallized insights for search improvement (admin). Period: `day`, `week`, or `month`.
  """
  @spec insights(String.t(), keyword()) :: map()
  def insights(dataset, opts \\ []) when is_binary(dataset) do
    period = opts |> Keyword.get(:period, "week") |> to_string()
    period_start = Keyword.get(opts, :period_start, default_period_start(period))

    quality = quality_stats(dataset, period, period_start)

    top_queries =
      from(c in SearchCrystal,
        where:
          c.dataset == ^dataset and c.period == ^period and c.period_start == ^period_start and
            c.query_normalized != "__quality__" and c.search_count > 0,
        order_by: [desc: c.search_count],
        limit: 20
      )
      |> Repo.all()
      |> Enum.map(&crystal_payload/1)

    merge_patterns =
      from(m in SearchMergePattern,
        where: m.dataset == ^dataset and m.period == ^period and m.period_start == ^period_start,
        order_by: [desc: m.transition_count],
        limit: 30
      )
      |> Repo.all()
      |> Enum.map(&merge_pattern_payload/1)

    %{
      period: period,
      periodStart: period_start,
      quality: quality,
      topQueries: top_queries,
      mergePatterns: merge_patterns,
      hints: improvement_hints(top_queries, merge_patterns, quality)
    }
  end

  defp safe_record(dataset, params, total, duration_ms, opts) do
    do_record(dataset, params, total, duration_ms, opts)
  rescue
    _ -> :skipped
  catch
    _, _ -> :skipped
  end

  defp do_record(dataset, params, total, duration_ms, opts) do
    actor_key = Keyword.get(opts, :actor_key, "anon")
    parent_event_id = Keyword.get(opts, :parent_event_id)
    source = Keyword.get(opts, :source, "api")
    session_key = Keyword.get(opts, :session_key)

    parsed = MediaSearchParams.parse(params)
    filters = filters_snapshot(parsed)
    raw_query = display_query(parsed, filters)

    base = %{
      dataset: dataset,
      result_count: total,
      zero_hits: total == 0,
      actor_key: actor_key,
      duration_ms: duration_ms,
      parent_event_id: parent_event_id,
      source: source,
      session_key: session_key
    }

    case qualify_query(raw_query, filters) do
      :skip ->
        :skipped

      {:reject, reason} ->
        {:ok, _event} =
          insert_event(
            Map.merge(base, %{
              query: "",
              query_normalized: "",
              filters: %{},
              quality: "rejected",
              reject_reason: Atom.to_string(reason)
            })
          )

        {:rejected, reason}

      {:ok, query, query_normalized} ->
        {:ok, event} =
          insert_event(
            Map.merge(base, %{
              query: query,
              query_normalized: query_normalized,
              filters: filters,
              quality: "accepted",
              reject_reason: nil
            })
          )

        {:ok, event.id}
    end
  end

  defp insert_event(attrs) do
    %SearchEvent{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert()
  end

  defp qualify_query(raw_query, filters) do
    has_filters = filters != %{} and map_size(filters) > 0

    case SearchQuerySanitizer.sanitize(raw_query) do
      {:ok, normalized} ->
        {:ok, String.trim(raw_query), normalized}

      {:reject, reason} when reason in [:empty, :too_short] and not has_filters ->
        :skip

      {:reject, _reason} when has_filters ->
        {:ok, "", ""}

      {:reject, reason} ->
        {:reject, reason}
    end
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

  defp accepted_events(queryable) do
    from(e in queryable,
      where: is_nil(e.quality) or e.quality == "accepted"
    )
  end

  defp recent_queries(dataset, actor_key, prefix, limit) do
    base =
      from(e in SearchEvent,
        where: e.dataset == ^dataset and e.actor_key == ^actor_key,
        order_by: [desc: e.inserted_at],
        limit: ^(limit * 4)
      )
      |> accepted_events()

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

  defp recent_key(%SearchEvent{query: q, query_normalized: n, filters: f}) do
    {n || q, f}
  end

  defp recent_payload(%SearchEvent{} = e) do
    %{
      query: e.query != "" && e.query || e.query_normalized,
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
          e.query_normalized != "",
      group_by: e.query_normalized,
      select: %{
        query_normalized: e.query_normalized,
        display_query: max(e.query),
        count: count(e.id),
        lastResultCount: max(e.result_count)
      },
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> accepted_events()
    |> maybe_prefix_on_normalized(prefix)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        query: row.display_query || row.query_normalized,
        count: row.count,
        resultCount: row.lastResultCount
      }
    end)
  end

  defp nohits_queries(dataset, prefix, limit) do
    cutoff = DateTime.add(DateTime.utc_now(), -@popular_window_days, :day)

    from(e in SearchEvent,
      where:
        e.dataset == ^dataset and e.inserted_at >= ^cutoff and e.zero_hits == true and
          e.query_normalized != "",
      group_by: e.query_normalized,
      select: %{query: max(e.query), count: count(e.id)},
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> accepted_events()
    |> maybe_prefix_on_normalized(prefix)
    |> Repo.all()
    |> Enum.map(fn row -> %{query: row.query, count: row.count} end)
  end

  defp quality_stats(dataset, period, period_start) do
    case Repo.get_by(SearchCrystal,
           dataset: dataset,
           period: period,
           period_start: period_start,
           query_normalized: "__quality__",
           filter_fingerprint: ""
         ) do
      nil ->
        %{rejected: 0, accepted: 0}

      row ->
        %{rejected: row.rejected_count, accepted: row.search_count}
    end
  end

  defp crystal_payload(%SearchCrystal{} = c) do
    %{
      query: c.query_normalized,
      filterFingerprint: c.filter_fingerprint,
      searchCount: c.search_count,
      zeroHitCount: c.zero_hit_count,
      successCount: c.success_count,
      uniqueActors: c.unique_actors,
      avgResultCount: c.avg_result_count,
      avgDurationMs: c.avg_duration_ms
    }
  end

  defp merge_pattern_payload(%SearchMergePattern{} = m) do
    %{
      from: m.from_fingerprint,
      to: m.to_fingerprint,
      type: m.pattern_type,
      transitions: m.transition_count,
      successes: m.success_count,
      successRate:
        if(m.transition_count > 0,
          do: Float.round(m.success_count / m.transition_count, 2),
          else: 0.0
        )
    }
  end

  defp improvement_hints(top_queries, merge_patterns, quality) do
    hints = []

    hints =
      if quality.rejected > 0 do
        [
          %{
            kind: "quality",
            message:
              "#{quality.rejected} rejected queries in period — review blocklist and spam rules."
          }
          | hints
        ]
      else
        hints
      end

    hints =
      Enum.reduce(top_queries, hints, fn q, acc ->
        if q.zeroHitCount > 0 and q.zeroHitCount >= div(q.searchCount, 2) do
          [
            %{
              kind: "nohits",
              message: "Query \"#{q.query}\" has high zero-hit rate — consider synonyms or tags.",
              query: q.query
            }
            | acc
          ]
        else
          acc
        end
      end)

    hints =
      Enum.reduce(merge_patterns, hints, fn p, acc ->
        cond do
          p.type == "zero_to_hit" and p.transitions >= 3 ->
            [
              %{
                kind: "merge",
                message:
                  "Users often recover from zero hits via \"#{p.to}\" — promote as suggested refinement.",
                pattern: p
              }
              | acc
            ]

          p.type == "facet_add" and p.transitions >= 5 ->
            [
              %{
                kind: "merge",
                message:
                  "Facet refinement \"#{p.from}\" → \"#{p.to}\" is common — consider a saved search.",
                pattern: p
              }
              | acc
            ]

          true ->
            acc
        end
      end)

    Enum.reverse(hints)
  end

  defp default_period_start("day"), do: Date.add(Date.utc_today(), -1)
  defp default_period_start("month"), do: Date.utc_today() |> Date.beginning_of_month()
  defp default_period_start(_week), do: Date.add(Date.utc_today(), -7)

  defp maybe_prefix(queryable, nil), do: queryable

  defp maybe_prefix(queryable, prefix) do
    pattern = prefix <> "%"

    from(e in queryable,
      where: ilike(e.query, ^pattern) or ilike(e.query_normalized, ^pattern)
    )
  end

  defp maybe_prefix_on_normalized(queryable, nil), do: queryable

  defp maybe_prefix_on_normalized(queryable, prefix) do
    pattern = prefix <> "%"
    from(e in queryable, where: ilike(e.query_normalized, ^pattern))
  end

  defp normalize_prefix(nil), do: nil
  defp normalize_prefix(""), do: nil

  defp normalize_prefix(prefix) when is_binary(prefix) do
    prefix |> String.trim() |> case do
      "" -> nil
      trimmed -> SearchQuerySanitizer.normalize(trimmed)
    end
  end
end
