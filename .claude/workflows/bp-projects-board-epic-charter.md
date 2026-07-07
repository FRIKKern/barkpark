<!-- doc-tier: agent | canonical-for: barkpark-projects-board-epic | budget: 4000tok -->

# Barkpark Projects — native task board epic charter

The epic's memory. North star: `.claude/workflows/bp-task-design-language-spec.md`
(esp. **§0 THE CRITERION** — "feels alive; you always feel progress" — and **§1** the
shared white-ladder status vocabulary). This board is the **GUI realization** of that
spec: the browser sibling of the `bp tasks` TUI (`internal/taskboard/`, Go — mirror the
DESIGN, never the code).

## Vision

Open `/admin/projects` in Studio and land on a live kanban over the REAL `type:task`
documents (the source of truth). Five columns down the status ladder — **open ○(50%) ·
ready ○(100%) · in_progress ⠋(Braille, blue, spinning) · blocked !(amber) · done ✓(teal)**
— cancelled folded to a dim tally. Each card: title · priority pip · goal(parent) chip ·
labels · worker · criteria `2/3` · and, when mirrored by the just-shipped GitHub bridge, a
**GitHub badge** (`#42` + sync state + click-through to the issue). Atop it a **momentum
header** — `◐ N in flight · ○ N ready · ✓ N done today · NN%` with an animated fill bar.
It **feels alive** the instant it paints (pure-CSS Braille spinner breathes at rest), then
moves for real: an agent claims/closes anywhere and the card flashes, slides to its new
column, the done-today tally climbs, the bar grows — you watch momentum. Drag a card
between columns and lifecycle flips **through the fenced claim/close primitives** — a card
another worker holds refuses the drop, never corrupts the claim. Group/filter by
goal/priority/label. The GUI twin of the terminal board: same glyphs, same motion, same
always-a-next-step.

## Decisions

1. **Surface = a NEW dedicated `:ops` LiveView `Barkpark.Plugins.Tasks.Web.BoardLive` at
   `/admin/projects`** — the pulse `DashboardLive` precedent verbatim (mount → subscribe on
   `connected?` → periodic `:refresh` → render). *Why:* `studio_live.ex`/`pane_builder.ex`
   are multi-session-hot; a standalone plugin LiveView keeps every board slice file-disjoint
   and reuses the proven `:ops` admin gate + desk-link path (`/admin/*` dodges the
   `/studio/<x>` scoper that mangled `/studio/pulse`). The tasks plugin owns `type:task`, so
   the board belongs in its namespace.

2. **Pure organizer `Barkpark.Tasks.Board` lives in CORE, not the plugin.** `build/2` is a
   deterministic, `now`-injected, LiveView-free function (bucketing + ready overlay +
   momentum + per-card projection); `snapshot/1` is a thin impure loader over it. *Why:* the
   momentum/ready logic is task-substrate logic, unit-testable without a socket and shareable
   with the existing `task-board` PortableDoc component + a future web surface. "Core owns
   machinery, plugin owns wiring" (the Bulldocs/Tasks lift doctrine). Reject a new
   `Barkpark.Projects.*` top-level — this is task logic; the brand "Projects" is the route +
   desk label only.

3. **`ready` is a DERIVED, read-only overlay computed IN-MEMORY from the fetched corpus** —
   a card is ready when `lifecycle_status ∈ {open, blocked}` AND every outbound `blocks`-edge
   target is `done` (mirrors `Tasks.Queue.ready_query/1` + the TUI `composeSnapshot`). *Why:*
   there is no stored `ready` status — it is a graph property. The loader reads the corpus
   **globally** (dataset default `production`, like `github` OpsLive's `Health.snapshot` and
   `prime`'s nil-workspace = all-rows path) and attaches each card's blocker statuses;
   `build/2` derives ready purely. Do **NOT** call `Queue.ready/1` with a nil workspace — it
   `scope_to_workspace(nil)` → `where: false` → silently empty (the fail-closed trap). Ready
   is never a drop target — a drag can't satisfy a dependency graph.

4. **Drag-to-restage writes THROUGH the fenced primitives, never a raw lifecycle patch.**
   →in_progress = `Tasks.claim_by_id(id, "studio:<user>", scope)` (same-worker re-claim is a
   lease renewal; a DIFFERENT worker's card → `:not_ready` → refuse + snap back, never
   clobber). →done/cancelled/blocked = `Tasks.close(uuid, worker, observed_epoch: …,
   lifecycle_status: …)` (only the holder closes; a non-holder → `:fenced_off` → refuse).
   Ready = non-drop. Reopen-to-open is DEFERRED (no clean primitive). *Why:* the wish demands
   "honoring claims/fencing — never corrupt a claimed task"; the primitives already carry
   advisory-lock + epoch-CAS + cascade-unblock, so the worst case is a refused drop. Worker
   identity = `studio:<current_user>` (the board is a supervisor tool; a human moving a card
   into In Progress IS the assignment gesture).

5. **Realtime rides the EXISTING task broadcast — no new process.** On `connected?`,
   subscribe to `"documents:#{dataset}"`; task CAS writes fire
   `{:document_changed, msg}` there (verified: `Tasks.Internal.emit_broadcasts` →
   `Content.broadcast_document_mutation`; `msg.mutation ∈ {task.claimed, task.closed,
   task.mutated, task.relabeled, task.reparented}`, `msg.doc = %{doc_id, title, status,
   content, updated_at}`). Re-bucket the changed card, flash it, climb done-today; a slow
   `:refresh` reconciles windowed stats. *Why:* delivers §0's "watch momentum" for free off a
   proven stream; NO boot-started DB worker (the github-bridge CI landmine that breaks the
   full ExUnit sandbox). The CSS spinner means it breathes even before the socket connects.

6. **Glyphs/colors/motion are the §1 manifest verbatim — the identical Unicode character,
   never a lookalike SVG.** Hard-code the white ladder (open `○`@50% · ready `○`@100% ·
   in_progress Braille `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` blue · blocked `!` amber · done `✓` teal blink×3 ·
   cancelled `✕` neutral) + the spec's light/dark hexes as a small Elixir glyph map + a
   `<style>` block of `@keyframes` in the render (pulse's self-contained inline discipline —
   no new asset, CSP-safe). Honor `prefers-reduced-motion` (freeze spinner on `⠿`, skip the
   done-flash). *Why:* user directive is exact ("same icons as TUI precisely"); CSS-only
   motion works in any static render and passes goldens.

7. **GitHub badge = a pure `content.github` read, attached in the organizer's card
   projection.** Read via `Barkpark.Plugins.Github.Link.get/1` (+ `synced?/1`) — a pure
   content read, no plugin call, safe even plugin-dark. Render `#issue` + sync dot
   (synced/detached) + href `github.com/<repo>/issues/<n>`; absent `content.github` → no
   badge, never fabricated. *Why:* makes tasks⇄GitHub visible on the wall for near-zero cost;
   the bridge stamps `content.github` on every mirror.

8. **No openapi regen, no bp verb.** An `:ops` `:live` route is NOT an HTTP API bucket —
   verified `docs/openapi.json` carries zero `/admin/pulse`/`/admin/github` refs. Builders
   run `mix barkpark.openapi` as belt-and-braces and commit ONLY if it diffs (expected
   no-op).

## The criterion — how each wave serves "feels alive"

- **Wave 1 (read-only baseline):** the momentum header IS the always-on progress read; the
  pure-CSS Braille spinner makes in_progress cards breathe at rest (alive before any event);
  the Ready column is the visible always-a-next-step. Static feels-alive, zero runtime.
- **Wave 2 (realtime):** flash-on-change + card-slide + climbing done-today tally + growing
  bar — "you watch momentum"; movement is never silent (§0.3, §0.4, §0.6).
- **Wave 3 (drag):** completion by hand is felt (done blink×3), and progress is one gesture —
  without ever corrupting a claim.
- **Wave 4 (group/filter) & Wave 5 (badge polish/web parity):** keep momentum legible on a
  big board and extend the alive surface to papers/web.

## Roadmap (integration order)

**Wave 1 — read-only feels-alive baseline** (this wave; 2 slices)
1. `board-organizer` — pure `Barkpark.Tasks.Board` (`build/2` + thin `snapshot/1`). MEDIUM.
2. `board-liveview-readonly` — `BoardLive` + `:ops` route + desk item + inline CSS vocabulary
   + GitHub badge render. MEDIUM. *(sequenced after slice 1; builds against its API.)*

**Wave 2 — realtime motion** (after wave 1)
3. `board-realtime` — subscribe `documents:#{dataset}`, re-bucket + flash + climb done-today
   (seen-set guard) + `:refresh` reconcile. MEDIUM. *(touches board_live.ex — after slice 2.)*

**Wave 3 — drag write-through** (after wave 2)
4. `board-drag-restage` — CSP-safe drag hook → `handle_event("restage")` through
   `claim_by_id`/`close` with `studio:<user>`, fence-refuse + snap-back. LARGE.

**Wave 4 — group / filter** (after wave 1; can parallel wave 3 if edits stay in Board + a
   disjoint handler)
5. `board-group-filter` — swimlane group-by (goal/priority/label) + filter chips, URL-param
   shareable, all through the pure organizer. MEDIUM.

**Wave 5 — reach & polish**
6. `board-web-parity` — wire the snapshot into the existing `task-board` PortableDoc block +
   web `portable-doc.tsx` for a live board embeddable in a paper. LARGE.
7. `board-docs-parity-gate` — TASK-SYSTEM Studio section + design-spec build-status row +
   a glyph/hue parity assertion vs `internal/taskboard/theme.go`. SMALL.

## Pure organizer contract (slices depend on this)

`Barkpark.Tasks.Board.build(cards, opts) :: %{columns, cancelled_count, momentum,
cards_by_id}` — PURE. `opts[:now]` a `DateTime` (default injected by `snapshot/1`).

Normalized `card` (loader produces from a `%Document{}`): `%{doc_id, title, priority,
parent_id, labels, worker, lifecycle_status, criteria: %{met,total}|nil, github: map|nil,
blocker_statuses: [String.t()], updated_at}`.

- `columns` = `%{open: [card], ready: [card], in_progress: [card], blocked: [card],
  done: [card]}`.
- Bucketing: in_progress→:in_progress; done→:done; cancelled→`cancelled_count` (folded, not
  a column); else ready? (open|blocked ∧ all `blocker_statuses=="done"`) → :ready; open→:open;
  blocked→:blocked.
- Order: ready by `priority` asc-nulls-last then `updated_at`; others `updated_at` desc; done
  recedes (rendered dim).
- `momentum` = `%{in_flight: len(in_progress), ready: len(ready), done_today: count(done
  with updated_at same UTC day as now), pct: round(len(done)/max(total_non_cancelled,1)*100)}`.
- Each card carries a derived `glyph`/`color_role` per §1 (ready = `○` full, open = `○` dim).

`Barkpark.Tasks.Board.snapshot(opts)` — impure: fetch `type:task` (content.kind=="task")
docs for `opts[:dataset]="production"` GLOBALLY (no fail-closed scope), attach each card's
`blocker_statuses` (lifecycle_status of every outbound `blocks`-edge target — batched or
per-task via `Tasks.edges(pk, direction: :outbound, kind: :blocks)`), reuse
`Tasks.criteria_progress/1` and `Github.Link.get/1`, then call `build/2`.

## Wave log

### Wave 2026-07-07 — Wave 1 (read-only feels-alive baseline), both slices GREEN

**Landed.** The whole Wave-1 roadmap in one pass:
- Slice 1 `board-organizer`: `Barkpark.Tasks.Board` — pure `build/2` (five-column
  bucketing, derived `ready` overlay mirroring `Queue.ready_query/1`, cancelled fold,
  momentum block, per-card §1 Unicode glyph/color_role) + thin impure `snapshot/1`
  (global `type:task` read per dataset, no fail-closed scope, draft-twin collapse,
  batched blocks-edge blocker statuses, normalization). Unit + 1 DB integration test.
- Slice 2 `board-liveview-readonly`: `Barkpark.Plugins.Tasks.Web.BoardLive` at
  `/admin/projects` (`:ops`, pulse `DashboardLive` shape), momentum header + animated
  fill bar, 5 status-ladder columns + cancelled tally, cards (title·priority·goal·
  labels·worker·criteria·§1 glyph·GitHub badge), **pure-CSS Braille spinner** (zero JS,
  CSP-safe, honors `prefers-reduced-motion`/`prefers-color-scheme`). Route + desk item
  appended (schema-gated Tasks list preserved). 13 LiveViewTest cases. openapi regen =
  no-op (D8 confirmed).

Contracts verified against real source, not fixtures: edge DIRECTION correct
(`from=task,to=blocker`, matches `Queue.ready_query`), `ready` predicate exact, glyphs
byte-identical to `internal/taskboard` (pinned by codepoint), pct never /0, cancelled
folded out of both column and denominator, done_today respects injected-now UTC day.
Feels-alive baseline MET for a read-only wave: momentum header + fill bar + always-on
Ready column + at-rest CSS spinner + honest empty state; GitHub badge (D7) present.

**Stalled / must reconcile at integration — Board module COLLISION (confirmed, not
hypothetical).** Both slices authored `Barkpark.Tasks.Board`; slice 2's builder wrote
its own copy because slice 1's wasn't in its worktree base. They diverge:
- (a) slice 1 lacks `github_synced` → every mirrored card's sync dot reads "detached"
  until `normalize` adds `github_synced: Link.synced?(doc)`.
- (b) worker: slice 1 reads ONLY `content.claim.worker`; builder reads
  `content.assignee || claim.worker` → the assignee-only "shows its worker" test FAILS
  under slice 1's Board.
- (c) `:bucket` (slice 1) vs `:col` (builder) — no impact, BoardLive uses neither.
- (d) blocker-default `open` vs `unknown` — both fail-closed, equivalent.
Integrator MUST keep exactly one. **Recommendation: take the builder's Board (superset —
reads assignee+claim, carries github_synced), OR port those two fields into slice 1's.**

**Blind spots banked for later slices (charter-sanctioned fail-safes, NOT bugs):**
- Cross-dataset/dangling blockers resolve to `open` (card stays blocked) whereas Queue
  reads the blocker regardless of dataset — a done blocker in another dataset leaves a
  card stuck `:blocked`. Revisit if multi-dataset task graphs appear.
- `snapshot/1` is UNWINDOWED (whole dataset + a `Link.get` + `Criteria.progress` per
  card in memory) — fine for a supervisor board now; paginate before it scales.
- Done column is UNBOUNDED (every done task ever) — at odds with the TUI's "done never
  floods"; cap it in a later wave (organizer's concern).
- `ready` tiebreak is `updated_at` (charter contract): editing a ready task pushes it
  toward the back of the queue — intended, but a product-behavior choice.

**Next.** Wave 2 `board-realtime` (subscribe `documents:#{dataset}`, re-bucket + flash +
climb done-today + `:refresh` reconcile) — this is where "you watch momentum" (§0)
becomes real. Do it AFTER the Board collision is resolved in the integration branch.
