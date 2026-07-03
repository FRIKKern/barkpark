defmodule BarkparkWeb.TasksController.Params do
  @moduledoc false
  # Param parsing, coercion, validation, query-filter, and render-shape helpers
  # extracted from `BarkparkWeb.TasksController` to keep the controller focused
  # on action control-flow. Every function here is pure-ish: it either parses a
  # raw param into a typed value, coerces a body field, applies a tenancy /
  # filter clause to an Ecto query, or renders a Document into the bd-compatible
  # shape the shim consumes. No `conn`, no action routing — the controller calls
  # these as `Params.<name>(...)`.

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Tasks.Criteria
  alias Barkpark.Tasks.Edge

  # ─── Query filters (index / prime / lookup) ─────────────────────────────

  def maybe_filter_claim_worker(query, nil), do: query

  def maybe_filter_claim_worker(query, worker) when is_binary(worker),
    do: from(d in query, where: fragment("?->'claim'->>'worker'", d.content) == ^worker)

  # Tenancy: route through the ONE shared, fail-CLOSED helper (a nil
  # workspace_id yields zero rows, never every tenant's events) — the same
  # `Scope.scope_to_workspace/3` the ready-queue and claim paths use. HTTP
  # callers always carry a real workspace (Default scope via AssignDefaultScope),
  # so scoped requests are unchanged; only an internal nil-scoped caller flips
  # from all-tenant (fail-OPEN) to zero rows (fail-CLOSED, the safe default).
  def maybe_filter_event_workspace(query, ws_id),
    do: Scope.scope_to_workspace(query, ws_id, nil)

  def maybe_filter_type(query, nil), do: query

  def maybe_filter_type(query, t) when is_binary(t),
    do: from(d in query, where: d.type == ^t)

  # Fail-soft: an array-style param (?type[]=task) or any non-binary value is
  # not a filterable scalar — apply no filter rather than 500 with a
  # FunctionClauseError on the CLI's primary endpoint.
  def maybe_filter_type(query, _), do: query

  def maybe_filter_kind(query, nil), do: query

  def maybe_filter_kind(query, k) when is_binary(k),
    do: from(d in query, where: fragment("?->>'kind'", d.content) == ^k)

  def maybe_filter_kind(query, _), do: query

  def maybe_filter_lifecycle(query, nil), do: query

  # Missing content.lifecycle_status defaults to "open" — matches the shim's
  # render fallback. Otherwise a goal POSTed without an explicit
  # `lifecycle_status` (the common case) would be invisible to
  # `bd list --status open`.
  def maybe_filter_lifecycle(query, "open") do
    from(d in query,
      where: fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content) == "open"
    )
  end

  def maybe_filter_lifecycle(query, s) when is_binary(s),
    do: from(d in query, where: fragment("?->>'lifecycle_status'", d.content) == ^s)

  def maybe_filter_lifecycle(query, _), do: query

  def maybe_filter_parent(query, nil), do: query

  # phase_id matches `content.parent_id` — the ONE parent pointer (the
  # legacy `content.parent` arm from the retired goal/phase model matched
  # a key nothing writes for `type:task` rows; killed with the parent vs
  # parent_id split — parent_id is a schema `reference` to another task).
  #
  # Prefix-agnostic parent↔doc_id matching (#7): the stored parent may be bare
  # (`phase-448247`) while the caller passes the draft id (`drafts.phase-448247`)
  # — or vice-versa. Strip a leading `drafts.` from BOTH the stored value and
  # the param before comparing, so `bd ready --label phase-<n>` finds its
  # children regardless of which side carries the prefix.
  def maybe_filter_parent(query, p) when is_binary(p) do
    from(d in query,
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^p)
    )
  end

  def maybe_filter_parent(query, _), do: query

  # C1 (task as universal node): `parent=<doc_id>` — keep only docs whose
  # `content.parent_id` (OR `content.parent`) points at the given doc_id. This
  # is the same edge the `phase_id` filter walks, but exposed under the generic
  # `parent` param so it reads as "the child tasks of ANY task" — realizing
  # "a goal is just a root task" and "a rail is the chronological child tasks of
  # a task". Mirrors `maybe_filter_parent/2` EXACTLY (prefix-agnostic match on
  # `parent_id` — the one parent pointer); the index applies chronological
  # ordering (inserted_at ASC) when this filter is active so the result reads
  # as that task's timeline/rail.
  def maybe_filter_parent_id(query, nil), do: query

  def maybe_filter_parent_id(query, p) when is_binary(p) do
    from(d in query,
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^p)
    )
  end

  def maybe_filter_parent_id(query, _), do: query

  # When `parent` is given, order chronologically (oldest first) so the slice
  # reads as the parent task's rail/timeline. Otherwise keep the default
  # "most recently touched first" ordering.
  def apply_index_order(query, parent) when is_binary(parent),
    do: from(d in query, order_by: [asc: d.inserted_at])

  def apply_index_order(query, _),
    do: from(d in query, order_by: [desc: d.updated_at])

  # tt5: `label=<exact>` — keep only docs whose `content.labels` JSON array
  # CONTAINS the exact label string. Backs the bd-shim's `bd list --label
  # file-claim:<path>` (and any arbitrary label) → find every task holding a
  # given claim. Tenancy-scoped via the same workspace/project filters as the
  # rest of the pipeline.
  #
  # Containment uses the scalar-membership form `labels @> to_jsonb(<text>)`,
  # NOT array-vs-array `labels @> '["x"]'::jsonb`. The stored jsonb arrays
  # (written by the W7 mirror) don't match a freshly-parsed array literal under
  # `@>` array containment, but scalar membership — the canonical "is this
  # element in the array" test — matches reliably (verified against the live
  # store). `to_jsonb(text)` builds the scalar jsonb operand inside Postgres,
  # so no client-side JSON encoding of the needle is needed.
  def maybe_filter_label(query, nil), do: query
  def maybe_filter_label(query, ""), do: query

  def maybe_filter_label(query, label) when is_binary(label) do
    from(d in query,
      where: fragment("?->'labels' @> to_jsonb(?::text)", d.content, ^label)
    )
  end

  def maybe_filter_label(query, _), do: query

  # Dataset discriminator (gap #4 fix). Without it a doc_id that collides across
  # DATASETS in one workspace/project resolves by drafts-CASE ordering alone —
  # effectively arbitrary across datasets, rooting the graph on the wrong doc and
  # silently dictating the traversal dataset via root.dataset. Mirrors add_edge's
  # resolve_doc_pk dataset branch and Graph.resolve_pk. v1 graph roots are
  # dataset-scoped to the optional `dataset` param (default: all datasets in
  # scope, published-preferred first row).
  def maybe_filter_dataset(query, nil), do: query
  def maybe_filter_dataset(query, ""), do: query
  def maybe_filter_dataset(query, dataset), do: from(d in query, where: d.dataset == ^dataset)

  # Tenancy boundary: route the workspace clause through the ONE shared,
  # fail-CLOSED helper (`Scope.scope_to_workspace/3`) — the SAME semantic the
  # ready-queue (Queue.ready_query) and claim (Tasks.Claim) paths now use, so
  # the tasks resource has a single nil-scope rule instead of three divergent
  # ones. A nil workspace_id yields zero rows (fail-CLOSED), never every
  # tenant's rows (the old fail-OPEN accident). HTTP callers always carry a real
  # workspace (Default scope via AssignDefaultScope), so scoped requests are
  # byte-identical; project narrowing rides the sibling helper below (applied
  # after this one, so the pair == scope_to_workspace(q, ws, project)).
  def maybe_filter_workspace(query, ws_id),
    do: Scope.scope_to_workspace(query, ws_id, nil)

  # Project is a leaf narrowing applied AFTER the workspace clause above; a nil
  # project means "do not narrow by project" (workspace-only scope), NOT "all
  # tenants" — the tenant boundary is already enforced by the workspace clause.
  def maybe_filter_project(query, nil), do: query

  def maybe_filter_project(query, p_id),
    do: from(d in query, where: d.project_id == ^p_id)

  # ─── Graph param parsing ────────────────────────────────────────────────

  def parse_direction("out"), do: :out
  def parse_direction("in"), do: :in
  def parse_direction(_), do: :both

  # perspective=drafts OR ?drafts=true → :drafts (token-gated, live extract).
  # Anything else → :published (the materialised default).
  def parse_perspective(%{"perspective" => "drafts"}), do: :drafts
  def parse_perspective(%{"drafts" => v}) when v in ["true", "1", true], do: :drafts
  def parse_perspective(_), do: :published

  # Comma-separated query value → list of non-empty strings, or nil when absent.
  def csv_list(nil), do: nil

  def csv_list(v) when is_binary(v) do
    case v
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> list
    end
  end

  def csv_list(_), do: nil

  # ─── Body coercion ──────────────────────────────────────────────────────

  # Coerce a body field into a list of strings. Accepts a list (filtering
  # non-strings), a bare string (wrapped), or nil/anything-else (→ []).
  def string_list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  def string_list(v) when is_binary(v), do: [v]
  def string_list(_), do: []

  # content.labels is a free-form JSON array; coerce missing / non-list to [].
  def labels_of(%{"labels" => labels}) when is_list(labels), do: labels
  def labels_of(_), do: []

  # content.papers is a JSON array of paper slugs; coerce missing / non-list to [].
  def papers_of(%{"papers" => papers}) when is_list(papers), do: papers
  def papers_of(_), do: []

  # ─── Render / shape ─────────────────────────────────────────────────────

  # Render a Document into the bd-compatible shape the shim consumes.
  # Keep the field set tight enough to translate cleanly into `bd show`
  # JSON, broad enough that callers like `bd list --json` don't lose
  # information (priority, assignee, content.kind for filtering).
  def render_doc(%Document{} = doc) do
    content = doc.content || %{}

    %{
      id: doc.id,
      doc_id: doc.doc_id,
      title: doc.title,
      status: doc.status,
      type: doc.type,
      dataset: doc.dataset,
      rev: doc.rev,
      kind: Map.get(content, "kind"),
      lifecycle_status: Map.get(content, "lifecycle_status"),
      priority: Map.get(content, "priority"),
      assignee: Map.get(content, "assignee"),
      parent_id: Map.get(content, "parent_id"),
      claim: Map.get(content, "claim"),
      # tt5: surface content.labels at the top level so the bd-shim's
      # `.labels[]` (used by `bd show .labels[]` + `bd list --label`) works
      # end-to-end. The shim reads `doc.labels`; without this it always saw [].
      labels: labels_of(content),
      # Phase A: surface content.papers at the top level the same way labels
      # are, so callers can read `doc.papers[]` without digging into content.
      papers: papers_of(content),
      content: content,
      inserted_at: doc.inserted_at,
      updated_at: doc.updated_at
    }
    # lvw-t6: {met,total} over content.acceptance_criteria — computed by the
    # single canonical owner (Barkpark.Tasks.Criteria). Key OMITTED when
    # criteria are absent/empty (wire §4: omit the segment, never "0/0").
    |> put_criteria_progress(content)
  end

  defp put_criteria_progress(map, content) do
    case Criteria.progress(content) do
      nil -> map
      progress -> Map.put(map, :criteria_progress, progress)
    end
  end

  # w7-08c (paper-y1c): batch edge-count maps so a list response
  # (ready/index) doesn't N+1 the task_edges table.
  #
  # Returns %{doc_id => {dependency_count, dependent_count}}. Single query
  # per side (outbound / inbound) joined on the candidate ids — preserves
  # the controller's tenancy contract by deriving ids from the already-
  # tenancy-scoped `docs` list.
  def batch_edge_counts([]), do: %{}

  def batch_edge_counts(docs) do
    ids = Enum.map(docs, & &1.id)

    # Outbound edges: from_id ∈ ids → this row depends on N blockers
    # (its dependency_count). Use a single grouped query.
    out_counts =
      from(e in Edge,
        where: e.from_id in ^ids,
        group_by: e.from_id,
        select: {e.from_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Inbound edges: to_id ∈ ids → N rows depend on this one
    # (its dependent_count).
    in_counts =
      from(e in Edge,
        where: e.to_id in ^ids,
        group_by: e.to_id,
        select: {e.to_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(docs, fn d ->
      {d.id, {Map.get(out_counts, d.id, 0), Map.get(in_counts, d.id, 0)}}
    end)
  end

  # Augment the base render_doc map with the three count fields the
  # bd-shim's list/ready shapes carry (dependency_count + dependent_count
  # from batch_edge_counts; comment_count fixed at 0 until the comment
  # substrate ships — TODO: wire when comment substrate exists).
  def render_doc_with_counts(%Document{} = doc, counts) do
    {dep_count, dependent_count} = Map.get(counts, doc.id, {0, 0})

    doc
    |> render_doc()
    |> Map.put(:dependency_count, dep_count)
    |> Map.put(:dependent_count, dependent_count)
    |> Map.put(:comment_count, 0)
  end

  # C2: a lightweight child summary — just enough to render the rail without
  # the full render_doc payload or a recursive child fetch (one level only).
  def child_summary(%Document{} = doc) do
    content = doc.content || %{}

    %{
      doc_id: doc.doc_id,
      title: doc.title,
      lifecycle_status: Map.get(content, "lifecycle_status"),
      inserted_at: doc.inserted_at
    }
    # Same omit-when-absent contract as render_doc — a parent's rail shows
    # each child's criteria progress without a per-child fetch.
    |> put_criteria_progress(content)
  end

  # ─── Opt building / int parsing / validation ────────────────────────────

  def put_opt(opts, _key, nil), do: opts
  def put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  def fetch_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, :missing, key}
    end
  end

  def fetch_int(params, key) do
    case Map.get(params, key) do
      n when is_integer(n) -> {:ok, n}
      s when is_binary(s) -> parse_int_strict(s, key)
      _ -> {:error, :missing, key}
    end
  end

  def parse_int_strict(s, key) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :missing, key}
    end
  end

  def parse_int(nil, default), do: default

  def parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> default
    end
  end

  def parse_int(v, _default) when is_integer(v), do: v

  # Phoenix parses `?limit[]=5` into a list and `?limit[a]=b` into a map — fail
  # soft to the default instead of a FunctionClauseError 500 (same array-param
  # class as the filter catch-alls in this module).
  def parse_int(_, default), do: default

  # Clamp an int param into [1, max] — mirrors the federated-search bound_limit
  # precedent so `?limit=-1` (Postgres rejects a negative LIMIT → 500) and
  # `?limit=999999999` (unbounded scan) can't reach the query. A nil default
  # passes through unclamped so the caller can apply its own floor (ready lets
  # Queue's @ready_default_limit stand in when the param is absent).
  def parse_limit(raw, default, max) do
    case parse_int(raw, default) do
      nil -> nil
      n -> n |> min(max) |> max(1)
    end
  end

  def reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_to_string({:invalid_lifecycle, s}), do: "invalid_lifecycle:#{s}"
  def reason_to_string(other), do: inspect(other)

  # ─── Acceptance-criteria close-out (living-values §8/§9) ─────────────────

  # Parses the optional close-body `criteria` list: each update targets one
  # acceptance_criteria row by index and flips met/evidence — SHAPE-only
  # validation here (pure); state conflicts (index out of range, criterion
  # guard mismatch) are the close transaction's to detect under its lock.
  # Returns {:ok, updates} or {:error, :invalid_criteria, msg} (→ 400).
  def parse_criteria(nil), do: {:ok, []}

  def parse_criteria(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_criteria_entry(entry) do
        {:ok, update} -> {:cont, {:ok, [update | acc]}}
        {:error, msg} -> {:halt, {:error, :invalid_criteria, msg}}
      end
    end)
    |> case do
      {:ok, updates} -> {:ok, Enum.reverse(updates)}
      other -> other
    end
  end

  def parse_criteria(_other),
    do:
      {:error, :invalid_criteria,
       "criteria must be a list of {index, met, evidence, criterion} objects"}

  defp parse_criteria_entry(%{"index" => index} = entry) when is_integer(index) and index >= 0 do
    met = Map.get(entry, "met", true)
    evidence = Map.get(entry, "evidence")
    criterion = Map.get(entry, "criterion")

    cond do
      not is_boolean(met) ->
        {:error, "criteria[].met must be a boolean when set"}

      not (is_nil(evidence) or is_binary(evidence)) ->
        {:error, "criteria[].evidence must be a string when set"}

      not (is_nil(criterion) or is_binary(criterion)) ->
        {:error, "criteria[].criterion must be a string when set (stored-text guard)"}

      true ->
        update = %{"index" => index, "met" => met}
        update = if is_binary(evidence), do: Map.put(update, "evidence", evidence), else: update

        update =
          if is_binary(criterion), do: Map.put(update, "criterion", criterion), else: update

        {:ok, update}
    end
  end

  defp parse_criteria_entry(_other),
    do: {:error, "each criteria entry needs an integer index >= 0"}

  def changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
