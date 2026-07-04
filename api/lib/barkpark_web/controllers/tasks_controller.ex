defmodule BarkparkWeb.TasksController do
  @moduledoc """
  W7b step 1 (paper-rx0 / w7-07a) — HTTP surface for the `bp task` CLI
  (historically the bd-compatible shim `bin/bd-shim`, retired 2026-06-22).

  Eleven endpoints, all bearer-token gated via the existing `:api` +
  `:require_token` pipelines in `router.ex`:

    * `GET    /v1/tasks`                    — `Tasks` index (filters: kind/lifecycle_status/phase_id/parent/label)
    * `GET    /v1/tasks/ready`              — `Tasks.ready/1`
    * `GET    /v1/tasks/prime`              — one-call agent rehydration (in_progress + ready head + recent events + counts)
    * `GET    /v1/tasks/:doc_id`            — single-task fetch (w7-08)
    * `POST   /v1/tasks/claim`              — `Tasks.claim/2` (queue-based)
    * `POST   /v1/tasks/:doc_id/claim`      — `Tasks.claim_by_id/3` (targeted, w7-08)
    * `POST   /v1/tasks/:doc_id/close`      — `Tasks.close/3`
    * `GET    /v1/tasks/:doc_id/edges`      — `Tasks.dependencies/2` + `dependents/2`
    * `POST   /v1/tasks/edges`              — `Tasks.add_dep/3`
    * `POST   /v1/tasks/:doc_id/labels`     — `Tasks.relabel_by_id/3`
    * `POST   /v1/tasks/:doc_id/papers`     — `Tasks.update_paper_refs_by_id/3`

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

  alias Barkpark.{Content, Repo, Tasks}
  alias Barkpark.Content.Document
  alias Barkpark.Content.Graph
  alias Barkpark.Tasks.Edge
  alias BarkparkWeb.TasksController.Params

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  # ─── GET /v1/tasks/ready ────────────────────────────────────────────────

  def ready(conn, params) do
    opts =
      []
      |> Params.put_opt(:phase_id, params["phase_id"])
      |> Params.put_opt(:limit, Params.parse_limit(params["limit"], nil, 1000))
      |> Keyword.merge(scope_opts(conn))

    docs = Tasks.ready(opts)
    counts = Params.batch_edge_counts(docs)
    json(conn, %{ok: true, docs: Enum.map(docs, &Params.render_doc_with_counts(&1, counts))})
  end

  # ─── GET /v1/tasks/prime ────────────────────────────────────────────────
  # One-call agent rehydration — the `bd prime` lesson from the Beads
  # retrospective (2026-06-11). After compaction / a fresh session, an agent
  # needs its working context in ONE response instead of four calls:
  #
  #   * `in_progress` — live claims, narrowed to `?worker=<id>` when given
  #     (an agent resuming asks "what am I holding?"); all live claims
  #     otherwise (an orchestrator asks "who holds what?").
  #   * `ready` — the head of the unblocked queue (`?limit=`, default 10).
  #   * `recent_events` — the last `limit` task mutation_events, newest
  #     first, as lean {event, doc_id, at} rows (full docs ride the SSE
  #     stream; prime is orientation, not replay).
  #   * `counts` — open/in_progress/blocked/done/cancelled totals for the
  #     scope, so "how big is the board?" needs no extra list call.
  def prime(conn, params) do
    scope = scope_opts(conn)
    worker = params["worker"]
    limit = params["limit"] |> Params.parse_int(10) |> min(100) |> max(1)

    in_progress =
      from(d in Document,
        where: d.type == "task",
        where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
        order_by: [desc: d.updated_at],
        limit: 100
      )
      |> Params.maybe_filter_workspace(Keyword.get(scope, :workspace_id))
      |> Params.maybe_filter_project(Keyword.get(scope, :project_id))
      |> Params.maybe_filter_claim_worker(worker)
      |> Repo.all()

    ready = Tasks.ready([limit: limit] ++ scope)
    counts = Params.batch_edge_counts(in_progress ++ ready)

    events =
      from(e in Barkpark.Content.MutationEvent,
        where: e.type == "task" and like(e.mutation, "task.%"),
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        select: %{event: e.mutation, doc_id: e.doc_id, at: e.inserted_at}
      )
      |> Params.maybe_filter_event_workspace(Keyword.get(scope, :workspace_id))
      |> Repo.all()

    lifecycle_counts =
      from(d in Document,
        where: d.type == "task",
        group_by: fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content),
        select: {fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content), count(d.id)}
      )
      |> Params.maybe_filter_workspace(Keyword.get(scope, :workspace_id))
      |> Params.maybe_filter_project(Keyword.get(scope, :project_id))
      |> Repo.all()
      |> Map.new()

    json(conn, %{
      ok: true,
      worker: worker,
      in_progress: Enum.map(in_progress, &Params.render_doc_with_counts(&1, counts)),
      ready: Enum.map(ready, &Params.render_doc_with_counts(&1, counts)),
      recent_events: events,
      counts: lifecycle_counts
    })
  end

  # ─── GET /v1/tasks ──────────────────────────────────────────────────────
  # w7-08c (paper-y1c): list-all endpoint. Returns every task doc in the
  # caller's tenant, optionally narrowed by `kind`, `lifecycle_status`, or
  # `phase_id` (parent match). Everything is a task — goals/phases/events are
  # gone as types. Backs the `bp task` list family (historically the bd-shim's
  # `bd list --json`) — replaces the previous "ready --limit 1000 then
  # client-side filter" path (which lost in-progress + closed rows).
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
    # Clamp into [1, 1000] so a raw value can't reach `limit: ^limit` below:
    # `?limit=-1` would emit `LIMIT -1` (Postgres rejects a negative LIMIT → 500)
    # and `?limit=100000000` would fan the whole task corpus out in one Repo.all.
    limit = Params.parse_limit(params["limit"], 1000, 1000)

    # C1 (task as universal node): when `parent` is given, the result reads as
    # that task's timeline/rail — its chronological child tasks (a "rail is the
    # chronological child tasks of a task"). Order by inserted_at ASC (oldest
    # first) for that view; keep the default desc:updated_at "most recently
    # touched first" ordering for the un-parent-filtered list.
    parent = params["parent"]

    base =
      from(d in Document,
        where: d.type == "task",
        limit: ^limit
      )

    query =
      base
      |> Params.maybe_filter_workspace(workspace_id)
      |> Params.maybe_filter_project(project_id)
      |> Params.maybe_filter_type(params["type"])
      |> Params.maybe_filter_kind(params["kind"])
      |> Params.maybe_filter_lifecycle(params["lifecycle_status"])
      |> Params.maybe_filter_parent(params["phase_id"])
      |> Params.maybe_filter_parent_id(parent)
      |> Params.maybe_filter_label(params["label"])
      |> Params.apply_index_order(parent)

    docs = Repo.all(query)
    counts = Params.batch_edge_counts(docs)
    json(conn, %{ok: true, docs: Enum.map(docs, &Params.render_doc_with_counts(&1, counts))})
  end

  # ─── POST /v1/tasks/claim ───────────────────────────────────────────────

  def claim(conn, params) do
    case params["worker_id"] do
      worker_id when is_binary(worker_id) and byte_size(worker_id) > 0 ->
        opts =
          []
          |> Params.put_opt(:phase_id, params["phase_id"])
          |> Keyword.merge(scope_opts(conn))

        case Tasks.claim(worker_id, opts) do
          {:ok, nil} ->
            conn
            |> put_status(:ok)
            |> json(%{ok: false, reason: "no_ready"})

          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: Params.render_doc(doc)})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: Params.reason_to_string(reason)})
        end

      _ ->
        bad_request(conn, "worker_id is required")
    end
  end

  # ─── GET /v1/tasks/:doc_id ──────────────────────────────────────────────
  # w7-08: dedicated single-task fetch, replacing the (now-retired) bd-shim's
  # listAll() walk.
  # Uses the SAME direct scoped query as `find_task_by_doc_id/2` — DO NOT
  # route through `Content.get_document/4` (dataset_id coalescence bug noted
  # in w7-07's report).

  def show(conn, %{"doc_id" => doc_id}) do
    case find_task_by_doc_id(doc_id, conn) do
      {:ok, doc} ->
        # w7-08c: count edges on the single-doc path too. batch_edge_counts/1
        # accepts a 1-element list and runs the same two grouped queries.
        counts = Params.batch_edge_counts([doc])

        # C2 (task carries its rail): the task's direct child tasks — the rows
        # whose `content.parent_id` points at this doc,
        # in chronological order. Reuses the SAME prefix-agnostic parent filter
        # the index's `parent=` slice walks (`maybe_filter_parent_id/2`) plus
        # the tenancy filters, so the matching logic lives in one place. One
        # level only — children render as lightweight summaries (NOT the full
        # render_doc) to keep the payload lean and avoid deep recursion.
        children = child_tasks(doc.doc_id, conn)

        json(conn, %{
          ok: true,
          doc: Params.render_doc_with_counts(doc, counts),
          children: Enum.map(children, &Params.child_summary/1),
          child_count: length(children)
        })

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # C2: the direct child tasks of `doc_id` — its rail — ordered chronologically
  # (inserted_at ASC, oldest first), tenancy-scoped to the caller's
  # workspace+project. Mirrors the index's C1 parent slice (lines ~85-101):
  # the SAME `maybe_filter_parent_id/2` (prefix-agnostic on `parent_id`,
  # `drafts.` stripped) + the SAME workspace/project filters,
  # over `type == "task"`. No duplicated matching logic — the filter helpers
  # are shared with `index/2`.
  defp child_tasks(doc_id, conn) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    from(d in Document,
      where: d.type == "task",
      order_by: [asc: d.inserted_at]
    )
    |> Params.maybe_filter_workspace(workspace_id)
    |> Params.maybe_filter_project(project_id)
    |> Params.maybe_filter_parent_id(doc_id)
    |> Repo.all()
  end

  # ─── POST /v1/tasks/:doc_id/claim ───────────────────────────────────────
  # w7-08: targeted claim (caller names the row). Calls Tasks.claim_by_id/3
  # which has the same advisory-lock + CAS + epoch-bump + durable-event
  # pattern as Tasks.claim/2 but for a specific doc.

  def claim_by_id(conn, %{"doc_id" => doc_id} = params) do
    case params["worker_id"] do
      worker_id when is_binary(worker_id) and byte_size(worker_id) > 0 ->
        # `resources` rides as a JSON list (curl) or a comma-separated string
        # (the bp `--set resources=a.go,b.go` path) — Tasks normalizes both.
        opts =
          [resources: params["resources"] || []]
          |> Keyword.merge(scope_opts(conn))

        case Tasks.claim_by_id(doc_id, worker_id, opts) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: Params.render_doc(doc)})

          {:error, :not_found} ->
            not_found(conn, "task not found")

          {:error, {:resource_conflict, conflicts}} ->
            # 409 with the HOLDERS: each conflict names the in-progress task,
            # its worker, and the overlapping resource strings — enough for
            # the caller to wait, renegotiate, or pick other files.
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: "resource_conflict", conflicts: conflicts})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: Params.reason_to_string(reason)})
        end

      _ ->
        bad_request(conn, "worker_id is required")
    end
  end

  # ─── POST /v1/tasks/:doc_id/close ───────────────────────────────────────

  def close(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, worker_id} <- Params.fetch_string(params, "worker_id"),
         {:ok, observed_epoch} <- Params.fetch_int(params, "observed_epoch"),
         {:ok, criteria} <- Params.parse_criteria(params["criteria"]),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        [observed_epoch: observed_epoch]
        |> Params.put_opt(:observed_rev, params["observed_rev"])
        |> Params.put_opt(:lifecycle_status, params["lifecycle_status"])
        |> Params.put_opt(:reason, params["reason"])
        |> Params.put_opt(:criteria, if(criteria == [], do: nil, else: criteria))

      case Tasks.close(task.id, worker_id, opts) do
        {:ok, %Document{} = doc} ->
          # Graduated enforcement (living-values §12): unmet criteria are
          # SURFACED as a soft warning on the (already successful) close —
          # never a gate (close_response below, shipped with lvw-t6).
          json(conn, close_response(doc))

        {:error, reason} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, reason: Params.reason_to_string(reason)})
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :invalid_criteria, msg} ->
        bad_request(conn, msg)

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # lvw-t6 warn-on-close: a task closed `done` with unmet acceptance_criteria
  # carries a top-level `warnings` list on the (still 2xx, still ok:true)
  # response — ADVISORY ONLY, the close has already committed; there is no
  # gate. `cancelled`/`blocked` closes skip the warning (abandoning criteria
  # is the point of cancelling). Absent/empty criteria → no warning
  # (Criteria.progress/1 returns nil — omit, never "0/0").
  defp close_response(%Document{} = doc) do
    base = %{ok: true, doc: Params.render_doc(doc)}

    with "done" <- Map.get(doc.content || %{}, "lifecycle_status"),
         %{met: met, total: total} when met < total <- Tasks.criteria_progress(doc.content) do
      Map.put(base, :warnings, [
        "acceptance_criteria: #{met}/#{total} met — closed done with unmet criteria " <>
          "(advisory, no gate; set met/evidence per criterion before closing)"
      ])
    else
      _ -> base
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
          dependencies: Enum.map(deps, &Params.render_doc/1),
          dependents: Enum.map(dependents, &Params.render_doc/1)
        })

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── GET /v1/graph/:id ──────────────────────────────────────────────────
  #
  # Goal ges/graph-edge-seam Phase 4. BFS over `content_edges` from ANY content
  # doc (gap #4 — mediaAsset, post, book; the blast-radius use case), NOT just
  # tasks. We therefore resolve the root GENERICALLY (no `type == "task"`
  # filter) — see resolve_graph_root/2 — and hand the resolved root's
  # `documents.id` UUID to `Content.Graph.traverse/2`.
  #
  # Query params: depth (clamp 1..5, never 4xx), direction (out|in|both),
  # kinds (csv), sources (csv plugin_source), perspective (published default;
  # `drafts`/`?drafts=true` token-gated — already inside the :require_token
  # tier — flips to a live extract over the drafts corpus, NOT the materialised
  # published-only table).
  def graph_show(conn, %{"id" => id} = params) do
    case resolve_graph_root(id, conn) do
      {:ok, %Document{} = root} ->
        opts = graph_traverse_opts(root, params, conn)
        result = Graph.traverse(root.id, opts)

        json(conn, %{
          ok: true,
          # Published-coalesced so a draft-only root still reports its stable
          # published id (the graph identity), never the `drafts.` twin.
          root: Content.published_id(root.doc_id),
          nodes: result.nodes,
          edges: result.edges,
          dependents: result.dependents,
          truncated: result.truncated,
          truncation_reason: result.truncation_reason
        })

      {:error, :not_found} ->
        not_found(conn, "document not found")
    end
  end

  # ─── GET /v1/graph/:id/tasks — the expectation REVERSE VIEW (lvw-t8) ─────
  #
  # Tasks that cite the root doc (in practice: a paper's `design_doc`/`papers`
  # referencers in `content_edges`), each with its acceptance-criteria
  # expectation state — living-values §8/§9: closing a task with met=true +
  # evidence (the lvw-t9 close mechanism) flips `satisfied` here on the next
  # read. Read-side only; published corpus by construction (the projector
  # rebuilds at `perspective: :published`); bounded by the graph engine's node
  # budget. Root resolution + scope mirror `graph_show` exactly.
  def graph_tasks(conn, %{"id" => id}) do
    case resolve_graph_root(id, conn) do
      {:ok, %Document{} = root} ->
        opts = scope_opts(conn) |> Keyword.put(:dataset, root.dataset)
        %{tasks: tasks, truncated: truncated} = Tasks.driven_tasks(root.doc_id, opts)

        json(conn, %{
          ok: true,
          # Published-coalesced, like graph_show — the graph identity.
          root: Content.published_id(root.doc_id),
          tasks: Enum.map(tasks, &render_driven_task/1),
          count: length(tasks),
          truncated: truncated
        })

      {:error, :not_found} ->
        not_found(conn, "document not found")
    end
  end

  # `criteria_progress` is omitted when nil (the lvw-t6 envelope convention:
  # consumers omit the segment, never render 0/0).
  defp render_driven_task(%{criteria_progress: nil} = task),
    do: Map.delete(task, :criteria_progress)

  defp render_driven_task(task), do: task

  # ─── GET /v1/graph/orphans ──────────────────────────────────────────────

  def graph_orphans(conn, _params) do
    opts = scope_opts(conn) |> Keyword.put(:dataset, request_dataset(conn))
    json(conn, %{ok: true, orphans: Graph.orphans(opts)})
  end

  # ─── GET /v1/graph/dangling ─────────────────────────────────────────────

  def graph_dangling(conn, _params) do
    opts = scope_opts(conn) |> Keyword.put(:dataset, request_dataset(conn))
    json(conn, %{ok: true, dangling: Graph.dangling(opts)})
  end

  # ─── GET /v1/graph (whole-dataset corpus graph) ─────────────────────────
  #
  # Returns EVERY published node + EVERY reference edge in the dataset so the
  # Web finder can render the full interactive graph as its landing view (the
  # Obsidian "show the whole vault" surface). Built on the LIVE corpus extractor
  # (slug-keyed, projection-independent) so node ids and edge endpoints share
  # ONE id space (the published doc-id). Orphans are included on purpose — like
  # Obsidian's showOrphans. A node budget guards a pathological corpus; the
  # tenancy + dataset scope ride scope_opts/request_dataset exactly like the
  # sibling graph actions.
  @graph_corpus_node_budget 2000

  def graph_corpus(conn, _params) do
    dataset = request_dataset(conn)
    # limit 1000 (the list_documents hard cap) so the corpus isn't silently
    # truncated at the default page size of 100 — BOTH the node list and
    # corpus_edges read through this opts, so a large dataset still yields a
    # complete graph (the node budget below is the real ceiling).
    opts = scope_opts(conn) |> Keyword.put(:dataset, dataset) |> Keyword.put(:limit, 1000)
    list_opts = Keyword.put(opts, :perspective, :published)

    types = dataset |> Content.list_schemas(opts) |> Enum.map(& &1.name)

    real_nodes =
      types
      |> Enum.flat_map(fn type -> Content.list_documents(type, dataset, list_opts) end)
      |> Enum.map(fn d ->
        pid = Content.published_id(d.doc_id)
        %{id: pid, doc_id: pid, type: d.type, title: d.title || pid, phantom: false}
      end)
      |> Enum.uniq_by(& &1.id)

    node_ids = MapSet.new(real_nodes, & &1.id)

    raw_edges =
      types
      |> Enum.flat_map(fn type -> Content.corpus_edges(type, dataset, opts) end)
      |> Enum.uniq_by(fn e -> {e.from_id, e.to_id, e.field} end)

    edges =
      Enum.map(raw_edges, fn e ->
        %{
          from_id: e.from_id,
          to_id: e.to_id,
          kind: e.kind || "references",
          weight: nil,
          plugin_source: nil
        }
      end)

    phantom_nodes =
      raw_edges
      |> Enum.reject(fn e -> MapSet.member?(node_ids, e.to_id) end)
      |> Enum.map(& &1.to_id)
      |> Enum.uniq()
      |> Enum.map(fn tid -> %{id: tid, doc_id: tid, type: nil, title: tid, phantom: true} end)

    all_nodes = real_nodes ++ phantom_nodes
    truncated = length(all_nodes) > @graph_corpus_node_budget
    nodes = if truncated, do: Enum.take(all_nodes, @graph_corpus_node_budget), else: all_nodes

    json(conn, %{
      ok: true,
      dataset: dataset,
      nodes: nodes,
      edges: edges,
      truncated: truncated,
      truncation_reason: if(truncated, do: "node_budget", else: nil)
    })
  end

  # GRAPH ROOT RESOLUTION (gap #4 BOUND DECISION). Roots on ANY content doc, so
  # we DELIBERATELY do NOT call find_task_by_doc_id/2 (which hard-filters
  # d.type == "task" via fetch_task_exact/3 and returns not_found for every
  # non-task root). Instead we replicate find_task_by_doc_id's tenancy
  # discipline (workspace_id + project_id) AND reference_title/4's
  # published-before-draft ordering, but WITHOUT the type filter. When a doc_id
  # collides across types in one scope, the published-preferred first row wins
  # (v1 graph roots on the published-preferred row — documented contract).
  defp resolve_graph_root(id, conn) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)
    dataset = conn.params["dataset"]

    pub_id = Content.published_id(id)
    draft = Content.draft_id(pub_id)

    query =
      from(d in Document,
        where: d.doc_id == ^pub_id or d.doc_id == ^draft,
        order_by: [asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id)]
      )
      |> Params.maybe_filter_workspace(workspace_id)
      |> Params.maybe_filter_project(project_id)
      |> Params.maybe_filter_dataset(dataset)

    case query |> Repo.all() |> List.first() do
      %Document{} = doc -> {:ok, doc}
      _ -> {:error, :not_found}
    end
  end

  # Build the keyword opts for Content.Graph.traverse/2 from query params + the
  # resolved root (for dataset/scope). perspective=drafts (alias ?drafts=true)
  # is token-gated — this whole controller is already behind :require_token, so
  # honouring the param here IS the gate.
  defp graph_traverse_opts(%Document{} = root, params, conn) do
    scope_opts(conn)
    |> Keyword.put(:dataset, root.dataset)
    # The drafts live-extract path works in published-slug space (extract_edges/2),
    # so it roots on the slug, not the UUID. The published path ignores this key.
    |> Keyword.put(:root_pub_id, Content.published_id(root.doc_id))
    |> Keyword.put(:depth, Params.parse_int(params["depth"], nil))
    |> Keyword.put(:direction, Params.parse_direction(params["direction"]))
    |> Keyword.put(:kinds, Params.csv_list(params["kinds"]))
    |> Keyword.put(:sources, Params.csv_list(params["sources"]))
    |> Keyword.put(:perspective, Params.parse_perspective(params))
  end

  # The dataset string a graph read scopes to. The graph endpoints have no
  # :doc_id segment to derive a dataset from, so we read the optional `dataset`
  # query param (defaulting to "production", the canonical content dataset).
  defp request_dataset(conn) do
    conn.params["dataset"] || "production"
  end

  # ─── POST /v1/tasks/edges ───────────────────────────────────────────────

  def add_edge(conn, params) do
    with {:ok, from_id} <- Params.fetch_string(params, "from_id"),
         {:ok, to_id} <- Params.fetch_string(params, "to_id"),
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
          |> json(%{ok: false, reason: "invalid_edge", errors: Params.changeset_errors(cs)})
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
  # Backs the `bp task` labels endpoint (historically the bd-shim's
  # `bd update <id> --add-label/--remove-label`), which in turn backs
  # paper-claim-files' `file-claim:<path>` ownership labels.

  def relabel(conn, %{"doc_id" => doc_id} = params) do
    add = Params.string_list(params["add"])
    remove = Params.string_list(params["remove"])

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        case Tasks.relabel_by_id(task.id, add, remove) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: Params.render_doc(doc)})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: Params.reason_to_string(reason)})
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
    add = Params.string_list(params["add"])
    remove = Params.string_list(params["remove"])

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        case Tasks.update_paper_refs_by_id(task.id, add, remove) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: Params.render_doc(doc)})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: Params.reason_to_string(reason)})
        end

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────────────

  # Look up a task by its `doc_id` string. We DO NOT route through
  # `Content.get_document/4` here on purpose — the dataset-string filter in
  # Content threads through `resolve_read_dataset_id/2` which, for callers
  # carrying both workspace + project scope, can resolve the requested
  # dataset string to a DIFFERENT workspace's dataset_id (barkpark-sknf
  # shape). For this tasks surface, `doc_id` is unique within
  # `(workspace, project, type=task)` and the dataset string is incidental,
  # so we filter directly on the workspace + project ids (the hard tenant
  # boundary) and skip the dataset coalescence entirely.
  #
  # Resolution rule: try the exact `doc_id` first. When no row is found AND
  # the caller did NOT already supply a `drafts.` prefix, retry with
  # `"drafts." <> doc_id`. This covers the common case where a task was
  # created via the mutate endpoint (which always stores `drafts.<id>`) and
  # the caller uses the bare id. An explicit `drafts.` prefix is always
  # treated as exact — the fallback is never applied in reverse.
  #
  # Disambiguation: if BOTH `t1` and `drafts.t1` exist (a task that was
  # published and still has a live draft), the exact match on `t1` wins —
  # the caller gets the published row, consistent with "exact match first".
  defp find_task_by_doc_id(doc_id, conn) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    case fetch_task_exact(doc_id, workspace_id, project_id) do
      {:ok, _} = hit ->
        hit

      {:error, :not_found} ->
        if String.starts_with?(doc_id, "drafts.") do
          {:error, :not_found}
        else
          fetch_task_exact("drafts." <> doc_id, workspace_id, project_id)
        end
    end
  end

  # Single-doc fetch by exact doc_id string, scoped to workspace + project.
  # Everything is a task — the single `type == "task"` filter covers root
  # tasks (goals), phases, and leaf work-tasks.
  defp fetch_task_exact(doc_id, workspace_id, project_id) do
    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task"
      )

    query =
      base
      |> Params.maybe_filter_workspace(workspace_id)
      |> Params.maybe_filter_project(project_id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Document{} = doc -> {:ok, doc}
    end
  end

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
end
