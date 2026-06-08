defmodule BarkparkWeb.TasksController do
  @moduledoc """
  W7b step 1 (paperflow-rx0 / w7-07a) — HTTP surface for paperflow's
  bd-compatible shim (`bin/bd-shim`, paperflow side).

  Eight endpoints, all bearer-token gated via the existing `:api` +
  `:require_token` pipelines in `router.ex`:

    * `GET    /v1/tasks/ready`              — `Tasks.ready/1`
    * `GET    /v1/tasks/epic/close-eligible` — child-tree aggregator
    * `GET    /v1/tasks/:doc_id`            — single-task fetch (w7-08)
    * `POST   /v1/tasks/claim`              — `Tasks.claim/2` (queue-based)
    * `POST   /v1/tasks/:doc_id/claim`      — `Tasks.claim_by_id/3` (targeted, w7-08)
    * `POST   /v1/tasks/:doc_id/close`      — `Tasks.close/3`
    * `GET    /v1/tasks/:doc_id/edges`      — `Tasks.dependencies/2` + `dependents/2`
    * `POST   /v1/tasks/edges`              — `Tasks.add_dep/3`

  ## Shape contract

  All read responses carry a `doc` (or `docs`) map shaped to mirror what
  the real `bd show --json` emits closely enough that the shim can pass
  it through unchanged (`id`, `title`, `status`, `type`, `lifecycle_status`,
  `kind`, `content`, `priority`, `assignee`, `dependencies`, …). See
  `render_doc/1`. The shim translates label-flavoured bd args to query
  params upstream of this controller.

  ## Why the doc_id is a URL segment for close but a body field for claim

  Claim's contract is "pick the next ready row" — there is no specific row
  the caller is naming. Close's contract is "terminate THIS row I just held
  the claim on" — the caller names it. The route shapes mirror the verb.
  """

  use BarkparkWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Repo, Tasks}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Edge

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  # ─── GET /v1/tasks/ready ────────────────────────────────────────────────

  def ready(conn, params) do
    opts =
      []
      |> put_opt(:phase_id, params["phase_id"])
      |> put_opt(:limit, parse_int(params["limit"], nil))
      |> Keyword.merge(scope_opts(conn))

    docs = Tasks.ready(opts)
    counts = batch_edge_counts(docs)
    json(conn, %{ok: true, docs: Enum.map(docs, &render_doc_with_counts(&1, counts))})
  end

  # ─── GET /v1/tasks ──────────────────────────────────────────────────────
  # w7-08c (paperflow-y1c): list-all endpoint. Returns every task-substrate
  # doc (type ∈ goal/phase/task/event) in the caller's tenant, optionally
  # narrowed by `type`, `kind`, `lifecycle_status`, or `phase_id` (parent
  # match). Used by the bd-shim's `bd list --json` family — replaces the
  # previous "ready --limit 1000 then client-side filter" path (which lost
  # in-progress + closed rows and never surfaced phases/goals).
  #
  # Why server-side filtering: the shim used to fetch ready and filter
  # client-side, which (a) only saw the ready slice (no in_progress / done /
  # phases / goals) and (b) wasted bandwidth. Server-side filter is the
  # honest implementation and matches what real `bd list` queries against
  # the SQLite store.

  def index(conn, params) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)
    limit = parse_int(params["limit"], 1000)

    # C1 (task as universal node): when `parent` is given, the result reads as
    # that task's timeline/rail — its chronological child tasks (a "rail is the
    # chronological child tasks of a task"). Order by inserted_at ASC (oldest
    # first) for that view; keep the default desc:updated_at "most recently
    # touched first" ordering for the un-parent-filtered list.
    parent = params["parent"]

    base =
      from(d in Document,
        where: d.type in ["task", "goal", "phase", "event"],
        limit: ^limit
      )

    query =
      base
      |> maybe_filter_workspace(workspace_id)
      |> maybe_filter_project(project_id)
      |> maybe_filter_type(params["type"])
      |> maybe_filter_kind(params["kind"])
      |> maybe_filter_lifecycle(params["lifecycle_status"])
      |> maybe_filter_parent(params["phase_id"])
      |> maybe_filter_parent_id(parent)
      |> maybe_filter_label(params["label"])
      |> apply_index_order(parent)

    docs = Repo.all(query)
    counts = batch_edge_counts(docs)
    json(conn, %{ok: true, docs: Enum.map(docs, &render_doc_with_counts(&1, counts))})
  end

  defp maybe_filter_type(query, nil), do: query

  # bd-shape "epic" is our type "goal" — translate at the boundary so
  # `bd list --type epic` finds the goal rows.
  defp maybe_filter_type(query, "epic"),
    do: from(d in query, where: d.type == "goal")

  defp maybe_filter_type(query, t) when is_binary(t),
    do: from(d in query, where: d.type == ^t)

  defp maybe_filter_kind(query, nil), do: query

  defp maybe_filter_kind(query, k) when is_binary(k),
    do: from(d in query, where: fragment("?->>'kind'", d.content) == ^k)

  defp maybe_filter_lifecycle(query, nil), do: query

  # Missing content.lifecycle_status defaults to "open" — matches the shim's
  # render fallback. Otherwise a goal POSTed without an explicit
  # `lifecycle_status` (the common case) would be invisible to
  # `bd list --status open`.
  defp maybe_filter_lifecycle(query, "open") do
    from(d in query,
      where: fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content) == "open"
    )
  end

  defp maybe_filter_lifecycle(query, s) when is_binary(s),
    do: from(d in query, where: fragment("?->>'lifecycle_status'", d.content) == ^s)

  defp maybe_filter_parent(query, nil), do: query

  # phase_id matches `content.parent_id` (work-tasks → phase) OR
  # `content.parent` (phases → goal). Both schemas are in play.
  #
  # Prefix-agnostic parent↔doc_id matching (#7): the stored parent may be bare
  # (`phase-448247`) while the caller passes the draft id (`drafts.phase-448247`)
  # — or vice-versa. Strip a leading `drafts.` from BOTH the stored value and
  # the param before comparing, so `bd ready --label phase-<n>` finds its
  # children regardless of which side carries the prefix.
  defp maybe_filter_parent(query, p) when is_binary(p) do
    from(d in query,
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^p) or
          fragment("regexp_replace(?->>'parent', '^drafts\\.', '')", d.content) ==
            fragment("regexp_replace(?, '^drafts\\.', '')", ^p)
    )
  end

  # C1 (task as universal node): `parent=<doc_id>` — keep only docs whose
  # `content.parent_id` (OR `content.parent`) points at the given doc_id. This
  # is the same edge the `phase_id` filter walks, but exposed under the generic
  # `parent` param so it reads as "the child tasks of ANY task" — realizing
  # "a goal is just a root task" and "a rail is the chronological child tasks of
  # a task". Mirrors `maybe_filter_parent/2` EXACTLY (prefix-agnostic match on
  # both `parent_id` and `parent`); the index applies chronological ordering
  # (inserted_at ASC) when this filter is active so the result reads as that
  # task's timeline/rail.
  defp maybe_filter_parent_id(query, nil), do: query

  defp maybe_filter_parent_id(query, p) when is_binary(p) do
    from(d in query,
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^p) or
          fragment("regexp_replace(?->>'parent', '^drafts\\.', '')", d.content) ==
            fragment("regexp_replace(?, '^drafts\\.', '')", ^p)
    )
  end

  # When `parent` is given, order chronologically (oldest first) so the slice
  # reads as the parent task's rail/timeline. Otherwise keep the default
  # "most recently touched first" ordering.
  defp apply_index_order(query, parent) when is_binary(parent),
    do: from(d in query, order_by: [asc: d.inserted_at])

  defp apply_index_order(query, _),
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
  defp maybe_filter_label(query, nil), do: query
  defp maybe_filter_label(query, ""), do: query

  defp maybe_filter_label(query, label) when is_binary(label) do
    from(d in query,
      where: fragment("?->'labels' @> to_jsonb(?::text)", d.content, ^label)
    )
  end

  # ─── POST /v1/tasks/claim ───────────────────────────────────────────────

  def claim(conn, params) do
    case params["worker_id"] do
      worker_id when is_binary(worker_id) and byte_size(worker_id) > 0 ->
        opts =
          []
          |> put_opt(:phase_id, params["phase_id"])
          |> Keyword.merge(scope_opts(conn))

        case Tasks.claim(worker_id, opts) do
          {:ok, nil} ->
            conn
            |> put_status(:ok)
            |> json(%{ok: false, reason: "no_ready"})

          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: render_doc(doc)})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: reason_to_string(reason)})
        end

      _ ->
        bad_request(conn, "worker_id is required")
    end
  end

  # ─── GET /v1/tasks/:doc_id ──────────────────────────────────────────────
  # w7-08: dedicated single-task fetch, replacing the bd-shim's listAll() walk.
  # Uses the SAME direct scoped query as `find_task_by_doc_id/2` — DO NOT
  # route through `Content.get_document/4` (dataset_id coalescence bug noted
  # in w7-07's report).

  def show(conn, %{"doc_id" => doc_id}) do
    case find_task_by_doc_id(doc_id, conn) do
      {:ok, doc} ->
        # w7-08c: count edges on the single-doc path too. batch_edge_counts/1
        # accepts a 1-element list and runs the same two grouped queries.
        counts = batch_edge_counts([doc])
        json(conn, %{ok: true, doc: render_doc_with_counts(doc, counts)})

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── POST /v1/tasks/:doc_id/claim ───────────────────────────────────────
  # w7-08: targeted claim (caller names the row). Calls Tasks.claim_by_id/3
  # which has the same advisory-lock + CAS + epoch-bump + durable-event
  # pattern as Tasks.claim/2 but for a specific doc.

  def claim_by_id(conn, %{"doc_id" => doc_id} = params) do
    case params["worker_id"] do
      worker_id when is_binary(worker_id) and byte_size(worker_id) > 0 ->
        opts = Keyword.merge([], scope_opts(conn))

        case Tasks.claim_by_id(doc_id, worker_id, opts) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: render_doc(doc)})

          {:error, :not_found} ->
            not_found(conn, "task not found")

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: reason_to_string(reason)})
        end

      _ ->
        bad_request(conn, "worker_id is required")
    end
  end

  # ─── GET /v1/tasks/epic/close-eligible ──────────────────────────────────
  # w7-08: aggregator returning [doc_id, …] for kind=goal tasks whose full
  # child-subtree (phases + work-tasks) is closed. Tenancy-scoped on
  # workspace + project. Returns BOTH open and closed goals that qualify —
  # the caller decides what to do (close them, just report, etc.).

  def epic_close_eligible(conn, _params) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    # Tenant boundary is workspace + project (the hard tenancy contract).
    # `dataset_id` is intentionally NOT in the WHERE clause — the bd-shim
    # surface is dataset-agnostic and goals can live anywhere within the
    # workspace's datasets. Each document's `type` is goal/phase/task — those
    # are the four kinds registered via `Tasks.schema_definitions/1`; the
    # `content.kind` field is a discriminator for the JSON validator only.
    # Prefix-agnostic parent↔doc_id matching (#7): a phase's `content.parent`
    # may be stored bare (`goal-258703`) while the goal's `doc_id` carries the
    # draft prefix (`drafts.goal-258703`) — or vice-versa. A naive `=` join
    # then finds zero children, and the `NOT EXISTS` becomes vacuously true,
    # flagging a goal with real open work as close-eligible (the e2e #7 bug:
    # `0/0 children`, closed===total when both 0). We strip a leading `drafts.`
    # from BOTH sides of every parent↔doc_id comparison via
    # `regexp_replace(…, '^drafts\\.', '')`, so the rollup counts children
    # robustly regardless of which writer's prefix convention is in play.
    sql = """
    SELECT g.doc_id FROM documents g
    WHERE g.type = 'goal'
      AND ($1::uuid IS NULL OR g.workspace_id = $1::uuid)
      AND ($2::uuid IS NULL OR g.project_id = $2::uuid)
      AND NOT EXISTS (
        SELECT 1 FROM documents c
        WHERE c.type = 'phase'
          AND regexp_replace(c.content->>'parent', '^drafts\\.', '') = regexp_replace(g.doc_id, '^drafts\\.', '')
          AND ($1::uuid IS NULL OR c.workspace_id = $1::uuid)
          AND ($2::uuid IS NULL OR c.project_id = $2::uuid)
          AND (
            COALESCE(c.content->>'lifecycle_status', '') NOT IN ('done','cancelled')
            OR EXISTS (
              SELECT 1 FROM documents w
              WHERE w.type = 'task'
                AND regexp_replace(w.content->>'parent_id', '^drafts\\.', '') = regexp_replace(c.doc_id, '^drafts\\.', '')
                AND ($1::uuid IS NULL OR w.workspace_id = $1::uuid)
                AND ($2::uuid IS NULL OR w.project_id = $2::uuid)
                AND COALESCE(w.content->>'lifecycle_status', '') NOT IN ('done','cancelled')
            )
          )
      )
    ORDER BY g.doc_id
    """

    %{rows: rows} =
      Repo.query!(sql, [dump_uuid(workspace_id), dump_uuid(project_id)])

    doc_ids = Enum.map(rows, fn [doc_id] -> doc_id end)
    json(conn, %{ok: true, doc_ids: doc_ids})
  end

  # ─── POST /v1/tasks/:doc_id/close ───────────────────────────────────────

  def close(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, worker_id} <- fetch_string(params, "worker_id"),
         {:ok, observed_epoch} <- fetch_int(params, "observed_epoch"),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        [observed_epoch: observed_epoch]
        |> put_opt(:observed_rev, params["observed_rev"])
        |> put_opt(:lifecycle_status, params["lifecycle_status"])

      case Tasks.close(task.id, worker_id, opts) do
        {:ok, %Document{} = doc} ->
          json(conn, %{ok: true, doc: render_doc(doc)})

        {:error, reason} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, reason: reason_to_string(reason)})
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── GET /v1/tasks/:doc_id/edges ────────────────────────────────────────

  def edges(conn, %{"doc_id" => doc_id} = params) do
    kind_opt =
      case params["kind"] do
        nil -> :blocks
        "all" -> :all
        other when is_binary(other) -> other
      end

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        deps = Tasks.dependencies(task.id, kind: kind_opt)
        dependents = Tasks.dependents(task.id, kind: kind_opt)

        json(conn, %{
          ok: true,
          dependencies: Enum.map(deps, &render_doc/1),
          dependents: Enum.map(dependents, &render_doc/1)
        })

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── POST /v1/tasks/edges ───────────────────────────────────────────────

  def add_edge(conn, params) do
    with {:ok, from_id} <- fetch_string(params, "from_id"),
         {:ok, to_id} <- fetch_string(params, "to_id"),
         {:ok, from_doc} <- find_task_by_doc_id(from_id, conn),
         {:ok, to_doc} <- find_task_by_doc_id(to_id, conn) do
      kind = params["kind"] || "blocks"

      case Tasks.add_dep(from_doc.id, to_doc.id, kind) do
        {:ok, %Edge{} = edge} ->
          json(conn, %{
            ok: true,
            edge: %{from_id: edge.from_id, to_id: edge.to_id, kind: edge.kind}
          })

        {:error, %Ecto.Changeset{} = cs} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{ok: false, reason: "invalid_edge", errors: changeset_errors(cs)})
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :not_found} ->
        not_found(conn, "from_id or to_id not found")
    end
  end

  # ─── POST /v1/tasks/:doc_id/labels ──────────────────────────────────────
  # tt5: add/remove `content.labels` entries on a single task. Body shape:
  #   { "add": ["file-claim:/x"], "remove": ["file-claim:/y"] }
  # Both keys optional (default []). Reads the doc workspace+project scoped
  # (same direct query as find_task_by_doc_id — NOT Content.get_document),
  # then delegates to Tasks.relabel_by_id/3 (advisory-lock + CAS-on-rev +
  # task.relabeled mutation_event). Returns { ok, doc }.
  #
  # Backs the bd-shim's `bd update <id> --add-label/--remove-label`, which in
  # turn backs paperflow-claim-files' `file-claim:<path>` ownership labels.

  def relabel(conn, %{"doc_id" => doc_id} = params) do
    add = string_list(params["add"])
    remove = string_list(params["remove"])

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        case Tasks.relabel_by_id(task.id, add, remove) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: render_doc(doc)})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: reason_to_string(reason)})
        end

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # Phase A: POST /v1/tasks/:doc_id/papers. Mirrors relabel/2 — reads add/remove
  # paper slugs from params, finds the task scoped by workspace+project, then
  # delegates to Tasks.update_paper_refs_by_id/3 (advisory-lock + CAS-on-rev +
  # task.referenced mutation_event). Returns { ok, doc }.
  def papers(conn, %{"doc_id" => doc_id} = params) do
    add = string_list(params["add"])
    remove = string_list(params["remove"])

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        case Tasks.update_paper_refs_by_id(task.id, add, remove) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: render_doc(doc)})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: reason_to_string(reason)})
        end

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # Coerce a body field into a list of strings. Accepts a list (filtering
  # non-strings), a bare string (wrapped), or nil/anything-else (→ []).
  defp string_list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp string_list(v) when is_binary(v), do: [v]
  defp string_list(_), do: []

  # ─── Helpers ────────────────────────────────────────────────────────────

  # content.labels is a free-form JSON array; coerce missing / non-list to [].
  defp labels_of(%{"labels" => labels}) when is_list(labels), do: labels
  defp labels_of(_), do: []

  # content.papers is a JSON array of paper slugs; coerce missing / non-list to [].
  defp papers_of(%{"papers" => papers}) when is_list(papers), do: papers
  defp papers_of(_), do: []

  # Look up a task by its `doc_id` string. We DO NOT route through
  # `Content.get_document/4` here on purpose — the dataset-string filter in
  # Content threads through `resolve_read_dataset_id/2` which, for callers
  # carrying both workspace + project scope, can resolve the requested
  # dataset string to a DIFFERENT workspace's dataset_id (barkpark-sknf
  # shape). For the bd-shim surface, `doc_id` is unique within
  # `(workspace, project, type=task)` and the dataset string is incidental,
  # so we filter directly on the workspace + project ids (the hard tenant
  # boundary) and skip the dataset coalescence entirely.
  defp find_task_by_doc_id(doc_id, conn) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    # w7-08: widen from `type == "task"` to the four W7 substrate types
    # (goal/phase/task/event). The bd-shim's `bd show <id>` is generic —
    # consumers pass a doc_id without knowing the kind. The tenancy
    # filters below remain the hard boundary.
    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type in ["task", "goal", "phase", "event"]
      )

    query =
      base
      |> maybe_filter_workspace(workspace_id)
      |> maybe_filter_project(project_id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Document{} = doc -> {:ok, doc}
    end
  end

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, ws_id),
    do: from(d in query, where: d.workspace_id == ^ws_id)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, p_id),
    do: from(d in query, where: d.project_id == ^p_id)

  # Render a Document into the bd-compatible shape the shim consumes.
  # Keep the field set tight enough to translate cleanly into `bd show`
  # JSON, broad enough that callers like `bd list --json` don't lose
  # information (priority, assignee, content.kind for filtering).
  defp render_doc(%Document{} = doc) do
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
      parent: Map.get(content, "parent"),
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
  end

  # w7-08c (paperflow-y1c): batch edge-count maps so a list response
  # (ready/index) doesn't N+1 the task_edges table.
  #
  # Returns %{doc_id => {dependency_count, dependent_count}}. Single query
  # per side (outbound / inbound) joined on the candidate ids — preserves
  # the controller's tenancy contract by deriving ids from the already-
  # tenancy-scoped `docs` list.
  defp batch_edge_counts([]), do: %{}

  defp batch_edge_counts(docs) do
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
  defp render_doc_with_counts(%Document{} = doc, counts) do
    {dep_count, dependent_count} = Map.get(counts, doc.id, {0, 0})

    doc
    |> render_doc()
    |> Map.put(:dependency_count, dep_count)
    |> Map.put(:dependent_count, dependent_count)
    |> Map.put(:comment_count, 0)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Repo.query! takes RAW Postgrex params — uuids must be 16-byte binaries,
  # not the human "73ad…" strings Ecto.UUID hands back from the scope helpers.
  # Dump nil → nil so the SQL's `$1::uuid IS NULL` branch fires.
  defp dump_uuid(nil), do: nil

  defp dump_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, raw} -> raw
      :error -> uuid
    end
  end

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, :missing, key}
    end
  end

  defp fetch_int(params, key) do
    case Map.get(params, key) do
      n when is_integer(n) -> {:ok, n}
      s when is_binary(s) -> parse_int_strict(s, key)
      _ -> {:error, :missing, key}
    end
  end

  defp parse_int_strict(s, key) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :missing, key}
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> default
    end
  end

  defp parse_int(v, _default) when is_integer(v), do: v

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string({:invalid_lifecycle, s}), do: "invalid_lifecycle:#{s}"
  defp reason_to_string(other), do: inspect(other)

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, reason: "bad_request", message: message})
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> json(%{ok: false, reason: "not_found", message: message})
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
