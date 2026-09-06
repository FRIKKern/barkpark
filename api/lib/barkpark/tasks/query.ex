defmodule Barkpark.Tasks.Query do
  @moduledoc """
  ONE owner for the task index/filter fragments — the composable
  `where`-clause helpers that narrow a `type:"task"` Document query by
  `kind` / `lifecycle_status` / `parent_id` / `label` / `dataset` / `claim`.

  Both callers share these so the filter semantics can't drift:

    * `BarkparkWeb.TasksController.Params` (the `GET /v1/tasks` index +
      prime/lookup) delegates its content-jsonb filters here.
    * `rows_for_query/2` — the LIVE-plan fetcher: a PortableDoc task block's
      `query` map → component snapshot rows (via
      `Barkpark.PortableDoc.TaskResolver.row_from_task/1`). This is what lets a
      paper embed a task view that reflects the real substrate.

  Tenancy stays fail-CLOSED (`Content.Scope.scope_to_workspace/3`); a nil
  workspace yields zero rows, never every tenant's.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Tasks.Edge
  alias Barkpark.PortableDoc.TaskResolver

  @rows_default_limit 500
  @rows_max_limit 1000

  # ── composable content-jsonb filters (the shared owner) ─────────────────────

  def maybe_filter_type(query, nil), do: query
  def maybe_filter_type(query, t) when is_binary(t), do: from(d in query, where: d.type == ^t)
  def maybe_filter_type(query, _), do: query

  def maybe_filter_kind(query, nil), do: query

  def maybe_filter_kind(query, k) when is_binary(k),
    do: from(d in query, where: fragment("?->>'kind'", d.content) == ^k)

  def maybe_filter_kind(query, _), do: query

  def maybe_filter_lifecycle(query, nil), do: query

  # Missing content.lifecycle_status defaults to "open" — matching the
  # `COALESCE(..., 'open')` used across the ready/index paths, so a task POSTed
  # without an explicit status is still visible to a `status=open` query.
  def maybe_filter_lifecycle(query, "open") do
    from(d in query,
      where: fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content) == "open"
    )
  end

  def maybe_filter_lifecycle(query, s) when is_binary(s),
    do: from(d in query, where: fragment("?->>'lifecycle_status'", d.content) == ^s)

  def maybe_filter_lifecycle(query, _), do: query

  # Prefix-agnostic parent↔doc_id match (strip a leading `drafts.` from BOTH
  # sides) — the child tasks of a phase/epic regardless of which side carries
  # the draft prefix.
  def maybe_filter_parent(query, nil), do: query

  def maybe_filter_parent(query, p) when is_binary(p) do
    from(d in query,
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^p)
    )
  end

  def maybe_filter_parent(query, _), do: query

  # Same edge as `maybe_filter_parent/2`, under the generic `parent` param name.
  def maybe_filter_parent_id(query, nil), do: query

  def maybe_filter_parent_id(query, p) when is_binary(p) do
    from(d in query,
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^p)
    )
  end

  def maybe_filter_parent_id(query, _), do: query

  # `content.labels` (jsonb array) CONTAINS the exact label — scalar-membership
  # (`labels @> to_jsonb(<text>)`), the form that matches the W7-mirror arrays.
  def maybe_filter_label(query, nil), do: query
  def maybe_filter_label(query, ""), do: query

  def maybe_filter_label(query, label) when is_binary(label),
    do: from(d in query, where: fragment("?->'labels' @> to_jsonb(?::text)", d.content, ^label))

  def maybe_filter_label(query, _), do: query

  def maybe_filter_dataset(query, nil), do: query
  def maybe_filter_dataset(query, ""), do: query
  def maybe_filter_dataset(query, dataset), do: from(d in query, where: d.dataset == ^dataset)

  @doc """
  Twin collapse (published-wins) — the ONE owner of the "count a twinned task
  once" law for every task READ path.

  A task can exist twice: `t1` (the canonical/published row) and `drafts.t1`
  (its shadow — every `/v1/data/mutate` write lands there). `maybe_filter_parent_id/2`
  strips a leading `drafts.` from BOTH sides, so a shadow whose `parent_id` is
  `drafts.<epic>` is GUARANTEED to match the published epic: without this
  predicate a twinned child contributes TWO rows and `+2` to `child_count`.

  The suppressed row is the one whose `drafts.`-stripped doc_id names a
  DISTINCT same-scope task. Only a `drafts.<id>` shadow can match: a
  non-prefixed row's stripped id equals its own doc_id, and the `<>` guard
  excludes itself, so a published row never suppresses itself. Mirrors
  `Barkpark.Tasks.Queue`'s ready-queue predicate (queue.ex ~146-173) and
  `Barkpark.Tasks.Board.load_task_docs`'s `hd(twins)` default.

  NOT a blanket `not like(doc_id, "drafts.%")` (the form `StudioChat` uses,
  correctly, for CLAIM lookups — the claim lives on the published row). A
  blanket exclusion would delete the whole population of mutate-created tasks
  that legitimately live at `drafts.<id>` with NO published twin — the very
  rows `Barkpark.Tasks.Claim` resolves by `drafts.`-fallback. Under twin
  collapse an UNPAIRED shadow has no distinct twin, so the `NOT EXISTS` is
  vacuously true and the row SURVIVES: an over-count is fixed without trading
  it for an under-count.

  Written as a raw correlated subquery rather than lifting queue.ex's
  `parent_as(:doc)` form verbatim — the bases here do not bind `as: :doc`, and
  a named-binding reference would not compile.
  """
  def collapse_twins(query) do
    from(d in query,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM documents AS twin
            WHERE twin.type = 'task'
              AND twin.doc_id = regexp_replace(?, '^drafts\\.', '')
              AND twin.doc_id <> ?
              AND twin.dataset = ?
              AND twin.workspace_id IS NOT DISTINCT FROM ?
              AND twin.project_id IS NOT DISTINCT FROM ?
          )
          """,
          d.doc_id,
          d.doc_id,
          d.dataset,
          d.workspace_id,
          d.project_id
        )
    )
  end

  # ── the id-prefix lookup (cchi-bl-task-get-needs-a-server-side-prefix-lookup) ──

  @id_prefix_limit 25

  @doc "How many id-prefix matches `id_prefix_lookup/2` will return before truncating."
  def id_prefix_limit, do: @id_prefix_limit

  @doc """
  The doc_id + title of the tasks whose id starts with `prefix` — ONE indexed
  query, in place of the CLI's nine-page client-side scan.

  ## Why this exists

  `bp task get <truncated-id>` answers not_found and wants to say "did you mean
  `<id>`?". Before this, the only way to ask was to WALK `GET /v1/tasks`: on the
  live ledger that is nine pages at the route's 1000-row clamp, ~3-4s with four
  requests in flight, and it is a scan whose cost grows with the ledger. The
  route could not be asked the question directly — its filter whitelist held
  `kind|label|lifecycle_status|parent|parent_id|phase_id|type` and nothing that
  reaches `doc_id`.

  ## The shape, and why each part

    * The predicate is `regexp_replace(doc_id, '^drafts\\.', '') LIKE prefix || '%'`
      — the SAME drafts-stripped expression `maybe_filter_parent_id/2`,
      `collapse_twins/1` and `documents_task_ready_dep_idx` already use, so a
      caller who typed the published id also finds an unpaired `drafts.` shadow
      of it. That is the id they would have to claim, so hiding it would be a
      lie of omission.
    * It is served by `documents_task_doc_id_prefix_idx`, a partial btree on
      that expression with `text_pattern_ops` (migration 20260906120000).
      `text_pattern_ops` is load-bearing: a DEFAULT-collation btree cannot serve
      `LIKE 'x%'` at all outside the C locale, so without the opclass this is a
      seq scan over every task row and the whole point is lost.
    * `prefix` is LIKE-escaped before it is interpolated, so a `%` or `_` a
      caller typed is a literal character and not a wildcard that would widen
      the match to rows the id cannot name.
    * The projection is `doc_id` + `title` ONLY. The caller renders one line per
      hit; selecting `content` would detoast the ~10 KB task jsonb per row for
      nothing (a full-view page of this route measures 10.2 MB against ~340 KB
      for the brief view).
    * Twins collapse exactly as they do on the index, so a twinned task is ONE
      hit here and "exactly one match" means what the caller thinks it means.

  Tenancy is fail-CLOSED via `Scope.scope_to_workspace/3` — a nil workspace
  yields zero rows.

  Options: `:workspace_id`, `:project_id`, `:dataset`, `:limit`.
  """
  def id_prefix_lookup(prefix, opts \\ [])

  def id_prefix_lookup(prefix, opts) when is_binary(prefix) and prefix != "" do
    limit = opts |> Keyword.get(:limit, @id_prefix_limit) |> clamp_prefix_limit()
    pattern = escape_like(prefix) <> "%"

    from(d in Document,
      where: d.type == "task",
      where:
        fragment(
          "regexp_replace(?, '^drafts\\.', '') LIKE ? ESCAPE '\\'",
          d.doc_id,
          ^pattern
        ),
      order_by: [asc: d.doc_id],
      limit: ^limit,
      select: %{doc_id: d.doc_id, title: d.title}
    )
    |> collapse_twins()
    |> Scope.scope_to_workspace(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    |> maybe_filter_dataset(Keyword.get(opts, :dataset))
    |> Repo.all()
  end

  def id_prefix_lookup(_prefix, _opts), do: []

  defp clamp_prefix_limit(n) when is_integer(n) and n > 0, do: min(n, @id_prefix_limit)
  defp clamp_prefix_limit(_), do: @id_prefix_limit

  # `\\`, `%` and `_` are the three characters LIKE reads as syntax. Escaping
  # them (with `ESCAPE '\\'` on the fragment) keeps "prefix" meaning prefix: an
  # unescaped `%` in a typed id would match rows the caller never named, and the
  # CLI's "exactly one match" claim would be made over the wrong set.
  defp escape_like(s), do: String.replace(s, ["\\", "%", "_"], fn c -> "\\" <> c end)

  def maybe_filter_claim_worker(query, nil), do: query

  def maybe_filter_claim_worker(query, worker) when is_binary(worker),
    do: from(d in query, where: fragment("?->'claim'->>'worker'", d.content) == ^worker)

  def maybe_filter_claim_worker(query, _), do: query

  # `id` tiebreaks make the order TOTAL (queue.ex tiebreak precedent): without
  # them, rows sharing a timestamp may swap across pages, so offset pagination
  # could repeat/skip rows. Only true timestamp ties reorder — non-paging
  # consumers see the same sequence as before.
  def apply_index_order(query, parent) when is_binary(parent),
    do: from(d in query, order_by: [asc: d.inserted_at, asc: d.id])

  def apply_index_order(query, _),
    do: from(d in query, order_by: [desc: d.updated_at, desc: d.id])

  # ── the live-plan fetcher ───────────────────────────────────────────────────

  @doc """
  Resolve a PortableDoc task block's `query` map into component snapshot rows.

  `query` keys (all optional): `parent_id` (child tasks of an epic/phase),
  `label` or `labels` (a list → task must carry ALL), `status` (string or list
  → `lifecycle_status` IN), `kind`, `dataset`, `limit`. `scope` is
  `[workspace_id:, project_id:]` (fail-closed).

  Each doc becomes a `render_doc`-shaped map (with an accurate
  `dependency_count` = its count of UNMET `blocks` blockers — the same
  not-`done` test `Queue.ready_query` uses) → `TaskResolver.row_from_task/1`,
  so `open` with an unmet blocker reads as backlog and `open` with none reads
  as ready — the white-ladder distinction, straight from the substrate.
  """
  def rows_for_query(query, scope \\ [], opts \\ []) when is_map(query) do
    docs = docs_for_query(query, scope)
    counts = unmet_blocker_counts(docs)

    # Field-visibility seal (charter W-one decision 10) — resolve the `task`
    # schema ONCE per call and gate the private-capable content fields, so a
    # schema-declared private/owner_only/readable_by field never leaks through a
    # paper task-embed row or a Studio preview row. The dataset cascade is
    # EXPLICIT: an `opts[:dataset]` threaded by the caller wins (the Studio
    # preview path NEVER stamps `dataset` into the block query, so deriving it
    # from the query map alone would seal against the WRONG schema there), then
    # the query-map `dataset`, then "production" — the same cascade
    # `load_task_schema/3` and the agg path use.
    dataset = Keyword.get(opts, :dataset) || Map.get(query, "dataset") || "production"
    readable? = row_field_visibility_gate(dataset)

    Enum.map(docs, fn doc ->
      doc
      |> to_render_map(Map.get(counts, doc.id, 0), readable?)
      |> TaskResolver.row_from_task()
    end)
  end

  # Inline fail-closed field-visibility twin of `Board.field_visibility_gate/1`
  # (board.ex:190-202). Resolve the `task` schema ONCE per `rows_for_query` call
  # (never per doc — no N+1) and return an ANONYMOUS-caller readability predicate
  # `(field :: String.t()) -> boolean()`. A schema miss degrades to allow-all (a
  # nil schema leaves every field undeclared ⇒ `field_readable?` true ⇒ public,
  # legacy parity), never raises: `CallerContext.anonymous/0` is a non-admin
  # struct that hits the checking clause and `raw_fields(nil) -> []`. Mirrors the
  # measure-visibility cross-check (`measure_field_readable?/2`) — one indexed
  # `Content.get_schema/3` bounds the cost.
  defp row_field_visibility_gate(dataset) do
    schema =
      case Barkpark.Content.get_schema("task", dataset, []) do
        {:ok, schema} -> schema
        _ -> nil
      end

    fn field ->
      Barkpark.Content.Envelope.field_readable?(
        schema,
        field,
        Barkpark.Content.CallerContext.anonymous()
      )
    end
  end

  @doc "The filtered, scoped, ordered task Documents for a block `query` map."
  def docs_for_query(query, scope) when is_map(query) do
    ws_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)
    limit = clamp_limit(Map.get(query, "limit"))
    parent = Map.get(query, "parent_id")

    from(d in Document, where: d.type == "task", limit: ^limit)
    |> collapse_twins()
    |> Scope.scope_to_workspace(ws_id, project_id)
    |> maybe_filter_dataset(Map.get(query, "dataset"))
    |> maybe_filter_kind(Map.get(query, "kind"))
    |> maybe_filter_parent_id(parent)
    |> apply_labels(Map.get(query, "label") || Map.get(query, "labels"))
    |> apply_statuses(Map.get(query, "status"))
    |> apply_index_order(parent)
    |> Repo.all()
  end

  # ── the aggregate/rollup fetcher (v1 = COUNT-ONLY) ──────────────────────────

  # Closed vocabularies. A groupBy dim / `over` bucket / timestamp field MUST be
  # one of these — anything else is rejected up front, so a `query` can never
  # reach a raw column or a jsonb path it names itself. Each categorical dim maps
  # to a pure extractor closure (`cat_keys/2`), never a caller-supplied path.
  @agg_group_dims ~w(status label parent assignee priority phase)
  @agg_time_buckets ~w(day week month)
  @agg_time_fields ~w(inserted_at updated_at closed_at)
  @agg_scan_cap 5000

  # ── v2 measure vocabulary (closed whitelist) ────────────────────────────────
  #
  # A v2 aggregate can COUNT (v1, default) or reduce a whitelisted MEASURE with
  # sum/avg/min/max. The measure vocabulary is closed EXACTLY like the groupBy
  # dims: a token maps to a PURE extractor closure (mirroring `cat_keys/2`),
  # NEVER a caller-supplied jsonb path — so a `query` can never point the reducer
  # at an arbitrary field. Each entry is `{extractor, extremum_safe?}`; a measure
  # is min/max-able ONLY when flagged `extremum_safe?` (min/max returns a real
  # row's value even for a large bucket, so it stays opt-in per measure).
  @agg_ops ~w(count sum avg min max)
  @agg_measures %{"priority" => {&__MODULE__.measure_priority/1, true}}

  # k-anonymity floor: a sum/avg/min/max cell (or total) folded over FEWER than
  # this many rows is SUPPRESSED (emits nil, never 0 — a 0 would itself leak),
  # because a tiny bucket's aggregate approximates the individual field values
  # that row-level field-visibility would redact. `count` is EXEMPT (it reveals
  # cardinality only, the v1 boundary).
  @k_anon 5

  @doc """
  Resolve a data-viz block's aggregate `query` into a neutral count tally the
  PortableDoc data-viz shapers (`TaskResolver.shape/2`) turn into the ratified
  chart / heatmap / stat Attrs.

  **v2 = count + sum/avg/min/max over a CLOSED measure whitelist.** Absent an
  `agg` key (or `op:"count"`) every cell / point / value is a COUNT of matching
  task documents — BYTE-IDENTICAL to v1. `count` reveals cardinality only, so it
  stays inside the workspace boundary that field-visibility redaction enforces at
  the ROW level. A measure op (`sum|avg|min|max`) reduces a whitelisted field's
  values, but a measure over a tiny bucket approximates the individual values
  redaction would hide — so measure cells (and the `total`) are k-anon
  SUPPRESSED (`nil`, never 0) below `@k_anon` rows, the measure field must be
  whitelisted (token→closure, never a caller path) AND readable to an anonymous
  caller, and min/max is gated to `extremum_safe?` measures.

  `query` shape (mirrors the ratified contract):

      %{
        "source"  => "tasks",                       # v2: tasks only
        "filter"  => %{parent_id, labels, status, kind, dataset},  # reuses the
                                                    #   shared `maybe_filter_*`
        "groupBy" => dim | [rowDim, colDim],        # closed whitelist
        "over"    => %{"bucket" => day|week|month,
                       "on" => inserted_at|updated_at|closed_at,
                       "last" => n},                 # optional time axis
        "agg"     => %{"op" => count|sum|avg|min|max,
                       "field" => <@agg_measures token>}  # absent ⇒ count (v1)
      }

  A groupBy element is either a categorical dim (`@agg_group_dims`) or a time
  bucket — a `day|week|month` string (on `inserted_at`) or `%{"bucket","on"}`.

  Returns `{:ok, tally}` where `tally` is
  `%{labels1:, labels2:, buckets:, total:, tally:}` (see `tally_docs/3`), or
  `{:error, reason}` for an out-of-whitelist dim / bucket / field or a non-task
  source. Tenancy stays fail-CLOSED via the SAME `Scope.scope_to_workspace/3`
  the row fetcher uses — a nil/foreign workspace yields an empty tally.
  """
  def agg_for_query(query, scope \\ [], opts \\ [])

  def agg_for_query(query, scope, opts) when is_map(query) do
    with "tasks" <- Map.get(query, "source", "tasks"),
         {:ok, dims} <- normalize_group_by(Map.get(query, "groupBy")),
         {:ok, over} <- normalize_over(Map.get(query, "over")),
         {:ok, agg} <-
           normalize_agg(Map.get(query, "agg"), fn -> resolve_schema(query, scope, opts) end) do
      docs = agg_docs(filter_of(query), scope)
      {:ok, tally_docs(docs, dims, over, agg)}
    else
      {:error, _} = err -> err
      other -> {:error, {:bad_source, other}}
    end
  end

  def agg_for_query(_query, _scope, _opts), do: {:error, :bad_query}

  # ── v2 agg normalisation (op + measure whitelist + visibility cross-check) ───

  # The `agg` spec is `%{"op" => count|sum|avg|min|max, "field" => <measure>}`.
  # ABSENT (or op=count) ⇒ `{"count", nil}` ⇒ v1 count path, byte-identical.
  # A non-count op must name a whitelisted measure; min/max additionally require
  # the measure to be `extremum_safe?`; and — belt+suspenders — the measure's
  # field must be READABLE to the resolving (anonymous, fail-closed) caller under
  # the task schema, so a field the schema marks private/owner_only/readable_by
  # is rejected even if it were added to `@agg_measures`. `schema_fn` is a thunk
  # so the schema is loaded ONLY for a non-count op (count stays query-free).
  defp normalize_agg(nil, _schema_fn), do: {:ok, {"count", nil}}

  defp normalize_agg(%{} = agg, schema_fn) do
    op = Map.get(agg, "op", "count")
    field = Map.get(agg, "field")

    case validate_measure(op, field) do
      # count: no field, no schema load, no visibility check (v1 boundary).
      {:ok, nil} ->
        {:ok, {"count", nil}}

      # a whitelisted, extremum-safe (if min/max) measure — now the belt+
      # suspenders field-visibility cross-check against the resolving caller.
      {:ok, extractor} ->
        if measure_field_readable?(schema_fn.(), field) do
          {:ok, {op, extractor}}
        else
          {:error, {:bad_measure, {:not_readable, field}}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp normalize_agg(other, _schema_fn), do: {:error, {:bad_measure, other}}

  @doc false
  # PURE op + measure whitelist gate (no schema, no DB — unit-testable with a
  # custom `measures` map). `count` needs no field. A measure op must name a
  # whitelisted field; `min`/`max` additionally require the measure to be flagged
  # `extremum_safe?` (min/max returns a real row's value even for a k-large
  # bucket, so it's opt-in per measure — a future sensitive measure defaults to
  # sum/avg-only). Returns `{:ok, extractor | nil}` or `{:error, {:bad_measure,
  # reason}}`.
  def validate_measure(op, field, measures \\ @agg_measures)

  def validate_measure("count", _field, _measures), do: {:ok, nil}

  def validate_measure(op, _field, _measures) when op not in @agg_ops,
    do: {:error, {:bad_measure, {:op, op}}}

  def validate_measure(op, field, measures) do
    case Map.get(measures, field) do
      {extractor, extremum_safe?} ->
        if op in ~w(min max) and not extremum_safe? do
          {:error, {:bad_measure, {:not_extremum_safe, field}}}
        else
          {:ok, extractor}
        end

      _ ->
        {:error, {:bad_measure, {:field, field}}}
    end
  end

  # Field-visibility cross-check against the resolving caller: ANONYMOUS +
  # fail-closed. A declared private / owner_only / readable_by field is denied.
  defp measure_field_readable?(schema, field) do
    Barkpark.Content.Envelope.field_readable?(
      schema,
      field,
      Barkpark.Content.CallerContext.anonymous()
    )
  end

  # Resolve the task schema for the visibility cross-check. A pre-loaded
  # `:schema` (threaded from the paper render path, loaded ONCE) wins; otherwise
  # a single indexed `Content.get_schema/3` (NOT cached — one Repo.one per
  # non-count agg block) under the resolving dataset + tenancy scope.
  defp resolve_schema(query, scope, opts) do
    Keyword.get(opts, :schema) || load_task_schema(query, scope, opts)
  end

  defp load_task_schema(query, scope, opts) do
    dataset = Keyword.get(opts, :dataset) || Map.get(filter_of(query), "dataset") || "production"

    case Barkpark.Content.Schema.get_schema_for_redaction("task", dataset, scope) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  @doc false
  # Pure measure extractor for `priority` — token→closure, mirroring `cat_keys/2`
  # (never a caller-supplied path). Returns the numeric priority (0=highest..4)
  # or nil when absent/non-numeric (a doc with no value simply doesn't
  # contribute to the measure or its k-anon count). Public only so the closure
  # capture in `@agg_measures` is unambiguous.
  def measure_priority(doc) do
    case content_get(doc, "priority") do
      n when is_integer(n) ->
        n

      n when is_float(n) ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp filter_of(query) do
    case Map.get(query, "filter") do
      %{} = f -> f
      _ -> %{}
    end
  end

  # Scoped, filtered task Documents for an aggregate — reuses the EXACT same
  # `Scope.scope_to_workspace/3` + `maybe_filter_*` composables as
  # `docs_for_query/2` so the tenancy boundary and filter semantics can't drift.
  defp agg_docs(filter, scope) do
    ws_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    from(d in Document, where: d.type == "task", limit: @agg_scan_cap)
    |> collapse_twins()
    |> Scope.scope_to_workspace(ws_id, project_id)
    |> maybe_filter_dataset(Map.get(filter, "dataset"))
    |> maybe_filter_kind(Map.get(filter, "kind"))
    |> maybe_filter_parent_id(Map.get(filter, "parent_id"))
    |> apply_labels(Map.get(filter, "label") || Map.get(filter, "labels"))
    |> apply_statuses(Map.get(filter, "status"))
    |> Repo.all()
  end

  # ── groupBy / over normalisation (closed-whitelist gate) ────────────────────

  defp normalize_group_by(nil), do: {:ok, []}
  defp normalize_group_by(dim) when is_binary(dim) or is_map(dim), do: wrap_dim(norm_dim(dim))

  defp normalize_group_by(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn d, {:ok, acc} ->
      case norm_dim(d) do
        {:ok, spec} -> {:cont, {:ok, acc ++ [spec]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_group_by(other), do: {:error, {:bad_dim, other}}

  defp wrap_dim({:ok, spec}), do: {:ok, [spec]}
  defp wrap_dim({:error, _} = err), do: err

  defp norm_dim(dim) when is_binary(dim) do
    cond do
      dim in @agg_group_dims -> {:ok, {:cat, dim}}
      dim in @agg_time_buckets -> {:ok, {:time, dim, "inserted_at"}}
      true -> {:error, {:bad_dim, dim}}
    end
  end

  defp norm_dim(%{} = m) do
    bucket = Map.get(m, "bucket")
    on = Map.get(m, "on", "inserted_at")

    if bucket in @agg_time_buckets and on in @agg_time_fields,
      do: {:ok, {:time, bucket, on}},
      else: {:error, {:bad_dim, m}}
  end

  defp norm_dim(other), do: {:error, {:bad_dim, other}}

  defp normalize_over(nil), do: {:ok, nil}

  defp normalize_over(%{} = over) do
    bucket = Map.get(over, "bucket")
    on = Map.get(over, "on", "inserted_at")
    last = Map.get(over, "last")

    cond do
      bucket not in @agg_time_buckets -> {:error, {:bad_over, bucket}}
      on not in @agg_time_fields -> {:error, {:bad_over_field, on}}
      not valid_last?(last) -> {:error, {:bad_over_last, last}}
      true -> {:ok, {:time, bucket, on, normalize_last(last)}}
    end
  end

  defp normalize_over(other), do: {:error, {:bad_over, other}}

  defp valid_last?(nil), do: true
  defp valid_last?(n) when is_integer(n) and n > 0, do: true
  defp valid_last?(_), do: false

  defp normalize_last(n) when is_integer(n) and n > 0, do: n
  defp normalize_last(_), do: nil

  # ── the pure count roll-up ──────────────────────────────────────────────────

  @doc false
  # Fold `docs` into a neutral 2-axis count tally. `dims` is 0/1/2 normalised
  # group specs; `over` is a normalised time axis (or nil). Returns
  # `%{labels1, labels2, buckets, total, tally}` where `tally` is keyed
  # `{primary_key, secondary_key}` (`:__all__` when an axis is absent). The
  # secondary axis is dim2 (heatmap cols → `labels2`) OR the `over` buckets
  # (chart points / stat spark → `buckets`), never both.
  def tally_docs(docs, dims, over, agg \\ {"count", nil}) do
    {op, extractor} = agg
    primary = Enum.at(dims, 0)

    secondary =
      case Enum.at(dims, 1) do
        nil -> if over, do: {:over, over}, else: nil
        d2 -> d2
      end

    # Per-cell accumulator is `{count, sum, min, max}` (see `bump/3`). `count` is
    # the number of CONTRIBUTING rows — every doc for `count`, only docs with a
    # non-nil measure for sum/avg/min/max — and gates k-anon suppression. A
    # doc's measure is read ONCE (`doc_measure/3`); a `:skip` (nil measure) drops
    # it from every axis, so it never inflates a bucket count it can't measure.
    {tally, p_labels, s_labels} =
      Enum.reduce(docs, {%{}, %{}, %{}}, fn doc, acc ->
        case doc_measure(op, extractor, doc) do
          :skip ->
            acc

          {:ok, val} ->
            pks = axis_keys(primary, doc)
            sks = axis_keys(secondary, doc)

            Enum.reduce(pks, acc, fn {pk, ps}, acc1 ->
              Enum.reduce(sks, acc1, fn {sk, ss}, {t, pl, sl} ->
                {
                  Map.update(t, {pk, sk}, bump(nil, op, val), &bump(&1, op, val)),
                  Map.put_new(pl, pk, ps),
                  Map.put_new(sl, sk, ss)
                }
              end)
            end)
        end
      end)

    {labels2, buckets} =
      case secondary do
        {:over, {:time, _b, _o, last}} -> {[], apply_last(ordered_labels(s_labels), last)}
        nil -> {[], nil}
        _ -> {ordered_labels(s_labels), nil}
      end

    %{
      op: op,
      labels1: ordered_labels(p_labels),
      labels2: labels2,
      buckets: buckets,
      total: total_value(op, extractor, docs),
      tally: finalize_tally(op, tally)
    }
  end

  # One doc's contribution to a measure. `count` always contributes (value is
  # unused — the count IS the value). A measure op contributes only its numeric
  # extractor value; a nil/non-numeric measure `:skip`s the doc entirely.
  defp doc_measure("count", _extractor, _doc), do: {:ok, nil}

  defp doc_measure(_op, extractor, doc) do
    case extractor.(doc) do
      n when is_number(n) -> {:ok, n}
      _ -> :skip
    end
  end

  # Accumulate one contribution into a cell's `{count, sum, min, max}`.
  defp bump(nil, "count", _val), do: {1, 0, nil, nil}
  defp bump({c, s, mn, mx}, "count", _val), do: {c + 1, s, mn, mx}
  defp bump(nil, _op, val), do: {1, val, val, val}
  defp bump({c, s, mn, mx}, _op, val), do: {c + 1, s + val, min(mn, val), max(mx, val)}

  # Finalise every cell to the scalar the shapers read. `count` cells stay
  # integers (never suppressed). A sum/avg/min/max cell folded over < @k_anon
  # rows is DROPPED (suppressed) — an absent cell reads as nil (never 0) for a
  # measure op, so a suppressed cell emits no number.
  defp finalize_tally(op, tally) do
    Enum.reduce(tally, %{}, fn {key, acc}, out ->
      case finalize_cell(op, acc) do
        nil -> out
        v -> Map.put(out, key, v)
      end
    end)
  end

  defp finalize_cell("count", {c, _s, _mn, _mx}), do: c
  defp finalize_cell(_op, {c, _s, _mn, _mx}) when c < @k_anon, do: nil
  defp finalize_cell("sum", {_c, s, _mn, _mx}), do: s
  defp finalize_cell("avg", {c, s, _mn, _mx}), do: s / c
  defp finalize_cell("min", {_c, _s, mn, _mx}), do: mn
  defp finalize_cell("max", {_c, _s, _mn, mx}), do: mx

  # The grand `total`: for `count` it stays `length(docs)` (v1 byte-identical);
  # for a measure it folds ALL contributing docs ONCE (never per-cell, so a
  # multi-label doc is counted once) and is k-anon suppressed (nil) below the
  # floor or when no doc carries the measure.
  defp total_value("count", _extractor, docs), do: length(docs)

  defp total_value(op, extractor, docs) do
    acc =
      Enum.reduce(docs, nil, fn doc, tacc ->
        case doc_measure(op, extractor, doc) do
          :skip -> tacc
          {:ok, val} -> bump(tacc, op, val)
        end
      end)

    if acc, do: finalize_cell(op, acc), else: nil
  end

  # Distinct axis keys for one doc, each `{key_string, sort_term}`. `:__all__`
  # (absent axis) collapses everything into one bucket; a missing categorical
  # value or timestamp yields `[]` so the doc simply doesn't count on that axis.
  defp axis_keys(nil, _doc), do: [{:__all__, nil}]
  defp axis_keys({:cat, dim}, doc), do: cat_keys(dim, doc)
  defp axis_keys({:time, bucket, on}, doc), do: time_keys(bucket, on, doc)
  defp axis_keys({:over, {:time, bucket, on, _last}}, doc), do: time_keys(bucket, on, doc)

  defp cat_keys("status", doc), do: one(content_get(doc, "lifecycle_status") || "open")
  defp cat_keys("parent", doc), do: one(strip_drafts(content_get(doc, "parent_id")))
  defp cat_keys("priority", doc), do: one(stringify(content_get(doc, "priority")))

  defp cat_keys("assignee", doc) do
    worker =
      case content_get(doc, "claim") do
        %{} = c -> Map.get(c, "worker")
        _ -> nil
      end

    one(worker || content_get(doc, "assignee"))
  end

  defp cat_keys("label", doc) do
    doc
    |> content_get("labels")
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&{&1, &1})
  end

  defp cat_keys("phase", doc) do
    doc
    |> content_get("labels")
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.find_value([], fn l ->
      case String.split(l, ":", parts: 2) do
        [p, rest] when p in ~w(phase wave) and rest != "" -> [{rest, rest}]
        _ -> nil
      end
    end)
  end

  defp cat_keys(_dim, _doc), do: []

  defp one(nil), do: []
  defp one(""), do: []
  defp one(v) when is_binary(v), do: [{v, v}]
  defp one(v), do: [{to_string(v), to_string(v)}]

  defp time_keys(bucket, on, doc) do
    case timestamp_for(doc, on) do
      %DateTime{} = dt -> [bucket_key(dt, bucket)]
      _ -> []
    end
  end

  defp timestamp_for(doc, "inserted_at"), do: doc.inserted_at
  defp timestamp_for(doc, "updated_at"), do: doc.updated_at

  defp timestamp_for(doc, "closed_at") do
    with %{} = claim <- content_get(doc, "claim"),
         ts when is_binary(ts) <- Map.get(claim, "closed_at"),
         {:ok, dt, _} <- DateTime.from_iso8601(ts) do
      dt
    else
      _ -> nil
    end
  end

  defp timestamp_for(_doc, _on), do: nil

  defp bucket_key(%DateTime{} = dt, "day") do
    d = DateTime.to_date(dt)
    {Date.to_iso8601(d), Date.to_erl(d)}
  end

  defp bucket_key(%DateTime{} = dt, "month") do
    d = DateTime.to_date(dt)
    {pad4(d.year) <> "-" <> pad2(d.month), {d.year, d.month, 0}}
  end

  defp bucket_key(%DateTime{} = dt, "week") do
    d = DateTime.to_date(dt)
    {y, w} = :calendar.iso_week_number(Date.to_erl(d))
    {pad4(y) <> "-W" <> pad2(w), {y, w}}
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
  defp pad4(n), do: String.pad_leading(Integer.to_string(n), 4, "0")

  defp ordered_labels(map) do
    map
    |> Map.delete(:__all__)
    |> Enum.sort_by(fn {_k, s} -> s end)
    |> Enum.map(fn {k, _s} -> k end)
  end

  defp apply_last(list, nil), do: list
  defp apply_last(list, n) when is_integer(n) and n > 0, do: Enum.take(list, -n)
  defp apply_last(list, _), do: list

  defp content_get(%Document{content: content}, key) when is_map(content),
    do: Map.get(content, key)

  defp content_get(_doc, _key), do: nil

  defp strip_drafts(nil), do: nil
  defp strip_drafts(s) when is_binary(s), do: Regex.replace(~r/^drafts\./, s, "")
  defp strip_drafts(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(s) when is_binary(s), do: s
  defp stringify(n), do: to_string(n)

  # A list of labels ANDs (task must carry all); a single string uses the
  # shared membership filter.
  defp apply_labels(query, nil), do: query
  defp apply_labels(query, label) when is_binary(label), do: maybe_filter_label(query, label)

  defp apply_labels(query, labels) when is_list(labels),
    do: Enum.reduce(labels, query, fn l, q -> maybe_filter_label(q, l) end)

  defp apply_labels(query, _), do: query

  # A list of statuses → `lifecycle_status` IN (…); a single string reuses the
  # shared filter (with its open-default COALESCE).
  defp apply_statuses(query, nil), do: query
  defp apply_statuses(query, s) when is_binary(s), do: maybe_filter_lifecycle(query, s)

  defp apply_statuses(query, list) when is_list(list) do
    strings = Enum.filter(list, &is_binary/1)

    case strings do
      [] ->
        query

      _ ->
        from(d in query,
          where: fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content) in ^strings
        )
    end
  end

  defp apply_statuses(query, _), do: query

  # Count of a task's UNMET `blocks` blockers — mirrors `Queue.ready_query`'s
  # not-exists subquery, but grouped so one query covers the whole page.
  defp unmet_blocker_counts([]), do: %{}

  defp unmet_blocker_counts(docs) do
    ids = Enum.map(docs, & &1.id)

    from(e in Edge,
      join: b in Document,
      on: b.id == e.to_id,
      where:
        e.from_id in ^ids and e.kind == "blocks" and
          fragment("COALESCE(?->>'lifecycle_status', '')", b.content) != "done",
      group_by: e.from_id,
      select: {e.from_id, count(e.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Build the `render_doc`-shaped map `TaskResolver.row_from_task/1` reads.
  #
  # `readable?` is the snapshot-wide fail-closed field-visibility predicate
  # (`row_field_visibility_gate/1`) — the single seal point for the projected
  # rows. The private-capable fields are gated PER-FIELD INDEPENDENTLY (each key
  # maps 1:1 to its schema field, a conscious charter choice over board.ex's
  # assignee+claim worker-union): a redacted field drops to nil (`row_from_task`
  # prunes nils, so the row simply omits it) — `labels` keeps its `else: []`
  # empty-list shape. LEFT UNGATED (board.ex count-vs-text law): `title`
  # (promoted, `@system_filterable`), `lifecycle_status` (system-filterable),
  # and the two derived COUNTS — `dependency_count` and `criteria_progress` —
  # which carry no field text, only cardinality.
  defp to_render_map(%Document{} = doc, unmet, readable?) do
    content = doc.content || %{}

    %{
      "title" => doc.title,
      "lifecycle_status" => Map.get(content, "lifecycle_status"),
      "priority" => if(readable?.("priority"), do: Map.get(content, "priority")),
      "assignee" => if(readable?.("assignee"), do: Map.get(content, "assignee")),
      "claim" => if(readable?.("claim"), do: Map.get(content, "claim")),
      "labels" => if(readable?.("labels"), do: Map.get(content, "labels") || [], else: []),
      "dependency_count" => unmet,
      "criteria_progress" => Barkpark.Tasks.Criteria.progress(content)
    }
  end

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @rows_max_limit)

  defp clamp_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> min(n, @rows_max_limit)
      _ -> @rows_default_limit
    end
  end

  defp clamp_limit(_), do: @rows_default_limit
end
