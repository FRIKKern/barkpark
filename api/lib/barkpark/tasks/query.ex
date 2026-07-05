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

  def maybe_filter_claim_worker(query, nil), do: query

  def maybe_filter_claim_worker(query, worker) when is_binary(worker),
    do: from(d in query, where: fragment("?->'claim'->>'worker'", d.content) == ^worker)

  def maybe_filter_claim_worker(query, _), do: query

  def apply_index_order(query, parent) when is_binary(parent),
    do: from(d in query, order_by: [asc: d.inserted_at])

  def apply_index_order(query, _), do: from(d in query, order_by: [desc: d.updated_at])

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
  def rows_for_query(query, scope \\ []) when is_map(query) do
    docs = docs_for_query(query, scope)
    counts = unmet_blocker_counts(docs)

    Enum.map(docs, fn doc ->
      doc
      |> to_render_map(Map.get(counts, doc.id, 0))
      |> TaskResolver.row_from_task()
    end)
  end

  @doc "The filtered, scoped, ordered task Documents for a block `query` map."
  def docs_for_query(query, scope) when is_map(query) do
    ws_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)
    limit = clamp_limit(Map.get(query, "limit"))
    parent = Map.get(query, "parent_id")

    from(d in Document, where: d.type == "task", limit: ^limit)
    |> Scope.scope_to_workspace(ws_id, project_id)
    |> maybe_filter_dataset(Map.get(query, "dataset"))
    |> maybe_filter_kind(Map.get(query, "kind"))
    |> maybe_filter_parent_id(parent)
    |> apply_labels(Map.get(query, "label") || Map.get(query, "labels"))
    |> apply_statuses(Map.get(query, "status"))
    |> apply_index_order(parent)
    |> Repo.all()
  end

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
  defp to_render_map(%Document{} = doc, unmet) do
    content = doc.content || %{}

    %{
      "title" => doc.title,
      "lifecycle_status" => Map.get(content, "lifecycle_status"),
      "priority" => Map.get(content, "priority"),
      "assignee" => Map.get(content, "assignee"),
      "claim" => Map.get(content, "claim"),
      "labels" => Map.get(content, "labels") || [],
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
