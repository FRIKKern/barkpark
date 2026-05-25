defmodule Barkpark.Search.Intelligence do
  @moduledoc """
  Barkpark core search intelligence — record, suggest, crystallize, improve.

  Any product surface (media DAM, document search, …) calls this module with a
  `surface` tag and a `scope` (e.g. `"media", "production"`). Surfaces translate
  their native params into a `%{}` context with `:query`, `:filters`, and `:offset`.

  See `docs/search/INTELLIGENCE.md` and `Barkpark.Media.SearchIntelligence`.
  """

  import Ecto.Query
  alias Barkpark.Search.{Crystal, Event, MergePattern, Sanitizer}
  alias Barkpark.Repo

  @popular_window_days 30
  @retention_days 90
  @default_limit 8
  @min_search_count 3

  @doc "Default retention for raw search events (days)."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  Record a search event. Returns `{:ok, event_id}`, `:skipped`, or `{:rejected, reason}`.
  Never raises — analytics must not break search.
  """
  @spec record(String.t(), String.t(), map(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, Ecto.UUID.t()} | :skipped | {:rejected, atom()}
  def record(surface, scope, context, total, duration_ms, opts \\ [])
      when is_binary(surface) and is_binary(scope) and is_map(context) do
    offset = Map.get(context, :offset, 0)

    result =
      cond do
        Keyword.get(opts, :disabled, false) ->
          :skipped

        Keyword.get(opts, :record, true) == false ->
          :skipped

        offset > 0 ->
          :skipped

        true ->
          safe_record(surface, scope, context, total, duration_ms, opts)
      end

    emit_record_telemetry(surface, scope, result)
    result
  rescue
    _ ->
      emit_record_telemetry(surface, scope, :error)
      :skipped
  catch
    _, _ ->
      emit_record_telemetry(surface, scope, :error)
      :skipped
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
      from(e in Event, where: e.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  @doc """
  Record a click or select interaction against a prior search event.
  Returns `{:ok, event_id}` or `:skipped`. Never raises.
  """
  @spec record_interaction(String.t(), String.t(), map(), keyword()) ::
          {:ok, Ecto.UUID.t()} | :skipped
  def record_interaction(surface, scope, attrs, opts \\ [])
      when is_binary(surface) and is_binary(scope) and is_map(attrs) do
    if Keyword.get(opts, :disabled, false) do
      :skipped
    else
      safe_record_interaction(surface, scope, attrs, opts)
    end
  rescue
    _ -> :skipped
  catch
    _, _ -> :skipped
  end

  @doc """
  Suggestions for autocomplete. Returns `%{recent: [], popular: [], nohits: []}`.
  """
  @spec suggestions(String.t(), String.t(), String.t(), String.t() | nil, keyword()) :: map()
  def suggestions(surface, scope, actor_key, prefix \\ nil, opts \\ [])
      when is_binary(surface) and is_binary(scope) do
    limit = Keyword.get(opts, :limit, @default_limit)
    min_count = Keyword.get(opts, :min_search_count, @min_search_count)
    prefix = normalize_suggest_prefix(prefix)

    suggest_opts = [min_search_count: min_count]

    %{
      recent: recent_queries(surface, scope, actor_key, prefix, limit),
      popular: popular_queries(surface, scope, prefix, limit, suggest_opts),
      nohits: nohits_queries(surface, scope, prefix, min(limit, 5))
    }
  end

  @spec insights(String.t(), String.t(), keyword()) :: map()
  def insights(surface, scope, opts \\ [])
      when is_binary(surface) and is_binary(scope) do
    period = opts |> Keyword.get(:period, "week") |> to_string()

    period_start =
      case Keyword.get(opts, :period_start) do
        %Date{} = date -> date
        _ -> default_period_start(period)
      end

    quality = quality_stats(surface, scope, period, period_start)

    top_queries =
      from(c in Crystal,
        where:
          c.surface == ^surface and c.scope == ^scope and c.period == ^period and
            c.period_start == ^period_start and c.query_normalized != "__quality__" and
            c.search_count > 0,
        order_by: [desc: c.search_count],
        limit: 20
      )
      |> Repo.all()
      |> Enum.map(&crystal_payload/1)

    merge_patterns =
      from(m in MergePattern,
        where:
          m.surface == ^surface and m.scope == ^scope and m.period == ^period and
            m.period_start == ^period_start,
        order_by: [desc: m.transition_count],
        limit: 30
      )
      |> Repo.all()
      |> Enum.map(&merge_pattern_payload/1)

    %{
      surface: surface,
      scope: scope,
      period: period,
      periodStart: period_start,
      quality: quality,
      topQueries: top_queries,
      mergePatterns: merge_patterns,
      hints: improvement_hints(top_queries, merge_patterns, quality)
    }
  end

  defp safe_record(surface, scope, context, total, duration_ms, opts) do
    do_record(surface, scope, context, total, duration_ms, opts)
  rescue
    _ -> :skipped
  catch
    _, _ -> :skipped
  end

  defp do_record(surface, scope, context, total, duration_ms, opts) do
    actor_key = Keyword.get(opts, :actor_key, "anon")
    parent_event_id = Keyword.get(opts, :parent_event_id)
    source = Keyword.get(opts, :source, "api")
    session_key = Keyword.get(opts, :session_key)
    tags = Keyword.get(opts, :tags, [])

    raw_query = Map.get(context, :query, "") || ""
    filters = Map.get(context, :filters, %{})

    base = %{
      surface: surface,
      scope: scope,
      result_count: total,
      zero_hits: total == 0,
      actor_key: actor_key,
      duration_ms: duration_ms,
      parent_event_id: parent_event_id,
      source: source,
      session_key: session_key,
      tags: tags
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

  defp safe_record_interaction(surface, scope, attrs, opts) do
    do_record_interaction(surface, scope, attrs, opts)
  rescue
    _ -> :skipped
  catch
    _, _ -> :skipped
  end

  defp do_record_interaction(surface, scope, attrs, opts) do
    query_event_id = interaction_uuid(attrs, :query_event_id, "queryEventId")
    object_id = interaction_string(attrs, :object_id, "objectId")
    event_type = interaction_type(attrs)
    position = interaction_position(attrs)

    if is_nil(query_event_id) or object_id in [nil, ""] do
      :skipped
    else
      case Repo.get(Event, query_event_id) do
        %Event{surface: ^surface, scope: ^scope, event_type: "search"} = search ->
          {:ok, event} =
            insert_event(%{
              surface: surface,
              scope: scope,
              event_type: event_type,
              query: search.query,
              query_normalized: search.query_normalized,
              filters: search.filters || %{},
              object_id: object_id,
              position: position,
              query_event_id: search.id,
              result_count: 0,
              zero_hits: false,
              actor_key: Keyword.get(opts, :actor_key, "anon"),
              parent_event_id: nil,
              source: Keyword.get(opts, :source, "api"),
              session_key: Keyword.get(opts, :session_key),
              quality: "accepted",
              reject_reason: nil,
              duration_ms: nil
            })

          {:ok, event.id}

        _ ->
          :skipped
      end
    end
  end

  defp interaction_uuid(attrs, atom_key, string_key) do
    value = Map.get(attrs, atom_key) || Map.get(attrs, string_key)

    case value do
      id when is_binary(id) ->
        case Ecto.UUID.cast(String.trim(id)) do
          {:ok, uuid} -> uuid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp interaction_string(attrs, atom_key, string_key) do
    case Map.get(attrs, atom_key) || Map.get(attrs, string_key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: String.slice(trimmed, 0, 256)

      value when not is_nil(value) ->
        value |> to_string() |> String.trim() |> String.slice(0, 256)

      _ ->
        nil
    end
  end

  defp interaction_type(attrs) do
    case Map.get(attrs, :type) || Map.get(attrs, "type") || Map.get(attrs, :event_type) ||
           Map.get(attrs, "eventType") do
      "select" -> "select"
      "click" -> "click"
      _ -> "click"
    end
  end

  defp interaction_position(attrs) do
    case Map.get(attrs, :position) || Map.get(attrs, "position") do
      n when is_integer(n) and n >= 0 -> n
      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i >= 0 -> i
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp insert_event(attrs) do
    %Event{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert()
  end

  defp qualify_query(raw_query, filters) do
    has_filters = filters != %{} and map_size(filters) > 0

    case Sanitizer.sanitize(raw_query) do
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

  defp accepted_events(queryable) do
    from(e in queryable,
      where: (is_nil(e.quality) or e.quality == "accepted") and e.event_type == "search"
    )
  end

  defp recent_queries(surface, scope, actor_key, prefix, limit) do
    base =
      from(e in Event,
        where: e.surface == ^surface and e.scope == ^scope and e.actor_key == ^actor_key,
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

  defp recent_key(%Event{query: q, query_normalized: n, filters: f}) do
    {n || q, f}
  end

  defp recent_payload(%Event{} = e) do
    %{
      query: e.query != "" && e.query || e.query_normalized,
      filters: e.filters || %{},
      resultCount: e.result_count,
      zeroHits: e.zero_hits,
      at: e.inserted_at
    }
  end

  defp popular_queries(surface, scope, prefix, limit, opts) do
    min_count = Keyword.get(opts, :min_search_count, @min_search_count)
    today = Date.utc_today()
    window_start = Date.add(today, -@popular_window_days)

    crystal_rows =
      popular_from_crystals(surface, scope, prefix, window_start, Date.add(today, -1))

    today_start = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    raw_rows = popular_from_events(surface, scope, prefix, today_start)

    crystal_rows
    |> merge_count_rows(raw_rows)
    |> Enum.filter(fn row -> row.count >= min_count end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn row ->
      %{
        query: row.query,
        count: row.count,
        resultCount: row.result_count
      }
    end)
  end

  defp popular_from_crystals(surface, scope, prefix, period_start, period_end) do
    base =
      from(c in Crystal,
        where:
          c.surface == ^surface and c.scope == ^scope and c.period == "day" and
            c.period_start >= ^period_start and c.period_start <= ^period_end and
            c.query_normalized != "" and c.query_normalized != "__quality__" and
            c.success_count > 0,
        group_by: c.query_normalized,
        select: %{
          query_normalized: c.query_normalized,
          count: sum(c.success_count),
          result_count: max(c.avg_result_count)
        }
      )

    base
    |> maybe_prefix_on_crystal(prefix)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        query: row.query_normalized,
        count: row.count,
        result_count: round_result_count(row.result_count)
      }
    end)
  end

  defp popular_from_events(surface, scope, prefix, since) do
    from(e in Event,
      where:
        e.surface == ^surface and e.scope == ^scope and e.inserted_at >= ^since and
          e.zero_hits == false and e.query_normalized != "",
      group_by: e.query_normalized,
      select: %{
        query_normalized: e.query_normalized,
        display_query: max(e.query),
        count: count(e.id),
        result_count: max(e.result_count)
      }
    )
    |> accepted_events()
    |> maybe_prefix_on_normalized(prefix)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        query: row.display_query || row.query_normalized,
        count: row.count,
        result_count: row.result_count
      }
    end)
  end

  defp nohits_queries(surface, scope, prefix, limit) do
    today = Date.utc_today()
    window_start = Date.add(today, -@popular_window_days)

    crystal_rows =
      nohits_from_crystals(surface, scope, prefix, window_start, Date.add(today, -1))

    today_start = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    raw_rows = nohits_from_events(surface, scope, prefix, today_start)

    crystal_rows
    |> merge_count_rows(raw_rows)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn row -> %{query: row.query, count: row.count} end)
  end

  defp nohits_from_crystals(surface, scope, prefix, period_start, period_end) do
    base =
      from(c in Crystal,
        where:
          c.surface == ^surface and c.scope == ^scope and c.period == "day" and
            c.period_start >= ^period_start and c.period_start <= ^period_end and
            c.query_normalized != "" and c.query_normalized != "__quality__" and
            c.zero_hit_count > 0,
        group_by: c.query_normalized,
        select: %{
          query_normalized: c.query_normalized,
          count: sum(c.zero_hit_count)
        }
      )

    base
    |> maybe_prefix_on_crystal(prefix)
    |> Repo.all()
    |> Enum.map(fn row -> %{query: row.query_normalized, count: row.count} end)
  end

  defp nohits_from_events(surface, scope, prefix, since) do
    from(e in Event,
      where:
        e.surface == ^surface and e.scope == ^scope and e.inserted_at >= ^since and
          e.zero_hits == true and e.query_normalized != "",
      group_by: e.query_normalized,
      select: %{query: max(e.query), count: count(e.id)}
    )
    |> accepted_events()
    |> maybe_prefix_on_normalized(prefix)
    |> Repo.all()
  end

  defp merge_count_rows(primary, secondary) do
    merged =
      Enum.reduce(secondary, Map.new(primary, fn row -> {row.query, row} end), fn row, acc ->
        Map.update(acc, row.query, row, fn existing ->
          count = existing.count + row.count

          result_count =
            Map.get(row, :result_count) || Map.get(existing, :result_count) || 0

          Map.merge(existing, %{count: count, result_count: result_count})
        end)
      end)

    Map.values(merged)
  end

  defp round_result_count(nil), do: 0
  defp round_result_count(value) when is_float(value), do: round(value)
  defp round_result_count(value) when is_integer(value), do: value

  defp quality_stats(surface, scope, period, period_start) do
    case Repo.get_by(Crystal,
           surface: surface,
           scope: scope,
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

  defp crystal_payload(%Crystal{} = c) do
    %{
      query: c.query_normalized,
      filterFingerprint: c.filter_fingerprint,
      searchCount: c.search_count,
      zeroHitCount: c.zero_hit_count,
      successCount: c.success_count,
      uniqueActors: c.unique_actors,
      avgResultCount: c.avg_result_count,
      avgDurationMs: c.avg_duration_ms,
      clickCount: c.click_count,
      ctr: c.ctr
    }
  end

  defp merge_pattern_payload(%MergePattern{} = m) do
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
        acc =
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

        if q.searchCount >= 10 and q.ctr < 0.1 do
          [
            %{
              kind: "ctr",
              message:
                "Query \"#{q.query}\" has low CTR (#{Float.round(q.ctr * 100, 1)}%) despite volume — review ranking or titles.",
              query: q.query,
              ctr: q.ctr
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
  defp default_period_start("week"), do: Date.add(Date.utc_today(), -7)
  defp default_period_start("month"), do: Date.utc_today() |> Date.beginning_of_month()
  defp default_period_start(_), do: Date.add(Date.utc_today(), -7)

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

  defp maybe_prefix_on_crystal(queryable, nil), do: queryable

  defp maybe_prefix_on_crystal(queryable, prefix) do
    pattern = prefix <> "%"
    from(c in queryable, where: ilike(c.query_normalized, ^pattern))
  end

  defp normalize_suggest_prefix(nil), do: nil
  defp normalize_suggest_prefix(""), do: nil

  defp normalize_suggest_prefix(prefix) when is_binary(prefix) do
    case Sanitizer.suggest_sanitize(prefix) do
      {:ok, normalized} -> normalized
      _ -> nil
    end
  end

  defp emit_record_telemetry(surface, scope, result) do
    {status, reason} =
      case result do
        {:ok, _} -> {:ok, nil}
        :skipped -> {:skipped, nil}
        {:rejected, reason} -> {:rejected, reason}
        :error -> {:error, nil}
        _ -> {:error, nil}
      end

    metadata =
      %{surface: surface, scope: scope, result: status}
      |> maybe_put_reason(reason)

    :telemetry.execute([:barkpark, :search, :intel, :record], %{count: 1}, metadata)
  end

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, reason)
end
