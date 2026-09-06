defmodule BarkparkWeb.TasksController do
  @moduledoc """
  W7b step 1 (paper-rx0 / w7-07a) — HTTP surface for the `bp task` CLI.

  Sixteen endpoints, all bearer-token gated via the existing `:api` +
  `:require_token` pipelines in `router.ex`:

    * `GET    /v1/tasks`                    — `Tasks` index (filters: kind/lifecycle_status/phase_id/parent/label,
      flat or under the `filter[<key>]=` container; an unsupported filter key
      is a 400, never a silently unfiltered page)
    * `GET    /v1/tasks/ready`              — `Tasks.ready/1` (filter container: `parent`/`parent_id`/`phase_id`,
      all naming the ONE parent axis `ready_query/1` has; any other key is a 400).
      `?dataset=` narrows the page to ONE dataset; with none named the page spans EVERY
      dataset in the caller's workspace/project scope and SAYS so (`page.dataset`,
      `page.datasets`, `page.dataset_scope`), and a doc_id living in more than one of them
      is withheld and named once in `page.dataset_ambiguous` (TwinResolver rule 3)
    * `GET    /v1/tasks/prime`              — one-call agent rehydration (in_progress + ready head + recent events + counts;
      filter container: `worker` only)
    * `GET    /v1/tasks/:doc_id`            — single-task fetch (w7-08)
    * `POST   /v1/tasks/claim`              — `Tasks.claim/2` (queue-based)
    * `POST   /v1/tasks/:doc_id/claim`      — `Tasks.claim_by_id/3` (targeted, w7-08)
    * `POST   /v1/tasks/:doc_id/close`      — `Tasks.close/3`
    * `POST   /v1/tasks/:doc_id/release`    — `Tasks.release/3` (voluntary unclaim)
    * `POST   /v1/tasks/:doc_id/stamp`      — `Tasks.stamp/3` (criterion-level mid-claim evidence)
    * `POST   /v1/tasks/:doc_id/pulse`      — `Tasks.pulse_by_id/3` (now-line + lease renewal)
    * `GET    /v1/tasks/:doc_id/edges`      — `Tasks.dependencies/2` + `dependents/2`
    * `POST   /v1/tasks/edges`              — `Tasks.add_dep/3`
    * `POST   /v1/tasks/:doc_id/labels`     — `Tasks.relabel_by_id/3`
    * `POST   /v1/tasks/:doc_id/papers`     — `Tasks.update_paper_refs_by_id/3`
    * `POST   /v1/tasks/:doc_id/move`       — `Tasks.move_by_id/2` (rail-l3 re-parent)
    * `POST   /v1/tasks/:doc_id/stage`      — `Tasks.stage/3` (sanctioned thought-state transition)
    * `POST   /v1/tasks/:doc_id/landed`     — `Tasks.record_landing/2` (NON-holder landing mark: no worker_id, no epoch)

  `GET /v1/tasks/events` (keyset replay) honours NO `filter[...]` key — `since`
  and `limit` are its only narrowings, and a filter key is a 400 naming it. The
  four whitelists live in one place: `TasksController.Params` `@route_filters`.

  ## Shape contract

  All read responses carry a `doc` (or `docs`) map with `id`, `title`,
  `status`, `type`, `lifecycle_status`, `kind`, `content`, `priority`,
  `assignee`, `dependencies`, and related task fields. The `bp task` CLI
  consumes this shape. See `render_doc/1`.

  ## Paging past the window: the keyset cursor on `GET /v1/tasks`
  ## (bl-api-tasks-stable-cursor)

  The index serves a WINDOW, not the corpus: `limit` rows (default 100, capped
  at `Params.index_limit_cap/0` = 1000) ordered `desc: updated_at, desc: id`.
  Every write to any task re-stamps `updated_at` and rotates that row to the
  head, so the window's tail falls off under ordinary traffic. A reader that
  walked the window and asked "is task X still here?" got ONE answer — absent —
  for two different facts: X was CLOSED, or X was pushed past row 1000 by a
  thousand unrelated touches. **Absence was not decidable.** The CLI lane's
  `internal/taskboard/merge.go` carries a client-side heuristic built on that
  ambiguity (PR #14251); this is the server-side fix it was standing in for.

  `?cursor=` is an OPT-IN keyset (seek) cursor over the tuple the ordering
  already uses — `(updated_at, id)`, or `(inserted_at, id)` on the `parent=`
  rail. Pass `?cursor=` (empty) to start at the head and receive
  `page.next_cursor`; pass that token back to get the next page. Paging is
  bounded by a WHERE clause, not by OFFSET, so a caller can walk **past the
  cap** to the end of the corpus: a row that rotated out of page 1 is reached
  on a later page, and a row that went terminal is reached and renders
  `lifecycle_status: "done"`. Absence now means "not in the corpus".

  ADDITIVE. `page.next_cursor` appears only when the caller spelled `?cursor=`
  at all, so a request that names no cursor gets the pre-change envelope key
  for key. `cursor` and a non-zero `offset` together are a 400 — they are two
  different paging models and silently honouring one would page from a place
  the caller did not ask for. A malformed or wrong-ordering cursor is a 400
  too, never a silent restart from the head (which reads exactly like a
  finished walk).

  THE REJECTED ALTERNATIVE was a closed-since delta feed
  (`?closed_since=<ts>`, terminal transitions only). Cheap, but a SECOND source
  of truth about task state with its own window and drift, and still blind to a
  row that rotated out WITHOUT closing (moved, re-parented, relabelled).
  `GET /v1/tasks/events` already answers "what changed since". Making the ONE
  list route complete beat adding a second incomplete one.

  Full rationale, including the honest limit of a keyset over a MUTABLE key:
  `TasksController.Params`, the cursor section.

  ## Why the doc_id is a URL segment for close but a body field for claim

  Claim's contract is "pick the next ready row" — there is no specific row
  the caller is naming. Close's contract is "terminate THIS row I just held
  the claim on" — the caller names it. The route shapes mirror the verb.
  """

  use BarkparkWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks}
  alias Barkpark.Tasks.Fleet
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Document
  alias Barkpark.Content.Graph
  alias Barkpark.Tasks.Edge
  alias Barkpark.Tasks.QueueGate
  alias Barkpark.Tasks.TwinResolver
  alias Barkpark.Tasks.Validation
  alias BarkparkWeb.AnonPerspective
  alias BarkparkWeb.ReadPerspective

  # The value set `GET /v1/graph/:id` declares in `Barkpark.Plugins.Capabilities`
  # ("published (default) | drafts (live extract over the drafts corpus)") and
  # therefore in `docs/openapi.json`. NARROWER than the document reads on
  # purpose: `raw` is not offered on this surface.
  @graph_perspectives ["published", "drafts"]
  alias BarkparkWeb.TasksController.Params

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  # ─── GET /v1/tasks/ready ────────────────────────────────────────────────

  # task-e1b74c19174cb2c1: the `filter[...]` container is PARSED here too, and
  # fail-CLOSED. Before this, `ready` read only its flat params — a caller who
  # learned `filter[parent_id]` on `GET /v1/tasks` (where #12780 made it work)
  # and carried it one route over got a 200 carrying the WHOLE ready queue.
  # Measured on guerrilla 2026-09-01: 200 rows, 47 distinct parents, HTTP 200,
  # against 18 rows / 1 parent for the honoured `?phase_id=` spelling. This is
  # the queue agents CLAIM from, so that false confirmation is one step from a
  # write against a foreign epic.
  #
  # `filter[parent]` / `filter[parent_id]` / `filter[phase_id]` all name the ONE
  # parent axis `ready_query/1` has; every other key is a 400 that names it (see
  # `Params` for why kind/lifecycle_status/type/label cannot be honoured here).
  def ready(conn, params) do
    with {:ok, filters} <- Params.parse_route_filters(params, :ready),
         {:ok, phase_id} <- Params.ready_phase_id(params, filters),
         {:ok, order} <- Params.parse_ready_order(params["order"]) do
      # The ready queue was ALREADY paged by default (Queue's 50) — it is the
      # index, not this route, that shipped default == cap. Resolving the
      # default HERE instead of letting `put_opt` drop a nil and Queue apply it
      # downstream changes no query: the same number reaches the same `LIMIT`.
      # It changes what the ROUTE can say — `page.limit` below is now the limit
      # the caller actually got, on ready exactly as on index, instead of being
      # unknowable to the renderer whenever `?limit=` was absent. The literal
      # stays in Queue (`ready_default_limit/0`); never fork it here.
      limit = Params.parse_limit(params["limit"], Tasks.Queue.ready_default_limit(), 1000)
      offset = Params.parse_offset(params["offset"])

      # `?dataset=` — HONOURED here since task-0084e191d406de96; it was parsed
      # nowhere and `Queue.maybe_filter_dataset/2` no-opped on the nil, so a
      # ready page for `?dataset=aker-brygge` and one for `?dataset=production`
      # were the SAME 1000 rows (measured live on guerrilla 2026-09-06). Read
      # exactly like `request_dataset/1` EXCEPT for its default: there is none.
      # A ready page with no dataset named spans every dataset in the caller's
      # workspace/project scope — defaulting to "production" here would silently
      # hide another dataset's claimable work from the queue agents work from,
      # which is a bigger change than this row is allowed to make. What changes
      # is that the span is now STATED (`page.dataset*` below) instead of being
      # an unstated global.
      dataset = ready_dataset_param(params)

      opts =
        []
        |> Params.put_opt(:phase_id, phase_id)
        |> Params.put_opt(:dataset, dataset)
        |> Params.put_opt(:limit, limit)
        |> Params.put_opt(:offset, offset)
        |> Params.put_opt(:order, order)
        |> Keyword.merge(scope_opts(conn))

      docs = Tasks.ready(opts)

      body =
        docs
        |> task_list_response(conn, params, limit: limit, offset: offset)
        |> put_ready_dataset_scope(docs, dataset, Tasks.dataset_ambiguous(opts))

      json(conn, body)
    else
      {:error, :invalid_ready_order} ->
        bad_request(conn, "order must be closure_nearest when set")

      {:error, reason} ->
        invalid_filter(conn, reason)
    end
  end

  # axi-w2-s2: the shared list envelope — cards in the requested view, plus
  # the ONE top-level truncation-honesty help[] line whenever a brief card
  # lost bytes to the …-caps (charter law 2; full view never truncates, never
  # carries the line).
  # PDS-D502: the help[] line is computed from the SEALED docs the caller
  # actually received — the seal is hoisted here (out of render_task_list/3,
  # which has exactly ONE caller) so the claim about the payload and the
  # payload are derived from the SAME list. Sealing first is safe: Params.seal/3
  # rewrites only `content`, and the count helpers read only id/doc_id.
  #
  # `page` (task-e2f5ecca0be9a6d1) is the truncation-VISIBILITY half of the
  # default-page-size fix. Shrinking the index default from 1000 to 100 without
  # it would trade one defect for a worse one: a caller who used to get every
  # row would silently get a hundred, and a short answer that reads as a
  # complete one is the failure mode this repo already paid for twice (the
  # `--all` shift guard, the unreadable-page refusal). So every list response
  # now states the window it served — `limit`, `offset`, `returned` and
  # `has_more` — and `has_more` is the CHEAP predicate `returned == limit`, not
  # a `COUNT(*)`: a second full scan to describe the first would re-earn the
  # very cost this change exists to remove. It can therefore say `true` on an
  # exactly-full last page; that errs toward "look again", the safe direction.
  # ADDITIVE ONLY — `ok`, `docs` and `help` keep their names and shapes, so the
  # SDK, the Studio and the taskboard read byte-identical fields.
  # `?dataset=` on the ready route. Fails SOFT on a non-binary spelling
  # (`?dataset[]=production`), like `request_dataset/1` — a malformed selector
  # must not 500 a queue read — but carries NO default: see `ready/2`.
  defp ready_dataset_param(params) do
    case params["dataset"] do
      dataset when is_binary(dataset) -> dataset
      _ -> nil
    end
  end

  # WHAT THIS PAGE SPANS, SAID OUT LOUD (task-0084e191d406de96 C0/C1).
  #
  # Two facts a ready page never carried, both about datasets:
  #
  #   * `page.dataset` / `page.datasets` / `page.dataset_scope` — the dataset the
  #     caller NAMED (nil when none) and the datasets this page actually spans.
  #     A silently-global default is the thing the C0 criterion forbids; the
  #     default is unchanged, it is now STATED.
  #   * `page.dataset_ambiguous` — every doc_id withheld because it lives in
  #     more than one dataset of this scope, listed ONCE with the dataset set it
  #     spans. That is `Barkpark.Tasks.TwinResolver` rule 3 at a listing: the
  #     by-id doors answer it with a 409 naming both datasets, and a listing
  #     cannot (one ambiguous id must not deny the caller the other forty-nine
  #     rows), so the refusal is scoped to the row and named instead of hidden.
  #
  # IN `page`, NOT IN `help[]`. A read envelope carries no `help[]` on this
  # route by rule (axi-s4 R5 — "help[] rides ONLY mutation successes", pinned by
  # tasks_controller_test.exs), and the brief-truncation line is that rule's one
  # standing exception, not an opening. A dataset fact a caller ACTS on belongs
  # in the structured block it can read without string-matching anyway.
  #
  # READY ONLY, deliberately: `task_list_response/4`'s other caller is the index,
  # which is not twin-collapsed and whose envelope stays byte-identical.
  defp put_ready_dataset_scope(body, docs, dataset, ambiguous) do
    spans = docs |> Enum.map(& &1.dataset) |> Enum.uniq() |> Enum.sort()

    page =
      body
      |> Map.fetch!(:page)
      |> Map.merge(%{
        dataset: dataset,
        datasets: spans,
        dataset_scope: if(dataset, do: "named", else: "all-datasets-in-scope"),
        dataset_ambiguous: ambiguous
      })

    Map.put(body, :page, page)
  end

  defp task_list_response(docs, conn, params, page_opts) do
    docs = seal_docs(docs, conn)

    %{ok: true, docs: render_task_list(docs, conn, params)}
    |> Params.maybe_put_brief_truncation_help(docs, Params.parse_view(params["view"]))
    |> Map.put(:page, page_block(docs, page_opts))
  end

  # `page` + the OPT-IN `next_cursor`. The key is added only when the caller
  # spelled `?cursor=` at all, so every pre-cursor caller reads a byte-identical
  # envelope. It is minted from the SEALED docs this response actually renders
  # (sealing rewrites `content` only — `id` and the timestamps survive), and it
  # is `nil` on a short page: `returned < limit` PROVES the walk is finished, so
  # a token there would invite one more round-trip to learn nothing.
  defp page_block(docs, page_opts) do
    meta = Params.page_meta(docs, page_opts)

    if Keyword.get(page_opts, :cursor_requested?, false) do
      next =
        if meta.has_more,
          do: Params.next_cursor(docs, Keyword.fetch!(page_opts, :cursor_axis)),
          else: nil

      Map.put(meta, :next_cursor, next)
    else
      meta
    end
  end

  # axi-s1 (R1/R2): render a list of already-tenancy-scoped task docs in the
  # caller's requested view. `?view=brief` → the brief v2 cards
  # (child_count via ONE batched grouped query, no content echo, no work
  # digests, the nine diet cuts); absent/unknown view → the full bd-compatible
  # shape with edge counts (the server default STAYS full — SDK/Studio/
  # taskboard untouched).
  # The docs arrive ALREADY sealed (field-visibility seal, fail-closed) — the
  # seal lives in task_list_response/4, this function's only caller, so the
  # truncation-honesty help[] line sees exactly what is rendered here.
  defp render_task_list(docs, conn, params) do
    case Params.parse_view(params["view"]) do
      :brief ->
        child_counts = Params.batch_child_counts(docs, scope_opts(conn))
        Enum.map(docs, &Params.render_brief(&1, child_counts))

      :full ->
        counts = Params.batch_edge_counts(docs)
        # task-3e0eda896a247776: the SAME batched grouped query the brief card
        # runs — the full card used to omit `child_count` entirely, so the
        # DEFAULT view of the ledger answered "no children" for every epic root.
        child_counts = Params.batch_child_counts(docs, scope_opts(conn))
        Enum.map(docs, &Params.render_doc_with_counts(&1, counts, child_counts))
    end
  end

  # ─── GET /v1/tasks/prime ────────────────────────────────────────────────
  # One-call agent rehydration. After compaction / a fresh session, an agent
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
  #
  # task-e1b74c19174cb2c1: `filter[...]` is fail-CLOSED here too. `filter[worker]`
  # is the ONE honoured key (the flat `?worker=` narrowing, in bracket spelling);
  # everything else 400s naming the key. A parent axis is deliberately refused:
  # prime answers with FOUR slices and only its ready head could take one, so
  # narrowing a quarter of the response would be a NEW false confirmation of the
  # same shape. Measured pre-fix on guerrilla 2026-09-01: `?filter[worker]=lead-cli`
  # → 200 with `worker: null` and all 28 live claims; `?worker=lead-cli` → 4.
  def prime(conn, params) do
    with {:ok, filters} <- Params.parse_route_filters(params, :prime),
         {:ok, worker} <- Params.prime_worker(params, filters),
         {:ok, order} <- Params.parse_ready_order(params["order"]) do
      scope = scope_opts(conn)
      limit = params["limit"] |> Params.parse_int(10) |> min(100) |> max(1)
      view = Params.parse_view(params["view"])

      %{in_progress: in_progress, recent_events: events, counts: lifecycle_counts} =
        Tasks.prime([worker: worker, limit: limit] ++ scope)

      ready = Tasks.ready([limit: limit] |> Params.put_opt(:order, order) |> Kernel.++(scope))

      # axi-s1: card render in the requested view — brief cards batch ONE
      # child-count query over the union; full keeps the historical edge-count
      # shape. Brief prime also trims recent_events to 5 rows (full keeps the
      # limit default of 10) — orientation, not replay; required for the ≤5 KB
      # brief-prime target (charter decision 12).
      # Field-visibility seal (fail-closed): render the CARDS off content-redacted
      # docs. The raw `in_progress` is kept for rails/notices below (they read
      # only parent_id/claim — never carriers of per-field visibility).
      sealed_in_progress = seal_docs(in_progress, conn)
      sealed_ready = seal_docs(ready, conn)

      {in_progress_cards, ready_cards} =
        case view do
          :brief ->
            child_counts = Params.batch_child_counts(sealed_in_progress ++ sealed_ready, scope)

            {Enum.map(sealed_in_progress, &Params.render_brief(&1, child_counts)),
             Enum.map(sealed_ready, &Params.render_brief(&1, child_counts))}

          :full ->
            counts = Params.batch_edge_counts(sealed_in_progress ++ sealed_ready)
            child_counts = Params.batch_child_counts(sealed_in_progress ++ sealed_ready, scope)

            render = &Params.render_doc_with_counts(&1, counts, child_counts)

            {Enum.map(sealed_in_progress, render), Enum.map(sealed_ready, render)}
        end

      events = if view == :brief, do: Enum.take(events, 5), else: events

      # rail-l1: rehydrate the worker's rail-awareness — a rails map keyed by each
      # distinct parent of its in-progress claims (rail_rev per rail, so a burst
      # agent can diff after compaction) + blocked_while_claimed notices for any
      # claim a second actor has since blocked.
      base =
        %{
          ok: true,
          worker: worker,
          in_progress: in_progress_cards,
          ready: ready_cards,
          recent_events: events,
          counts: lifecycle_counts,
          rails: prime_rails(in_progress, conn)
        }
        # axi-w2-s2: prime inherits the brief truncation-honesty help[] line —
        # checked over BOTH card slices (charter law 2). PDS-D502: the SEALED
        # lists, so the line describes what the caller received.
        |> Params.maybe_put_brief_truncation_help(sealed_in_progress ++ sealed_ready, view)

      json(conn, maybe_put_notices(base, prime_notices(in_progress)))
    else
      {:error, :invalid_ready_order} ->
        bad_request(conn, "order must be closure_nearest when set")

      {:error, reason} ->
        invalid_filter(conn, reason)
    end
  end

  # ─── GET /v1/tasks/events ───────────────────────────────────────────────
  # The task-events feed — a keyset replay over the `mutation_events` backlog
  # (`Barkpark.Tasks.Events`). ONE event stream every surface polls: pass the
  # last `id` you saw as `?since=` and get every task mutation after it, in
  # commit order (id ASC). A THIN projection over the existing table — no new
  # store, no migration (D10). Poll fallback for the chat/statusline/deck/TUI;
  # SSE is a later wave.
  #
  # NOTE: this action is route-mounted ABOVE `/tasks/:doc_id` (see
  # `Barkpark.Plugins.Tasks.register_routes/1`, the prime precedent) so
  # `/v1/tasks/events` never resolves as `:doc_id = "events"`.
  #
  # Response: `{ok, events: [%{id, event, doc_id, rev, at}], cursor, has_more}`.
  # `cursor` is the id to resume from on the next poll (the last event's id, or
  # the caller's own `since` when the page was empty); `has_more` is true when a
  # full page came back, so the caller polls again immediately instead of
  # waiting for the next tick.
  #
  # task-e1b74c19174cb2c1: this feed honours NO `filter[...]` key — its rows are
  # `mutation_events`, not tasks, so no task filter key exists on a row and
  # reaching one would need the join to `documents` this module deliberately
  # refuses. `since` (the keyset cursor) and `limit` are the only narrowings.
  # A `filter[...]` is therefore a 400 that names the key, never the pre-fix 200
  # carrying an unnarrowed page (measured on guerrilla 2026-09-01:
  # `?filter[doc_id]=task-e1b74c19174cb2c1&limit=5` → 5 rows, 5 distinct doc_ids).
  #
  # The filter gate is folded INTO this function rather than wrapping an
  # extracted private body: the PDS receipt census keys its register on the
  # function that emits each success receipt, so moving the `json/2` call into a
  # helper would orphan this action's register row and leave the new emitter
  # unjudged. (The prose here deliberately does not spell the two-word literal
  # that census greps for — a comment is not a receipt, and spelling it would
  # move the phantom count.)
  def events(conn, params) do
    with {:ok, _no_filters} <- Params.parse_route_filters(params, :events) do
      dataset = request_dataset(conn)
      since = Params.parse_int(params["since"], 0)

      limit =
        Tasks.Events.page_limit(Params.parse_int(params["limit"], Tasks.Events.default_limit()))

      workspace_id = Keyword.get(scope_opts(conn), :workspace_id)

      rows =
        Tasks.Events.replay_since(dataset, since, limit: limit, workspace_id: workspace_id)

      cursor =
        case rows do
          [] -> max(since, 0)
          _ -> List.last(rows).id
        end

      json(conn, %{ok: true, events: rows, cursor: cursor, has_more: length(rows) == limit})
    else
      {:error, reason} -> invalid_filter(conn, reason)
    end
  end

  # ─── GET /v1/tasks ──────────────────────────────────────────────────────
  # w7-08c (paper-y1c): list-all endpoint. Returns every task doc in the
  # caller's tenant, optionally narrowed by `kind`, `lifecycle_status`, or
  # `phase_id` (parent match). Everything is a task — goals/phases/events are
  # gone as types. Backs the `bp task` list family and replaces the previous
  # "ready --limit 1000 then client-side filter" path (which lost in-progress
  # + closed rows).
  #
  # Why server-side filtering: client-side filtering only saw the ready slice
  # (no in_progress / done / phases / goals) and wasted bandwidth.

  def index(conn, params) do
    # gr-bl-tasks-route-parent-filter-ignored: the `filter[...]` container is
    # PARSED before anything else and fail-CLOSED. Before this, `filter[parent_id]`
    # (the spelling the data-query surface uses, and the one GR126 prescribes)
    # was never read: the response was a 200 carrying the UNFILTERED page — a
    # false confirmation an operator can act on. A filter this route cannot
    # honour now 400s naming the key; one it can honour is applied below.
    # task-233cb8a1d033c738: the FLAT namespace is closed too. The container was
    # fail-closed by #12780 while the top level stayed fail-OPEN, so
    # `?parent_id=X` and `?bogus=1` both returned a 200 carrying the UNFILTERED
    # page — a false confirmation, not a missing feature.
    with :ok <- Params.reject_unknown_flat_params(params, :index),
         {:ok, filters} <- Params.parse_index_filters(params) do
      do_index(conn, params, filters)
    else
      {:error, reason} -> invalid_filter(conn, reason)
    end
  end

  defp do_index(conn, params, filters) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)
    # Clamp into [1, 1000] so a raw value can't reach `limit: ^limit` below:
    # `?limit=-1` would emit `LIMIT -1` (Postgres rejects a negative LIMIT → 500)
    # and `?limit=100000000` would fan the whole task corpus out in one Repo.all.
    #
    # THE DEFAULT USED TO BE THE CAP (1000, 1000) — so the clamp above bounded
    # only callers who ASKED for too much, and a bare `GET /v1/tasks` (every
    # `bp task ls` with no flags, every ad-hoc curl) took the widest page the
    # route can serve: one `Repo.all` + one batched child-count query + one
    # render over the whole task corpus, measured at 8,525 rows / ~9 MB on
    # guerrilla. Six of those concurrently is the shape that put `documents`
    # at 21.4 billion seq_tup_read and queued the auth plugs behind it
    # (task-e2f5ecca0be9a6d1). A default is what an UNINFORMED caller gets, so
    # it must be the cheap answer; the cap is what an informed one may ask for
    # and stays 1000. `?limit=` is honoured up to that cap exactly as before —
    # nothing a caller can spell changed, only what silence means.
    # The cap is `Params.index_limit_cap/0` (1000) rather than a literal, so a
    # test can shrink it and prove the ACROSS-THE-BOUNDARY cursor property on a
    # small corpus instead of seeding 1001 rows. The default is the cheap
    # answer (100) or the cap, whichever is smaller — a default above the cap
    # would be clamped anyway and would misreport itself.
    cap = Params.index_limit_cap()
    limit = Params.parse_limit(params["limit"], min(100, cap), cap)

    # tlv-bl-tasks-ls-offset-broken (D19): offset used to be silently ignored —
    # every page repeated page 0 and `bp task ls --all` self-aborted with
    # pagination_stalled. Params.parse_offset applies the ONE shared floor
    # convention (floor 0, cap 100k) — same clamp ready/2 uses — so a raw value
    # can never reach `OFFSET` as a negative (Postgres 500) or as an unbounded
    # deep scan.
    offset = Params.parse_offset(params["offset"])

    # C1 (task as universal node): when `parent` is given, the result reads as
    # that task's timeline/rail — its chronological child tasks (a "rail is the
    # chronological child tasks of a task"). Order by inserted_at ASC (oldest
    # first) for that view; keep the default desc:updated_at "most recently
    # touched first" ordering for the un-parent-filtered list.
    # `filter[parent]` / `filter[parent_id]` name the SAME edge as the flat
    # `?parent=`; this binding drives the rail (inserted_at ASC) ordering below,
    # so the bracket spelling reads as the parent's timeline exactly as the flat
    # one does. The filter CLAUSES are applied independently (see the query
    # below) — a caller who passes both spellings with different values gets the
    # honest conjunction (zero rows), never a silently-dropped predicate.
    # `parent_id` is the spelling content.parent_id teaches, so it is an ACCEPTED
    # ALIAS rather than a refusal — refusing the name the schema itself uses
    # would trade a wrong answer for a wrong lesson.
    parent =
      params["parent"] || params["parent_id"] || filters["parent"] || filters["parent_id"]

    # dr-w34-s4: twin collapse (published-wins) — a `drafts.<id>` shadow whose
    # published twin exists in the same scope is suppressed, so a twinned task
    # is ONE row here exactly as it is one row in `child_tasks/2` and in the
    # ready queue. An UNPAIRED `drafts.<id>` row (the whole mutate-created
    # population) has no distinct twin and survives — see
    # `Tasks.Query.collapse_twins/1` for why this is NOT a blanket `drafts.`
    # exclusion. NOTE the pagination consequence: `limit`/`offset` live in this
    # BASE, so removing shadow rows shifts which rows land on which page and
    # moves `bp task ls --all` totals.
    base =
      from(d in Document,
        where: d.type == "task",
        limit: ^limit,
        offset: ^offset
      )
      |> Tasks.Query.collapse_twins()

    query =
      base
      |> Params.maybe_filter_workspace(workspace_id)
      |> Params.maybe_filter_project(project_id)
      |> Params.maybe_filter_type(params["type"])
      |> Params.maybe_filter_kind(params["kind"])
      |> Params.maybe_filter_lifecycle(params["lifecycle_status"])
      |> Params.maybe_filter_parent(params["phase_id"])
      # The RESOLVED `parent` (bound above), not `params["parent"]` — otherwise
      # the `parent_id` alias reaches the cursor axis and not the filter, and
      # `?parent_id=X` returns the UNFILTERED page while looking like it worked.
      # That is the original defect wearing a new hat, and a helper-level test
      # would not have caught it: this is why the tests assert on RETURNED ROWS.
      |> Params.maybe_filter_parent_id(parent)
      |> Params.maybe_filter_label(params["label"])
      # The bracket spelling composes as ADDITIONAL where-clauses on the same
      # `Barkpark.Tasks.Query` fragments (nil = no-op), so `?kind=a&filter[kind]=b`
      # is an AND that returns nothing rather than one param quietly winning.
      |> Params.maybe_filter_type(filters["type"])
      |> Params.maybe_filter_kind(filters["kind"])
      |> Params.maybe_filter_lifecycle(filters["lifecycle_status"])
      |> Params.maybe_filter_parent(filters["phase_id"])
      |> Params.maybe_filter_parent_id(filters["parent"])
      |> Params.maybe_filter_parent_id(filters["parent_id"])
      |> Params.maybe_filter_label(filters["label"])
      |> Params.apply_index_order(parent)

    # bl-api-tasks-stable-cursor: the keyset seek. Parsed AFTER `parent` is
    # bound because the cursor's axis is the ORDERING's axis, and the ordering
    # is what `parent` selects. Fail-closed on a bad token (see the moduledoc).
    case Params.parse_index_cursor(params, parent) do
      {:ok, cursor} when cursor != nil and offset > 0 ->
        bad_request(
          conn,
          "cursor and offset are two different paging models — drop `offset` " <>
            "(the cursor already names where the page starts)"
        )

      {:ok, cursor} ->
        docs = query |> Params.apply_index_cursor(cursor) |> Repo.all()

        json(
          conn,
          task_list_response(docs, conn, params,
            limit: limit,
            offset: offset,
            cursor_axis: Params.cursor_axis(parent),
            cursor_requested?: Params.cursor_requested?(params)
          )
        )

      {:error, reason} ->
        bad_request(conn, reason)
    end
  end

  # ─── POST /v1/tasks/claim ───────────────────────────────────────────────

  def claim(conn, params) do
    case params["worker_id"] do
      worker_id when is_binary(worker_id) and byte_size(worker_id) > 0 ->
        with {:ok, order} <- Params.parse_ready_order(params["order"]) do
          opts =
            []
            |> Params.put_opt(:phase_id, params["phase_id"])
            |> Params.put_opt(:order, order)
            |> Params.put_opt(:caller_token_id, caller_token_id(conn))
            |> Keyword.merge(Params.execution_policy_opts(params))
            |> Keyword.merge(scope_opts(conn))

          case Tasks.claim(worker_id, opts) do
            {:ok, nil} ->
              conn
              |> put_status(:ok)
              |> json(%{ok: false, reason: "no_ready"})

            {:ok, %Document{} = doc} ->
              # Queue-claim: the subject is unknown pre-write, so no pre-write
              # baseline — rail_changed (if observed_rail_rev is passed) compares
              # against the post-write rev.
              json(
                conn,
                with_rail_extras(
                  %{
                    ok: true,
                    doc: Params.render_doc(seal_doc(doc, conn)),
                    help: Params.mutation_help(:claim, doc, worker_id),
                    lease: Params.claim_lease(doc)
                  },
                  doc,
                  nil,
                  conn,
                  params
                )
              )

            {:error, {:invalid_execution_policy, errors}} ->
              bad_request(conn, "invalid execution_policy_override: #{inspect(errors)}")

            {:error, reason} ->
              conn
              |> put_status(:conflict)
              |> json(%{ok: false, reason: Params.reason_to_string(reason)})
          end
        else
          {:error, :invalid_ready_order} ->
            bad_request(conn, "order must be closure_nearest when set")
        end

      _ ->
        bad_request(conn, "worker_id is required")
    end
  end

  # ─── GET /v1/tasks/:doc_id ──────────────────────────────────────────────
  # w7-08: dedicated single-task fetch, replacing a listAll() walk.
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
        # whose `content.parent_id` points at this doc, in chronological
        # order. Reuses the SAME prefix-agnostic parent filter
        # the index's `parent=` slice walks (`maybe_filter_parent_id/2`) plus
        # the tenancy filters, so the matching logic lives in one place. One
        # level only — children render as lightweight summaries (NOT the full
        # render_doc) to keep the payload lean and avoid deep recursion.
        children = child_tasks(doc.doc_id, conn)

        # Field-visibility seal (fail-closed): the doc AND its child summaries
        # are rendered off content-redacted docs under the request's caller.
        # task-3e0eda896a247776: `child_count` rides INSIDE `doc` as well as at
        # the top level. `children` is already the authoritative list here, so
        # the inner field is keyed off the SAME `length(children)` the envelope
        # reports — one query, one number, and `doc.child_count` now means the
        # same thing on `bp task get` as it does on a `bp task ls` / `ready`
        # card. The top-level key is UNCHANGED for the readers already on it.
        child_counts = %{Params.strip_draft_prefix(doc.doc_id) => length(children)}

        json(conn, %{
          ok: true,
          doc: Params.render_doc_with_counts(seal_doc(doc, conn), counts, child_counts),
          children: Enum.map(seal_docs(children, conn), &Params.child_summary/1),
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
    # dr-w34-s4: child_count = length(children), and this is its ONLY producer.
    # `maybe_filter_parent_id/2` strips `drafts.` from BOTH sides, so a shadow
    # child is GUARANTEED to match its published parent and used to contribute
    # +2. Twin collapse counts it once — while an unpaired `drafts.<id>` child
    # (no published twin) still counts, so the epic's live number cannot drop
    # by deleting real tasks. SAME predicate the index applies, so
    # `bp task get <epic>` and `bp task ls --parent <epic>` agree.
    |> Tasks.Query.collapse_twins()
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
          |> Params.put_opt(:caller_token_id, caller_token_id(conn))
          |> Keyword.merge(Params.execution_policy_opts(params))
          |> Keyword.merge(scope_opts(conn))
          |> Params.put_opt(
            :criteria_unstated_override,
            params["criteria_unstated_override"] ||
              get_in(params, ["set", "criteria_unstated_override"])
          )

        # Snapshot the rail BEFORE the claim so rail_changed compares
        # observed_rail_rev against the rail the worker actually saw (not the
        # rev its own claim produces). nil when the row is absent/parentless.
        pre_task =
          case find_task_by_doc_id(doc_id, conn) do
            {:ok, %Document{} = pre} -> pre
            _ -> nil
          end

        baseline_rev = if pre_task, do: pre_write_rail_rev(pre_task, conn), else: nil

        case Tasks.claim_by_id(doc_id, worker_id, opts) do
          {:ok, %Document{} = doc} ->
            json(
              conn,
              with_rail_extras(
                %{
                  ok: true,
                  doc: Params.render_doc(seal_doc(doc, conn)),
                  help: Params.mutation_help(:claim_by_id, doc, worker_id),
                  lease: Params.claim_lease(doc)
                },
                doc,
                baseline_rev,
                conn,
                params
              )
            )

          {:error, :not_found} ->
            not_found(conn, "task not found")

          {:error, {:resource_conflict, conflicts}} ->
            # 409 with the HOLDERS: each conflict names the in-progress task,
            # its worker, and the overlapping resource strings — enough for
            # the caller to wait, renegotiate, or pick other files.
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: "resource_conflict", conflicts: conflicts})

          {:error, {:invalid_execution_policy, errors}} ->
            bad_request(conn, "invalid execution_policy_override: #{inspect(errors)}")

          # THE THREE-ARM SPLIT (task-eb2b6170e19f1611). `Tasks.claim_by_id/3`
          # collapses three different refusals into one `:not_ready` atom, and
          # the CLI turns that into one sentence covering all three: "someone
          # else holds it or it isn't ready". Three different remedies, one
          # word — the caller cannot tell which applies, and the filing that
          # produced this fix spent hours chasing a phantom readiness bug on a
          # row that was simply `human_gated` by its own author.
          #
          # The refusal atom is UNCHANGED (so is the wire `reason` token, which
          # internal/cli/errors.go and pr-task-gate.sh both string-match) — the
          # arm is DERIVED here from the pre-claim snapshot the rail baseline
          # already fetched, and rides as additive fields + a `message` the bp
          # CLI prints in place of the bare token.
          {:error, :not_ready} ->
            conn
            |> put_status(:conflict)
            |> json(not_ready_arm(pre_task, worker_id))

          # task-9554c64bf51a0f81: the refusal must carry its own remedy. ~30
          # agents drive this verb daily, and a refusal that does not say what
          # to type costs every one of them a round trip — which is what turns a
          # good gate into a resented one.
          {:error, :criteria_unstated} ->
            conn
            |> put_status(:conflict)
            |> json(%{
              ok: false,
              reason: "criteria_unstated",
              task: doc_id,
              message: Params.criteria_unstated_message(doc_id, worker_id)
            })

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: Params.reason_to_string(reason)})
        end

      _ ->
        bad_request(conn, "worker_id is required")
    end
  end

  # Name WHICH arm of `claim_by_id`'s readiness gate refused, in the same order
  # `Barkpark.Tasks.Claim` evaluates them: executable-gate first
  # (`check_executable_for_targeted_claim` → QueueGate), lifecycle second
  # (`check_ready_for_targeted_claim` → Validation.claimable_statuses/0).
  #
  # Every arm keeps `reason: "not_ready"`. `arm` is the machine-readable
  # discriminator; `message` is the sentence a human acts on.
  @doc false
  def not_ready_arm(nil, _worker_id),
    do: %{ok: false, reason: "not_ready", arm: "unknown"}

  def not_ready_arm(%Document{content: content}, worker_id) do
    c = content || %{}
    holder = claim_holder(c)
    gate = Map.get(c, "queue_gate")
    status = Map.get(c, "lifecycle_status")

    cond do
      not is_nil(holder) and holder != worker_id ->
        %{
          ok: false,
          reason: "not_ready",
          arm: "held_by_other",
          held_by: holder,
          message:
            "held by #{holder} — nobody else can claim it. If that worker id is YOURS, " <>
              "re-claim with it VERBATIM to renew the lease. If the row also reads " <>
              "lifecycle open, the holder is stranded: free it with " <>
              "`bp task release <id> <your-worker-id> <claim.epoch> --yes`."
        }

      not QueueGate.executable?(c, worker_id) ->
        %{
          ok: false,
          reason: "not_ready",
          arm: "queue_gated",
          execution_class: QueueGate.execution_class(c, worker_id),
          gate_reason: if(is_map(gate), do: Map.get(gate, "reason")),
          message:
            "queue_gate state is #{inspect(QueueGate.execution_class(c, worker_id))} — this row " <>
              "is gated by its AUTHOR, not by readiness, and no retry will change that. " <>
              "Read content.queue_gate.reason for what it is waiting on."
        }

      status not in Validation.claimable_statuses() ->
        %{
          ok: false,
          reason: "not_ready",
          arm: "not_claimable_status",
          lifecycle_status: status,
          message:
            "lifecycle_status is #{inspect(status)}; only " <>
              "#{inspect(Validation.claimable_statuses())} is claimable. " <>
              "Reopen it with `bp task stage <id> open` first."
        }

      true ->
        %{ok: false, reason: "not_ready", arm: "unknown"}
    end
  end

  defp claim_holder(content) do
    case get_in(content, ["claim", "worker"]) do
      worker when is_binary(worker) -> if String.trim(worker) == "", do: nil, else: worker
      _ -> nil
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
        |> Params.put_opt(:landed, params["landed"])
        # The two LOUD overrides (PDS-D288/D289). Without these two lines the
        # honesty gates are refuse-only over HTTP — a lead could not seal a
        # foreign task and nobody could close over an honest unmet criterion
        # through the API or the bp CLI at all. `bp task close … --set
        # holder_override="<reason>"` is the wire form; a blank/absent reason is
        # NOT an override (Tasks.Close.override_reason/1), so an empty string
        # cannot be used to launder the gate.
        |> Params.put_opt(:holder_override, params["holder_override"])
        |> Params.put_opt(:criteria_override, params["criteria_override"])
        # The reporter-loop override (`Github.Acknowledgement`). Separate from
        # `criteria_override` on purpose: closing an outsider's bug report
        # without telling them is its own admission and must be its own record.
        |> Params.put_opt(:ack_override, params["ack_override"])
        # The close-artifact override (PDS-D291). Its own body param for the same
        # reason `ack_override` is: "no criteria AND no artifact, done anyway" is
        # a different admission from "a named criterion is unproven", and letting
        # `criteria_override` buy both would make the routine flag discharge the
        # rare one. Wire form: `bp task close … --set close_reason_override="…"`.
        |> Params.put_opt(:close_reason_override, params["close_reason_override"])
        |> Params.put_opt(:caller_token_id, caller_token_id(conn))

      # Snapshot the rail BEFORE the close (from the already-fetched pre-close
      # task) so rail_changed reflects only concurrent actors, not this close.
      baseline_rev = pre_write_rail_rev(task, conn)

      case Barkpark.Tasks.Close.close_with_receipt(task.id, worker_id, opts) do
        # THE REPLAY (task-17224f58d3bda3bd). This worker's close already
        # landed; the response it got for it did not come back. Answer 200 with
        # the stored row and say so in one field, so a caller can tell "my write
        # landed earlier" from "my write landed just now" without a re-read —
        # and, above all, so it stops reading a landed write as a failure.
        {:ok, %Document{} = doc, :already_closed} ->
          json(
            conn,
            close_response(doc, worker_id, conn)
            |> Map.put(:already_closed, true)
            |> Map.put(
              :message,
              "already closed by #{worker_id} — this call changed nothing and the stored close_reason is unchanged"
            )
          )

        {:ok, %Document{} = doc, :closed} ->
          # Graduated enforcement (living-values §12): unmet criteria are
          # SURFACED as a soft warning on the (already successful) close —
          # never a gate (close_response below, shipped with lvw-t6).
          # rail-l1: rail_rev + notices ride the same 2xx envelope — advisory,
          # the close has ALREADY committed even when blocked_while_claimed
          # fires (L1 notices are informational; refusal is the L4 task).
          json(
            conn,
            with_rail_extras(
              close_response(doc, worker_id, conn),
              doc,
              baseline_rev,
              conn,
              params
            )
          )

        {:error, {:doc_changed_since_claim, current_rev, changed_fields}} ->
          # Edited-under-you fence (rail-awareness L2): the task's work-defining
          # brief changed while this worker held the claim, and no explicit
          # observed_rev was pinned. 409 with the current rev + which fields
          # drifted so the caller re-reads before closing against stale
          # assumptions (or pins observed_rev for strict rev fencing).
          conn
          |> put_status(:conflict)
          |> json(%{
            ok: false,
            reason: "doc_changed_since_claim",
            current_rev: current_rev,
            changed_fields: changed_fields,
            # pds-bl-close-409-hint-promises-absent-fields: the two VALUES were
            # always here; the COMMAND that consumes them was not, so a caller
            # read `current_rev` off the body and still went looking for the
            # recovery. Naming it here is what makes the body self-sufficient.
            message: Params.drift_hint(current_rev, changed_fields)
          })

        {:error, reason} ->
          conflict(conn, reason, :close, fence_extras(conn, doc_id, reason))
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

  # ─── POST /v1/tasks/:doc_id/release ─────────────────────────────────────

  def release(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, worker_id} <- Params.fetch_string(params, "worker_id"),
         {:ok, observed_epoch} <- Params.fetch_int(params, "observed_epoch"),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      case Tasks.release(task.id, worker_id, observed_epoch: observed_epoch) do
        {:ok, %Document{} = doc} ->
          json(conn, %{
            ok: true,
            doc: Params.render_doc(seal_doc(doc, conn)),
            help: Params.mutation_help(:release, doc, worker_id)
          })

        {:error, reason} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, reason: Params.reason_to_string(reason)})
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

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
  # axi-s4 R5: the envelope also carries `help` (next-command templates —
  # after a close that is `bp task next <worker>`), a sibling of `warnings`.
  defp close_response(%Document{} = doc, worker_id, conn) do
    base = %{
      ok: true,
      # Field-visibility seal (fail-closed) on the echoed doc; the warning
      # computation below stays on the RAW doc (it is about the actor's own
      # close, never a visibility decision).
      doc: Params.render_doc(seal_doc(doc, conn)),
      help: Params.mutation_help(:close, doc, worker_id)
    }

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

  # ─── POST /v1/tasks/:doc_id/stage ───────────────────────────────────────
  # The sanctioned lifecycle-transition verb for the thought/backlog states
  # (charter D8): `bp task stage <id> <state> [--object …] [--note …]
  #   [--disposition open|parked|closed] [--reopen-trigger …]`. Body:
  #   { "worker_id": "cycle-42", "state": "researching",
  #     "object": "research", "note": "surveying candidate",
  #     "disposition": "parked", "reopen-trigger": "when the ARM runner exists" }
  # PDS wave 24: disposition + reopen_trigger are forwarded because this verb is
  # the ONLY sanctioned writer of content.disposition — the raw door refuses and
  # names this route, so a route that dropped the params would make that refusal
  # unfixable. `reopen_trigger` is accepted in both spellings: the manifest flag
  # is hyphenated (`--reopen-trigger`, matching `criterion-text`) and the CLI
  # sends the flag name verbatim, while a hand-written JSON body naturally uses
  # the content key's underscore.
  # `state` is the target (considering | researching | open — kills go through
  # close, claims through claim) OR the row's own current state, the PDS-wave-25
  # same-state no-op that lets a FINISHED row record its adjudication without
  # being resurrected. `Tasks.stage/3` enforces the shared Transitions legality
  # table, writes/clears content.engagement, and emits task.staged. An illegal
  # transition (e.g. open → done) is a 422 naming from/to
  # and the sanctioned verb — never a silent no-op. Mirrors close/2's shape
  # (find_task_by_doc_id → primitive → minimal receipt) MINUS the epoch fence
  # (thought is not contended work).
  def stage(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, state} <- Params.fetch_string(params, "state"),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        []
        |> Params.put_opt(:object, params["object"])
        |> Params.put_opt(:holder, params["worker"] || params["worker_id"])
        |> Params.put_opt(:note, params["note"])
        # The adjudication triple (PDS wave 24). Without these two forwards the
        # 422 that `Mutations.ensure_disposition_via_verb/4` raises names a
        # retry instruction no operator can execute — a refusal that lies about
        # its own remedy, which is the exact class this wave exists to close.
        |> Params.put_opt(:disposition, params["disposition"])
        |> Params.put_opt(:reopen_trigger, params["reopen_trigger"] || params["reopen-trigger"])
        # PDS wave 28: the fourth durable key — the command that could prove the
        # reason wrong. Forwarded for the same reason the triple is: this verb is
        # the only sanctioned writer, so a route that dropped the param would
        # make the raw door's refusal unfixable. Optional by design.
        |> Params.put_opt(:rerun, params["rerun"] || params["disposition_rerun"])
        # The displacement override (task-d6f3e66b1b829e6e criterion 3). Absent
        # → false, so a `--note` that would replace a DIFFERENT non-blank
        # disposition_reason is refused; the caller has to say they read what
        # is there. `stage_supersede/1` reads both wire spellings.
        |> Params.put_opt(:supersede, Params.stage_supersede(params))
        |> Params.put_opt(:caller_token_id, caller_token_id(conn))

      case Tasks.stage(task.id, state, opts) do
        {:ok, %Document{} = doc} ->
          json(conn, %{ok: true, doc: Params.render_doc(seal_doc(doc, conn))})

        {:error, {:illegal_transition, from, to}} ->
          # A refused transition (bad target OR an illegal table pair) is a 422
          # naming both ends and the sanctioned verb — the guard TEACHES.
          #
          # PDS-D349: the old text said stage "moves only between
          # considering|researching|open", which the wave-25 widening made
          # FALSE — a row can also be staged to its OWN current state to carry
          # an adjudication in place (`done → done`). In an epic about verbs
          # that lie, a refusal that misstates its own rule is the same defect
          # one layer down, so the message now names BOTH doors: what stage
          # MOVES between, and the no-op it adjudicates on.
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            ok: false,
            reason: "illegal_transition",
            from: from,
            to: to,
            message:
              "cannot stage #{from} → #{to}: stage MOVES a task only between " <>
                "considering|researching|open (plus the sanctioned reopen edges " <>
                "→ open), and otherwise only accepts a same-state no-op " <>
                "(state == the row's current #{inspect(from)}) to record an " <>
                "adjudication in place — use `bp task close` (→ cancelled) or " <>
                "`bp task claim` (→ in_progress); `done` is REACHED only via close, " <>
                "though a done row can be adjudicated with " <>
                "`bp task stage <id> done --disposition …`"
          })

        {:error, {:invalid_object, object}} ->
          bad_request(
            conn,
            "object must be \"research\" or \"build\", got #{inspect(object)}"
          )

        {:error, {:invalid_disposition, value}} ->
          bad_request(
            conn,
            "disposition must be one of " <>
              Enum.map_join(Tasks.Stage.dispositions(), ", ", &inspect/1) <>
              " (trimmed and downcased), got #{inspect(value)}"
          )

        # A park that cannot say what would reopen it has decided nothing. The
        # refusal is a 422 naming the flag that fixes it — and NOTHING was
        # written, so a retry with the flag is the whole remedy.
        {:error, {:missing_reopen_trigger, disposition}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            ok: false,
            reason: "missing_reopen_trigger",
            disposition: disposition,
            message:
              "cannot stage a #{inspect(disposition)} disposition with no reopen trigger: " <>
                "pass --reopen-trigger \"<what would make this worth reconsidering>\" " <>
                "(or leave the row's existing trigger in place). Nothing was written."
          })

        # A rerun that cannot fail is not evidence. The refusal is a 422 naming
        # the FIELD, the shape that was refused, WHY that shape cannot fail, and
        # a legal substitute — and nothing was written, so the retry is the
        # whole remedy. Absence is never refused: a reason is allowed to say it
        # cannot be checked.
        {:error, {:unfalsifiable_rerun, code, value}} ->
          why =
            Tasks.Stage.forbidden_rerun_shapes()
            |> Enum.find_value(fn {c, why} -> if c == code, do: why end)
            |> Kernel.||(
              "a pipeline reports its LAST stage's exit code, so a formatting tail " <>
                "(head/tail/wc/jq/…) reports ITS success as the check's — " <>
                "`git show origin/main:<deleted-path> | head -1` exits 0 where the bare " <>
                "`git show` exits 128"
            )

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            ok: false,
            reason: "unfalsifiable_rerun",
            field: Tasks.Stage.disposition_rerun_key(),
            shape: to_string(code),
            value: value,
            message:
              "disposition_rerun #{inspect(value)} cannot fail, so it cannot prove the " <>
                "reason wrong: #{why}. Write one of these instead — " <>
                Enum.map_join(Tasks.Stage.legal_rerun_substitutes(), " · ", &"`#{&1}`") <>
                " — or omit --rerun entirely, which is an honest \"this reason cannot be " <>
                "checked\" and is accepted. Nothing was written."
          })

        # A NOTE THAT WOULD DESTROY A NOTE (task-d6f3e66b1b829e6e criterion 3).
        # 409, and NOTHING was written. The refusal SHOWS the text it just
        # saved — a bare "no" would send the caller back with the destructive
        # flag without ever reading what they were about to erase, which is the
        # whole failure this door exists to prevent. Notes of 1228 chars exist
        # on the live ledger, so the wire copy is bounded and states the TRUE
        # length; `existing_note_truncated` says whether what you are reading is
        # the whole thing, and `bp task events --payload` has it in full either
        # way.
        {:error, {:note_would_supersede, existing}} ->
          {excerpt, truncated?} = Params.note_excerpt(existing)

          conn
          |> put_status(:conflict)
          |> json(%{
            ok: false,
            reason: "note_would_supersede",
            existing_note: excerpt,
            existing_note_length: String.length(existing),
            existing_note_truncated: truncated?,
            message:
              "refusing to replace the disposition_reason already on this row — " <>
                "--note REPLACES, it does not append, and nothing was written. " <>
                "THE NOTE YOU WOULD HAVE DESTROYED (#{String.length(existing)} chars" <>
                if(truncated?, do: ", shown truncated", else: "") <>
                "): #{inspect(excerpt)} — read it before you decide. " <>
                "If replacing it IS what you meant, re-run the same stage with " <>
                "--supersede; the displaced text then stays recoverable from " <>
                "`bp task events --payload` as `payload.staged.superseded_note`. " <>
                "If it is not, put your text somewhere that does not overwrite a " <>
                "caution — the brief, or a comment on the row."
          })

        {:error, :not_found} ->
          not_found(conn, "task not found")

        {:error, reason} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, reason: Params.reason_to_string(reason)})
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── POST /v1/tasks/:doc_id/stamp ───────────────────────────────────────
  # Criterion-level mid-claim evidence (expressive-agent-loops D3/D6/D7/D8).
  # Body/query (the bp CLI rides flags as query params): worker_id +
  # observed_epoch (positional in bp), criterion=<index>, then EXACTLY one of
  #   met=true      + evidence=<non-empty> → flip the lock, evidence or nothing
  #   miss=true     + note=<non-empty>     → honest attempt, met never flips. On
  #                                          a DONE/CANCELLED row this is the
  #                                          ONE accepted verb (plus withdraw),
  #                                          and it also needs
  #                                          observed_rev=<the rev you read>;
  #                                          met=true stays not_in_progress.
  #   withdraw=true + note=<non-empty>     → LOWER the lock (D745): met→false,
  #                                          evidence preserved, a signed
  #                                          withdrawals[] record appended. On a
  #                                          row with no claim it also needs
  #                                          observed_rev=<the rev you read>.
  # doc_id resolves via find_task_by_doc_id (close's pattern) and the
  # primitive locks task:<uuid> — the close family, serialized with close over
  # the same criteria. Progress is advisory: the response is the fresh doc
  # (criteria_progress rides render_doc); close remains the seal.
  def stamp(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, worker_id} <- Params.fetch_string(params, "worker_id"),
         {:ok, observed_epoch} <- Params.fetch_int(params, "observed_epoch"),
         {:ok, index, outcome, criterion_text} <- Params.parse_stamp(params),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        [observed_epoch: observed_epoch, criterion: index, outcome: outcome]
        |> Params.put_opt(:criterion_text, criterion_text)
        |> Params.put_opt(:merge_gated, Params.stamp_merge_gated(params))
        |> Params.put_opt(:observed_rev, Params.stamp_observed_rev(params))
        |> Params.put_opt(:caller_token_id, caller_token_id(conn))

      case Tasks.stamp(task.id, worker_id, opts) do
        {:ok, %Document{} = doc} ->
          # Stamp does NOT bump the epoch — help[] reuses the claim epoch the
          # caller already holds (read from the fresh doc, same code path as
          # pulse's bumped one).
          json(conn, %{
            ok: true,
            doc: Params.render_doc(seal_doc(doc, conn)),
            help: Params.mutation_help(:stamp, doc, worker_id)
          })

        # task-f6fba9a87369ce8e: evidence that locates its proof on a BRANCH and
        # names nothing durable is a SHAPE refusal, not a state conflict — the
        # row is fine, the proof is not — so it renders 400 like the other shape
        # errors rather than 409. The message names the missing thing AND how to
        # supply it, because the whole point of refusing at stamp time is that
        # the sha is still in the stamper's hands right now.
        {:error, :branch_only_evidence} ->
          bad_request(conn, Barkpark.Tasks.EvidenceDurability.message())

        {:error, reason} ->
          # Every failure here is a state conflict (not_holder / fenced_off /
          # stale_claim / index out of range / criterion-text guard / not
          # in_progress) — shape errors were already 400'd by parse_stamp above.
          # The criteria-grain conflicts ride an actionable `message` (D56): a
          # guard that refuses without saying what to type is a guard agents
          # route around.
          conflict(conn, reason, :stamp, fence_extras(conn, doc_id, reason))
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :invalid_stamp, msg} ->
        bad_request(conn, msg)

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── POST /v1/tasks/:doc_id/landed ──────────────────────────────────────
  # THE NON-HOLDER LANDING MARK (task-59fe7b40b719b379). Body/query:
  #   { "commit": "<sha>", "pr": "<number>", "note": "<sentence>",
  #     "criterion": <0-based index|null> }
  #
  # NO worker_id and NO observed_epoch — deliberately, and that absence IS the
  # feature. A push-to-main workflow holds no claim and knows no epoch, so
  # `stamp` refuses it 409 not_holder (check_holder then check_fencing) and
  # `close` is not CI's to call. This route sits on the same :token_root bucket
  # as every other /v1/tasks write, so it is still bearer-gated and still
  # write-tier (RequireWriteForMutation) — what it drops is the HOLDER gate, not
  # authentication. `Tasks.Landed` owns the blast radius: content.landed plus at
  # most ONE merge-shaped criterion.
  def landed(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, criterion} <- Params.parse_landed_criterion(params["criterion"]),
         :ok <- Params.check_landed_payload(params, criterion),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        []
        |> Params.put_opt(:commit, params["commit"])
        |> Params.put_opt(:pr, params["pr"])
        |> Params.put_opt(:note, params["note"])
        |> Params.put_opt(:criterion, criterion)
        |> Params.put_opt(:caller_token_id, caller_token_id(conn))

      case Tasks.record_landing(task.id, opts) do
        {:ok, %Document{} = doc} ->
          json(conn, %{ok: true, doc: Params.render_doc(seal_doc(doc, conn))})

        {:error, reason} ->
          # Every remaining failure is a STATE conflict (the index does not
          # resolve / the row is already met / the row is not merge-shaped /
          # a concurrent write moved the rev). Shape errors were 400'd above.
          conflict(conn, reason, :landed)
      end
    else
      {:error, :invalid_landed, msg} ->
        bad_request(conn, msg)

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # 409 envelope: the reason token stays the machine-readable contract; a
  # criteria-grain reason ALSO carries a top-level `message` telling the caller
  # exactly what to pass next (the bp CLI prints it in place of the token).
  defp conflict(conn, reason, surface, extra \\ %{}) do
    body = Map.merge(%{ok: false, reason: Params.reason_to_string(reason)}, extra)

    message =
      Params.criteria_hint(reason, surface) ||
        Params.fence_hint(reason, surface, Map.get(extra, :current_epoch))

    body =
      case message do
        nil -> body
        message -> Map.put(body, :message, message)
      end

    conn
    |> put_status(:conflict)
    |> json(body)
  end

  # dr-w14-bl-fenced-off-409-is-mute: `fenced_off` is the one close/stamp
  # refusal whose remedy needs a number the caller CANNOT compute — the epoch
  # the row carries now (a `bp task pulse` advances it, so the epoch handed out
  # at claim time is stale after the first heartbeat). Read it back on the
  # refusal path ONLY, so the 409 body names it (`current_epoch`) alongside the
  # command that spends it, and the caller recovers without the re-read the bare
  # token silently demanded. `fenced_off` always implies a live claim
  # (`Tasks.Close.check_fencing/2` — no claim closes cleanly), so the lookup
  # normally hits; a miss just degrades to the re-read sentence.
  defp fence_extras(conn, doc_id, :fenced_off) do
    case find_task_by_doc_id(doc_id, conn) do
      {:ok, %Document{content: %{"claim" => %{"epoch" => epoch}}}} when is_integer(epoch) ->
        %{current_epoch: epoch}

      _ ->
        %{}
    end
  end

  defp fence_extras(_conn, _doc_id, _reason), do: %{}

  # ─── POST /v1/tasks/:doc_id/pulse ───────────────────────────────────────
  # Now-line heartbeat + lease renewal in one atomic write (Tasks.Pulse; see
  # its moduledoc for the write-path law). Body shape:
  #   { "worker_id": "agent-1", "now": "warm-up pinned, rerunning", "criterion": 2 }
  # `criterion` optional (non-negative integer index into acceptance_criteria).
  # NO observed_epoch — pulse is the renewal, it survives fence bumps; a lost
  # lease is a 409, never a re-claim — `not_in_progress:<status>` when the ROW
  # moved (reaped/released/closed/staged), `not_holder` when a LIVE claim is
  # someone else's (task-b6fcc8e2f57e1cd5).

  # A now-line is a ticker cell, not a worklog: bound it so one chatty agent
  # can't bloat every board row + event payload. Bytes, honest 400 (never a
  # silent truncation — the worker should know its pulse didn't land as sent).
  @pulse_now_max_bytes 500

  def pulse(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, worker_id} <- Params.fetch_string(params, "worker_id"),
         {:ok, text} <- Params.fetch_string(params, "now"),
         :ok <- check_now_length(text),
         {:ok, criterion} <- parse_criterion(params["criterion"]),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        [text: text]
        |> Params.put_opt(:criterion, criterion)
        |> Params.put_opt(:caller_token_id, caller_token_id(conn))

      case Tasks.pulse_by_id(task.id, worker_id, opts) do
        {:ok, %Document{} = doc} ->
          # Pulse BUMPS the claim epoch — mutation_help reads the FRESH epoch
          # off this post-write doc, so help[] never echoes the (now-stale)
          # epoch the caller last saw.
          json(conn, %{
            ok: true,
            doc: Params.render_doc(seal_doc(doc, conn)),
            help: Params.mutation_help(:pulse, doc, worker_id),
            # A pulse RENEWS the lease (Tasks.Pulse refreshes ts_iso), so the
            # receipt reports the NEW window, not the one the claim granted.
            lease: Params.claim_lease(doc)
          })

        {:error, reason} ->
          # Through `conflict/4` so a `{:not_in_progress, status}` refusal
          # carries its remedy hint as the 409's top-level `message` (the bp
          # CLI prints that in place of the bare token) — task-b6fcc8e2f57e1cd5.
          conflict(conn, reason, :pulse)
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :now_too_long} ->
        bad_request(conn, "now must be at most #{@pulse_now_max_bytes} bytes")

      {:error, :invalid_criterion} ->
        bad_request(conn, "criterion must be a non-negative integer")

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  defp check_now_length(text) when byte_size(text) <= @pulse_now_max_bytes, do: :ok
  defp check_now_length(_), do: {:error, :now_too_long}

  # ─── POST /v1/tasks/:doc_id/renew ───────────────────────────────────────
  # The NON-HOLDER lease extension (Tasks.Renew — its moduledoc carries the
  # decision, the rejected alternative, and the blast radius). Body shape:
  #   { "pr": 15234, "state": "open" | "closed" | "merged", "reason": "open_pr" }
  # `pr` is REQUIRED: an extension with no named reason is a blank cheque, and
  # the clear is pr-matched so PR #2 closing cannot cancel PR #1's grace.
  # NO worker_id and NO observed_epoch — the caller is CI, which can never hold
  # the claim; that is the whole point of the verb, and it is why the epoch is
  # not bumped (a bump would stale every lead's stamp/close CAS).

  def renew(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, pr} <- parse_pr(params["pr"]),
         {:ok, state} <- parse_pr_state(params["state"]),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        [pr: pr, state: state]
        |> Params.put_opt(:reason, params["reason"])
        |> Params.put_opt(:caller_token_id, caller_token_id(conn))

      case Tasks.renew_lease_by_id(task.id, opts) do
        {:ok, %Document{} = doc} ->
          json(conn, %{ok: true, doc: Params.render_doc(seal_doc(doc, conn))})

        {:error, reason} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, reason: Params.reason_to_string(reason)})
      end
    else
      {:error, :invalid_pr} ->
        bad_request(conn, "pr is required and must be a positive integer")

      {:error, :invalid_state} ->
        bad_request(conn, ~s|state must be one of "open", "closed", "merged"|)

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # `pr` arrives as an int (JSON body) or a string (`--pr 15234` through
  # generic manifest dispatch / the query form). Absent is a 400, not a
  # default: see the comment above.
  defp parse_pr(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_pr(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_pr}
    end
  end

  defp parse_pr(_), do: {:error, :invalid_pr}

  # Absent state means "open" — the renew is the common call, the clear is the
  # one a caller has to ask for by name.
  defp parse_pr_state(nil), do: {:ok, "open"}
  defp parse_pr_state(s) when s in ["open", "closed", "merged"], do: {:ok, s}
  defp parse_pr_state(_), do: {:error, :invalid_state}

  # `criterion` arrives as an int (JSON body) or a string (`--criterion 2`
  # through generic dispatch / query form). Absent → {:ok, nil} (a plain
  # now-line names no lock). Negative / non-integer → honest 400.
  defp parse_criterion(nil), do: {:ok, nil}
  defp parse_criterion(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp parse_criterion(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_criterion}
    end
  end

  defp parse_criterion(_), do: {:error, :invalid_criterion}

  # ─── GET /v1/tasks/:doc_id/edges ────────────────────────────────────────

  def edges(conn, %{"doc_id" => doc_id} = params) do
    # `kind` is a FILTER, so a shape we cannot filter on is refused LOUDLY —
    # `?kind[]=blocks` decodes to a list and used to fall off this case as a
    # CaseClauseError-500 (before find_task_by_doc_id/2, so even a nonexistent
    # doc_id 500'd instead of 404ing). Silently ignoring an unusable filter
    # would return an unfiltered graph the caller believes is filtered — the
    # same dishonesty query_controller's invalid_filter_op guard refuses.
    # Contrast request_dataset/1, a SCOPE SELECTOR with a documented default,
    # which fails SOFT.
    with {:ok, kind_opt} <- parse_edge_kind(params["kind"]) do
      edges_for_kind(conn, doc_id, kind_opt)
    else
      {:error, :invalid_kind} ->
        bad_request(conn, "kind must be a string")
    end
  end

  defp parse_edge_kind(nil), do: {:ok, :blocks}
  defp parse_edge_kind("all"), do: {:ok, :all}
  defp parse_edge_kind(other) when is_binary(other), do: {:ok, other}
  defp parse_edge_kind(_), do: {:error, :invalid_kind}

  defp edges_for_kind(conn, doc_id, kind_opt) do
    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        deps = Tasks.dependencies(task.id, kind: kind_opt)
        dependents = Tasks.dependents(task.id, kind: kind_opt)

        # Field-visibility seal (fail-closed): the deps/next graph is rendered
        # off content-redacted docs under the request's caller.
        json(conn, %{
          ok: true,
          dependencies: Enum.map(seal_docs(deps, conn), &Params.render_doc/1),
          dependents: Enum.map(seal_docs(dependents, conn), &Params.render_doc/1)
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
        # AFTER the existence-hiding 404 below, never before. This is the route
        # with the draft-leak history (graph_draft_leak_test.exs): a refusal
        # raised ahead of root resolution would answer "that id exists, your
        # perspective is wrong" to a caller the endpoint is meant to tell
        # nothing. `raw` is refused here on purpose — the manifest declares this
        # route as published | drafts only, so it is not a missing branch.
        case ReadPerspective.unsupported(params, @graph_perspectives) do
          nil -> graph_traverse(conn, root, params)
          bad -> ReadPerspective.refuse(conn, bad, @graph_perspectives)
        end

      {:error, :not_found} ->
        not_found(conn, "document not found")
    end
  end

  defp graph_traverse(conn, %Document{} = root, params) do
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

        %{tasks: tasks, truncated: truncated, unhydrated: unhydrated} =
          Tasks.driven_tasks(root.doc_id, opts)

        json(conn, %{
          ok: true,
          # Published-coalesced, like graph_show — the graph identity.
          root: Content.published_id(root.doc_id),
          tasks: Enum.map(tasks, &render_driven_task/1),
          count: length(tasks),
          truncated: truncated,
          # A citing task whose edge was read but whose document did not
          # hydrate under this read's scope. `truncated` cannot carry it (the
          # node budget never bit), and a short list that reports itself
          # complete is how three real citations stayed invisible for two
          # weeks — task-464b89f30e3f8e41. Always present, `[]` when clean.
          unhydrated: unhydrated
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

  # Both derived corpus reads run through `graph_derived_opts/1`, which adds the
  # SAME schema-visibility clamp `/v1/graph` applies (`visible_schemas/2`, the
  # canonical owner) — these endpoints emit a document's `type` and `title`, so
  # they answer the corpus question and must answer it under the corpus clamp.
  # Both also report their BOUND now (`limit` + `truncated`): the 5,000-row scan
  # ceiling was already enforced inside `Content.Graph`, but a bare list that
  # stops at the ceiling is indistinguishable from a complete answer — the same
  # dishonesty `/v1/graph`'s `truncated` flag already fixed for the corpus.
  def graph_orphans(conn, _params) do
    %{orphans: orphans, count: count, limit: limit, truncated: truncated} =
      Graph.orphans_bounded(graph_derived_opts(conn))

    json(conn, %{
      ok: true,
      orphans: orphans,
      count: count,
      limit: limit,
      truncated: truncated
    })
  end

  # ─── GET /v1/graph/dangling ─────────────────────────────────────────────

  def graph_dangling(conn, _params) do
    %{dangling: dangling, count: count, limit: limit, truncated: truncated} =
      Graph.dangling_bounded(graph_derived_opts(conn))

    json(conn, %{
      ok: true,
      dangling: dangling,
      count: count,
      limit: limit,
      truncated: truncated
    })
  end

  # Scope + dataset + the schema-visibility TYPE allowlist for the two derived
  # corpus reads. The allowlist is derived at READ TIME off the schema rows this
  # caller may see, so a schema flipped to private drops out of orphans/dangling
  # on the very next read — and an empty allowlist fails CLOSED (no types → no
  # rows), never open.
  defp graph_derived_opts(conn) do
    dataset = request_dataset(conn)
    opts = scope_opts(conn) |> Keyword.put(:dataset, dataset)

    types =
      dataset
      |> Content.list_schemas(opts)
      |> visible_schemas(conn)
      |> Enum.map(& &1.name)

    Keyword.put(opts, :types, types)
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
  #
  # TWO ceilings, BOTH reported honestly (stw9-backlog-graph-server-honesty):
  #   - per_type_cap  — the per-type page ceiling (the list_documents hard cap).
  #     Deliberately NOT lifted: one derivation already costs ~9.6k queries and
  #     lifting the cap multiplies the dominant per-document term (the N+1 is
  #     filed separately as stw10-backlog-graph-n-plus-one). When a type's list
  #     comes back at the cap, one COUNT confirms whether more exist.
  #   - node_budget   — the whole-graph node ceiling. When it fires, edges are
  #     re-filtered to the SURVIVING node set so no edge endpoint dangles
  #     (previously the take dropped the phantom tail while every edge kept
  #     pointing at it).
  # `truncated` goes true whenever EITHER ceiling fired — clients (graph.ts:193)
  # discard `truncation_reason` unless `truncated` is true, so the flag is
  # load-bearing. Both values are config-overridable for tests only.
  @graph_corpus_node_budget 2000
  @graph_corpus_per_type_limit 1000

  # THIRD ceiling, and the only one that protects the BOX rather than the
  # payload: a CONCURRENT-DERIVATION CAP.
  #
  # One corpus derivation is cheap in statements and expensive in wall time (it
  # holds a pool connection across every type's document page). During the
  # 2026-07-28 storm `graph_corpus/2` was the top application crash frame in
  # guerrilla's journal — 9,566 frames that day — because concurrent static-site
  # builds each asked for the whole corpus at once, exhausted `POOL_SIZE=10`
  # (config/runtime.exs) and 500-ed UNRELATED requests ("Sent 500 in 32003ms").
  # Denying the route to public-read tokens accidentally shed that load; this
  # slice re-admits the route, so the shedding has to become deliberate.
  #
  # Beyond the cap the request is REFUSED FAST (503 + Retry-After) instead of
  # queueing on the DB pool: a shed request costs one ETS lookup, a queued one
  # costs a connection every other route also needs. Slots are ETS rows keyed by
  # a ref and carrying {owner_pid, deadline}; every acquire first sweeps rows
  # whose OWNER DIED, so a slot cannot leak even if a request process is killed
  # mid-derivation (`after` covers every ordinary exit AND every raise).
  #
  # The ACQUIRE path's saturation races resolve toward REFUSAL, never toward
  # over-admission: the row is inserted BEFORE `:ets.info(:size)` is read, so the
  # latest admitter necessarily counts itself and every racer, sees cap+1 and
  # backs out. Two racers can both back out; at saturation shedding is the
  # intended behaviour, so a spurious 503 is the safe error.
  #
  # THAT CLAIM HELD FOR ACQUIRE AND DID NOT HOLD FOR THE TTL SWEEP. The sweep
  # also reaped rows whose `deadline` had passed, and a deadline is a wall-time
  # GUESS about whether a derivation has finished, not a fact about it. A
  # derivation outliving @graph_corpus_slot_ttl_ms had its row deleted while its
  # owner was still alive and still holding the pool connection this cap exists
  # to protect — and because every acquire sweeps first, an ARRIVING request
  # performed that reap on the live holders' behalf and was then admitted over
  # the cap. It refilled without limit (effective concurrency ~
  # ceil(duration / TTL) x cap) and it was self-amplifying: extra admissions
  # lengthen every derivation, which crosses the TTL more often. Fail-open in
  # the only regime where the cap matters. The deadline arm is now GONE; the
  # deadline itself stays on the row as diagnostic data.
  @graph_corpus_slots :barkpark_graph_corpus_slots
  @graph_corpus_max_concurrency 4
  @graph_corpus_slot_ttl_ms 60_000

  # WHEN a shed client should come back. This header used to say `1`, which was
  # not derived from anything: a slot is held for a whole derivation, and at
  # SATURATION a derivation is an order of magnitude longer than one second.
  #
  # MEASURED on guerrilla (live, token-carrying, 2026-08-22): one derivation is
  # 2.45 / 2.80 / 3.36s serial-warm; FOUR concurrent — the cap — hold their
  # slots 10.18 / 10.38 / 10.57 / 10.76s. So every shed inside a saturated
  # window is answered ~10s before capacity actually exists.
  #
  # THAT NUMBER IS LOAD-BEARING, not cosmetic: `retry-after: 1` is what a
  # retrying client obeys. search-starter's SSR landing retries a 503 twice
  # (`templates/search-starter/lib/bp-fetch.ts`), so under a saturated cap all
  # three of its attempts landed at t+0.31s / t+1.44s / t+3.58s — every one of
  # them inside the 10.2s hold, every one shed — it then rendered an EMPTY
  # `bp-doc-id`, and the deploy HEALTH gate correctly refused to switch
  # (`deploy/site-deploy-node.sh` health_gate_node, which does NOT retry an
  # empty marker). The cap protected the box by failing every concurrent
  # deploy's health probe. See `stw10-backlog-flagship-health-pool`.
  #
  # The value must therefore OUTLAST a saturated derivation, with headroom over
  # the 10.8s worst case measured above. Clients clamp it (the SDK's
  # MAX_RATE_LIMIT_BACKOFF_MS, bp-fetch's MAX_RETRY_AFTER_MS), so it is advice a
  # caller is free to bound — it is not a promise to block for this long.
  @graph_corpus_retry_after_seconds 12

  def graph_corpus(conn, params) do
    case acquire_graph_corpus_slot() do
      {:ok, slot} ->
        try do
          derive_graph_corpus(conn, params)
        after
          release_graph_corpus_slot(slot)
        end

      :busy ->
        retry_after = graph_corpus_retry_after_seconds()

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:service_unavailable)
        |> json(%{
          ok: false,
          reason: "graph_corpus_busy",
          retry_after: retry_after,
          message:
            "too many concurrent /v1/graph derivations (limit #{graph_corpus_max_concurrency()}); retry in #{retry_after}s — a slot is held for a whole derivation, not for a moment"
        })
    end
  end

  defp derive_graph_corpus(conn, params) do
    dataset = request_dataset(conn)
    per_type_limit = graph_corpus_per_type_limit()

    # per-type limit (default: the list_documents hard cap) so the corpus isn't
    # silently truncated at the default page size of 100 — BOTH the node list
    # and corpus_edges read through this opts.
    opts =
      scope_opts(conn) |> Keyword.put(:dataset, dataset) |> Keyword.put(:limit, per_type_limit)

    list_opts = Keyword.put(opts, :perspective, :published)

    # Keep the schema STRUCTS, not just their names: they are threaded into the
    # edge fold below as a prefetch. `extract_edges/2` used to re-read this same
    # invariant list once PER DOCUMENT — 4096 identical queries on the live
    # corpus, the dominant cost behind a measured 34s first paint.
    schemas = Content.list_schemas(dataset, opts) |> visible_schemas(conn)
    all_types = Enum.map(schemas, & &1.name)

    case parse_graph_types(params["types"], all_types) do
      {:error, message} ->
        bad_request(conn, message)

      {:ok, types} ->
        # Node-listing phase, carrying the per-type-cap signal out instead of
        # discarding it: a type whose page comes back at the cap gets ONE count
        # query to confirm the ceiling actually fired (vs exactly-at-cap).
        {doc_lists, per_type_capped} =
          Enum.map_reduce(types, false, fn type, capped ->
            docs = Content.list_documents(type, dataset, list_opts)

            capped =
              capped or
                (length(docs) >= per_type_limit and
                   Content.count_documents(type, dataset, list_opts) > per_type_limit)

            {docs, capped}
          end)

        real_nodes =
          doc_lists
          |> List.flatten()
          |> Enum.map(fn d ->
            pid = Content.published_id(d.doc_id)
            %{id: pid, doc_id: pid, type: d.type, title: d.title || pid, phantom: false}
          end)
          |> Enum.uniq_by(& &1.id)

        node_ids = MapSet.new(real_nodes, & &1.id)

        # Fold over the documents the node phase ALREADY read (doc_lists is in
        # `types` order), instead of `corpus_edges/3` re-listing every type a
        # second time, and hand the fold its schema prefetch.
        #
        # `dangling: :skip` is the OPT-IN escape from `extract_edges/2`'s
        # per-target existence query — ONE un-batched round-trip per reference
        # value per document (~1,300 serial queries on the live corpus), held
        # against a single checked-out pool connection long enough to hit the
        # 15s DBConnection checkout ceiling and return a 500. This path NEVER
        # reads the boolean: the `edges` mapping below keeps only
        # from_id/to_id/kind/weight/plugin_source, and the phantom-node pass
        # answers the same "does the target exist?" question in memory off
        # `node_ids`. The flag is local to THIS call site — /v1/graph/dangling
        # (Graph.dangling/1), EdgeProjector and corpus_edges/3 read through the
        # unchanged `:resolve` default and keep resolving.
        edge_opts = opts |> Keyword.put(:schemas, schemas) |> Keyword.put(:dangling, :skip)

        raw_edges =
          types
          |> Enum.zip(doc_lists)
          |> Enum.flat_map(fn {_type, docs} ->
            Content.corpus_edges_for_docs(docs, dataset, edge_opts)
          end)
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
        node_budget = graph_corpus_node_budget()
        over_budget = length(all_nodes) > node_budget
        nodes = if over_budget, do: Enum.take(all_nodes, node_budget), else: all_nodes

        # Edge honesty: only edges whose BOTH endpoints survived the budget.
        # Under budget this is a no-op (every to_id has a real or phantom node);
        # over budget it kills the orphaned-edge class the old code shipped.
        kept_ids = MapSet.new(nodes, & &1.id)

        edges =
          Enum.filter(edges, fn e ->
            MapSet.member?(kept_ids, e.from_id) and MapSet.member?(kept_ids, e.to_id)
          end)

        json(conn, %{
          ok: true,
          dataset: dataset,
          nodes: nodes,
          edges: edges,
          truncated: per_type_capped or over_budget,
          truncation_reason: graph_truncation_reason(per_type_capped, over_budget)
        })
    end
  end

  # types= validation: nil/blank → all schemas; otherwise a comma-separated
  # list validated against the schema-name set. An unknown type is a hard 400 —
  # silently ignoring it would ship a graph that quietly ignores the caller's
  # narrowing (the exact dishonesty class this endpoint's truncation fix kills).
  defp parse_graph_types(raw, all_types) when raw in [nil, ""], do: {:ok, all_types}

  defp parse_graph_types(raw, all_types) when is_binary(raw) do
    requested =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case {requested, requested -- all_types} do
      {[], _} -> {:ok, all_types}
      {_, []} -> {:ok, Enum.filter(all_types, &(&1 in requested))}
      {_, unknown} -> {:error, "unknown types: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp parse_graph_types(_raw, _all_types),
    do: {:error, "types must be a comma-separated string of schema names"}

  defp graph_truncation_reason(true, true), do: "per_type_cap+node_budget"
  defp graph_truncation_reason(true, false), do: "per_type_cap"
  defp graph_truncation_reason(false, true), do: "node_budget"
  defp graph_truncation_reason(false, false), do: nil

  # ─── corpus visibility, keyed on the CALLER ──────────────────────────────
  #
  # The clamp itself lives in `Barkpark.Content.Schema.visible_schemas/2` —
  # the ONE owner, shared with `FinderLive.graph_payload/2` (the public
  # finder's inline twin of this derivation). It used to be defined HERE,
  # keyed `if PublicRead.public_read_token?(conn)` with an else-arm of "show
  # everything": an allow-list of one restricted tier that failed OPEN for
  # every principal it did not recognise — and FinderLive carried a second,
  # hand-copied derivation with no clamp at all, so an anonymous visitor read
  # every private type's titles through /finder (task-336d22b7722ea71e). The
  # shared function inverts the key — default-narrow, widen only for an
  # authenticated principal outside the public-read tier — and keying it on
  # `CallerContext.from_conn/1` means a tokenless caller lands in the narrow
  # arm by construction instead of falling through the tier test.
  #
  # The corpus read already pins `perspective: :published` (drafts never
  # leak); this is the schema-VISIBILITY half. Derived at READ TIME over the
  # schema rows this request already loaded (no extra query, no hardcoded
  # type list): flip a schema to private and the very next corpus read drops
  # it.
  #
  # Phantom nodes are deliberately NOT filtered — and that is now a MEASUREMENT,
  # not the shipped-as-is argument it used to be. A phantom is a referenced-but-
  # absent id with `title == id`, so for a public-read caller it can name a
  # private-type or an unpublished document. The question "is that a NEW leak?"
  # is answered per field shape by
  # `test/barkpark_web/controllers/graph_phantom_id_exposure_test.exs`
  # (dr-bl-graph-phantom-id-exposure, measured 2026-09-06), which drives ONE
  # public-read token at both routes and prints every response body:
  #
  #   shape                   | id via GET /v1/data/doc | phantom here | verdict
  #   ------------------------|-------------------------|--------------|--------
  #   `reference`             | YES                     | YES          | no new leak
  #   `arrayOf` of `reference`| YES                     | YES          | no new leak
  #   PortableDoc inline ref  | YES                     | NO           | never extracted
  #
  # The third row is the one the filing did not predict: `Edges.extract_field_edges/2`
  # has exactly two clauses (`reference`, `arrayOf`-of-`reference`) plus a `[]`
  # catch-all, so an inline PortableDoc ref produces no edge and therefore no
  # phantom at all. Every phantom this endpoint CAN emit carries an id the same
  # caller already reads off the referring document on the allowed doc route, so
  # dropping or hashing them would cost the dangling-edge signal without closing
  # anything. The test asserts the RELATIONSHIP (phantom ⇒ id already readable),
  # so narrowing the doc route later reds it here rather than silently voiding
  # this ruling.
  defp visible_schemas(schemas, conn) do
    Barkpark.Content.Schema.visible_schemas(
      schemas,
      Barkpark.Content.CallerContext.from_conn(conn)
    )
  end

  # ─── corpus admission cap (see the @graph_corpus_max_concurrency comment) ──

  defp acquire_graph_corpus_slot do
    # NO lazy `:ets.new` here. The table is created once from
    # `Barkpark.Application.start/2`; a request-path create would hand ownership
    # of the bound to a transient request process, and the bound would die (and
    # silently RESET) with it. If the table is somehow absent the `rescue` below
    # sheds rather than 500s.
    sweep_graph_corpus_slots()

    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + @graph_corpus_slot_ttl_ms
    :ets.insert(@graph_corpus_slots, {ref, self(), deadline})

    if :ets.info(@graph_corpus_slots, :size) > graph_corpus_max_concurrency() do
      :ets.delete(@graph_corpus_slots, ref)
      emit_graph_corpus_refused()
      :busy
    else
      {:ok, ref}
    end
  rescue
    # The table is created at application boot and never deleted, so this arm is
    # unreachable in a running system. It exists so that a bookkeeping accident
    # can never become a 500 on a read route: with no table there is no bound,
    # and an UNBOUNDED corpus derivation is the failure this cap was built to
    # prevent — so the safe answer is to shed, exactly as saturation races do.
    ArgumentError -> :busy
  end

  # The ONLY consumer of the row's `deadline`, and the accepted answer to the
  # capacity loss recorded on `sweep_graph_corpus_slots/0` below: a slot held by
  # an alive-but-wedged holder is now VISIBLE rather than bounded. Every refused
  # acquire says how many slots are held and how long the OLDEST has been held,
  # so an operator can tell a saturated cap (ages in seconds, ages that move)
  # from a wedged one (ages in minutes, ages that only grow) without reaching
  # into the ETS table. Age is derived from the row's deadline, which is stamped
  # at acquire as `now + @graph_corpus_slot_ttl_ms`.
  defp emit_graph_corpus_refused do
    now = System.monotonic_time(:millisecond)

    oldest_age_ms =
      @graph_corpus_slots
      |> :ets.tab2list()
      |> Enum.map(fn {_ref, _pid, deadline} -> now - deadline + @graph_corpus_slot_ttl_ms end)
      |> Enum.max(fn -> 0 end)

    :telemetry.execute(
      [:barkpark, :graph_corpus, :slot, :refused],
      %{slots: :ets.info(@graph_corpus_slots, :size), oldest_holder_age_ms: oldest_age_ms},
      %{cap: graph_corpus_max_concurrency()}
    )
  end

  defp release_graph_corpus_slot(ref) do
    :ets.delete(@graph_corpus_slots, ref)
  rescue
    # Runs from an `after` clause, i.e. AFTER the response was sent. Raising
    # here would crash the request process for a slot that no longer exists.
    ArgumentError -> :ok
  end

  # Reap slots whose owner DIED, and only those. Liveness is a fact about the
  # holder; the row's deadline is not, so it is diagnostic data here and nothing
  # more (see the @graph_corpus_max_concurrency comment for the over-admission
  # the deadline arm caused).
  #
  # WHY DEAD-ONLY LOSES NOTHING. `graph_corpus/2` wraps the derivation in a
  # lexical `try/after`, and `after` runs on an ordinary return, on a raise, on
  # a throw and on an in-process `exit/1` — so a 15s DBConnection timeout
  # releases its own slot without any sweep. What `after` does NOT cover is an
  # exit signal delivered from ANOTHER process to this untrapping one — `:kill`
  # is the un-trappable case, but `Process.exit(pid, :shutdown)` skips `after`
  # just the same. Every one of those leaves the owner DEAD, which is exactly
  # what this arm reclaims: it is load-bearing and must survive.
  #
  # THE TRADE, stated rather than discovered under review: an alive-but-wedged
  # holder now keeps its slot until it finishes, so a permanently stuck
  # derivation costs one slot of capacity for its lifetime. That is fail-CLOSED
  # capacity loss — the cap sheds a little more than strictly necessary — and it
  # matches this cap's own doctrine that at saturation a spurious 503 is the
  # safe error. Nothing in api/config bounds handler wall time, so the previous
  # behaviour was not "reclaiming stuck work": it was cancelling the bound on
  # HEALTHY long derivations. Killing a wedged owner is a different mechanism
  # with real blast radius (a broken connection instead of a clean 503) and is
  # deliberately NOT done here (filed: acpc-bl-graph-slot-wedged-live-holder).
  #
  # THAT FILING IS NOW RESOLVED, AND THE ANSWER IS: ACCEPT THE CAPACITY LOSS.
  # The kill-bound is not built, for three reasons, recorded here so the next
  # reader does not re-open the trade from the symptom alone:
  #
  #   1. It is a DIFFERENT MECHANISM, not a tighter version of this one. Every
  #      other arm of this cap answers a shed client with a clean 503 and a
  #      `retry-after`; `Process.exit(pid, :kill)` answers an in-flight client
  #      with a broken connection. And because `after` does not run on a kill,
  #      the sweep would have to delete the row itself — so the sweep stops
  #      being a reader of facts about holders and becomes a writer that acts on
  #      a wall-time GUESS, which is exactly the property that made the deleted
  #      deadline arm fail open.
  #
  #   2. ONLY ONE HALF OF A WEDGE IS EVEN UNBOUNDED, and it has no observed
  #      instance. A DB-bound derivation is self-limiting: Ecto's per-query
  #      default raises DBConnection.ConnectionError at 15s and `after` runs on
  #      a raise, so the slot frees itself with no sweep at all (proven by
  #      `graph_corpus_slot_wedge_acceptance_test.exs`). What is unbounded is the
  #      in-memory node/edge dedup — `List.flatten |> Enum.uniq_by` over the
  #      derived documents — which is pure BEAM work with no timeout in front of
  #      it, and nothing in api/config bounds handler wall time (`queue_target`
  #      appears once in the whole api tree, in `config/test.exs`; Bandit's
  #      `read_timeout` gates reading request BYTES, not handler execution). We
  #      have no production or CI report of that phase actually wedging — the
  #      2026-07-28 storm was pool exhaustion, i.e. the DB half. Building a kill
  #      path against a failure mode nobody has seen buys a real blast radius
  #      with a hypothetical.
  #
  #   3. The honest remedy for capacity loss is OBSERVABILITY, not a guess.
  #      There was no way to see this cap's occupancy from outside; there is now
  #      (`emit_graph_corpus_refused/0` above). If a wedge is ever observed —
  #      `oldest_holder_age_ms` climbing past minutes while `slots` sits at the
  #      cap — reopen this with the evidence, and set any TTL well clear of the
  #      32003ms storm request so a healthy slow derivation is never reaped.
  defp sweep_graph_corpus_slots do
    for {ref, pid, _deadline} <- :ets.tab2list(@graph_corpus_slots),
        not Process.alive?(pid) do
      :ets.delete(@graph_corpus_slots, ref)
    end

    :ok
  end

  @doc """
  Create the `/v1/graph` admission-cap slot table, owned by the caller.

  Called ONCE from `Barkpark.Application.start/2` so the table's owner is the
  application process rather than whichever request happened to arrive first —
  a bound whose bookkeeping dies with a request is not a bound. Idempotent: a
  second call (a re-boot in the test VM) is a no-op, and the rows are slots, so
  nothing is lost by NOT clearing them.
  """
  def init_graph_corpus_slots, do: ensure_graph_corpus_slots()

  defp ensure_graph_corpus_slots do
    case :ets.whereis(@graph_corpus_slots) do
      :undefined ->
        try do
          :ets.new(@graph_corpus_slots, [:named_table, :public, :set, read_concurrency: true])
        rescue
          # Lost the create race to a concurrent boot (the test VM re-starts the
          # supervision tree) — the table exists, which is all this needs.
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  defp graph_corpus_max_concurrency,
    do:
      Application.get_env(
        :barkpark,
        :graph_corpus_max_concurrency,
        @graph_corpus_max_concurrency
      )

  defp graph_corpus_retry_after_seconds,
    do:
      Application.get_env(
        :barkpark,
        :graph_corpus_retry_after_seconds,
        @graph_corpus_retry_after_seconds
      )

  @doc false
  # Test seam: hold a real slot from the test process so the admission cap can be
  # driven deterministically (no sleeping, no spawned load).
  def __acquire_graph_corpus_slot_for_test__, do: acquire_graph_corpus_slot()

  @doc false
  def __release_graph_corpus_slot_for_test__(ref), do: release_graph_corpus_slot(ref)

  defp graph_corpus_node_budget,
    do: Application.get_env(:barkpark, :graph_corpus_node_budget, @graph_corpus_node_budget)

  defp graph_corpus_per_type_limit,
    do: Application.get_env(:barkpark, :graph_corpus_per_type_limit, @graph_corpus_per_type_limit)

  # GRAPH ROOT RESOLUTION (gap #4 BOUND DECISION). Roots on ANY content doc, so
  # we DELIBERATELY do NOT call find_task_by_doc_id/2 (which hard-filters
  # d.type == "task" via fetch_task_exact/3 and returns not_found for every
  # non-task root). Instead we replicate find_task_by_doc_id's tenancy
  # discipline (workspace_id + project_id) AND reference_title/4's
  # published-before-draft ordering, but WITHOUT the type filter. When a doc_id
  # collides across types in one scope, the published-preferred first row wins
  # (v1 graph roots on the published-preferred row — documented contract).
  #
  # PERSPECTIVE GATE (task-d223068f55efbf47, SECURITY): resolution honours the
  # REQUESTED perspective. The old unconditional `pub OR draft` match meant a
  # draft-only id (no published twin) fell back to its `drafts.<id>` row at the
  # DEFAULT (published) perspective — any plain read token got a 200 confirming
  # the draft's existence and echoing its real title through the traversal
  # (live-proven). Now a default/published-perspective request resolves ONLY a
  # published root (draft-only id -> not_found); the draft fallback survives
  # solely for an explicit drafts/raw perspective from a non-anon-pinned tier.
  # Both callers (graph_show, graph_tasks) route through here, so both are
  # covered. Mutation proof: graph_draft_leak_test.exs.
  defp resolve_graph_root(id, conn) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)
    dataset = conn.params["dataset"]

    pub_id = Content.published_id(id)

    query =
      case graph_perspective(conn, conn.params) do
        :published ->
          from(d in Document, where: d.doc_id == ^pub_id)

        _drafts_or_raw ->
          draft = Content.draft_id(pub_id)

          from(d in Document,
            where: d.doc_id == ^pub_id or d.doc_id == ^draft,
            # THE THIRD FORK (task-ca05dd6a02a0b55f, closed here by
            # task-327276db28c99818). Published-vs-draft is the CORRECT axis and
            # it stays. The `asc: d.dataset` that used to sit under it is gone:
            # a dataset the caller did not name may not decide which row they
            # get (`Barkpark.Tasks.TwinResolver` rule 2), and the tie it broke
            # is now REFUSED for a task id rather than picked — see the
            # refuse_ambiguous_task! call below.
            order_by: [
              asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id),
              asc: d.id
            ]
          )
      end
      |> Params.maybe_filter_workspace(workspace_id)
      |> Params.maybe_filter_project(project_id)
      |> Params.maybe_filter_dataset(dataset)

    rows = Repo.all(query)

    # THE ONE RULE at the graph root (`Barkpark.Tasks.TwinResolver` — read that
    # moduledoc; this door writes no second rule). TASK-SCOPED on purpose: the
    # graph roots on ANY content type, and a second copy of a non-task document
    # in another dataset is the dataset feature working, so only a `type ==
    # "task"` id spanning datasets with no `?dataset=` refuses (409
    # `ambiguous_dataset`, naming both). Every non-task root — and every task id
    # with one row in scope — resolves byte-identically to before.
    #
    # AFTER the query, BEFORE the answer, and after the perspective filter is in
    # the query: a draft-only id still 404s at the published perspective (the
    # graph_draft_leak_test.exs gate), and the refusal can only name rows this
    # caller's own scope already admitted.
    TwinResolver.refuse_ambiguous_task!(rows, pub_id, dataset)

    case List.first(rows) do
      %Document{} = doc -> {:ok, doc}
      _ -> {:error, :not_found}
    end
  end

  # The graph read perspective, clamped through the AnonPerspective chokepoint.
  # Params.parse_perspective keeps this surface's `?drafts=true` alias, but an
  # anon-pinned caller (tokenless, or the browser-shipped public-read
  # credential — charter D60/D61) is pinned to :published regardless of the
  # param. DEFENSE-IN-DEPTH ONLY on this route today: public-read is already
  # 403 at /v1/graph/* (route-level), so this clamp's observable delta is ~zero
  # — the LOAD-BEARING gate is resolve_graph_root honouring the perspective.
  defp graph_perspective(conn, params) do
    if AnonPerspective.anon_pinned?(conn) do
      :published
    else
      Params.parse_perspective(params)
    end
  end

  # Build the keyword opts for Content.Graph.traverse/2 from query params + the
  # resolved root (for dataset/scope). perspective rides graph_perspective/2 —
  # the AnonPerspective-clamped resolver — NOT the conn-blind param parse alone
  # (the old comment's ":require_token IS the gate" assumption was invalidated
  # by the browser-shipped public-read token, #6270 / SR-2).
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
    |> Keyword.put(:perspective, graph_perspective(conn, params))
  end

  # The dataset string a graph read scopes to. The graph endpoints have no
  # :doc_id segment to derive a dataset from, so we read the optional `dataset`
  # query param (defaulting to "production", the canonical content dataset).
  # Fails SOFT on purpose: a non-binary `dataset` (e.g. `?dataset[]=production`,
  # which Plug decodes to a list) used to flow straight into is_binary-guarded
  # callees with no fallback clause — Tasks.Events.replay_since/3 and
  # Tasks.Fleet.roster/2 among seven call sites — raising FunctionClauseError
  # (500) before any Repo call. A scope selector with a documented default
  # falls back to that default rather than 400ing six live routes; the `kind`
  # FILTER in edges/2 is the deliberate opposite and returns 400.
  defp request_dataset(conn) do
    case conn.params["dataset"] do
      dataset when is_binary(dataset) -> dataset
      _ -> "production"
    end
  end

  # ─── field-visibility seal (fail-closed) ────────────────────────────────
  # Redact each task doc's `content` under the request's caller through the
  # canonical Envelope chokepoint (`Params.seal/3` → `Envelope.redact/4`) before
  # it is serialized. ONE caller + "task"-schema resolve per request, applied to
  # every doc the response echoes — the list, single-doc, edges/next, and
  # mutation-ack paths all pass their docs through here so NO `render_doc`
  # emission is fail-open. Latent hardening: with no task field declaring
  # visibility today the wire is byte-identical; it fails closed the moment one
  # does. Siblings already sealed: `Barkpark.Tasks.Query`'s measure/agg branch
  # and the board peek panel — this closes the JSON echo they left behind.
  defp seal_docs(docs, conn) when is_list(docs) do
    {caller, schema} = seal_ctx(conn)
    Enum.map(docs, &Params.seal(&1, caller, schema))
  end

  defp seal_doc(%Document{} = doc, conn) do
    {caller, schema} = seal_ctx(conn)
    Params.seal(doc, caller, schema)
  end

  # The request principal + the resolved "task" schema — resolved ONCE and
  # reused across a list. A missing schema (`{:error, :not_found}`) yields nil:
  # `Envelope.redact/4` then still drops encrypted ciphertext, and declared
  # visibility (which needs the schema) simply has nothing to act on.
  defp seal_ctx(conn) do
    schema =
      case Content.Schema.get_schema_for_redaction(
             "task",
             request_dataset(conn),
             scope_opts(conn)
           ) do
        {:ok, s} -> s
        _ -> nil
      end

    {CallerContext.from_conn(conn), schema}
  end

  # ─── POST /v1/tasks/edges ───────────────────────────────────────────────

  def add_edge(conn, params) do
    with {:ok, from_id} <- Params.fetch_string(params, "from_id"),
         {:ok, to_id} <- Params.fetch_string(params, "to_id"),
         {:ok, from_doc} <- find_task_by_doc_id(from_id, conn),
         {:ok, to_doc} <- find_task_by_doc_id(to_id, conn) do
      kind = params["kind"] || "blocks"

      # The STRUCTS, not their ids: both were resolved through the scoped
      # pre-flight above, and `Edges.add_dep/3` twin-canonicalises from the
      # struct so it never has to read an endpoint back by primary key.
      case Tasks.add_dep(from_doc, to_doc, kind, caller_token_id(conn)) do
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
  # Backs the `bp task` labels endpoint, which in turn backs
  # paper-claim-files' `file-claim:<path>` ownership labels.

  def relabel(conn, %{"doc_id" => doc_id} = params) do
    add = Params.string_list(params["add"])
    remove = Params.string_list(params["remove"])

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        case Tasks.relabel_by_id(task.id, add, remove, caller_token_id(conn)) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: Params.render_doc(seal_doc(doc, conn))})

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
        case Tasks.update_paper_refs_by_id(task.id, add, remove, caller_token_id(conn)) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: Params.render_doc(seal_doc(doc, conn))})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: Params.reason_to_string(reason)})
        end

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # Task 5 (session-handoff): POST /v1/tasks/:doc_id/sessions. Clone of
  # papers/2 — reads add/remove session doc-ids from params, finds the task
  # scoped by workspace+project, then delegates to
  # Tasks.update_session_refs_by_id/4 (advisory-lock + CAS-on-rev +
  # task.referenced mutation_event). Returns { ok, doc }. Sessions are
  # referenced by slug string only; no FK.
  def sessions(conn, %{"doc_id" => doc_id} = params) do
    add = Params.string_list(params["add"])
    remove = Params.string_list(params["remove"])

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        case Tasks.update_session_refs_by_id(task.id, add, remove, caller_token_id(conn)) do
          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: Params.render_doc(seal_doc(doc, conn))})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: Params.reason_to_string(reason)})
        end

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── POST /v1/tasks/:doc_id/move ────────────────────────────────────────
  # rail-l3: re-parent a task. Body shape:
  #   { "new_parent_id": "<doc-id>" }   move under that task's rail
  #   { "new_parent_id": null } | {}    move to the root (parent_id removed)
  #
  # Resolution mirrors every other endpoint (bare-id → drafts. fallback via
  # find_task_by_doc_id) for BOTH the subject and the new parent. Guards:
  #   * new parent must exist AND be a task → 409 invalid_parent
  #     (find_task_by_doc_id already hard-filters type == "task")
  #   * a move under the task itself or one of its descendants → 409 cycle
  #   * a no-op move (already that parent) → 200 with the doc unchanged
  #
  # Response envelope: { ok, doc } plus `rail_rev` = the DESTINATION rail's
  # digest (omitted on a move to root) and `from_rail_rev` = the SOURCE rail's
  # digest (omitted when the task was already at root). Both are read back AFTER
  # the write — `Tasks.Rail.rev/2` computes on demand, so the membership flip
  # flips both digests with no bump plumbing.
  def move(conn, %{"doc_id" => doc_id} = params) do
    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        old_parent = task_parent_id(task)

        case resolve_new_parent(Map.get(params, "new_parent_id"), conn) do
          {:ok, new_parent_doc_id} ->
            case Tasks.move_by_id(task.id, new_parent_doc_id, caller_token_id(conn)) do
              {:ok, %Document{} = doc} ->
                scope = scope_opts(conn) |> Keyword.put(:dataset, doc.dataset)

                json(
                  conn,
                  %{ok: true, doc: Params.render_doc(seal_doc(doc, conn))}
                  |> maybe_put(:rail_rev, Tasks.rail_rev(new_parent_doc_id, scope))
                  |> maybe_put(:from_rail_rev, Tasks.rail_rev(old_parent, scope))
                )

              {:error, reason} ->
                conn
                |> put_status(:conflict)
                |> json(%{ok: false, reason: Params.reason_to_string(reason)})
            end

          {:error, :invalid_parent} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: "invalid_parent"})
        end

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # Resolve the requested new parent to its canonical (published) doc_id, or nil
  # for a root move (null / absent / blank). A non-blank id that resolves to no
  # task → {:error, :invalid_parent} (covers both "no such row" and "not a
  # task", since find_task_by_doc_id hard-filters type == "task"). We store the
  # PUBLISHED id (drafts. stripped) so content.parent_id matches the bare-id
  # convention every other rail reader uses (Tasks.Rail strips drafts. on both
  # sides anyway, but keeping the stored value canonical avoids a drafts. twin
  # leaking into the hierarchy pointer).
  defp resolve_new_parent(nil, _conn), do: {:ok, nil}
  defp resolve_new_parent("", _conn), do: {:ok, nil}

  defp resolve_new_parent(pid, conn) when is_binary(pid) do
    case find_task_by_doc_id(pid, conn) do
      {:ok, %Document{} = parent} -> {:ok, Content.published_id(parent.doc_id)}
      {:error, :not_found} -> {:error, :invalid_parent}
    end
  end

  defp resolve_new_parent(_other, _conn), do: {:error, :invalid_parent}

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
  #
  # ── THE ONE RULE (task-49eef068420df918 + task-baf9b74a0ffc83f4) ─────────
  # The exact-then-`drafts.`-fallback dance above is now ONE query decided by
  # `Barkpark.Tasks.TwinResolver` — read that moduledoc for the rule. The
  # observable deltas: a `drafts.` twin can no longer answer for a doc_id whose
  # published row exists but was filtered out by nothing (it never should have),
  # and a doc_id living in two datasets is REFUSED (409 naming both) instead of
  # answered from whichever dataset sorts first. `?dataset=` on the task doors is
  # honoured as the caller's disambiguator — it used to be ignored here.
  defp find_task_by_doc_id(doc_id, conn) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    fetch_task_exact(doc_id, workspace_id, project_id, dataset: conn.params["dataset"])
  end

  # Single-doc fetch by exact doc_id string, scoped to workspace + project.
  # Everything is a task — the single `type == "task"` filter covers root
  # tasks (goals), phases, and leaf work-tasks.
  #
  # ── THE DATASET COLLISION (task-0c30e7b99ad87cec) ───────────────────────
  #
  # `documents` is unique on `(doc_id, type, dataset_id)` — NOT on
  # `(doc_id, type)` (migration 20260527134000_flip_uniqueness_to_dataset_id).
  # One task doc_id may therefore live in TWO datasets inside a single
  # workspace/project, and this reader carries no dataset discriminator (by
  # design: `bp task get <id>` names no dataset). Before this change the read
  # was a bare `Repo.one/1`, so that shape raised `Ecto.MultipleResultsError`
  # → a 500 on EVERY call, forever, for a row the ready queue happily lists:
  # a listing that serves ids its own by-id reader cannot resolve. Measured on
  # guerrilla 2026-09-02: `bp task ready` served `akbr-feedback-2026-08-epic`
  # TWICE in one page (once per dataset) and three consecutive `bp task get`
  # calls returned `internal_error`. An agent reads that as transient and
  # retries blindly forever — the failure this row was filed for.
  #
  # The repair is the rule the CANONICAL slug resolver already spells
  # (`Barkpark.Content.Graph.resolve_doc/3`, `@canonical capability:slug-resolve`):
  # order deterministically, then `LIMIT 1`. This function is a fork of that
  # resolver that kept the scoping and dropped the `limit(1)`. The order is
  # TOTAL — published-first, then `dataset`, then `id` — so the same call
  # returns the same row on every request and across every pooled connection;
  # a partial order would trade a 500 for a silently-alternating answer, which
  # is the worse defect (see queue.ex's `id` tiebreak, same reasoning).
  #
  # A `LIMIT 1` here can only ever CHANGE the outcome for a doc_id that has
  # more than one row in scope — the shape that used to raise. A doc_id with
  # exactly one row (every ordinary task) reads byte-identically.
  # THE REPAIR (task-49eef068420df918 + task-baf9b74a0ffc83f4). The total order
  # above bought determinism and paid for it with a SILENT WRONG ROW: the tie it
  # broke by `asc: d.dataset` is precisely the tie the caller named nothing to
  # break. `Barkpark.Tasks.TwinResolver` owns the rule now (published wins, a
  # draft twin never wins over a published row, and an unnamed cross-dataset tie
  # is REFUSED at 409 rather than picked). A doc_id with exactly one row in scope
  # — every ordinary task — still reads byte-identically.
  #
  # The scoping stays EXACTLY as it was (`Params.maybe_filter_*`, fail-open on
  # nil): `Tasks.Claim` scopes fail-CLOSED through `Scope.scope_to_workspace/3`,
  # and unifying the two is a different row's work, so the resolver takes the
  # caller's scoping rather than imposing one.
  defp fetch_task_exact(doc_id, workspace_id, project_id, opts) do
    TwinResolver.resolve(
      doc_id,
      fn q ->
        q
        |> Params.maybe_filter_workspace(workspace_id)
        |> Params.maybe_filter_project(project_id)
      end,
      &Repo.all/1,
      opts
    )
  end

  # ─── rail-l1: rail-awareness envelope extras ────────────────────────────
  # rail_rev + typed notices ride the claim / claim_by_id / close / prime
  # responses so a BURST-based agent sees rail drift and new blockers on its
  # next server touch — no polling, no new channel. See Barkpark.Tasks.Rail.
  #
  # ADVISORY ONLY at L1: a blocked_while_claimed notice never changes a status
  # code and NEVER gates a write — a close still commits with an unsatisfied
  # blocker (refusal / fencing is the separate L4 task). rail_rev is an ETag:
  # clients compare it `≠`, not `<`.

  # Merge rail_rev (when the subject task has a parent) + notices (when
  # non-empty) into a subject-task envelope (claim / claim_by_id / close).
  #
  # `baseline_rev` is the rail_rev computed BEFORE this request's own write
  # (nil for queue-claim, whose subject is unknown pre-write). The
  # rail_changed comparison runs `observed_rail_rev` against `baseline_rev`,
  # NOT against the post-write rev — so a worker's OWN claim/close never trips
  # its own rail_changed; only a concurrent actor's edit does. The response's
  # `rail_rev` FIELD reports the post-write rev — the fresh baseline the worker
  # carries into its next action (nobody else acting → next baseline == this
  # field → match → silence).
  defp with_rail_extras(envelope, %Document{} = task, baseline_rev, conn, params) do
    parent_id = task_parent_id(task)
    scope = scope_opts(conn) |> Keyword.put(:dataset, task.dataset)
    rail_rev = Tasks.rail_rev(parent_id, scope)
    compare_rev = baseline_rev || rail_rev

    notices =
      []
      |> add_execution_policy_notices(task)
      |> add_blocked_notice(task)
      |> add_rail_changed_notice(parent_id, compare_rev, rail_rev, params["observed_rail_rev"])

    envelope
    |> maybe_put(:rail_rev, rail_rev)
    |> maybe_put_notices(notices)
  end

  # The rail_rev of `task`'s parent rail as it stands NOW — computed before a
  # claim/close write so it captures the rail the worker is acting against
  # (the rail_changed comparison baseline). nil when the task has no parent.
  defp pre_write_rail_rev(%Document{} = task, conn) do
    Tasks.rail_rev(task_parent_id(task), scope_opts(conn) |> Keyword.put(:dataset, task.dataset))
  end

  # prime rehydrates a WORKER: the rails map covers each DISTINCT parent of the
  # worker's in-progress claims, and notices surface blocked_while_claimed for
  # any of those claims. No top-level rail_rev in prime — the map is the right
  # shape when a worker may hold claims across several rails. prime carries no
  # observed_rail_rev, so no rail_changed notice here.
  defp prime_rails(in_progress, conn) do
    scope = scope_opts(conn)

    in_progress
    |> Enum.map(fn %Document{} = d -> {task_parent_id(d), d.dataset} end)
    |> Enum.reject(fn {parent_id, _dataset} -> is_nil(parent_id) end)
    |> Enum.uniq()
    |> Map.new(fn {parent_id, dataset} ->
      {parent_id, Tasks.rail_rev(parent_id, Keyword.put(scope, :dataset, dataset))}
    end)
  end

  defp prime_notices(in_progress) do
    Enum.flat_map(in_progress, fn %Document{} = d -> add_blocked_notice([], d) end)
  end

  defp task_parent_id(%Document{content: content}) do
    case content && Map.get(content, "parent_id") do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  defp add_blocked_notice(notices, %Document{} = task) do
    case Tasks.unsatisfied_blockers(task.id) do
      [] ->
        notices

      blockers ->
        notices ++
          [%{type: "blocked_while_claimed", task_id: task.doc_id, blockers: blockers}]
    end
  end

  defp add_execution_policy_notices(notices, %Document{content: content}) do
    case get_in(content || %{}, ["claim", "execution_policy", "notices"]) do
      policy_notices when is_list(policy_notices) -> notices ++ policy_notices
      _ -> notices
    end
  end

  # Fires when the caller supplied observed_rail_rev and it differs from the
  # PRE-write baseline (a concurrent actor moved the rail). Reports the current
  # (post-write) rail_rev so the worker can refresh its baseline.
  defp add_rail_changed_notice(notices, parent_id, baseline_rev, current_rev, observed)
       when is_binary(parent_id) and is_binary(baseline_rev) and is_binary(current_rev) and
              is_binary(observed) and observed != "" and observed != baseline_rev do
    notices ++ [%{type: "rail_changed", parent_id: parent_id, rail_rev: current_rev}]
  end

  defp add_rail_changed_notice(notices, _parent_id, _baseline, _current, _observed), do: notices

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Audit hardening: the id of the api_token that authenticated this request,
  # threaded into task-workflow mutation_events so the audit trail attributes
  # each mutation to the CALLING TOKEN (distinct from the self-declared
  # worker_id). `nil` for an anonymous / tokenless request — the stamp is then
  # omitted, keeping events backward-compatible. Metadata only; it never
  # affects authorization.
  defp caller_token_id(conn) do
    case conn.assigns[:api_token] do
      %{id: id} -> id
      _ -> nil
    end
  end

  # ─── POST /v1/fleet/beat ────────────────────────────────────────────────
  # Personal Dev Fleet presence heartbeat (Barkpark.Tasks.Fleet). Registration
  # rides the plain Content path; every later beat is the zero-row atomic
  # write (PDF-D17). `dataset` query param defaults "production", the same
  # request_dataset/1 the graph reads use; scope opts feed ONLY the
  # registration create.

  def fleet_beat(conn, params) do
    dataset = request_dataset(conn)

    case Fleet.beat(params, dataset, scope_opts(conn)) do
      {:ok, receipt} ->
        json(conn, %{
          ok: true,
          registered: receipt.registered,
          doc: receipt.doc
        })

      {:error, :missing_worker} ->
        bad_request(conn, "worker is required")

      {:error, :invalid_status} ->
        unprocessable(
          conn,
          "invalid_status",
          "status must be one of: " <> Enum.join(Fleet.statuses(), " | ")
        )

      {:error, :invalid_ttl} ->
        unprocessable(conn, "invalid_ttl", "ttl must be a positive integer (seconds)")

      {:error, :invalid_capacity} ->
        unprocessable(
          conn,
          "invalid_capacity",
          "capacity must be a free-form string or an object with size_class (light | standard | heavy | xl), non-negative slots_total/slots_free (slots_free <= slots_total), and an optional non-negative budget"
        )

      {:error, :stale_beat} ->
        conflict(conn, :stale_beat, nil)

      {:error, other} ->
        unprocessable(conn, "beat_failed", "beat failed: #{inspect(other)}")
    end
  end

  # ─── GET /v1/fleet/roster ───────────────────────────────────────────────
  # The fleet roster — WORKSPACE-SCOPED, with online/offline computed at read
  # time, fail closed. The envelope key is `documents` (PDF-D21): the one key
  # every installed bp binary renders as a real table; a bespoke key would
  # degrade to one crammed KV cell.
  #
  # Owner ruling, 2026-09-01 (task-4e2986e8609670d7, criterion 0), verbatim:
  #
  #   orchestrator, delegated; owner informed 2026-09-01 — RULED A: scope the
  #   roster read with scope_opts(conn); the global view is for the OPERATOR
  #   tier only, NOT any `admin` bit.
  #
  # This route READ globally while `fleet_beat/2` two functions up WROTE
  # scoped — the asymmetry that leaked every workspace's listeners, and each
  # worker's in-progress task id, to any bearer holding `read`. Both halves now
  # thread the same `scope_opts(conn)`.
  #
  # `scope_opts/1` ALWAYS carries `:workspace_id` for a conn — a real id, or
  # the `:shared_only` sentinel when the request resolved no workspace — so a
  # request can never reach `Fleet.roster/2`'s `global: true` opt-in, and never
  # falls into its fail-closed nil arm by accident either. See the ruling and
  # the operator-tier note in `Barkpark.Tasks.Fleet`'s moduledoc.

  def fleet_roster(conn, _params) do
    dataset = request_dataset(conn)
    json(conn, %{ok: true, documents: Fleet.roster(dataset, scope_opts(conn))})
  end

  defp unprocessable(conn, reason, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, reason: reason, message: message})
  end

  defp maybe_put_notices(map, []), do: map
  defp maybe_put_notices(map, notices), do: Map.put(map, :notices, notices)

  # A `filter[...]` this route cannot honour (gr-bl-tasks-route-parent-filter-ignored).
  # Distinct `reason` from the generic bad_request so a caller (and the CLI) can
  # tell "your filter was refused" from "your body was malformed", and `details`
  # carries the machine-readable key + the accepted set. Mirrors the
  # `invalid_filter` code Content.Errors emits on the data-query surface.
  defp invalid_filter(conn, reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      ok: false,
      reason: "invalid_filter",
      message: Params.filter_message(reason),
      details: Params.filter_details(reason)
    })
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
