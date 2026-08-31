defmodule Barkpark.Search.Intelligence do
  @moduledoc """
  Barkpark core search intelligence — record, suggest, crystallize, improve.

  Any product surface (media DAM, document search, …) calls this module with a
  `surface` tag and a `scope` (e.g. `"media", "production"`). Surfaces translate
  their native params into a `%{}` context with `:query`, `:filters`, and `:offset`.

  See `docs/search/INTELLIGENCE.md` and `Barkpark.Search.MediaIntelligence`.
  """

  import Ecto.Query
  alias Barkpark.Content.Scope
  alias Barkpark.Search.{Crystal, Crystallizer, Event, MergePattern, Sanitizer, Synonyms}
  alias Barkpark.Repo

  @typedoc """
  Why an interaction was not recorded. `:recording_disabled` is a deliberate
  no-op; every other reason means a signal was lost, and callers are expected
  to render the two differently.
  """
  @type interaction_skip_reason ::
          :recording_disabled | :incomplete_reference | :unknown_query_event | :error

  @typedoc """
  Outcome of a correction signal. `:recorded` is the only value that means a
  `correction` event reached the table.
  """
  @type correction_status :: :recorded | :recording_disabled | :blank | :identical | :error

  @popular_window_days 30
  @retention_days 90
  @default_limit 8
  @min_search_count 3
  @default_source_cap 500

  # Generous per-source SQL LIMIT for the popular/nohits suggestion aggregates.
  # `query_normalized` is attacker-mintable on the anonymous suggestion/correction
  # routes, so every GROUP BY aggregate must carry an explicit SQL-side bound:
  # without it an attacker forces a full-table GROUP BY sorted in BEAM memory.
  # The cap (default #{@default_source_cap}/source) sits far above the caller's
  # output limit (<= #{@default_limit}), so normal-cardinality output is unchanged;
  # runtime-overridable via `config :barkpark, :search_suggestions_source_cap`.
  defp source_cap,
    do: Application.get_env(:barkpark, :search_suggestions_source_cap, @default_source_cap)

  @doc "Default retention for raw search events (days)."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @typedoc """
  Why a `record/6` call recorded nothing (pds-bl-w36-record6-conflation).
  These four-plus-one causes used to collapse to a bare `:skipped`, which
  destroyed the information a caller needs to tell "recording is off" from
  "we crashed" — the identical conflation `record_interaction/4` already had
  repaired. Same vocabulary, one module.

    * `:recording_disabled` — recording is off for this request. Deliberate.
    * `:record_false` — the caller opted this one call out (`record: false`).
    * `:offset_page` — a paginated follow-up page; only page one is an event.
    * `:unqualified_query` — the query did not qualify for analytics
      (blank/unusable after normalization). Nothing to record, not a fault.
    * `:error` — an exception or exit was swallowed on the way to the insert.
      A real failure.
  """
  @type record_skip_reason ::
          :recording_disabled | :record_false | :offset_page | :unqualified_query | :error

  @doc """
  Record a search event. Returns `{:ok, event_id}`, `{:skipped, reason}`, or
  `{:rejected, reason}` — the skip reason names which of the causally distinct
  no-write outcomes happened (see `t:record_skip_reason/0`).
  Never raises — analytics must not break search.
  """
  @spec record(String.t(), String.t(), map(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, Ecto.UUID.t()} | {:skipped, record_skip_reason()} | {:rejected, atom()}
  def record(surface, scope, context, total, duration_ms, opts \\ [])
      when is_binary(surface) and is_binary(scope) and is_map(context) do
    offset = Map.get(context, :offset, 0)

    result =
      cond do
        Keyword.get(opts, :disabled, false) ->
          {:skipped, :recording_disabled}

        Keyword.get(opts, :record, true) == false ->
          {:skipped, :record_false}

        offset > 0 ->
          {:skipped, :offset_page}

        true ->
          safe_record(surface, scope, context, total, duration_ms, opts)
      end

    emit_record_telemetry(surface, scope, result)
    result
  rescue
    _ ->
      emit_record_telemetry(surface, scope, :error)
      {:skipped, :error}
  catch
    _, _ ->
      emit_record_telemetry(surface, scope, :error)
      {:skipped, :error}
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

  Returns `{:ok, event_id}` when a row was written, otherwise `{:skipped, reason}`.
  The reason is the whole point: a caller must be able to tell a recorder that was
  deliberately switched off from one that lost the write.

    * `:recording_disabled` — recording is off for this request. A deliberate
      no-op; nothing was lost.
    * `:incomplete_reference` — the request carried no usable `query_event_id`
      or `object_id`. A bad request, not a server fault.
    * `:unknown_query_event` — the referenced search event does not exist for
      this surface/scope, so the interaction has no parent to hang off.
    * `:error` — an exception or exit was swallowed on the way to the insert
      (a failed insert arrives here as a `MatchError`). A real failure.

  Never raises — analytics must not break search.
  """
  @spec record_interaction(String.t(), String.t(), map(), keyword()) ::
          {:ok, Ecto.UUID.t()} | {:skipped, interaction_skip_reason()}
  def record_interaction(surface, scope, attrs, opts \\ [])
      when is_binary(surface) and is_binary(scope) and is_map(attrs) do
    if Keyword.get(opts, :disabled, false) do
      {:skipped, :recording_disabled}
    else
      safe_record_interaction(surface, scope, attrs, opts)
    end
  rescue
    _ -> {:skipped, :error}
  catch
    _, _ -> {:skipped, :error}
  end

  @doc """
  Suggestions for autocomplete. Returns `%{recent: [], popular: [], nohits: []}`.
  """
  @spec suggestions(String.t(), String.t(), String.t(), String.t() | nil, keyword()) :: map()
  def suggestions(surface, scope, actor_key, prefix \\ nil, opts \\ [])
      when is_binary(surface) and is_binary(scope) do
    limit = Keyword.get(opts, :limit, @default_limit)
    min_count = Keyword.get(opts, :min_search_count, @min_search_count)
    workspace_id = Keyword.get(opts, :workspace_id)
    prefix = normalize_suggest_prefix(prefix)

    suggest_opts = [min_search_count: min_count]

    %{
      recent: recent_queries(surface, scope, actor_key, prefix, limit, workspace_id),
      popular: popular_queries(surface, scope, prefix, limit, suggest_opts, workspace_id),
      nohits: nohits_queries(surface, scope, prefix, min(limit, 5), workspace_id)
    }
  end

  @spec insights(String.t(), String.t(), keyword()) :: map()
  def insights(surface, scope, opts \\ [])
      when is_binary(surface) and is_binary(scope) do
    period = opts |> Keyword.get(:period, "week") |> normalize_period()
    workspace_id = Keyword.get(opts, :workspace_id)

    period_start =
      case Keyword.get(opts, :period_start) do
        %Date{} = date -> date
        _ -> default_period_start(period)
      end

    quality = quality_stats(surface, scope, period, period_start, workspace_id)

    prev_counts =
      previous_period_search_counts(surface, scope, period, period_start, workspace_id)

    rates = search_rates(surface, scope, period, period_start, workspace_id)

    top_queries =
      from(c in Crystal,
        where:
          c.surface == ^surface and c.scope == ^scope and c.period == ^period and
            c.period_start == ^period_start and c.query_normalized != "__quality__" and
            c.search_count > 0,
        order_by: [desc: c.search_count],
        limit: 20
      )
      |> scope_ws(workspace_id)
      |> Repo.all()
      |> Enum.map(&crystal_payload(&1, prev_counts))

    merge_patterns =
      from(m in MergePattern,
        where:
          m.surface == ^surface and m.scope == ^scope and m.period == ^period and
            m.period_start == ^period_start,
        order_by: [desc: m.transition_count],
        limit: 30
      )
      |> scope_ws(workspace_id)
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
      synonymCandidates:
        Synonyms.candidates(surface, scope,
          period: period,
          period_start: period_start,
          workspace_id: Keyword.get(opts, :workspace_id)
        ),
      zeroHitRate: rates.zero_hit_rate,
      recoveryRate: rates.recovery_rate,
      hints: improvement_hints(top_queries, merge_patterns, quality)
    }
  end

  defp search_rates(surface, scope, period, period_start, workspace_id) do
    rows =
      from(e in Event,
        where:
          e.surface == ^surface and e.scope == ^scope and e.event_type == "search" and
            (is_nil(e.quality) or e.quality == "accepted") and
            e.inserted_at >= ^period_start_dt(period, period_start) and
            e.inserted_at < ^period_end_dt(period, period_start),
        select: {e.zero_hits, e.metadata}
      )
      |> scope_ws(workspace_id)
      |> Repo.all()

    total = length(rows)

    zero_hits = Enum.count(rows, fn {zh, _} -> zh end)

    recoveries =
      Enum.count(rows, fn {_, meta} ->
        is_map(meta) and Map.get(meta, "recovery") not in [nil, ""]
      end)

    %{
      zero_hit_rate: if(total > 0, do: Float.round(zero_hits / total, 3), else: 0.0),
      recovery_rate: if(total > 0, do: Float.round(recoveries / total, 3), else: 0.0)
    }
  end

  defp period_start_dt("day", %Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp period_start_dt("week", %Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp period_start_dt("month", %Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp period_start_dt(_, %Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  # Upper bound of the rate window — MUST mirror the crystallizer's `period_bounds/2`
  # (half-open `[start, end)`) so `zeroHitRate`/`recoveryRate` cover exactly the same
  # span as the crystal-keyed `topQueries` in the same insights payload. Without this,
  # the rates ran period_start→now while topQueries were period-exact — mis-scoped.
  defp period_end_dt("day", %Date{} = date),
    do: DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

  defp period_end_dt("week", %Date{} = date),
    do: DateTime.new!(Date.add(date, 7), ~T[00:00:00], "Etc/UTC")

  defp period_end_dt("month", %Date{} = date),
    do: DateTime.new!(Date.add(Date.end_of_month(date), 1), ~T[00:00:00], "Etc/UTC")

  # Fallback mirrors the "week" window — `normalize_period/1` maps any unknown
  # period to "week", so its default_period_start is a Monday-keyed 7-day span.
  defp period_end_dt(_, %Date{} = date),
    do: DateTime.new!(Date.add(date, 7), ~T[00:00:00], "Etc/UTC")

  defp safe_record(surface, scope, context, total, duration_ms, opts) do
    do_record(surface, scope, context, total, duration_ms, opts)
  rescue
    _ -> {:skipped, :error}
  catch
    _, _ -> {:skipped, :error}
  end

  defp do_record(surface, scope, context, total, duration_ms, opts) do
    actor_key = Keyword.get(opts, :actor_key, "anon")
    parent_event_id = Keyword.get(opts, :parent_event_id)
    source = Keyword.get(opts, :source, "api")
    session_key = Keyword.get(opts, :session_key)
    tags = Keyword.get(opts, :tags, [])
    metadata = Keyword.get(opts, :metadata, %{})

    raw_query = Map.get(context, :query, "") || ""
    filters = Map.get(context, :filters, %{})

    base = %{
      surface: surface,
      scope: scope,
      # Tenant attribution stamped at INGEST — without it every event is
      # workspace_id=nil and the crystallizer folds two tenants sharing a scope
      # STRING into one summed roll-up. Threaded from the controller's resolved
      # `current_workspace`; nil on unscoped/legacy callers (behaviour-identical
      # to pre-tenancy).
      workspace_id: Keyword.get(opts, :workspace_id),
      result_count: total,
      zero_hits: total == 0,
      actor_key: actor_key,
      duration_ms: duration_ms,
      parent_event_id: parent_event_id,
      source: source,
      session_key: session_key,
      tags: tags,
      metadata: metadata
    }

    case qualify_query(raw_query, filters) do
      :skip ->
        {:skipped, :unqualified_query}

      {:reject, reason} ->
        submit_event(
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
        {:ok, id} =
          submit_event(
            Map.merge(base, %{
              query: query,
              query_normalized: query_normalized,
              filters: filters,
              quality: "accepted",
              reject_reason: nil
            })
          )

        {:ok, id}
    end
  end

  defp safe_record_interaction(surface, scope, attrs, opts) do
    do_record_interaction(surface, scope, attrs, opts)
  rescue
    _ -> {:skipped, :error}
  catch
    _, _ -> {:skipped, :error}
  end

  defp do_record_interaction(surface, scope, attrs, opts) do
    query_event_id = interaction_uuid(attrs, :query_event_id, "queryEventId")
    object_id = interaction_string(attrs, :object_id, "objectId")
    event_type = interaction_type(attrs)
    position = interaction_position(attrs)

    if is_nil(query_event_id) or object_id in [nil, ""] do
      {:skipped, :incomplete_reference}
    else
      case Repo.get(Event, query_event_id) do
        %Event{surface: ^surface, scope: ^scope, event_type: "search"} = search ->
          {:ok, event} =
            insert_event(%{
              surface: surface,
              scope: scope,
              # Inherit the parent search event's tenant so an interaction can
              # never re-attribute a click to nil/another workspace.
              workspace_id: Keyword.get(opts, :workspace_id) || search.workspace_id,
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
          {:skipped, :unknown_query_event}
      end
    end
  end

  @doc """
  Record a query correction (`from` → `to`) and auto-promote a synonym once at
  least two DISTINCT sessions have signalled the same correction.

  Behaviour:

    1. Normalize `from`/`to` via the `Sanitizer`.
    2. Insert a `correction` event (`object_id` = normalized `to`) so distinct
       sessions can be counted.
    3. Count DISTINCT `session_key` for the same `(surface, scope, from→to)`
       correction. A nil `session_key` is treated as its own single bucket so
       an anonymous client can never alone trip the gate.
    4. When the distinct-session count is `>= 2` and no enabled synonym already
       maps `from → to`, write an `alt_correction` synonym via
       `Synonyms.promote/4` (`source: "auto"`); a unique-constraint conflict is
       treated as "already exists".

  Returns `{:ok, %{status: status, promoted: boolean, distinct_sessions: non_neg_integer}}`.

  `promoted: false, distinct_sessions: 0` is returned by four causally different
  outcomes, so `status:` is what tells them apart:

    * `:recorded` — a `correction` event was written.
    * `:recording_disabled` — recording is off for this request (a no-op).
    * `:blank` — `from` or `to` normalized to an empty string.
    * `:identical` — `from` and `to` normalized to the same string.
    * `:error` — an exception or exit was swallowed. The signal was lost.

  Never raises — wraps insert + promote so a correction signal can't break the
  request.
  """
  @spec record_correction(String.t(), String.t(), map(), keyword()) ::
          {:ok,
           %{
             status: correction_status(),
             promoted: boolean(),
             distinct_sessions: non_neg_integer()
           }}
  def record_correction(surface, scope, attrs, opts \\ [])
      when is_binary(surface) and is_binary(scope) and is_map(attrs) do
    if Keyword.get(opts, :disabled, false) do
      {:ok, correction_result(:recording_disabled)}
    else
      safe_record_correction(surface, scope, attrs, opts)
    end
  rescue
    _ -> {:ok, correction_result(:error)}
  catch
    _, _ -> {:ok, correction_result(:error)}
  end

  defp safe_record_correction(surface, scope, attrs, opts) do
    do_record_correction(surface, scope, attrs, opts)
  rescue
    _ -> {:ok, correction_result(:error)}
  catch
    _, _ -> {:ok, correction_result(:error)}
  end

  # Every non-recorded correction outcome carries the same counters; only the
  # status separates a deliberate no-op from a lost signal.
  defp correction_result(status),
    do: %{status: status, promoted: false, distinct_sessions: 0}

  defp do_record_correction(surface, scope, attrs, opts) do
    from_raw = correction_string(attrs, :from, "from")
    to_raw = correction_string(attrs, :to, "to")
    from_norm = if from_raw, do: Sanitizer.normalize(from_raw), else: ""
    to_norm = if to_raw, do: Sanitizer.normalize(to_raw), else: ""
    session_key = Keyword.get(opts, :session_key)
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      from_norm == "" or to_norm == "" ->
        {:ok, correction_result(:blank)}

      from_norm == to_norm ->
        {:ok, correction_result(:identical)}

      true ->
        _ =
          insert_event(%{
            surface: surface,
            scope: scope,
            workspace_id: Keyword.get(opts, :workspace_id),
            event_type: "correction",
            query: from_raw,
            query_normalized: from_norm,
            object_id: to_norm,
            result_count: 0,
            zero_hits: false,
            actor_key: Keyword.get(opts, :actor_key, "anon"),
            source: Keyword.get(opts, :source, "api"),
            session_key: session_key,
            quality: "accepted",
            reject_reason: nil,
            duration_ms: nil
          })

        distinct = count_distinct_correction_sessions(surface, scope, from_norm, to_norm)

        promoted =
          distinct >= 2 and
            not synonym_exists?(surface, scope, from_norm, to_norm, workspace_id) and
            promote_correction(surface, scope, from_norm, to_norm, workspace_id)

        {:ok, %{status: :recorded, promoted: promoted, distinct_sessions: distinct}}
    end
  end

  defp count_distinct_correction_sessions(surface, scope, from_norm, to_norm) do
    # SQL COUNT(DISTINCT session_key) — never fetch every distinct session row into
    # Elixir just to take length/1 (these are anonymous, attacker-driven writes).
    from(e in Event,
      where:
        e.surface == ^surface and e.scope == ^scope and e.event_type == "correction" and
          e.query_normalized == ^from_norm and e.object_id == ^to_norm,
      select: count(e.session_key, :distinct)
    )
    |> Repo.one()
  end

  defp synonym_exists?(surface, scope, from_norm, to_norm, workspace_id) do
    surface
    |> Synonyms.list(scope, workspace_id)
    |> Enum.any?(fn s ->
      s.enabled and s.from == from_norm and s.to == to_norm
    end)
  end

  defp promote_correction(surface, scope, from_norm, to_norm, workspace_id) do
    case Synonyms.promote(
           surface,
           scope,
           %{
             "from" => from_norm,
             "to" => to_norm,
             "kind" => "alt_correction"
           },
           workspace_id
         ) do
      {:ok, _row} -> true
      # Unique-constraint conflict (a concurrent promote landed first): treat as
      # already-exists, not a failure.
      {:error, _reason} -> false
    end
  end

  defp correction_string(attrs, atom_key, string_key) do
    case Map.get(attrs, atom_key) || Map.get(attrs, string_key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: String.slice(trimmed, 0, 256)

      _ ->
        nil
    end
  end

  defp interaction_uuid(attrs, atom_key, string_key) do
    value = Map.get(attrs, atom_key) || Map.get(attrs, string_key)

    case value do
      id when is_binary(id) ->
        Repo.uuid_or_nil(String.trim(id))

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
      n when is_integer(n) and n >= 0 ->
        n

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

  # Submit a search event WITHOUT stalling the caller's response. The record
  # write sat synchronously inside every keystroke's request; normally ~free,
  # but any DB contention (crystallizer roll-up, Oban, a checkpoint) stalled
  # THE SEARCH RESPONSE by exactly that hiccup — the observed "sometimes 450ms"
  # spikes on an otherwise ~100ms path. The event id is PRE-GENERATED so the
  # response's `searchEventId` contract (click attribution) is unchanged; the
  # INSERT rides Barkpark.TaskSupervisor (Task.* propagates `$callers`, so the
  # test sandbox and its DataCase drain still own the connection). Config
  # `:search_intel_record_async` (default true; test.exs sets false so every
  # existing assertion stays deterministic). Failures degrade exactly like the
  # sync path: telemetry-only, never a caller error.
  defp submit_event(attrs) do
    id = Ecto.UUID.generate()
    attrs = Map.put(attrs, :id, id)

    if Application.get_env(:barkpark, :search_intel_record_async, true) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
          _ = insert_event(attrs)
        end)

      {:ok, id}
    else
      case insert_event(attrs) do
        {:ok, event} -> {:ok, event.id}
        error -> error
      end
    end
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

  # Tenant leaf for every crystal/event read. `nil` = the legacy/unscoped bucket
  # (`workspace_id IS NULL`), matching the pre-tenancy default so existing
  # callers stay behaviour-identical; a real workspace_id narrows to that tenant
  # so a scope STRING shared across workspaces no longer unions their roll-ups.
  # Binds on `workspace_id`, present on Crystal, MergePattern and Event alike.
  #
  # Mapped onto the centralized clause in `Content.Scope`, byte-for-byte: the
  # `:shared_only` sentinel IS `workspace_id IS NULL`, and the binary arm IS
  # `workspace_id == ^ws`. Deliberately the WORKSPACE-ONLY helper, NOT
  # `scope_to_workspace_including_global/3`: intel roll-ups have no shared
  # layer, so a tenant must never see NULL-workspace rows folded into its own
  # counts. `Search.Synonyms` takes the including-global helper for the opposite
  # reason (its NULL rows are a deliberately shared synonym layer) — the two
  # boundaries look alike and are not, so they stay separate helpers on purpose.
  defp scope_ws(queryable, workspace_id),
    do: Scope.scope_to_workspace(queryable, workspace_id || :shared_only)

  # Anonymous actors collapse to ONE globally-shared `actor_key == "anon"`, so an
  # anon recent-queries read would union every anonymous session/tenant. Fail
  # closed: anon actors get no recent history at all (popular/nohits still serve
  # them). Non-anon callers (client:<x>, token:<id>, reader) keep their recents.
  defp recent_queries(_surface, _scope, "anon", _prefix, _limit, _workspace_id), do: []

  defp recent_queries(surface, scope, actor_key, prefix, limit, workspace_id) do
    base =
      from(e in Event,
        where: e.surface == ^surface and e.scope == ^scope and e.actor_key == ^actor_key,
        order_by: [desc: e.inserted_at],
        limit: ^(limit * 4)
      )
      |> accepted_events()

    base
    |> scope_ws(workspace_id)
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
      query: (e.query != "" && e.query) || e.query_normalized,
      filters: e.filters || %{},
      resultCount: e.result_count,
      zeroHits: e.zero_hits,
      at: e.inserted_at
    }
  end

  defp popular_queries(surface, scope, prefix, limit, opts, workspace_id) do
    min_count = Keyword.get(opts, :min_search_count, @min_search_count)
    today = Date.utc_today()
    window_start = Date.add(today, -@popular_window_days)

    crystal_rows =
      popular_from_crystals(
        surface,
        scope,
        prefix,
        window_start,
        Date.add(today, -1),
        workspace_id
      )

    today_start = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    raw_rows = popular_from_events(surface, scope, prefix, today_start, workspace_id)

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

  defp popular_from_crystals(surface, scope, prefix, period_start, period_end, workspace_id) do
    cap = source_cap()

    base =
      from(c in Crystal,
        where:
          c.surface == ^surface and c.scope == ^scope and c.period == "day" and
            c.period_start >= ^period_start and c.period_start <= ^period_end and
            c.query_normalized != "" and c.query_normalized != "__quality__" and
            c.success_count > 0,
        group_by: c.query_normalized,
        order_by: [desc: sum(c.success_count)],
        limit: ^cap,
        select: %{
          query_normalized: c.query_normalized,
          count: sum(c.success_count),
          result_count: max(c.avg_result_count)
        }
      )

    base
    |> scope_ws(workspace_id)
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

  defp popular_from_events(surface, scope, prefix, since, workspace_id) do
    cap = source_cap()

    from(e in Event,
      where:
        e.surface == ^surface and e.scope == ^scope and e.inserted_at >= ^since and
          e.zero_hits == false and e.query_normalized != "",
      group_by: e.query_normalized,
      order_by: [desc: count(e.id)],
      limit: ^cap,
      select: %{
        query_normalized: e.query_normalized,
        display_query: max(e.query),
        count: count(e.id),
        result_count: max(e.result_count)
      }
    )
    |> accepted_events()
    |> scope_ws(workspace_id)
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

  defp nohits_queries(surface, scope, prefix, limit, workspace_id) do
    today = Date.utc_today()
    window_start = Date.add(today, -@popular_window_days)

    crystal_rows =
      nohits_from_crystals(
        surface,
        scope,
        prefix,
        window_start,
        Date.add(today, -1),
        workspace_id
      )

    today_start = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    raw_rows = nohits_from_events(surface, scope, prefix, today_start, workspace_id)

    crystal_rows
    |> merge_count_rows(raw_rows)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn row -> %{query: row.query, count: row.count} end)
  end

  defp nohits_from_crystals(surface, scope, prefix, period_start, period_end, workspace_id) do
    cap = source_cap()

    base =
      from(c in Crystal,
        where:
          c.surface == ^surface and c.scope == ^scope and c.period == "day" and
            c.period_start >= ^period_start and c.period_start <= ^period_end and
            c.query_normalized != "" and c.query_normalized != "__quality__" and
            c.zero_hit_count > 0,
        group_by: c.query_normalized,
        order_by: [desc: sum(c.zero_hit_count)],
        limit: ^cap,
        select: %{
          query_normalized: c.query_normalized,
          count: sum(c.zero_hit_count)
        }
      )

    base
    |> scope_ws(workspace_id)
    |> maybe_prefix_on_crystal(prefix)
    |> Repo.all()
    |> Enum.map(fn row -> %{query: row.query_normalized, count: row.count} end)
  end

  defp nohits_from_events(surface, scope, prefix, since, workspace_id) do
    cap = source_cap()

    from(e in Event,
      where:
        e.surface == ^surface and e.scope == ^scope and e.inserted_at >= ^since and
          e.zero_hits == true and e.query_normalized != "",
      group_by: e.query_normalized,
      order_by: [desc: count(e.id)],
      limit: ^cap,
      select: %{query: max(e.query), count: count(e.id)}
    )
    |> accepted_events()
    |> scope_ws(workspace_id)
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

  defp quality_stats(surface, scope, period, period_start, workspace_id) do
    # Query (not get_by): a `nil` workspace_id must match `IS NULL` via scope_ws,
    # and Ecto forbids `= nil` in a keyword get_by.
    row =
      from(c in Crystal,
        where:
          c.surface == ^surface and c.scope == ^scope and c.period == ^period and
            c.period_start == ^period_start and c.query_normalized == "__quality__" and
            c.filter_fingerprint == ""
      )
      |> scope_ws(workspace_id)
      |> Repo.one()

    case row do
      nil ->
        %{rejected: 0, accepted: 0}

      row ->
        %{rejected: row.rejected_count, accepted: row.search_count}
    end
  end

  defp previous_period_search_counts(surface, scope, period, period_start, workspace_id) do
    prev_start = previous_period_start(period, period_start)

    from(c in Crystal,
      where:
        c.surface == ^surface and c.scope == ^scope and c.period == ^period and
          c.period_start == ^prev_start and c.query_normalized != "__quality__",
      select: {c.query_normalized, c.search_count}
    )
    |> scope_ws(workspace_id)
    |> Repo.all()
    |> Map.new()
  end

  defp previous_period_start("week", start), do: Date.add(start, -7)
  defp previous_period_start("day", start), do: Date.add(start, -1)
  # Month crystals are keyed to first-of-month; `-30 days` rarely lands on a
  # month boundary, so step back one day into the prior month and snap to its
  # first — the true previous-month key.
  defp previous_period_start("month", start),
    do: start |> Date.add(-1) |> Date.beginning_of_month()

  defp previous_period_start(_, start), do: Date.add(start, -7)

  defp crystal_payload(%Crystal{} = c, prev_counts) do
    prev = Map.get(prev_counts, c.query_normalized, 0)

    %{
      query: c.query_normalized,
      filterFingerprint: c.filter_fingerprint,
      searchCount: c.search_count,
      searchCountDelta: c.search_count - prev,
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
                message:
                  "Query \"#{q.query}\" has high zero-hit rate — consider synonyms or tags.",
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

  # Defaults MUST land exactly on the key the crystallizer writes, else the
  # `period_start ==` filters in `insights` return empty — 200 with no rows, no
  # error anywhere. This used to be a hand-copy of that arithmetic; it now calls
  # the writer's own function, because the copy in `Search.Synonyms` drifted and
  # read zero rows six days in seven before anyone noticed.
  defp default_period_start(period), do: Crystallizer.period_start_for(period)

  # `?period[k]=v` / `?period[]=x` reach here as a map/list — `to_string/1` on
  # those raises (Protocol.UndefinedError → 500). Only a binary/atom is a valid
  # period key; anything else falls back to the default window, matching the
  # fail-open param idiom used elsewhere in the search stack.
  defp normalize_period(period) when is_binary(period), do: period
  defp normalize_period(period) when is_atom(period) and not is_nil(period), do: to_string(period)
  defp normalize_period(_), do: "week"

  @doc """
  Escape ILIKE metacharacters (`\\`, `%`, `_`) in a user-typed prefix so it is
  matched literally before the trailing `%` wildcard is appended. Backslash
  first — mirrors `Barkpark.Search.DocumentsRetriever.like_pattern/1`.
  """
  def escape_like_prefix(prefix) when is_binary(prefix) do
    prefix
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp maybe_prefix(queryable, nil), do: queryable

  defp maybe_prefix(queryable, prefix) do
    pattern = escape_like_prefix(prefix) <> "%"

    from(e in queryable,
      where: ilike(e.query, ^pattern) or ilike(e.query_normalized, ^pattern)
    )
  end

  defp maybe_prefix_on_normalized(queryable, nil), do: queryable

  defp maybe_prefix_on_normalized(queryable, prefix) do
    pattern = escape_like_prefix(prefix) <> "%"
    from(e in queryable, where: ilike(e.query_normalized, ^pattern))
  end

  defp maybe_prefix_on_crystal(queryable, nil), do: queryable

  defp maybe_prefix_on_crystal(queryable, prefix) do
    pattern = escape_like_prefix(prefix) <> "%"
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

  # Non-binary prefixes reach here when a client sends an array/map param
  # (e.g. ?q[]=x makes params["q"] a list) — treat as "no prefix" instead of crashing.
  defp normalize_suggest_prefix(_), do: nil

  @doc false
  def normalize_suggest_prefix_for_test(prefix), do: normalize_suggest_prefix(prefix)

  defp emit_record_telemetry(surface, scope, result) do
    {status, reason} =
      case result do
        {:ok, _} -> {:ok, nil}
        {:skipped, reason} -> {:skipped, reason}
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
