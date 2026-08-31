defmodule Barkpark.Search.Crystallizer do
  @moduledoc """
  Core crystallization — roll raw search events into day / week / month aggregates.

  Surface-agnostic: operates on `search_intel_*` tables keyed by `surface` + `scope`.
  """

  import Ecto.Query
  alias Barkpark.Content.Scope
  alias Barkpark.Search.{Crystal, Event, MergePattern, Sanitizer}
  alias Barkpark.Repo

  @chain_gap_minutes 30

  # Re-crystallize this many trailing days on every run (yesterday back N days)
  # so a missed cron run (downtime) or an exhausted-attempts Oban job self-heals
  # instead of leaving a permanent hole. `crystallize_period` upserts, so
  # re-processing an already-crystallized day is an idempotent overwrite — no
  # duplicate rows, bounded cost.
  @backfill_days 3

  @doc """
  The `period_start` key of the most recently COMPLETED period, given `today`.

  ONE derivation, shared by the WRITER below and by every reader that filters
  `period_start == ^…`. A reader that spells the key itself is a silent
  zero-row bug, not a crash: `Crystal` / `MergePattern` rows exist, the query
  simply matches none of them and the caller answers 200 with an empty result.

  That is not hypothetical. `Search.Synonyms` spelled the week key
  `Date.add(Date.utc_today(), -7)`, which coincides with the Monday-anchored key
  the crystallizer writes only ON MONDAYS — so `candidates/3` and its
  crystal-backed evidence read zero rows six days in seven. Call this instead of
  re-deriving; if you need a different window, pass it explicitly.

  * `:day` → yesterday (the first day the backfill window covers)
  * `:week` → the Monday of the previous week
  * `:month` → the first of the previous month
  * anything else → the `:week` key, matching the readers' default period
  """
  # @canonical capability:search-crystal-period-key aka:period_start,week key,crystal key,beginning_of_week,default_period_start
  @spec period_start_for(atom() | String.t(), Date.t()) :: Date.t()
  def period_start_for(period, today \\ Date.utc_today())

  def period_start_for(period, %Date{} = today) when is_atom(period) and not is_nil(period),
    do: period_start_for(Atom.to_string(period), today)

  def period_start_for("day", %Date{} = today), do: Date.add(today, -1)

  def period_start_for("week", %Date{} = today),
    do: today |> Date.beginning_of_week(:monday) |> Date.add(-7)

  def period_start_for("month", %Date{} = today),
    do: today |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()

  def period_start_for(_other, %Date{} = today), do: period_start_for("week", today)

  @doc "Crystallize all surface/scope/workspace tuples for a trailing day window plus week/month boundaries when due."
  @spec crystallize_due(Date.t()) :: map()
  def crystallize_due(%Date{} = today \\ Date.utc_today()) do
    day_targets = for n <- 1..@backfill_days, do: Date.add(today, -n)

    # Enumerate distinct (surface, scope, workspace_id) TRIPLES, not just
    # (surface, scope) pairs. Two workspaces that share a scope STRING (e.g. both
    # own the universally-seeded `"production"` slug) resolve to the SAME
    # `dataset_id`, so a scope-only enumeration folded their events into one
    # crystal (workspace_id=nil) and summed two tenants' analytics. The
    # workspace_id leaf keeps each tenant's roll-up on its own row.
    triples =
      from(e in Event, select: {e.surface, e.scope, e.workspace_id}, distinct: true)
      |> Repo.all()

    day_stats =
      Enum.flat_map(triples, fn {surface, scope, workspace_id} ->
        Enum.map(day_targets, fn day ->
          {{surface, scope, workspace_id, day},
           crystallize_period(surface, scope, :day, day, workspace_id)}
        end)
      end)

    # Weeks/months got only a single-shot trigger on their boundary day (Monday /
    # the 1st). A missed cron run on that exact day stranded the completed week's
    # or month's crystal permanently — the very hole @backfill_days closes for
    # days. Widen both to the same trailing catch-up window: crystallize_period
    # is an idempotent upsert and the target period_start is stable across the
    # window, so re-runs on the window days dedup rather than duplicate.
    week_stats =
      if Date.day_of_week(today) <= @backfill_days do
        # Start of the most recently completed week (its Monday) — identical on
        # every day of the window (Mon → today-7, Tue → today-8, Wed → today-9,
        # all the same Monday). period_start_for/2 is the ONE spelling; readers
        # call it too, which is the point.
        week_start = period_start_for(:week, today)

        Enum.map(triples, fn {surface, scope, workspace_id} ->
          {{surface, scope, workspace_id},
           crystallize_period(surface, scope, :week, week_start, workspace_id)}
        end)
      else
        []
      end

    month_stats =
      if today.day <= @backfill_days do
        # Previous month's start — stable for every day in the window, so the 1st,
        # 2nd and 3rd all target the same month and dedup via upsert.
        month_start = period_start_for(:month, today)

        Enum.map(triples, fn {surface, scope, workspace_id} ->
          {{surface, scope, workspace_id},
           crystallize_period(surface, scope, :month, month_start, workspace_id)}
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

  @doc """
  Crystallize one surface/scope/workspace/period bucket (idempotent upsert).

  `workspace_id` scopes both the events read AND the roll-up rows written, so a
  scope STRING shared across tenants no longer merges their analytics. `nil` is
  the legacy/unscoped bucket (events whose `workspace_id IS NULL`) — the default
  keeps the pre-tenancy `crystallize_period/4` call sites behaviour-identical.
  """
  @spec crystallize_period(
          String.t(),
          String.t(),
          :day | :week | :month,
          Date.t(),
          binary() | nil
        ) ::
          map()
  def crystallize_period(surface, scope, period, period_start, workspace_id \\ nil)
      when is_binary(surface) and is_binary(scope) and period in [:day, :week, :month] do
    {start_dt, end_dt} = period_bounds(period, period_start)

    events =
      from(e in Event,
        where:
          e.surface == ^surface and e.scope == ^scope and e.inserted_at >= ^start_dt and
            e.inserted_at < ^end_dt
      )
      |> scope_workspace(workspace_id)
      |> Repo.all()

    query_rows = aggregate_queries(events)
    merge_rows = detect_merge_patterns(events)

    crystal_count =
      upsert_crystals(surface, scope, period, period_start, query_rows, events, workspace_id)

    pattern_count =
      upsert_merge_patterns(surface, scope, period, period_start, merge_rows, workspace_id)

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

  # Tenant leaf for the events read + upsert get_by. A `nil` workspace_id means
  # the legacy/unscoped bucket, so match `IS NULL` (never `= NULL`, which is
  # never true) — Postgres treats NULL as distinct, so this keeps the null arm
  # from folding into a real tenant's roll-up.
  #
  # Mapped onto the centralized clause in `Content.Scope`, byte-for-byte: the
  # `:shared_only` sentinel IS `workspace_id IS NULL`, and the binary arm IS
  # `workspace_id == ^ws`. Deliberately the WORKSPACE-ONLY helper, NOT
  # `scope_to_workspace_including_global/3` — a tenant's roll-up must never
  # absorb the NULL-workspace legacy rows. (`Search.Synonyms` takes the
  # including-global helper because its NULL rows ARE a shared layer; same
  # shape, opposite contract.)
  defp scope_workspace(query, workspace_id),
    do: Scope.scope_to_workspace(query, workspace_id || :shared_only)

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

  defp upsert_crystals(
         surface,
         scope,
         period,
         period_start,
         {rows, rejected_count},
         _events,
         workspace_id
       ) do
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
          period_start: period_start,
          workspace_id: workspace_id
        })
        |> put_dataset_id(scope)
      )
      |> upsert_crystal()
    end)
    |> length()
  end

  defp upsert_crystal(changeset) do
    attrs = Ecto.Changeset.apply_changes(changeset)

    # Query (not get_by): a `nil` workspace_id must match `IS NULL`, and Ecto
    # forbids `= nil` in a keyword get_by. scope_workspace/2 picks the arm.
    existing =
      from(c in Crystal,
        where:
          c.surface == ^attrs.surface and c.scope == ^attrs.scope and
            c.period == ^attrs.period and c.period_start == ^attrs.period_start and
            c.query_normalized == ^attrs.query_normalized and
            c.filter_fingerprint == ^attrs.filter_fingerprint
      )
      |> scope_workspace(attrs.workspace_id)
      |> Repo.one()

    case existing do
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

  defp upsert_merge_patterns(surface, scope, period, period_start, rows, workspace_id) do
    period_str = Atom.to_string(period)

    Enum.map(rows, fn row ->
      %MergePattern{}
      |> Ecto.Changeset.change(
        Map.merge(row, %{
          surface: surface,
          scope: scope,
          period: period_str,
          period_start: period_start,
          workspace_id: workspace_id
        })
        |> put_dataset_id(scope)
      )
      |> upsert_merge_pattern()
    end)
    |> length()
  end

  defp upsert_merge_pattern(changeset) do
    attrs = Ecto.Changeset.apply_changes(changeset)

    existing =
      from(m in MergePattern,
        where:
          m.surface == ^attrs.surface and m.scope == ^attrs.scope and
            m.period == ^attrs.period and m.period_start == ^attrs.period_start and
            m.from_fingerprint == ^attrs.from_fingerprint and
            m.to_fingerprint == ^attrs.to_fingerprint and
            m.pattern_type == ^attrs.pattern_type
      )
      |> scope_workspace(attrs.workspace_id)
      |> Repo.one()

    case existing do
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

  # W2 dual-write: resolve the crystal/merge-pattern `scope` STRING → its
  # `dataset_id` (under the seeded Default project) and stamp it alongside
  # `scope` so the flipped `(surface, dataset_id, …)` uniques stay meaningful.
  # The `scope` string remains the mirror; no-ops when unresolvable.
  defp put_dataset_id(attrs, scope) when is_binary(scope) do
    case Barkpark.Tenancy.default_project_dataset_id(scope) do
      id when is_binary(id) -> Map.put(attrs, :dataset_id, id)
      _ -> attrs
    end
  end
end
