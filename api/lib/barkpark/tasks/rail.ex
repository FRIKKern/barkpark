defmodule Barkpark.Tasks.Rail do
  @moduledoc """
  rail-l1 — the **rail ETag** (`rail_rev`) + the blocker probe behind the
  multi-agent rail-awareness notices.

  A **rail** is a parent task's children — the rows whose
  `content.parent_id` points at the parent (a "rail is the chronological
  child tasks of a task", per `Barkpark.Tasks`). Rails change UNDER working
  agents: a sibling task is filed, a child's priority is bumped, a `blocks`
  edge is discovered mid-flight. Agents here are burst-based — they have no
  socket to push a change down — so the delivery channel is the response
  they already receive on their next server touch (claim / close / prime).
  `rail_rev` is the compact fingerprint that lets a burst agent notice its
  rail moved without re-listing it.

  ## The digest (`rev/2`)

  `rev/2` computes a short hex digest (sha256, first 16 hex chars) over,
  for a given dataset + parent `doc_id`:

    1. the rail's children, each as the tuple
       `(doc_id, lifecycle_status, priority, rev)`, sorted by `doc_id`; PLUS
    2. every `blocks` edge from `task_edges` where EITHER endpoint is one of
       those children, sorted.

  Therefore ANY of these flips the digest:

    * a child create / close / cancel / re-parent (in or out) — the child
      set changes;
    * a child priority change — the tuple changes;
    * a `blocks`-edge add/remove touching a child — the edge set changes.

  Because a child's `rev` is part of the tuple, ANY edit to a child (even a
  description tweak) also flips the digest. This is deliberate — `rail_rev`
  is intentionally CONSERVATIVE (an ETag, compared `≠` not `<`): a false
  "changed" costs an agent one re-read; a false "unchanged" would hide real
  drift. Stability is only promised against edits to NON-child tasks.

  ## No stored state

  There is NO stored counter, NO migration, NO bump plumbing. `rev/2` is
  computed on demand at read time from two indexed queries (children by
  `parent_id`, then `blocks` edges by the child id set). A stored revision
  would need every child write, every edge write, and every re-parent to
  find and bump the right parent row — three write paths to keep in sync
  and a second source of truth to drift. Recomputing from the substrate is
  the honest implementation: the digest cannot lie about the rail because
  the rail IS its only input.

  ## ETag semantics

  Clients compare `observed_rail_rev != current` (an inequality), never a
  monotonic `<`. The digest carries no ordering; it is an identity, like an
  HTTP `ETag`. Two different rails have (with overwhelming probability)
  different digests; the same rail always has the same digest.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Blockers
  alias Barkpark.Tasks.Edge

  # ASCII field/record separators — safe delimiters for the digest preimage
  # (neither appears in a doc_id, rev, or lifecycle_status).
  @unit "\x1f"
  @record "\x1e"

  @doc """
  The `rail_rev` ETag for the rail parented by `parent_doc_id`, or `nil`
  when `parent_doc_id` is nil (a parentless task has no rail).

  ## Options
    * `:workspace_id` — binary uuid. Fails CLOSED (empty rail) when nil, via
      the shared `Scope.scope_to_workspace/3` — never every tenant's rows.
    * `:project_id`   — binary uuid. Narrows within the workspace.
    * `:dataset`      — string dataset name. When omitted, no dataset filter.

  Returns a 16-char lowercase hex string, or `nil`.
  """
  @spec rev(binary() | nil, keyword()) :: String.t() | nil
  def rev(parent_doc_id, opts \\ [])

  def rev(nil, _opts), do: nil

  def rev(parent_doc_id, opts) when is_binary(parent_doc_id) do
    children = rail_children(parent_doc_id, opts)
    child_ids = Enum.map(children, & &1.id)
    edges = blocks_edges_touching(child_ids)
    digest(children, edges)
  end

  @doc """
  The `doc_id`s of `task_uuid`'s blockers that are NOT yet satisfied — the
  payload of a `blocked_while_claimed` notice.

  This is the canonical multi-agent case: agent A files a `blocks` edge onto
  agent B's claimed task; B's next touch (claim / close / prime) surfaces
  the unsatisfied blockers here. Returns `[]` when nothing blocks.

  THE NOTICE READS THE SAME BLOCKER SET THE DOORS DO (task-814b2d28bdb4b2f5).
  This probe used to run its own query — `blocks` edges only, gated on a bare
  `lifecycle_status != 'done'` — which made it a FIFTH reader of "what blocks
  this task", disagreeing with `Tasks.Queue`, `Tasks.Claim` and `Tasks.Close`
  in both directions:

    * a blocker recorded only in `content.dependencies` was omitted here, so
      the claim door refused with `blocked_by_unsatisfied_deps` while the one
      surface that exists to SAY WHY reported nothing;
    * a blocker that read `done` with no record of a close was omitted here
      and unsatisfied at the doors, the same silence.

  `Tasks.Blockers.unsatisfied/1` is that one set. A door that refuses and a
  notice that explains must not be able to disagree.
  """
  @spec unsatisfied_blockers(binary()) :: [String.t()]
  def unsatisfied_blockers(task_uuid) when is_binary(task_uuid) do
    # global-read: by-PK notice re-read — `task_uuid` IS the Document PK and is never caller-supplied: the one production caller (`TasksController.add_blocked_notice/2`) passes `task.id` off a Document it already loaded through the tenant-scoped in-progress query, so tenancy is resolved by that caller's scope, not re-threaded here. Same internal-worker posture as the by-PK re-reads in close.ex / stamp.ex / pulse.ex. (The marker MUST stay the line directly above the call — tenant-scope-check.sh reads only the immediately-preceding line.)
    case Repo.get(Document, task_uuid) do
      nil -> []
      %Document{} = doc -> Blockers.unsatisfied(doc)
    end
  end

  # ─── internals ─────────────────────────────────────────────────────────

  # The rail's children: prefix-agnostic `parent_id` match (a leading
  # `drafts.` stripped from BOTH sides — the SAME edge the board's rail
  # readers use, `Tasks.Query.maybe_filter_parent_id/2`), tenancy-scoped.
  # Selects only the four digest inputs plus the id (for the edge scan).
  defp rail_children(parent_doc_id, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    dataset = Keyword.get(opts, :dataset)

    from(d in Document,
      where: d.type == "task",
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^parent_doc_id),
      select: %{
        id: d.id,
        doc_id: d.doc_id,
        lifecycle_status: fragment("?->>'lifecycle_status'", d.content),
        priority: fragment("?->>'priority'", d.content),
        rev: d.rev
      }
    )
    |> maybe_filter_dataset(dataset)
    |> Scope.scope_to_workspace(workspace_id, project_id)
    |> Repo.all()
  end

  # Every `blocks` edge with either endpoint in the child id set — ONE query
  # (bitmap-OR over the `(from_id, kind)` + `(to_id, kind)` indexes), never
  # N+1 per child. Empty child set → no edges (skip the query).
  defp blocks_edges_touching([]), do: []

  defp blocks_edges_touching(child_ids) do
    from(e in Edge,
      where: e.kind == "blocks" and (e.from_id in ^child_ids or e.to_id in ^child_ids),
      select: {e.from_id, e.to_id}
    )
    |> Repo.all()
  end

  # sha256 over a deterministic string preimage → first 16 hex chars.
  # Children sorted by doc_id, edges sorted as (from, to) pairs, so the
  # digest is order-independent of how the DB returned the rows.
  defp digest(children, edges) do
    child_lines =
      children
      |> Enum.sort_by(& &1.doc_id)
      |> Enum.map(fn c ->
        Enum.join([c.doc_id, blank(c.lifecycle_status), blank(c.priority), blank(c.rev)], @unit)
      end)

    edge_lines =
      edges
      |> Enum.map(fn {from_id, to_id} -> Enum.join([from_id, to_id], @unit) end)
      |> Enum.sort()

    preimage = Enum.join(["C" | child_lines] ++ ["E" | edge_lines], @record)

    :sha256
    |> :crypto.hash(preimage)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp blank(nil), do: ""
  defp blank(v), do: to_string(v)

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset),
    do: from(d in query, where: d.dataset == ^dataset)
end
