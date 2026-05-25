defmodule Barkpark.Search.Crystallizer do
  @moduledoc """
  Core crystallization — roll raw search events into day / week / month aggregates.

  Surface-agnostic: operates on `search_intel_*` tables keyed by `surface` + `scope`.
  """

  import Ecto.Query
  alias Barkpark.Search.{Crystal, Event, MergePattern, Sanitizer}
  alias Barkpark.Repo

  @chain_gap_minutes 30

  @doc "Crystallize all surface/scope pairs for yesterday plus week/month boundaries when due."
  @spec crystallize_due(Date.t()) :: map()
  def crystallize_due(%Date{} = today \\ Date.utc_today()) do
    yesterday = Date.add(today, -1)

    pairs =
      from(e in Event, select: {e.surface, e.scope}, distinct: true)
      |> Repo.all()

    day_stats =
      Enum.map(pairs, fn {surface, scope} ->
        {{surface, scope}, crystallize_period(surface, scope, :day, yesterday)}
      end)

    week_stats =
      if Date.day_of_week(today) == 1 do
        week_start = Date.add(today, -7)

        Enum.map(pairs, fn {surface, scope} ->
          {{surface, scope}, crystallize_period(surface, scope, :week, week_start)}
        end)
      else
        []
      end

    month_stats =
      if today.day == 1 do
        month_start = Date.add(Date.beginning_of_month(today), -1) |> Date.beginning_of_month()

        Enum.map(pairs, fn {surface, scope} ->
          {{surface, scope}, crystallize_period(surface, scope, :month, month_start)}
        end)
      else
        []
      end

    %{
      day: day_stats,
      week: week_stats,
      month: month_stats
    }
  end

  @doc "Crystallize one surface/scope/period bucket (idempotent upsert)."
  @spec crystallize_period(String.t(), String.t(), :day | :week | :month, Date.t()) :: map()
  def crystallize_period(surface, scope, period, period_start)
      when is_binary(surface) and is_binary(scope) and period in [:day, :week, :month] do
    {start_dt, end_dt} = period_bounds(period, period_start)

    events =
      from(e in Event,
        where:
          e.surface == ^surface and e.scope == ^scope and e.inserted_at >= ^start_dt and
            e.inserted_at < ^end_dt
      )
      |> Repo.all()

    query_rows = aggregate_queries(events)
    merge_rows = detect_merge_patterns(events)

    crystal_count = upsert_crystals(surface, scope, period, period_start, query_rows, events)
    pattern_count = upsert_merge_patterns(surface, scope, period, period_start, merge_rows)

    %{
      events: length(events),
      crystals: crystal_count,
      merge_patterns: pattern_count
    }
  end

  @doc "Stable fingerprint for query + filters (used in crystals and merge detection)."
  @spec fingerprint(String.t(), map()) :: String.t()
  def fingerprint(query_normalized, filters) when is_map(filters) do
    parts = fingerprint_parts(query_normalized, filters)
    Enum.join(parts, "|")
  end

  @doc "Classify a transition between two consecutive search states."
  @spec classify_transition(map(), map()) :: String.t()
  def classify_transition(from, to) do
    from_q = Map.get(from, :query_normalized, "")
    to_q = Map.get(to, :query_normalized, "")
    from_f = Map.get(from, :filters, %{})
    to_f = Map.get(to, :filters, %{})
    from_zero = Map.get(from, :zero_hits, false)
    to_zero = Map.get(to, :zero_hits, false)

    cond do
      from_zero and not to_zero ->
        "zero_to_hit"

      from_q != "" and to_q != "" and from_q != to_q and from_f == to_f ->
        "query_replace"

      from_q != to_q and map_size(to_f) > map_size(from_f) ->
        "query_and_facet_add"

      map_size(to_f) > map_size(from_f) ->
        "facet_add"

      map_size(to_f) < map_size(from_f) ->
        "facet_remove"

      from_q != to_q ->
        "query_refine"

      true ->
        "filter_merge"
    end
  end

  defp period_bounds(:day, day) do
    start_dt = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC")
    {start_dt, end_dt}
  end

  defp period_bounds(:week, week_start) do
    start_dt = DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(Date.add(week_start, 7), ~T[00:00:00], "Etc/UTC")
    {start_dt, end_dt}
  end

  defp period_bounds(:month, month_start) do
    start_dt = DateTime.new!(month_start, ~T[00:00:00], "Etc/UTC")
    next_month = Date.add(Date.end_of_month(month_start), 1)
    end_dt = DateTime.new!(next_month, ~T[00:00:00], "Etc/UTC")
    {start_dt, end_dt}
  end

  defp aggregate_queries(events) do
    search_events =
      events
      |> Enum.filter(&(&1.event_type == "search"))
      |> Enum.filter(&analytics_eligible?/1)

    interaction_events =
      events
      |> Enum.filter(&(&1.event_type in ["click", "select"]))
      |> Enum.filter(&analytics_eligible?/1)

    accepted =
      Enum.filter(search_events, fn e ->
        e.quality == "accepted" or is_nil(e.quality)
      end)

    rejected_count = length(search_events) - length(accepted)

    grouped =
      accepted
      |> Enum.group_by(fn e ->
        {e.query_normalized || Sanitizer.normalize(e.query || ""),
         fingerprint(e.query_normalized || "", e.filters || %{})}
      end)

    rows =
      Enum.map(grouped, fn {{query_normalized, filter_fp}, rows} ->
        actors = rows |> Enum.map(& &1.actor_key) |> Enum.uniq() |> length()
        zero_hits = Enum.count(rows, & &1.zero_hits)
        success = length(rows) - zero_hits
        search_count = length(rows)

        click_count =
          interaction_events
          |> Enum.count(fn c ->
            c.query_normalized == query_normalized and
              fingerprint(c.query_normalized || "", c.filters || %{}) == filter_fp
          end)

        ctr =
          if search_count > 0,
            do: Float.round(click_count / search_count, 4),
            else: 0.0

        avg_results =
          rows |> Enum.map(& &1.result_count) |> avg_int()

        avg_ms =
          rows
          |> Enum.map(& &1.duration_ms)
          |> Enum.reject(&is_nil/1)
          |> avg_int()

        %{
          query_normalized: query_normalized,
          filter_fingerprint: filter_fp,
          search_count: search_count,
          zero_hit_count: zero_hits,
          success_count: success,
          unique_actors: actors,
          avg_result_count: avg_results,
          avg_duration_ms: avg_ms,
          click_count: click_count,
          ctr: ctr
        }
      end)

    {rows, rejected_count}
  end

  defp upsert_crystals(surface, scope, period, period_start, {rows, rejected_count}, _events) do
    period_str = Atom.to_string(period)

    quality_row = %{
      query_normalized: "__quality__",
      filter_fingerprint: "",
      search_count: 0,
      zero_hit_count: 0,
      success_count: 0,
      unique_actors: 0,
      avg_result_count: 0.0,
      avg_duration_ms: 0.0,
      rejected_count: rejected_count,
      click_count: 0,
      ctr: 0.0
    }

    Enum.map([quality_row | rows], fn row ->
      attrs = Map.put(row, :rejected_count, Map.get(row, :rejected_count, 0))

      %Crystal{}
      |> Ecto.Changeset.change(
        Map.merge(attrs, %{
          surface: surface,
          scope: scope,
          period: period_str,
          period_start: period_start
        })
      )
      |> upsert_crystal()
    end)
    |> length()
  end

  defp upsert_crystal(changeset) do
    attrs = Ecto.Changeset.apply_changes(changeset)

    case Repo.get_by(Crystal,
           surface: attrs.surface,
           scope: attrs.scope,
           period: attrs.period,
           period_start: attrs.period_start,
           query_normalized: attrs.query_normalized,
           filter_fingerprint: attrs.filter_fingerprint
         ) do
      nil ->
        Repo.insert!(changeset)

      existing ->
        existing
        |> Ecto.Changeset.change(
          Map.take(attrs, [
            :search_count,
            :zero_hit_count,
            :success_count,
            :unique_actors,
            :avg_result_count,
            :avg_duration_ms,
            :rejected_count,
            :click_count,
            :ctr
          ])
        )
        |> Repo.update!()
    end
  end

  defp detect_merge_patterns(events) do
    accepted =
      events
      |> Enum.filter(fn e ->
        (e.quality == "accepted" or is_nil(e.quality)) and e.event_type == "search" and
          is_binary(e.actor_key) and e.actor_key != "" and analytics_eligible?(e)
      end)
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    events_by_id = Map.new(accepted, &{&1.id, &1})

    chains =
      accepted
      |> Enum.group_by(& &1.actor_key)
      |> Enum.flat_map(fn {_actor, actor_events} ->
        actor_events
        |> Enum.sort_by(& &1.inserted_at, DateTime)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [prev, next] -> linked_transition?(prev, next, events_by_id) end)
        |> Enum.map(fn [prev, next] -> {prev, next} end)
      end)

    chains
    |> Enum.map(fn {prev, next} ->
      from_state = event_state(prev)
      to_state = event_state(next)

      %{
        from_fingerprint: fingerprint(from_state.query_normalized, from_state.filters),
        to_fingerprint: fingerprint(to_state.query_normalized, to_state.filters),
        pattern_type: classify_transition(from_state, to_state),
        success: not next.zero_hits
      }
    end)
    |> Enum.group_by(&{&1.from_fingerprint, &1.to_fingerprint, &1.pattern_type})
    |> Enum.map(fn {{from_fp, to_fp, type}, transitions} ->
      success_count = Enum.count(transitions, & &1.success)

      %{
        from_fingerprint: from_fp,
        to_fingerprint: to_fp,
        pattern_type: type,
        transition_count: length(transitions),
        success_count: success_count
      }
    end)
  end

  defp linked_transition?(prev, next, events_by_id) do
    next.parent_event_id == prev.id or
      (is_nil(next.parent_event_id) and within_chain_gap?(prev, next)) or
      (next.parent_event_id && Map.get(events_by_id, next.parent_event_id) == prev)
  end

  defp within_chain_gap?(%Event{} = a, %Event{} = b) do
    DateTime.diff(b.inserted_at, a.inserted_at, :second) <= @chain_gap_minutes * 60
  end

  defp event_state(%Event{} = e) do
    q = e.query_normalized || Sanitizer.normalize(e.query || "")

    %{
      query_normalized: q,
      filters: e.filters || %{},
      zero_hits: e.zero_hits
    }
  end

  defp upsert_merge_patterns(surface, scope, period, period_start, rows) do
    period_str = Atom.to_string(period)

    Enum.map(rows, fn row ->
      %MergePattern{}
      |> Ecto.Changeset.change(
        Map.merge(row, %{
          surface: surface,
          scope: scope,
          period: period_str,
          period_start: period_start
        })
      )
      |> upsert_merge_pattern()
    end)
    |> length()
  end

  defp upsert_merge_pattern(changeset) do
    attrs = Ecto.Changeset.apply_changes(changeset)

    case Repo.get_by(MergePattern,
           surface: attrs.surface,
           scope: attrs.scope,
           period: attrs.period,
           period_start: attrs.period_start,
           from_fingerprint: attrs.from_fingerprint,
           to_fingerprint: attrs.to_fingerprint,
           pattern_type: attrs.pattern_type
         ) do
      nil ->
        Repo.insert!(changeset)

      existing ->
        existing
        |> Ecto.Changeset.change(%{
          transition_count: attrs.transition_count,
          success_count: attrs.success_count
        })
        |> Repo.update!()
    end
  end

  defp fingerprint_parts(query_normalized, filters) do
    q_part = if query_normalized != "", do: ["q:" <> query_normalized], else: []

    facet_parts =
      filters
      |> Map.get("facets", %{})
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> "facet." <> k <> ":" <> to_string(v) end)

    kind =
      case Map.get(filters, "kind") do
        k when is_binary(k) and k != "" -> ["kind:" <> k]
        _ -> []
      end

    collection =
      case Map.get(filters, "collection") do
        c when is_binary(c) and c != "" -> ["collection:" <> c]
        _ -> []
      end

    q_part ++ kind ++ collection ++ facet_parts
  end

  defp avg_int([]), do: 0.0

  defp avg_int(nums) do
    nums |> Enum.sum() |> Kernel./(length(nums)) |> Float.round(1)
  end

  defp analytics_eligible?(%Event{source: "test"}), do: false

  defp analytics_eligible?(%Event{tags: tags}) when is_list(tags) do
    not Enum.member?(tags, "test")
  end

  defp analytics_eligible?(_), do: true
end
