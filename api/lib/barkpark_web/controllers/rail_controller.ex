defmodule BarkparkWeb.RailController do
  @moduledoc """
  W7c step 3 (w7-11 / paperflow-158) — goal-path rail data plane.

  Three read endpoints under `/v1/rail/*` consumed by the paperflow
  daemon's proxy (when `PAPERFLOW_MIRROR_GOALS=1`). The rail itself —
  the 240px gitGraph beside every paperflow doc — fetches via these
  endpoints; the goal hub gate (Gate-C) closes when this lands.

      * `GET /v1/rail/goal-path?goal=<doc_id>`
          → timeline of kind:event mutations for the goal AND all docs
            transitively parented to it (phases, tasks). Ordered desc by ts.
      * `GET /v1/rail/event/:event_id`
          → ONE event row's full sidecar payload.
      * `GET /v1/rail/diff?from=<event_id>&to=<event_id>`
          → line-level diff between two events' html_payloads.

  ## Data-source decision: mutation_events (NOT type='event' documents)

  The rail tracks **lifecycle events**, not edits to a separate
  denormalized document type. Tasks/Phases/Goals emit `mutation_events`
  rows (`task.claimed`, `task.closed`, `task.compacted`,
  `task.lease_expired`, …) via `Tasks.insert_mutation_event!/3` and
  TTL-sweeper / compactor counterparts. That table is the canonical
  log: durable, tenancy-stamped, ordered by an integer id, snapshots
  the post-update doc in the `document` map column.

  Storing the same lifecycle as `type='event'` documents would be redundant
  denormalization — every mutation already writes a row to mutation_events;
  a parallel `Document{type:'event'}` write would double the surface for no
  new fact, drift on missed double-writes, and conflict with the existing
  event-doc kind (already used by the paperflow daemon's sidecar import
  path for "goal-snapshot" etc., which is a separate axis). This controller
  reads ONLY mutation_events; the legacy filesystem sidecars at
  `~/.paperflow/events/<id>.html` remain reachable via the `:event_id`
  endpoint's fallback for pre-W7 records the daemon migrated over.

  ## Tenancy

  Workspace + project scope from the request (via `ScopeHelpers.scope_opts/1`,
  set by the `AssignDefaultScope` plug on flat `/v1/*` routes). The
  `mutation_events` rows are scoped already (`Tasks.insert_mutation_event!/3`
  stamps `workspace_id` + `project_id` from the source doc) — so a single
  WHERE filter on those columns gives the hard boundary without joining
  through documents twice.

  ## Goal → events traversal (2-level, no recursive CTE)

  Goal-tasks have phase-task children (`phase.content.parent = <goal>`).
  Phase-tasks have work-task children (`task.content.parent_id = <phase>`).
  The depth is fixed at 2; one UNION query reaches every descendant
  doc_id without a recursive CTE. This is the W7-04 / w7-08 topology and
  must stay flat — if a future schema adds a third axis, switch to a
  recursive CTE before the rail collapses under N+1 reads.

  ## Branch labelling

  Each event carries a `branch` string for the rail's gitGraph:

      * `main`            — default (most events live here)
      * `alt-<n>`         — walk-back branches (the rail's "click an older
                            node to fork" path; encoded in the event's
                            `document.content.branch` snapshot when the
                            hook reads `.paperflow/active-event-base`)
      * `simplified-<n>`  — the Simplify sub-action's candidates

  We surface what the snapshot carries; absent → `main`. Future writers
  must set `content.branch` for non-main events.
  """

  use BarkparkWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Repo, TextDiff}
  alias Barkpark.Content.{Document, MutationEvent}

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @event_kinds_default ~w(
    task.claimed task.closed task.mutated task.lease_expired
    task.compacted task.restored
  )

  # ─── GET /v1/rail/goal-path?goal=<doc_id> ──────────────────────────────

  def goal_path(conn, %{"goal" => goal_doc_id}) when is_binary(goal_doc_id) and byte_size(goal_doc_id) > 0 do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    # Resolve the goal first — its existence + tenancy is the gate. A
    # missing goal returns an empty event list, not 404: the rail can ask
    # for a goal that lives in a different scope; surface "no events" so
    # the rail renders an empty gitGraph instead of an error toast.
    goal = find_doc_by_id(goal_doc_id, "goal", workspace_id, project_id)

    case goal do
      nil ->
        json(conn, %{ok: true, events: []})

      %Document{} ->
        events = load_goal_path_events(goal_doc_id, workspace_id, project_id)
        json(conn, %{ok: true, events: events})
    end
  end

  def goal_path(conn, _params) do
    bad_request(conn, "query param `goal` is required")
  end

  # ─── GET /v1/rail/event/:event_id ──────────────────────────────────────

  def event(conn, %{"event_id" => event_id}) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    case fetch_event(event_id, workspace_id, project_id) do
      {:ok, row} ->
        json(conn, %{ok: true, event: render_event_full(row)})

      :not_found ->
        # Legacy filesystem-sidecar fallback: pre-W7 deploys wrote
        # ~/.paperflow/events/<id>.html. Honour that path if the daemon
        # mounted it via PAPERFLOW_EVENTS_DIR. Without the env we 404.
        case legacy_sidecar(event_id) do
          {:ok, html} ->
            json(conn, %{ok: true, event: %{event_id: event_id, kind: "legacy.sidecar",
                                            doc_id: nil, ts: nil, html_payload: html}})
          :not_found ->
            not_found(conn, "event not found")
        end
    end
  end

  # ─── GET /v1/rail/diff?from=<event_id>&to=<event_id> ───────────────────

  def diff(conn, params) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    with {:ok, from_id} <- fetch_string(params, "from"),
         {:ok, to_id} <- fetch_string(params, "to"),
         {:ok, from_row} <- fetch_event_or_error(from_id, workspace_id, project_id),
         {:ok, to_row} <- fetch_event_or_error(to_id, workspace_id, project_id) do
      from_html = render_html_payload(from_row)
      to_html = render_html_payload(to_row)
      hunks = TextDiff.hunks(from_html, to_html)
      json(conn, %{ok: true, from: from_id, to: to_id, hunks: hunks})
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :not_found, which} ->
        not_found(conn, "event `#{which}` not found")
    end
  end

  # ─── helpers — data load ───────────────────────────────────────────────

  # The 2-level goal→descendants set, materialized as a list of doc_ids.
  # Single SQL: union of {goal.doc_id} ∪ {phases under goal} ∪ {tasks under
  # phases under goal}. Tenancy filters carried through every leg.
  defp load_descendant_doc_ids(goal_doc_id, workspace_id, project_id) do
    sql = """
    SELECT doc_id FROM documents
    WHERE doc_id = $1
      AND type = 'goal'
      AND ($2::uuid IS NULL OR workspace_id = $2::uuid)
      AND ($3::uuid IS NULL OR project_id = $3::uuid)
    UNION
    SELECT doc_id FROM documents p
    WHERE p.type = 'phase'
      AND p.content->>'parent' = $1
      AND ($2::uuid IS NULL OR p.workspace_id = $2::uuid)
      AND ($3::uuid IS NULL OR p.project_id = $3::uuid)
    UNION
    SELECT t.doc_id FROM documents t
    JOIN documents p
      ON p.type = 'phase'
     AND p.doc_id = t.content->>'parent_id'
     AND ($2::uuid IS NULL OR p.workspace_id = $2::uuid)
     AND ($3::uuid IS NULL OR p.project_id = $3::uuid)
    WHERE t.type = 'task'
      AND p.content->>'parent' = $1
      AND ($2::uuid IS NULL OR t.workspace_id = $2::uuid)
      AND ($3::uuid IS NULL OR t.project_id = $3::uuid)
    """

    %{rows: rows} =
      Repo.query!(sql, [goal_doc_id, dump_uuid(workspace_id), dump_uuid(project_id)])

    Enum.map(rows, fn [doc_id] -> doc_id end)
  end

  defp load_goal_path_events(goal_doc_id, workspace_id, project_id) do
    descendant_ids = load_descendant_doc_ids(goal_doc_id, workspace_id, project_id)

    case descendant_ids do
      [] ->
        []

      ids ->
        base =
          from(e in MutationEvent,
            where: e.doc_id in ^ids,
            where: e.mutation in ^@event_kinds_default,
            order_by: [desc: e.id]
          )

        query =
          base
          |> maybe_filter_event_workspace(workspace_id)
          |> maybe_filter_event_project(project_id)

        query
        |> Repo.all()
        |> Enum.map(&render_event_summary/1)
    end
  end

  # Find a doc by (doc_id, type) inside tenancy. nil → not found.
  defp find_doc_by_id(doc_id, type, workspace_id, project_id) do
    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == ^type
      )

    base
    |> maybe_filter_workspace(workspace_id)
    |> maybe_filter_project(project_id)
    |> Repo.one()
  end

  # Fetch a single MutationEvent by id (string-or-int). Returns {:ok, row}
  # or :not_found. Tenancy-scoped.
  defp fetch_event(event_id, workspace_id, project_id) do
    case parse_int(event_id) do
      nil ->
        :not_found

      n when is_integer(n) ->
        base = from(e in MutationEvent, where: e.id == ^n)

        query =
          base
          |> maybe_filter_event_workspace(workspace_id)
          |> maybe_filter_event_project(project_id)

        case Repo.one(query) do
          nil -> :not_found
          row -> {:ok, row}
        end
    end
  end

  # Same as fetch_event/3 but the not-found tuple carries which side failed,
  # so the /diff endpoint can name it in the 404.
  defp fetch_event_or_error(event_id, workspace_id, project_id) do
    case fetch_event(event_id, workspace_id, project_id) do
      {:ok, row} -> {:ok, row}
      :not_found -> {:error, :not_found, event_id}
    end
  end

  # Read a legacy sidecar HTML — only when PAPERFLOW_EVENTS_DIR is set.
  # Path-traversal-safe: event_id must be alnum/dash/dot only.
  defp legacy_sidecar(event_id) do
    base = System.get_env("PAPERFLOW_EVENTS_DIR")

    cond do
      is_nil(base) or base == "" ->
        :not_found

      not Regex.match?(~r/^[A-Za-z0-9._-]+$/, to_string(event_id)) ->
        :not_found

      true ->
        path = Path.join(base, "#{event_id}.html")

        case File.read(path) do
          {:ok, html} -> {:ok, html}
          {:error, _} -> :not_found
        end
    end
  end

  # ─── helpers — render ──────────────────────────────────────────────────

  # Rail timeline row: short shape consumed by the gitGraph commits.
  defp render_event_summary(%MutationEvent{} = e) do
    snapshot = e.document || %{}
    doc_title = Map.get(snapshot, "title")
    payload = Map.get(snapshot, "content") || %{}
    branch = Map.get(payload, "branch") || "main"

    %{
      event_id: e.id,
      kind: e.mutation,
      doc_id: e.doc_id,
      doc_title: doc_title,
      ts: e.inserted_at,
      payload: payload,
      branch: branch
    }
  end

  # Single-event read: same as the summary, plus the html_payload string
  # if the snapshot carries one (or the sidecar fallback brought one in).
  defp render_event_full(%MutationEvent{} = e) do
    snapshot = e.document || %{}
    payload = Map.get(snapshot, "content") || %{}

    %{
      event_id: e.id,
      kind: e.mutation,
      doc_id: e.doc_id,
      ts: e.inserted_at,
      html_payload: render_html_payload(e),
      payload: payload
    }
  end

  # The html_payload extractor used by both `event/2` and `diff/2`. Order
  # of precedence: snapshot's `content.payload_html` → snapshot's `content`
  # rendered as a tiny inline shape → empty string. The diff endpoint
  # tolerates empty strings (TextDiff handles nil/"" via the underlying
  # split_lines/1).
  defp render_html_payload(%MutationEvent{document: doc}) when is_map(doc) do
    case get_in(doc, ["content", "payload_html"]) do
      html when is_binary(html) -> html
      _ -> ""
    end
  end

  defp render_html_payload(_), do: ""

  # ─── helpers — query plumbing ──────────────────────────────────────────

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, ws_id),
    do: from(d in query, where: d.workspace_id == ^ws_id)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, p_id),
    do: from(d in query, where: d.project_id == ^p_id)

  defp maybe_filter_event_workspace(query, nil), do: query

  defp maybe_filter_event_workspace(query, ws_id),
    do: from(e in query, where: e.workspace_id == ^ws_id)

  defp maybe_filter_event_project(query, nil), do: query

  defp maybe_filter_event_project(query, p_id),
    do: from(e in query, where: e.project_id == ^p_id)

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

  defp parse_int(nil), do: nil

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
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
