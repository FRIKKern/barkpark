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
  # WHAT IS **NOT** AN AXIS — `documents.status` (tgw10-bl-drafts-in-ready-pool).
  # There is no `d.status == "published"` predicate anywhere below, and that is a
  # DECISION, not an omission. `bp task create` lands a DRAFT by default, so a
  # status filter here would hide every unpublished task from the queue agents
  # claim from. An UNPAIRED `drafts.<id>` row is therefore admitted AS ITSELF;
  # only a draft with a same-scope published twin is suppressed, by axis 3 above.
  # This matches the LISTING rule (`tasks_controller.do_index/3` carries no status
  # predicate either — docs/setup/TASK-SYSTEM.md, "Draft prefix"), so `ready` and
  # `ls` agree on which twin is the one row. Two consequences a caller must own:
  # a pool census over `ready` must dedupe on the `drafts.`-stripped doc_id, and
  # lifecycle `blocked` rows ARE in the queue (see @ready_lifecycle_statuses).
  # The manifest summary for `task.ready` says all of this in one sentence
  # (Barkpark.Plugins.Tasks, pinned by cli_commands_manifest_test.exs) — if this
  # comment and that sentence ever disagree, the query is the truth.
  #
  # Phase scoping (`maybe_filter_phase`) normalizes the `drafts.` prefix on BOTH
  # sides of the `parent_id` match, the SAME edge `Tasks.Rail` uses, so a child
  # parented at `drafts.phase-x` is still found by a phase-scoped ready for
  # `phase-x` (and vice-versa).

  import Ecto.Query

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.{DependencySatisfaction, Edge, QueueGate, Validation}

  # The ONE dependency-satisfaction predicate, read at COMPILE time out of
  # Tasks.DependencySatisfaction so both gates below are literally the same SQL
  # as `DependencySatisfaction.satisfied?/1` rather than hand-typed neighbours
  # of it. Ecto's `fragment/n` needs a compile-time literal, which is why these
  # are module attributes and not function calls.
  #
  # Axis 1 (the blocks-EDGE gate) used to test `lifecycle_status != 'done'` and
  # NOTHING ELSE, while `Tasks.Claim`/`Tasks.Close` applied the full predicate
  # to the same edges. A blocker that read `done` but carried no record of a
  # close was therefore SATISFIED here and UNSATISFIED there: the queue offered
  # the row and the claim door refused it with `blocked_by_unsatisfied_deps`,
  # which is the loud half of task-814b2d28bdb4b2f5.
  @dep_satisfied_sql DependencySatisfaction.content_sql_fragment()
  @dep_unsatisfied_sql "NOT (" <> @dep_satisfied_sql <> ")"

  # Axis 2's raw SQL, hoisted so its satisfaction clause can be INTERPOLATED
  # from Tasks.DependencySatisfaction instead of typed out a second time. Ecto's
  # `fragment/n` takes only a compile-time literal, and an interpolated heredoc
  # is not one — the attribute is what makes the interpolation legal.
  #
  # Six binds, in order: content, content, shared_only?, workspace_uuid,
  # dataset, project_id. The interpolated predicate names its `done` alias and
  # consumes NO binds, so it cannot shift them.
  @declared_deps_sql """
  NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(
           CASE WHEN jsonb_typeof(?->'dependencies') = 'array'
                THEN ?->'dependencies'
                ELSE '[]'::jsonb END
         ) AS dep(id)
    WHERE 0 = (
      SELECT count(*)
      FROM documents AS done
      WHERE done.type = 'task'
        AND CASE WHEN ?::boolean
                 THEN done.workspace_id IS NULL
                 ELSE done.workspace_id = ? END
        AND #{DependencySatisfaction.sql_fragment("done")}
        AND done.dataset = ?
        AND done.project_id IS NOT DISTINCT FROM ?
        AND regexp_replace(done.doc_id, '^drafts\\.', '') =
            regexp_replace(dep.id, '^drafts\\.', '')
    )
  )
  """

  @ready_default_limit 50
  # Derived at compile time from the ONE claimability source of truth
  # (Validation.claimable_statuses/0 — ~w(open blocked)); never fork a local
  # literal. The base `WHERE` below binds this same list via `IN ^…`.
  @ready_lifecycle_statuses Validation.claimable_statuses()

  @doc """
  The page size `ready/1` applies when the caller names no `:limit`.

  Public because the HTTP layer must be able to REPORT the window it served
  (`page.limit` on the `/v1/tasks/ready` envelope) even when the request carried
  no `?limit=`. Reading it here keeps `@ready_default_limit` the single literal;
  a controller-side copy is the exact drift that made the CLI manifest claim a
  page size the server never had.
  """
  def ready_default_limit, do: @ready_default_limit

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
    # one function. `Content.Scope.scope_to_workspace/3` — applied to the outer
    # query at the end — has owned a `:shared_only` arm since the class fix. The
    # raw-SQL half did not. The atom is TRUTHY, so `&&` fell straight through to
    # `Ecto.UUID.dump!/1`, whose only success clauses take a 36-char string or a
    # 16-byte binary; an atom hits `dump(_), do: :error` and `dump!/1` raises
    # ArgumentError. That is a 500 on exactly the condition the sentinel exists
    # for — no Default workspace seeded — and it takes the ready queue, prime,
    # and claim with it.
    #
    # STILL TRUE AFTER THE CTEs WENT (task-9a2e75098a62cf45). The two
    # `MATERIALIZED` CTEs that used to carry this branch are gone, but the raw
    # seat is not: the `done` probe inside the dependency gate below is still
    # SQL this module writes by hand, and it still spends `shared_only?` and
    # `workspace_uuid`. The branch moved; it was not deleted, and
    # `queue_shared_only_scope_test.exs` still holds it.
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
    # NULL, and `done.workspace_id = NULL` matches nothing. That is today's
    # behaviour and is deliberately not this change's to touch — widening `nil`
    # would blind every caller that legitimately means "everything". (The outer
    # `scope_to_workspace/3` fails CLOSED on nil anyway, so such a read returns
    # no rows whatever this binds.)
    workspace_uuid =
      if shared_only?, do: nil, else: workspace_id && Ecto.UUID.dump!(workspace_id)

    base =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        where: fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
        # THE GHOST GATE (task-052f74f2cac22b76). `lifecycle_status` and
        # `content.disposition` are written by SEPARATE verbs — close writes the
        # lifecycle, stage writes the adjudication — and nothing makes the two
        # atomic. A row can therefore carry `disposition: "closed"`, a
        # `disposition_reason` explaining that the question is settled, and a
        # lifecycle that never moved. Measured on the live ledger: one such row
        # today, and the known control (task-38786b2edab15955) was handed out as
        # a P0 seed ELEVEN DAYS after its fix merged, because the queue only ever
        # read the lifecycle half.
        #
        # WHY THE READ SIDE AND NOT THE WRITE SIDE. The alternative — having the
        # disposition write also advance the lifecycle — makes `bp task stage`
        # able to CLOSE a row as a side effect of adjudicating it, which is a
        # much larger power than that verb should have and is destructive when
        # it is wrong. Excluding the row from the queue is non-destructive: the
        # row keeps every field it had, a human can still read it, claim it by
        # id and reopen it. It stops the harm (work handed out that somebody
        # already settled) without letting an adjudication seal a lifecycle.
        #
        # An ABSENT disposition is not a closed one, so `IS DISTINCT FROM` is
        # required rather than `!=`: on NULL, `!=` yields NULL, the predicate is
        # not TRUE, and every row that never carried a disposition — 5,443 of
        # them — would silently vanish from the queue.
        where: fragment("?->>'disposition' IS DISTINCT FROM 'closed'", d.content),
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
                  fragment(@dep_unsatisfied_sql, b.content, b.content, b.content, b.content),
              select: 1
            )
          ),
        # (2) content.dependencies gate: every doc_id in the (jsonb array)
        # `content.dependencies` must resolve to a same-scope task that is
        # `done`. `drafts.` is stripped on both sides so a dep pointing at either
        # twin matches. A dep with NO match — including a dangling id — fails
        # CLOSED. A non-array/absent value unnests to zero rows and never gates.
        #
        # WHY CORRELATED AND NOT A CTE (task-9a2e75098a62cf45). This gate used to
        # ride TWO `MATERIALIZED` CTEs — `ready_done_tasks` (every done task in
        # the workspace) and `ready_unsatisfied_tasks` (every open/blocked task
        # in the workspace, dependencies unnested and hash-anti-joined to it) —
        # and the outer query then anti-joined the candidate row against the
        # second one. `MATERIALIZED` is a planner FENCE: both CTEs were computed
        # in FULL, over the whole corpus, BEFORE the outer `LIMIT` could discard
        # anything, and the outer anti-join degenerated to a nested loop that
        # rescanned the CTE once per candidate (measured: 1,320,188 rows removed
        # by the join filter on a 12k-task corpus, ~170 ms of a ~320 ms query).
        # That is what made `?limit=1` cost the same as `?limit=40`.
        #
        # The correlated form below is the SAME predicate — "no dependency of
        # THIS row lacks a same-scope done twin" — evaluated per surviving row
        # against `documents_task_ready_dep_idx`.
        #
        # WHY `count(*) = 0` AND NOT `NOT EXISTS` — this is load-bearing, not
        # style. `NOT EXISTS` in a WHERE is FLATTENED by the planner into an
        # anti-join with the `dep` function scan, and a set-returning function
        # is estimated at the default 100 rows, so the planner prices a
        # Materialize-and-rescan of `documents` below a parameterized index
        # probe and takes it. A scalar aggregate subquery cannot be flattened,
        # so the probe stays parameterized by `dep.id` and the equality on the
        # `drafts.`-stripped doc_id stays an Index Cond. Same predicate, and the
        # difference is not marginal: measured on a 12k-task corpus with the
        # index in place, `NOT EXISTS` runs 25 ms on a custom plan and 2.5 s on
        # the GENERIC plan Postgrex's statement cache settles into, while this
        # form is 24-27 ms on both. `bp task ready` is served by long-lived
        # pooled connections; the generic plan is the one that matters.
        #
        # SCOPE EQUIVALENCE, spelled out because it is the part a rewrite loses:
        # the old CTE narrowed CANDIDATES with the raw `CASE WHEN shared_only`
        # arm and the DONE set with `Content.Scope.scope_to_workspace/2`. The
        # outer query is scoped by the SAME `scope_to_workspace/3` (plus dataset,
        # project and phase), so every row this gate can see was already inside
        # the old candidate set — the candidate arm is therefore redundant here
        # and is dropped. The DONE arm is NOT redundant and is reproduced
        # verbatim below, `nil` quirk included: `workspace_uuid` is nil for an
        # unscoped read, `done.workspace_id = NULL` matches nothing, and the old
        # `scope_to_workspace(_, nil)` emitted `where: false` — both yield an
        # empty done set, and the outer query returns no rows either way.
        where:
          fragment(
            @declared_deps_sql,
            d.content,
            d.content,
            ^shared_only?,
            ^workspace_uuid,
            d.dataset,
            d.project_id
          ),
        # (3) twin collapse (published-wins): suppress a row when a DISTINCT
        # same-scope task shares its published id (its `drafts.`-stripped doc_id).
        # Only a `drafts.<id>` shadow can match here — the non-prefixed (canonical
        # / published) row's stripped id equals its own doc_id, so the `!=` guard
        # excludes itself and it is never suppressed. Mirrors
        # `Tasks.Board.load_task_docs` collapsing twins to the published card.
        #
        # The `LIKE 'drafts.%'` conjunct is that same sentence made MECHANICAL,
        # not a second filter: for a non-prefixed doc_id the subquery is
        # provably empty (`o.doc_id = d.doc_id AND o.doc_id <> d.doc_id`), so
        # `NOT (like AND exists)` and a bare `NOT exists` admit exactly the same
        # rows. What changes is cost — `AND` short-circuits, so the correlated
        # index probe now runs only for the shadow rows instead of once per
        # candidate (measured: 3,181 probes → 130 on a 12k-task corpus).
        where:
          not (fragment("? LIKE 'drafts.%'", d.doc_id) and
                 exists(
                   from(o in Document,
                     where:
                       o.type == "task" and
                         o.doc_id ==
                           fragment(
                             "regexp_replace(?, '^drafts\\.', '')",
                             parent_as(:doc).doc_id
                           ) and
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
                 )),
        limit: ^limit,
        offset: ^offset
      )

    base
    |> maybe_collapse_cross_dataset_twins(dataset)
    |> maybe_filter_dataset(dataset)
    |> maybe_filter_phase(phase_id)
    |> Scope.scope_to_workspace(workspace_id, project_id)
    |> apply_order(order)
  end

  # ── Axis 5: CROSS-DATASET twin resolution (task-0084e191d406de96) ──────────
  #
  # THE SAME RULE axis 3 applies inside one dataset, applied ACROSS datasets —
  # and it is not a second rule: it is `Barkpark.Tasks.TwinResolver`'s, stated
  # once in that module's moduledoc and cited from every task door since
  # PR #16474. Rules 1 and 2 pick the row (published spelling and published
  # status win; `dataset` is NEVER a tiebreak); rule 3 REFUSES when more than
  # one row survives at the winning tier and the caller named no dataset.
  #
  # WHY THIS EXISTS. `documents` is unique on `(doc_id, type, dataset_id)`, so
  # one task doc_id may live in two datasets of one workspace+project (eleven
  # such pairs measured live on guerrilla 2026-09-06). Axis 3's collapse
  # requires `o.dataset == d.dataset` BY DESIGN — a dataset is a real tenant
  # boundary and a same-id row in another dataset is not a shadow of this one —
  # so a twinned id contributed TWO rows to ONE ready page, and `bp task next`
  # could claim whichever copy the order happened to reach first. That is the
  # silent-wrong-row read #16474 closed at the by-id doors, one door over.
  #
  # THE MECHANISM. Each row carries the resolver's TIER (@twin_tier_sql):
  # published spelling AND `status: published` = 2, published spelling = 1,
  # `drafts.` twin = 0. A row is suppressed when a row of the same
  # `drafts.`-stripped doc_id, same workspace+project, in a DIFFERENT dataset,
  # ties or beats its tier. Both consequences are the rule:
  #
  #   * a UNIQUE winning tier leaves exactly ONE row — rules 1+2, and no
  #     comparison of dataset STRINGS decides which;
  #   * a TIE at the winning tier suppresses BOTH — rule 3. The queue does not
  #     pick a dataset the caller did not name. The withheld ids are not hidden:
  #     `dataset_ambiguous/1` names each once with the dataset set it spans, and
  #     `GET /v1/tasks/ready` renders that in `page.dataset_ambiguous` — in the
  #     `page` block, NOT in `help[]`, which on this route rides mutation
  #     successes only (axi-s4 R5, pinned by tasks_controller_test.exs).
  #     `?dataset=` is the way through — the same way out the by-id 409 hints at.
  #
  # ACTIVE ONLY WHEN THE CALLER NAMED NO DATASET. `?dataset=` IS the
  # disambiguation, so a dataset-scoped read sees its own dataset's row
  # unchanged and there is nothing left to be ambiguous about.
  #
  # `Tasks.Claim.claim/2` rides this same query, so an ambiguous id is not
  # handed out by `bp task next` either. Deliberate, and it is rule 3 at the
  # write door: `Tasks.claim_by_id/3` already refuses such an id with a 409, and
  # a queue that offered what the claim door refuses would be exactly the
  # ready/claim disagreement this module exists to prevent.
  @twin_tier_sql "CASE WHEN ? NOT LIKE 'drafts.%' AND ? = 'published' THEN 2 " <>
                   "WHEN ? NOT LIKE 'drafts.%' THEN 1 ELSE 0 END"

  defp maybe_collapse_cross_dataset_twins(query, dataset) when is_binary(dataset), do: query

  defp maybe_collapse_cross_dataset_twins(query, nil) do
    from([doc: d] in query, where: not exists(cross_dataset_twin_at_tier(:gte)))
  end

  @doc """
  The task doc_ids axis 5 WITHHELD from a dataset-less ready page, each with the
  dataset set it spans — the LISTING half of `TwinResolver` rule 3.

  A by-id door answers rule 3 with a 409. A ready page cannot: it is a many-row
  answer, and refusing the whole page over one ambiguous id would deny the
  caller the forty-nine rows that are not ambiguous at all. So the refusal is
  scoped to the ROW it is about — the id contributes no row to the page, and
  appears exactly ONCE here, naming the datasets the caller may choose between.

  Returns `[]` whenever the caller named a `:dataset` (nothing is ambiguous
  then), otherwise a doc_id-sorted list of
  `%{doc_id: String.t(), datasets: [String.t()]}`.

  DELIBERATELY CHEAPER THAN `ready_query/1`. This probe carries the IDENTITY
  predicates (type, kind, claimable lifecycle, the ghost-disposition gate) plus
  the scope and phase filters, and NOT the dependency, blocks-edge or queue-gate
  axes: ambiguity is a property of the ID, not of readiness, and a second full
  evaluation of the expensive gates merely to describe the first is the cost the
  correlated rewrite of those gates exists to avoid. It can therefore name an id
  that would ALSO have been gated out for another reason — over-reporting toward
  "look again", the safe direction for a fact whose only action is to name a
  dataset.
  """
  def dataset_ambiguous(opts) do
    case Keyword.get(opts, :dataset) do
      dataset when is_binary(dataset) ->
        []

      _ ->
        opts
        |> dataset_ambiguous_query()
        |> Repo.all()
        |> Enum.group_by(& &1.doc_id, & &1.dataset)
        |> Enum.map(fn {doc_id, datasets} ->
          %{doc_id: doc_id, datasets: datasets |> Enum.uniq() |> Enum.sort()}
        end)
        |> Enum.filter(&(length(&1.datasets) > 1))
        |> Enum.sort_by(& &1.doc_id)
    end
  end

  defp dataset_ambiguous_query(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    phase_id = Keyword.get(opts, :phase_id)

    from(d in Document,
      as: :doc,
      where: d.type == "task",
      where: fragment("?->>'kind'", d.content) == "task",
      where: fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
      where: fragment("?->>'disposition' IS DISTINCT FROM 'closed'", d.content),
      # A sibling in another dataset TIES this row's tier …
      where: exists(cross_dataset_twin_at_tier(:eq)),
      # … and none beats it. Together: this row sits at the winning tier and the
      # winner is not unique — precisely the tie rule 3 refuses to break.
      where: not exists(cross_dataset_twin_at_tier(:gt)),
      select: %{
        doc_id: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
        dataset: d.dataset
      }
    )
    |> maybe_filter_phase(phase_id)
    |> Scope.scope_to_workspace(workspace_id, project_id)
  end

  # The correlated sibling probe. ONE definition, three comparisons: `:gte` is
  # the suppression axis ("someone else ties or beats me"), `:eq`/`:gt` are the
  # two halves of "I sit at the winning tier and share it". Written once so the
  # page's suppression and the page's explanation cannot drift apart — a forked
  # copy of a scope predicate is precisely how this class keeps coming back
  # (see the `Media.Delivery.Search` note above).
  defp cross_dataset_twin_at_tier(op) do
    from(o in Document, where: ^cross_dataset_twin_condition(op), select: 1)
  end

  defp cross_dataset_twin_condition(:gte) do
    dynamic(
      [o],
      ^cross_dataset_twin_base() and ^twin_tier_dynamic(:gte)
    )
  end

  defp cross_dataset_twin_condition(:eq) do
    dynamic(
      [o],
      ^cross_dataset_twin_base() and ^twin_tier_dynamic(:eq)
    )
  end

  defp cross_dataset_twin_condition(:gt) do
    dynamic(
      [o],
      ^cross_dataset_twin_base() and ^twin_tier_dynamic(:gt)
    )
  end

  defp twin_tier_dynamic(:gte) do
    dynamic(
      [o],
      fragment(@twin_tier_sql, o.doc_id, o.status, o.doc_id) >=
        fragment(
          @twin_tier_sql,
          parent_as(:doc).doc_id,
          parent_as(:doc).status,
          parent_as(:doc).doc_id
        )
    )
  end

  defp twin_tier_dynamic(:eq) do
    dynamic(
      [o],
      fragment(@twin_tier_sql, o.doc_id, o.status, o.doc_id) ==
        fragment(
          @twin_tier_sql,
          parent_as(:doc).doc_id,
          parent_as(:doc).status,
          parent_as(:doc).doc_id
        )
    )
  end

  defp twin_tier_dynamic(:gt) do
    dynamic(
      [o],
      fragment(@twin_tier_sql, o.doc_id, o.status, o.doc_id) >
        fragment(
          @twin_tier_sql,
          parent_as(:doc).doc_id,
          parent_as(:doc).status,
          parent_as(:doc).doc_id
        )
    )
  end

  # SAME id (`drafts.`-stripped), SAME workspace+project, DIFFERENT dataset.
  #
  # THE `regexp_replace` ON THE INNER COLUMN IS THE SARGABLE FORM HERE, and it is
  # counter-intuitive enough to be worth the lines, because the obvious review
  # note is "a function on the inner column forbids an index — rewrite it as an
  # equality on the bare column". That note is right in general and WRONG on this
  # table: migration 20260901180000 built `documents_task_ready_dep_idx`, a
  # PARTIAL EXPRESSION index on exactly
  #
  #     (regexp_replace(doc_id, '^drafts\\.', ''), workspace_id,
  #      content->>'lifecycle_status', dataset, project_id)  WHERE type = 'task'
  #
  # for the dependency gate's identical probe. This predicate is therefore an
  # `Index Cond` on that index, and the four trailing columns resolve most of the
  # surrounding scope filter inside the index instead of on the heap. Axis 3's
  # collapse above is the same shape for the same reason.
  #
  # MEASURED, not assumed — 6,002 candidate rows, three runs of each form on one
  # test DB, `EXPLAIN (ANALYZE, BUFFERS)` over `Repo.to_sql(:all, ready_query/1)`:
  #
  #   * THIS form → `Index Scan using documents_task_ready_dep_idx on documents sd0`,
  #     `Index Cond: (regexp_replace(doc_id, '^drafts\\.', '') = regexp_replace(d0.doc_id, ...))`
  #     — 118 / 129 / 136 ms.
  #   * The "sargable" rewrite (`o.doc_id = strip(parent) OR o.doc_id =
  #     'drafts.' || strip(parent)`) → also index-driven, a `BitmapOr` of two
  #     `documents_doc_id_type_dataset_id_index` probes — but 212 / 226 / 233 ms,
  #     because that index carries NONE of the scope columns and every candidate
  #     then pays a heap recheck (`Heap Blocks: exact=6002`).
  #
  # 1.8x slower for the same rows. 20260901180000's moduledoc states the general
  # law this is one instance of: re-costing this probe onto a different index
  # measured 3.2 s there. Do NOT "fix" the function call away without re-running
  # that comparison and quoting both plans.
  defp cross_dataset_twin_base do
    dynamic(
      [o],
      o.type == "task" and
        fragment("regexp_replace(?, '^drafts\\.', '')", o.doc_id) ==
          fragment("regexp_replace(?, '^drafts\\.', '')", parent_as(:doc).doc_id) and
        o.dataset != parent_as(:doc).dataset and
        fragment("? IS NOT DISTINCT FROM ?", o.workspace_id, parent_as(:doc).workspace_id) and
        fragment("? IS NOT DISTINCT FROM ?", o.project_id, parent_as(:doc).project_id)
    )
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
