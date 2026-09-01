defmodule Barkpark.Tasks.Queue do
  @moduledoc false
  # The dependency-aware, phase-scoped ready-queue query. `ready/1` (read-only)
  # and `Tasks.Claim.claim/2` (row-locked) both ride `ready_query/1` — keeping ONE
  # definition is what makes "claim returns exactly what ready would have picked"
  # a property of the code, not a documentation promise.
  #
  # Readiness gating happens on FOUR independent axes, all folded into the base
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
  #   4. queue_gate — only a missing/null legacy gate or the exact executable-v1
  #      shape is admitted. Non-executable and malformed persisted gates fail closed.
  #
  # Phase scoping (`maybe_filter_phase`) normalizes the `drafts.` prefix on BOTH
  # sides of the `parent_id` match, the SAME edge `Tasks.Rail` uses, so a child
  # parented at `drafts.phase-x` is still found by a phase-scoped ready for
  # `phase-x` (and vice-versa).

  import Ecto.Query

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Edge, QueueGate, Validation}

  @ready_default_limit 50
  # Derived at compile time from the ONE claimability source of truth
  # (Validation.claimable_statuses/0 — ~w(open blocked)); never fork a local
  # literal. The raw-SQL CTE below binds this same list via `= ANY(?)`.
  @ready_lifecycle_statuses Validation.claimable_statuses()

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
    offset = Keyword.get(opts, :offset, 0)
    order = Keyword.get(opts, :order, :compatibility)

    # ── The empty-scope sentinel at a RAW seat (task-3e2a70930c6df723) ──────
    #
    # `:shared_only` is what `BarkparkWeb.ScopeHelpers.scope_opts/1` emits when
    # a REQUEST resolved no workspace. It means the SHARED layer
    # (`workspace_id IS NULL`), never "every tenant". THREE doors arrive here
    # carrying it, because all three ride `ready_query/1`:
    # `GET /v1/tasks/ready`, `GET /v1/tasks/prime`, and `Tasks.Claim.claim/2`.
    #
    # THE FORK THIS CLOSES. `workspace_id` is handed to TWO interpreters in this
    # one function. `Content.Scope.scope_to_workspace/3` — applied to
    # `done_tasks` just below and to the outer query at the end — has owned a
    # `:shared_only` arm since the class fix. The raw-SQL CTE did not. The atom
    # is TRUTHY, so `&&` fell straight through to `Ecto.UUID.dump!/1`, whose
    # only success clauses take a 36-char string or a 16-byte binary; an atom
    # hits `dump(_), do: :error` and `dump!/1` raises ArgumentError. That is a
    # 500 on exactly the condition the sentinel exists for — no Default
    # workspace seeded — and it takes the ready queue, prime, and claim with it.
    #
    # THE SAME SHAPE, FOUND TWICE. `Media.Delivery.Search` was corrected at
    # `join_scope_workspace/3` and missed at `scope_fragments/2` 340 lines below
    # IN THE SAME MODULE (PR #14669). Both misses were found by grepping a
    # FUNCTION NAME; the defect is keyed on the GUARD SHAPE — a value from
    # `scope_opts/1` reaching a UUID-dumping or `is_binary`-guarded seam that
    # bypasses `Content.Scope`. That is why the predicate below stays ONE SQL
    # body with one branch rather than a second copy of the statement: a forked
    # copy is precisely how this class keeps coming back.
    shared_only? = workspace_id == :shared_only

    # `nil` is left EXACTLY as it was. It is the explicit-global read; it binds
    # NULL, and `candidate.workspace_id = NULL` matches nothing. That is today's
    # behaviour and is deliberately not this change's to touch — widening `nil`
    # would blind every caller that legitimately means "everything".
    workspace_uuid =
      if shared_only?, do: nil, else: workspace_id && Ecto.UUID.dump!(workspace_id)

    done_tasks =
      Document
      |> Scope.scope_to_workspace(workspace_id)
      |> then(fn query ->
        from(t in query,
          where: t.type == "task",
          where: fragment("?->>'lifecycle_status'", t.content) == "done",
          distinct: [
            t.dataset,
            t.project_id,
            fragment("regexp_replace(?, '^drafts\\.', '')", t.doc_id)
          ],
          select: %{
            dataset: t.dataset,
            project_id: t.project_id,
            normalized_id: fragment("regexp_replace(?, '^drafts\\.', '')", t.doc_id)
          }
        )
      end)

    unsatisfied_tasks =
      from(
        u in fragment(
          """
          SELECT DISTINCT candidate.id
          FROM documents AS candidate
          CROSS JOIN LATERAL jsonb_array_elements_text(
            CASE WHEN jsonb_typeof(candidate.content->'dependencies') = 'array'
                 THEN candidate.content->'dependencies'
                 ELSE '[]'::jsonb END
          ) AS dep(id)
          LEFT JOIN ready_done_tasks AS done
            ON done.dataset = candidate.dataset
           AND done.project_id IS NOT DISTINCT FROM candidate.project_id
           AND done.normalized_id = regexp_replace(dep.id, '^drafts\\.', '')
          WHERE candidate.type = 'task'
            AND CASE WHEN ?::boolean
                     THEN candidate.workspace_id IS NULL
                     ELSE candidate.workspace_id = ? END
            AND candidate.content->>'kind' = 'task'
            AND candidate.content->>'lifecycle_status' = ANY(?)
            AND done.normalized_id IS NULL
          """,
          ^shared_only?,
          ^workspace_uuid,
          ^@ready_lifecycle_statuses
        ),
        select: %{id: field(u, :id)}
      )

    base =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        where: fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
        where: ^QueueGate.executable_query(),
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
        # twin matches. `ready_unsatisfied_tasks` expands dependencies once and
        # hash-joins them to the materialized done set; a dep with NO match —
        # including a dangling id — records the candidate here, so this outer
        # anti-filter excludes it (fail CLOSED). A non-array/absent value unnests
        # to zero rows and never gates.
        where:
          fragment(
            """
            NOT EXISTS (SELECT 1 FROM ready_unsatisfied_tasks AS u WHERE u.id = ?)
            """,
            d.id
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
        limit: ^limit,
        offset: ^offset
      )

    base
    |> with_cte("ready_done_tasks", as: ^done_tasks, materialized: true)
    |> with_cte("ready_unsatisfied_tasks", as: ^unsatisfied_tasks, materialized: true)
    |> maybe_filter_dataset(dataset)
    |> maybe_filter_phase(phase_id)
    |> Scope.scope_to_workspace(workspace_id, project_id)
    |> apply_order(order)
  end

  defp apply_order(query, :closure_nearest) do
    from([doc: d] in query,
      order_by: [
        asc:
          fragment(
            """
            CASE WHEN jsonb_typeof(?->'acceptance_criteria') = 'array'
                 THEN (SELECT count(*) FROM jsonb_array_elements(?->'acceptance_criteria') AS criterion
                       WHERE criterion->'met' IS DISTINCT FROM 'true'::jsonb)
                 ELSE 0 END
            """,
            d.content,
            d.content
          ),
        asc: d.inserted_at,
        asc: d.doc_id
      ]
    )
  end

  defp apply_order(query, order) when order in [nil, :compatibility] do
    from([doc: d] in query,
      order_by: [
        asc_nulls_last: fragment("(?->>'priority')::int", d.content),
        asc: d.inserted_at,
        asc: d.id
      ]
    )
  end

  defp apply_order(_query, order),
    do: raise(ArgumentError, "unsupported ready order: #{inspect(order)}")

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
