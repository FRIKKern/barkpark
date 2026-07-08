defmodule Barkpark.Tasks.Queue do
  @moduledoc false
  # The dependency-aware, phase-scoped ready-queue query. `ready/1` (read-only)
  # and `Tasks.Claim.claim/2` (row-locked) both ride `ready_query/1` — keeping ONE
  # definition is what makes "claim returns exactly what ready would have picked"
  # a property of the code, not a documentation promise.
  #
  # Readiness gating happens on THREE independent axes, all folded into the base
  # `WHERE` so ready/1 and the atomic claim can never disagree:
  #
  #   1. `blocks`-edge gate (task_edges rows) — the authoritative graph store.
  #   2. `content.dependencies` gate — the doc_id list on the task itself. A dep
  #      is satisfied only by a same-scope `done` task; missing/dangling ids fail
  #      CLOSED (treated as unsatisfied). This is a READ-side gate; there is no
  #      write-path materialization of content.dependencies into edges.
  #   3. draft/published TWIN collapse — a `drafts.<id>` shadow row (the fork a
  #      published-task mutate leaves behind) is suppressed while its published
  #      twin exists in scope, so a twinned task yields exactly ONE ready/claimable
  #      row (published-wins, matching `Tasks.Board`/`Content.published_id`).
  #
  # Phase scoping (`maybe_filter_phase`) normalizes the `drafts.` prefix on BOTH
  # sides of the `parent_id` match, the SAME edge `Tasks.Rail` uses, so a child
  # parented at `drafts.phase-x` is still found by a phase-scoped ready for
  # `phase-x` (and vice-versa).

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edge

  @ready_default_limit 50
  @ready_lifecycle_statuses ~w(open blocked)

  def ready(opts \\ []) do
    opts
    |> ready_query()
    |> Repo.all()
  end

  def ready_query(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    dataset = Keyword.get(opts, :dataset)
    phase_id = Keyword.get(opts, :phase_id)
    limit = Keyword.get(opts, :limit, @ready_default_limit)

    base =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        where: fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
        # (1) blocks-edge gate: no outbound `blocks` edge to a non-`done` target.
        #
        # TWIN-EDGE GAP (documented; follow-up filed): `task_edges` FKs reference
        # `documents.id` (a per-row uuid), so a `blocks` edge binds to ONE twin.
        # After twin-collapse (axis 3) the published row is what surfaces, so an
        # edge filed onto the DRAFT twin's uuid does not gate it. The doc_id-based
        # `content.dependencies` gate (axis 2) IS twin-tolerant and is the safe
        # path across twins today; canonicalizing edge endpoints to the published
        # uuid is the real fix (out of scope here).
        where:
          not exists(
            from(e in Edge,
              join: b in Document,
              on: b.id == e.to_id,
              where:
                e.from_id == parent_as(:doc).id and
                  e.kind == "blocks" and
                  fragment("COALESCE(?->>'lifecycle_status', '')", b.content) != "done",
              select: 1
            )
          ),
        # (2) content.dependencies gate: every doc_id in the (jsonb array)
        # `content.dependencies` must resolve to a same-scope task that is
        # `done`. `drafts.` is stripped on both sides so a dep pointing at either
        # twin matches. A dep with NO matching done task — including a dangling
        # id that resolves to nothing — leaves the inner NOT EXISTS true, so the
        # task is excluded (fail CLOSED). A non-array/absent `dependencies` value
        # unnests to zero rows and never gates.
        where:
          fragment(
            """
            NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(
                CASE WHEN jsonb_typeof(?->'dependencies') = 'array'
                     THEN ?->'dependencies'
                     ELSE '[]'::jsonb END
              ) AS dep(id)
              WHERE NOT EXISTS (
                SELECT 1 FROM documents t
                WHERE t.type = 'task'
                  AND t.dataset = ?
                  AND t.workspace_id IS NOT DISTINCT FROM ?
                  AND t.project_id IS NOT DISTINCT FROM ?
                  AND regexp_replace(t.doc_id, '^drafts\\.', '') =
                      regexp_replace(dep.id, '^drafts\\.', '')
                  AND t.content->>'lifecycle_status' = 'done'
              )
            )
            """,
            d.content,
            d.content,
            d.dataset,
            d.workspace_id,
            d.project_id
          ),
        # (3) twin collapse (published-wins): suppress a row when a DISTINCT
        # same-scope task shares its published id (its `drafts.`-stripped doc_id).
        # Only a `drafts.<id>` shadow can match here — the non-prefixed (canonical
        # / published) row's stripped id equals its own doc_id, so the `!=` guard
        # excludes itself and it is never suppressed. Mirrors
        # `Tasks.Board.load_task_docs` collapsing twins to the published card.
        where:
          not exists(
            from(o in Document,
              where:
                o.type == "task" and
                  o.doc_id ==
                    fragment("regexp_replace(?, '^drafts\\.', '')", parent_as(:doc).doc_id) and
                  o.doc_id != parent_as(:doc).doc_id and
                  o.dataset == parent_as(:doc).dataset and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    o.workspace_id,
                    parent_as(:doc).workspace_id
                  ) and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    o.project_id,
                    parent_as(:doc).project_id
                  ),
              select: 1
            )
          ),
        order_by: [
          asc_nulls_last: fragment("(?->>'priority')::int", d.content),
          asc: d.inserted_at
        ],
        limit: ^limit
      )

    base
    |> maybe_filter_dataset(dataset)
    |> maybe_filter_phase(phase_id)
    |> Scope.scope_to_workspace(workspace_id, project_id)
  end

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from([doc: d] in query, where: d.dataset == ^dataset)
  end

  defp maybe_filter_phase(query, nil), do: query

  # Prefix-agnostic parent match — the `drafts.` prefix is stripped from BOTH
  # the stored `content.parent_id` and the requested `phase_id`, the same edge
  # `Tasks.Rail.rail_children/2` uses, so a phase-scoped ready finds children
  # regardless of which twin's id either side carries.
  defp maybe_filter_phase(query, phase_id) when is_binary(phase_id) do
    from([doc: d] in query,
      where:
        fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", ^phase_id)
    )
  end
end
