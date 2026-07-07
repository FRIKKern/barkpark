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

9. **Realtime is a LIGHT optimistic re-bucket + a heavy `:refresh` reconcile — split into
   two PURE organizer functions (wave 2).** The broadcast carries only the ONE changed doc
   (`msg.doc = %{doc_id, title, status, content, updated_at}`), never the dependency graph —
   so a single event cannot re-derive the global `ready` overlay or the cascade-unblock of
   the tasks this one was blocking. Therefore:
   - `Board.card_from_broadcast(msg_doc, prev_card)` — PURE. Projects a broadcast `doc` map
     into a normalized card, byte-parallel to `snapshot`'s private `to_card`: reads
     `content["lifecycle_status"|"priority"|"parent_id"|"labels"]`, `worker =
     content["assignee"] || content["claim"]["worker"]`, `Tasks.criteria_progress(content)`,
     and github via a synthesized `%Document{doc_id, content, status, updated_at}` fed to
     `Link.get/1` + `Link.synced?/1`. **Carries `prev_card.blocker_statuses` forward** (the
     event has none) so an already-known card keeps its readiness inputs; an unseen card gets
     `[]` and is placed by raw lifecycle (open/blocked/in_progress/done) — its `ready`
     correctness waits for the next `:refresh`.
   - `Board.apply_change(board, card, opts) :: {board, change}` — PURE. Re-buckets that one
     card, updates `cards_by_id` + `columns`, recomputes `momentum.{in_flight, ready, pct}`
     from the new columns, and returns a `change = %{doc_id, from_col, to_col, kind}` where
     `kind ∈ {:moved, :entered, :closed, :cancelled, :updated, :ignored}` (the LiveView keys
     its flash/slide off this). `done_today` is **monotonic within a session** — bump it by 1
     only on a genuine new close (`to_col == :done` and the card was not already `:done`),
     never recompute it from the (capped) done column; a `:refresh` snapshot resets it to the
     authoritative windowed value. *Why:* delivers §0's "watch momentum" instantly and
     honestly — the eye sees the right card move now; the every-N-seconds full `snapshot/1`
     reconcile silently corrects ready/cascades/windowed-stats without a flicker. Backend
     ALSO broadcasts each cascade-unblocked dep as its own `task.mutated` event
     (`close.ex` emits one per unblocked dep), so those cards animate on their own events too.

11. **Foreign-held refusal is a BOARD-LEVEL holder-identity guard, NOT an epoch fence
   (wave 3).** `Tasks.close/3` fences on the **epoch only** (`check_fencing`:
   `claim.epoch == observed_epoch → :ok`) — it does **NOT** check worker identity, and it
   preserves the original `claim.worker` while stamping `closed_by`. So a same-epoch `close`
   by a NON-holder would *succeed* and terminate the real holder's active work — exactly the
   "steal/overwrite a claim" the wish forbids. Therefore the two write paths refuse
   differently, and BOTH honor D4:
   - **→in_progress = `Tasks.claim_by_id(doc_id, "studio:<user>", scope)`.** The primitive
     itself fences: a foreign `in_progress` card is not in `{open,blocked}` → `:not_ready` →
     refuse + snap back. A same-worker `in_progress` card is a lease **renewal** (`{:ok}`,
     stays in_progress) → treat as an accepted no-op. `open|ready|blocked` held by nobody →
     claims.
   - **→done / →blocked = `Tasks.close(task.id, "studio:<user>", observed_epoch: …,
     lifecycle_status: …)` — allowed ONLY when `studio:<user>` IS the current holder**
     (`card.lifecycle_status == "in_progress"` AND `card.worker == "studio:<user>"`). A
     non-holder → **refuse + snap back WITHOUT calling `close`** (calling it would corrupt the
     claim). `:fenced_off`/`:stale_claim` from `close` is the belt-and-braces for the race
     where the epoch moved between the board's fresh read and the write.
   - **Allowed drop set is EXACTLY:** `{open, ready, blocked} → in_progress` (claim);
     `in_progress → done` (close done, holder); `in_progress → blocked` (close blocked,
     holder). Everything else refuses + snaps back: **`→open` (reopen — DEFERRED per D4, no
     clean primitive)**, `→ready` (derived, non-drop per D3), `open→done` (unclaimed direct
     close — deferred; must claim first), `done→*`, cancelled-as-target (folded, no column).
   *Why:* the primitives already carry the fence; the ONE gap is that `close`'s epoch-fence
   can't tell "the holder is closing" from "a supervisor is stealing," so the board adds the
   holder-identity check that `bp` gets for free by convention. Worst case is a refused drop.

12. **Restage scope MUST match the board's global read, or every drag silently `:not_found`
   (wave 3).** The board reads the `type:task` corpus GLOBALLY (no workspace scope, D3), but
   `claim_by_id`/`close`'s fetch is **fail-CLOSED on nil workspace** (`Scope.scope_to_workspace`
   → `where: false` on nil). So the `restage` handler must resolve the SAME scope
   `tasks_controller` uses for its `/v1/tasks/:doc_id/{claim,close}` actions — the Default-
   workspace flat posture (`Barkpark.Tenancy.get_default_workspace/0`, the context LiveAuth
   `:ops` already authorizes the board under). `close` also needs the task **UUID pk**
   (`Repo.get(Document, task.id)`) + `observed_epoch` (`content.claim.epoch`), so the handler
   **re-reads the live doc FRESH** by `doc_id` at event time (`Content.get_document/4` or the
   same lookup `tasks_controller.find_task_by_doc_id` uses) — never trusts the possibly-stale
   board card's epoch. **VERIFY with a live-DB test that a restage actually FLIPS the persisted
   row's `lifecycle_status`** — a fixture-only assertion hides a scope mismatch that would make
   every real drag a silent no-op.

10. **Done column is WINDOWED so the board never becomes a dead wall (§0).** `build/2` and
   `apply_change/3` render only the most-recent `@done_window` done cards (default 12,
   mirroring the TUI FocusSet cap) — newest-first, a fresh close prepended and the tail
   dropped. **`momentum.pct` and `momentum.done_today` are computed from the FULL done set
   BEFORE truncation** (never the capped render list) so the bar and tally stay honest. A
   `done_total` count is retained for the column header. *Why:* the wish's acceptance test is
   "never a dead wall of text" — an unbounded done pile (the wave-1 banked blind spot) is
   exactly that wall; the momentum maths must not silently shrink when the render caps.

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

**Wave 1 — read-only feels-alive baseline** ✅ LANDED (#1266; 2 slices)
1. `board-organizer` — pure `Barkpark.Tasks.Board` (`build/2` + thin `snapshot/1`). ✅ DONE.
2. `board-liveview-readonly` — `BoardLive` + `:ops` route + desk item + inline CSS vocabulary
   + GitHub badge render. ✅ DONE.

**Wave 2 — realtime motion** ✅ LANDED (#1270; 1 slice — see wave-2 log)
3. `board-realtime` — subscribe `documents:#{dataset}`, light optimistic re-bucket (D9) +
   flash/slide + monotonic climbing done-today + windowed done (D10) + `:refresh` reconcile,
   seen-set guard. ✅ DONE. *(one builder owned both board files — no parallel split.)*

**Wave 3 — drag write-through** (THIS WAVE; 1 slice — see wave-3 plan in the log)
4. `board-drag-restage` — CSP-safe drag hook (`Hooks.BarkparkBoardDrag`, mirrors the
   shipped `BarkparkPaperSortable`) → `handle_event("restage")` through `claim_by_id`/`close`
   with `studio:<user>`, optimistic move + fence-refuse + snap-back. LARGE.
   *(one builder owns `board_live.ex` + the root-layout hook + a small pure `board.ex`
   helper — no parallel split; a second slice touching `board_live.ex` would re-collide.)*

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

**Board module COLLISION — RESOLVED at integration (#1266).** The merged `board.ex` took
the superset per the recommendation: `worker = content["assignee"] || claim.worker`,
`github_synced: Link.synced?(doc)` present on every card, `:col` (not `:bucket`) as the
bucket key, blocker-default `"unknown"` (fail-closed). Both organizer (`build/2`) and
LiveView tests live in ONE file, `test/barkpark/plugins/tasks/web/board_live_test.exs`
(ConnCase). No open reconciliation remains from wave 1.

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

**Next.** Wave 2 `board-realtime` — see the wave-2 plan below.

### Wave 2026-07-07 — Wave 2 (realtime motion) — PLANNED, 1 slice

**Why one slice, not a parallel fan-out.** The entire epic is TWO files so far
(`api/lib/barkpark/tasks/board.ex` + `api/lib/barkpark/plugins/tasks/web/board_live.ex`)
with ONE test file (`board_live_test.exs`). Realtime inherently owns BOTH the pure
organizer (new `card_from_broadcast` + `apply_change` + done-window, D9/D10) and the
LiveView wiring (subscribe + handle_info + flash/slide + `:refresh`). Splitting into two
parallel builders would recreate the exact wave-1 collision (slice 2 needing slice 1's
not-yet-merged API → a rewrite). ONE builder in ONE worktree owns both files and both test
suites — zero interface-timing gap, and the two functions D9 names are unit-testable
without a socket in the same ConnCase. "Up to 5" → a focused 1 is the honest, lowest-risk
cut toward "make it literally move."

**Slice 3 `board-realtime` (LARGE).** Deliver §0's "you open the board and something is
moving" for real, riding the EXISTING broadcast — NO boot-started worker (the github-bridge
CI landmine that breaks the full ExUnit sandbox). Respects D1/D2 (plugin wires, core owns
machinery), D5 (existing broadcast, no new process), D6 (pure-CSS/LiveView motion, CSP-safe,
`prefers-reduced-motion`), D8 (no openapi, `:ops :live` route unchanged), D9 (light
optimistic re-bucket + heavy `:refresh` reconcile), D10 (windowed done column).

- **In `board.ex` (pure, D9/D10):** add `card_from_broadcast/2`, `apply_change/3`, and the
  `@done_window` cap in `build/2` (+ `apply_change/3`) with pct/done_today computed from the
  full done set before truncation. Reuse the existing private normalization vocabulary so a
  broadcast-projected card is byte-parallel to a `snapshot` card.
- **In `board_live.ex` (wiring):** on `connected?(socket)`, `Phoenix.PubSub.subscribe(
  Barkpark.PubSub, "documents:#{dataset}")` and schedule a periodic `:refresh`
  (`Process.send_after`, ~15s); `handle_info({:document_changed, %{type: "task"} = msg}, …)`
  → `card_from_broadcast(msg.doc, board.cards_by_id[id])` → `apply_change` → assign + drive
  the flash/slide off the returned `change` (a `data-flash`/`data-just-moved` attr the CSS
  `@keyframes` in the render keys off, and/or `phx-mounted={JS.transition(...)}` on the
  re-inserted card — LiveView-core JS, CSP-safe); `handle_info(:refresh, …)` → full
  `Board.snapshot/1` re-assign (reconciles ready overlay, cascades, windowed done_today) and
  reschedule. A **seen-set/dedup guard** ignores an event whose `{doc_id, updated_at}` is
  already reflected (the mount snapshot + our own re-render can echo). Non-`task` events and
  events for the wrong dataset are dropped. The momentum bar already CSS-transitions its
  width, so a climbing pct animates for free; add a brief tally-bump animation on `done_today`.
- **Tests (all in `board_live_test.exs`, ConnCase, `Phoenix.LiveViewTest` — NEVER
  phx.server):** (1) pure — `card_from_broadcast` projects worker/labels/priority/github and
  carries prev blocker_statuses; `apply_change` moves a card open→in_progress, bumps
  in_flight, returns `change.kind==:moved`; a new close bumps done_today monotonically and
  prepends to a capped done column; pct uses the full (pre-cap) count. (2) live — mount
  `live(conn, "/admin/projects")` connected, `send(view.pid, {:document_changed, msg})` for a
  `task.claimed`/`task.closed`, assert `render(view)` re-buckets the card, the momentum count
  changes, and a flash marker (`data-flash`/`data-just-moved`) appears; assert an unknown
  non-task event is ignored; assert dedup drops a repeat. (3) `handle_info(:refresh, …)`
  re-renders without crashing.
- **HARD RULES:** no boot-started process anywhere (subscribe happens in `mount` under
  `connected?`, per-socket only); if for any reason a boot-started helper is added, gate it
  OFF in `config/test.exs` (it will not be — this rides the socket). Keep every edit inside
  the two board files; file-disjoint from all other epics.

**Gate (exact):**
```
cd api && CC=/usr/bin/clang mix test \
  test/barkpark/plugins/tasks/web/board_live_test.exs \
  test/barkpark/plugins/tasks/ test/barkpark/tasks/ \
  test/barkpark_web/controllers/mutate_controller_test.exs \
  test/barkpark_web/controllers/query_controller_filter_test.exs
```
The controller files are the BROAD ConnCase swath — they exercise the endpoint + full
mutation/broadcast path, so a sandbox or broadcast regression surfaces here (a board-only run
would hide it). openapi is a no-op (D8): run `mix barkpark.openapi` belt-and-braces, commit
only if it diffs (it won't).

### Wave 2026-07-07 — Wave 2 (board-realtime), GREEN — the board literally moves

**Landed (1 slice, 1 builder, 1 worktree — as planned; no parallel split, no collision).**
The board now moves for real off the existing task broadcast — NO boot-started process (D5),
so the ExUnit sandbox stays intact. Every edit stayed inside the two board files + their one
test file; file-disjoint from all other epics.

- **Pure organizer (`board.ex`, D9/D10):**
  - `card_from_broadcast/2` — projects a broadcast `doc` (`%{doc_id,title,status,content,
    updated_at}`) into a card byte-parallel to the private `to_card/3` (worker =
    `assignee||claim.worker`, criteria via `Tasks.criteria_progress`, github via a synthesized
    `%Document{}` → `Link.get`/`synced?`), **carries `prev_card.blocker_statuses` forward**;
    an unseen card gets `[]` and is placed by raw lifecycle until the next `:refresh`.
  - `apply_change/3` — re-buckets one card, recomputes `in_flight/ready/pct/done_total` from
    the full uncapped `cards_by_id`, returns `change=%{doc_id,from_col,to_col,kind}` with
    `kind ∈ {:moved,:closed,:cancelled,:entered,:updated,:ignored}`. `done_today` is
    **monotonic** (bumps only on a genuine fresh close, never recomputed from the capped
    column); cancelled leaves the columns and bumps `cancelled_count`.
  - `@done_window` (12) caps the rendered done pile in `build/2` + `apply_change/3`;
    **`pct`/`done_today`/`done_total` are computed from the FULL done set BEFORE truncation.**
    `build/2` stays backward-compatible (wave-1 tests unchanged; only `:done` capped + an
    additive `:done_total`). — **This closes the wave-1 UNBOUNDED-DONE blind spot** (the
    "dead wall" §0 explicitly forbids); the perfecter's fix also made the Done header count
    climb past 12 so progress never *looks* frozen.

- **LiveView (`board_live.ex`):** `mount` subscribes to `documents:production` under
  `connected?` + schedules a 15s `:refresh`; a per-socket seen-set of `{doc_id,updated_at}`
  drops echoes/repeats. `{:document_changed, %{type:"task"}}` → project → `apply_change` →
  assign + flash; `:refresh` does a full `Board.snapshot` reconcile and resets the
  `done_today` baseline; a catch-all clause ignores stray/non-task messages without crashing.
  Motion is CSP-safe: a `bp-flash` `@keyframes` on the just-changed card (`data-just-moved`),
  a done-today scale bump, and the already-width-transitioned momentum bar — all frozen under
  `prefers-reduced-motion`. openapi regen a no-op (D8), `:ops :live` route unchanged.

**Feels-alive verdict (perfecter-confirmed):** the criterion is now materially met, not just
static — at rest the CSS Braille spinner breathes on in_progress; on an event the changed
card flashes, the done-today tally climbs monotonically with a scale bump, and the momentum
bar grows. GitHub badge never fabricated; honest empty state preserved.

**Known, non-blocking (charter-sanctioned, NOT defects):**
- **NOT browser-verified** — profile-locked + `phx.server` OOMs locally (codelist-seed
  gotcha), so this is `LiveViewTest` render/mount/handle_info only (the prescribed path). Real
  WebSocket delivery to a live socket is not asserted, though the subscribe topic matches the
  broadcaster byte-for-byte. A human live pass is the remaining confidence step.
- **Seen-set MapSet grows for the socket lifetime** — negligible (KB over a workday on an
  admin board); left untouched to avoid a re-flash-on-refresh regression for no real gain.
- **Dataset is inherent to the topic subscription** (the broadcast carries no dataset field) —
  correct by construction, but a multi-dataset board would need a topic-per-dataset revisit.

**Next.** Wave 3 `board-drag-restage` — completion by hand through the fenced
`claim_by_id`/`close` primitives (D4), fence-refuse + snap-back. Wave 4 `board-group-filter`
can parallel it (disjoint handler). The one open confidence gap for the whole realtime path
is a single human browser session (an agent can't clear the profile lock / local OOM).

### Wave 2026-07-07 — Wave 3 (drag write-through) — PLANNED, 1 slice

**Why one slice (again).** The epic is still exactly two files (`board.ex` + `board_live.ex`)
+ one test file, plus this wave's ONE additive JS hook in the shared root layout. Drag
write-through is inherently cohesive: the drag hook's event shape, the `handle_event` that
maps a drop to a fenced call, the optimistic move, and the snap-back-on-refuse are all one
interlocking mechanism. Splitting hook↔handler or Board-helper↔LiveView into parallel
builders recreates the wave-1 interface-timing collision (one half needs the other's
not-yet-merged contract). A second slice touching `board_live.ex` (e.g. pulling wave-4
group/filter forward) would file-collide on the same render + assigns. So: ONE builder, ONE
worktree, owning `board_live.ex` + the root-layout hook + a small pure `board.ex` helper.
"Up to 5" → a focused 1 is the honest, lowest-risk cut toward "drag flips the lifecycle."

**Slice 4 `board-drag-restage` (LARGE).** Make the board INTERACTIVE: drag a card to a new
column → the task's lifecycle flips THROUGH THE FENCED PRIMITIVES (the same claim/close path
`bp` uses), worker = `studio:<current_user>`, never a raw `Content` write, never a corrupted
claim. Respects D1/D2 (plugin wires, core owns machinery), D3 (ready is a NON-DROP target),
D4 (write through `claim_by_id`/`close`; reopen deferred), D5 (no new process — rides the
socket), D6 (CSP-safe hook, `prefers-reduced-motion`), D8 (no openapi, no bp verb), D9/D10
(reuse `apply_change/3` for the optimistic move + windowed done), **D11 (board-level
holder-identity guard — the crux)**, **D12 (Default-workspace scope + fresh UUID/epoch read)**.

- **JS hook (`lib/barkpark_web/layouts/root.html.heex`, ADDITIVE):** add `Hooks.BarkparkBoardDrag`
  right beside the existing `Hooks.BarkparkPaperSortable` (**copy its shape verbatim** — inline
  in the same Hooks-registration `<script>` before `new LiveView.LiveSocket`, so it is
  CSP-safe: NO new blocking `<head>` script (Golden Rule 4), NO `eval`/`onclick`, no bundler,
  no changeset — root.html.heex is a compiled HEEx template served verbatim). HTML5
  `dragstart`/`dragover`/`drop`/`dragend` on `this.el`; a card is `[data-role="task-card"]`
  with `draggable="true"` + its `data-doc-id`; a drop target is the enclosing
  `[data-role="column"]` with `data-col`. On drop, read the target column's `data-col` and
  `this.pushEvent("restage", {doc_id, to_col})`; add a `.bp-drop-ok`/`.bp-drop-no` class on
  `dragover` for a drop-target highlight (pure CSS). The board opts in by putting
  `phx-hook="BarkparkBoardDrag"` on the `.bp-board` container (studio + every other LiveView
  is untouched — the hook is inert without the attribute). `destroyed()` removes every
  listener (mirror `BarkparkPaperSortable`).

- **LiveView (`board_live.ex`):** `handle_event("restage", %{"doc_id" => doc_id, "to_col" =>
  to_col}, socket)`:
  1. **Resolve worker** = `"studio:" <> (socket.assigns.current_user ...)`; fall back to
     `"studio:admin"` when the assign is nil/thin (test conns).
  2. **Fresh read** the live doc by `doc_id` under the **Default-workspace scope** (D12 —
     mirror `tasks_controller`'s lookup; `Barkpark.Tenancy.get_default_workspace/0`). This
     gives `task.id` (UUID pk) + `observed_epoch = get_in(content, ["claim","epoch"]) || 0`
     + the true current holder — never trust the board card's possibly-stale epoch.
  3. **Compute the plan** via a PURE `board.ex` helper (below) from `(from_col, to_col,
     holder, worker)`:
       * `:claim` → `Tasks.claim_by_id(doc_id, worker, scope)`; `{:ok,_}` accept, any
         `{:error, :not_ready | :blocked_by_unsatisfied_deps | {:resource_conflict,_} |
         :stale_claim | :not_found}` → refuse.
       * `{:close, status}` (`"done"`/`"blocked"`) → **only if `holder == worker`** →
         `Tasks.close(task.id, worker, observed_epoch: epoch, lifecycle_status: status)`;
         `{:ok,_}` accept, `{:error, :fenced_off | :stale_claim | {:doc_changed_since_claim,
         _,_} | _}` → refuse. If `holder != worker` the plan is already `:refuse` (never call
         close — D11).
       * `:refuse` (foreign hold, `→open`, `→ready`, `open→done`, `done→*`, illegal) → snap
         back + notice, NO primitive call.
  4. **Optimistic UI (D9):** move the card to `to_col` immediately via `Board.apply_change/3`
     + assign, THEN run the primitive; on accept keep it (the real `task.claimed`/`task.closed`
     broadcast will also arrive and the D9 seen-set/idempotent `apply_change` de-dupes — no
     double count); on refuse **roll back** by re-assigning `Board.snapshot/1` (authoritative)
     and set a transient `@notice` ("`{holder}` is holding this — can't move it" / "Ready is
     automatic" / "Reopening isn't supported yet"). Render the notice as a dismissible banner
     (CSS fade, frozen under `prefers-reduced-motion`); snap-back is the card returning to its
     origin column on the re-render.
- **Pure helper (`board.ex`):** `restage_plan(from_col, to_col, holder, worker) :: {:claim} |
  {:close, String.t()} | :refuse` — the D11 transition table, PURE + unit-tested (no socket,
  no DB). Keep the allowed set EXACTLY `{open,ready,blocked}→in_progress`,
  `in_progress→{done,blocked}` (holder only); all else `:refuse`.

- **Tests (all in `board_live_test.exs`, ConnCase, `Phoenix.LiveViewTest` — NEVER
  phx.server):**
  (1) **pure** — `restage_plan` returns `{:claim}` for `open→in_progress`, `{:close,"done"}`
      for holder `in_progress→done`, `:refuse` for foreign `in_progress→done`, `→ready`,
      `→open`, `open→done`.
  (2) **live ok-move (real DB flip, D12 proof)** — seed a REAL `open` task via the live path,
      `live(conn, "/admin/projects")` connected, `render_hook(view, "restage", %{"doc_id"=>id,
      "to_col"=>"in_progress"})` → assert the **persisted** row's `content["lifecycle_status"]
      == "in_progress"` (re-read from Repo) AND `render(view)` shows the card in In Progress.
  (3) **fenced-refuse-snapback** — seed an `in_progress` task whose `content.claim.worker` is
      `"agent-x"` (NOT the studio worker); restage → `"done"` → assert **no close was called**
      (DB row still `in_progress`), the card snaps back, a notice renders. (Also: restage a
      foreign card → `"in_progress"` → `claim_by_id` returns `:not_ready` → same refuse.)
  (4) **ready non-drop** — restage → `"ready"` → DB unchanged, snap back, notice.
  (5) **illegal / reopen deferred** — restage a `done` card → `"open"` → DB unchanged, snap
      back, notice.
  (6) **dedup** — a successful claim followed by its own `task.claimed` broadcast does not
      double-move / double-count (seen-set holds).
- **HARD RULES:** no boot-started process (the write rides the socket event, per-socket only —
  the github-bridge sandbox landmine stays clear); server edits confined to `board_live.ex` +
  the pure `board.ex` helper; the ONLY shared-file touch is the additive `Hooks.BarkparkBoardDrag`
  block in root.html.heex (surgical, inert without the opt-in attr — do NOT touch
  `studio_live.ex`/`pane_builder.ex`). File-disjoint from all other epics.

**Gate (exact):**
```
cd api && CC=/usr/bin/clang mix test \
  test/barkpark/plugins/tasks/web/board_live_test.exs \
  test/barkpark/plugins/tasks/ test/barkpark/tasks/ \
  test/barkpark_web/controllers/mutate_controller_test.exs \
  test/barkpark_web/controllers/query_controller_filter_test.exs
```
The controller files are the BROAD ConnCase swath (they exercise the endpoint + full
mutation/broadcast path, so a sandbox/broadcast regression surfaces here, not just in a
board-only run). No openapi regen (D8 — `:ops :live` route unchanged; belt-and-braces `mix
barkpark.openapi` is a no-op), no bp verb (no Go build), no changeset (root.html.heex isn't a
`js/` package — its inline hook is served verbatim by the app).

### Wave 2026-07-07 — Wave 3 (board-drag-restage), GREEN — the board is now interactive

**Landed in-branch (1 slice, 1 builder, 1 worktree — as planned; no parallel split, no
collision).** Drag a card to a new column and the task's lifecycle flips through the FENCED
`claim_by_id`/`close` primitives `bp` uses — never a raw `Content` write, never a corrupted
claim. Server edits stayed inside `board.ex` + `board_live.ex`; the only shared-file touch is
the additive, opt-in `Hooks.BarkparkBoardDrag` block in `root.html.heex` (inert without the
`.bp-board` attr — studio and every other LiveView untouched). Not yet on `main` (main HEAD is
still #1270/wave 2); the perfecter branch
`projects-board/board-drag-restage-drag-a-card-between-c-0-p` awaits integration/merge.

- **Pure organizer (`board.ex`, D11):** `restage_plan(from_col, to_col, holder, worker) ::
  {:claim} | {:close, String.t()} | :refuse` — the transition table as a pure, socket-free,
  DB-free function. Allowed set is EXACTLY `{open,ready,blocked}→in_progress ⇒ {:claim}`;
  holder's `in_progress→done ⇒ {:close,"done"}`; holder's `in_progress→blocked ⇒
  {:close,"blocked"}` (both guarded `when holder == worker`); a catch-all `:refuse`. **The
  crux — the claim-steal gap is closed HERE, before any primitive call:** a foreign hold
  (`holder != worker`) on `in_progress→done/blocked` falls to `:refuse`, so `Tasks.close/3`
  (which fences on EPOCH, not identity, and would let a same-epoch non-holder close succeed and
  terminate the real holder's work) is never reached.
- **LiveView (`board_live.ex`, D12):** `handle_event("restage", …)` resolves the
  Default-workspace scope (`Tenancy.get_default_workspace/0`, the same posture
  `tasks_controller` uses), **FRESH-reads the live row** by `doc_id` for its UUID pk +
  observed `content.claim.epoch` + true holder (never the card's possibly-stale epoch), asks
  `restage_plan/4` for the verdict, then runs `Tasks.claim_by_id/3` or `Tasks.close/3`. On
  refuse it rolls back to an authoritative `Board.snapshot/1` and raises a dismissible,
  next-step notice (`@holder holds this task…` / Ready-is-automatic / reopen-not-supported).
  A `with`-else + catch-all handler makes any resolution failure a clean notice, never a crash.
- **JS hook (`root.html.heex`, D6):** `Hooks.BarkparkBoardDrag` inline beside
  `BarkparkPaperSortable` — CSP-safe (no bundler/changeset/eval), HTML5 drag, `pushEvent`
  `restage {doc_id, to_col}`, pure-CSS `drop-ok`/`drop-no` highlights + grab/grabbing cursors,
  `prefers-reduced-motion` honored, listeners torn down on `destroyed()`.

**Correctness PROVEN against the live DB (not fixtures):** `render_hook` restage flips the
PERSISTED row (`dr-open→in_progress`, `dr-wip→done`, `dr-park→blocked`, all re-read via
`Repo.get_by`); the D12 scope-mismatch trap (which would silently no-op every drag) is caught
because these tasks carry an explicit `workspace_id`. `dr-foreign` (held by `agent-x`) →
Done **leaves the row UNTOUCHED** — the D11 holder guard fires before `close`, proving the
epoch-not-identity steal gap is shut. `→ready` and reopen (`done→open`) are non-drops (DB
unchanged, snap-back + notice). Pure `restage_plan/4` cases cover claim/close/foreign/ready/
reopen/unclaimed-done. Gate: 242 tests, 0 failures; format clean; docs-anchors PASS.

**Feels-alive verdict (perfecter-confirmed): SHIPS.** Progress is now one gesture: grab/grabbing
cursors, drop-ok/drop-no highlights, optimistic move + snap-back for momentum, done blink×3 on
a real close, refusal notices phrased as the NEXT step ("claim first, then close"). Reduced-
motion honored throughout. This is the wish's interactive payload — not micro-repair.

**LEAD MUST KNOW / known non-blocking (charter-sanctioned, NOT defects):**
- **Every real drag assumes production tasks live in the DEFAULT workspace.** A task with a
  different/nil `workspace_id` REFUSES the drag with an honest notice — never a corrupt write,
  but a silent no-op. Verified only for default-ws. If production `type:task` docs ever live
  outside Default, the restage read must broaden to match the board's global read (D12 seam).
- **Own-card → Blocked with no live blockers** lands optimistically in Ready (derived
  semantics), reconciled on the 15s `:refresh` — an accepted charter tradeoff.
- **HTML5 drag is mouse-only this wave** (no keyboard/touch reorder); **NOT browser-verified**
  — still `LiveViewTest` render_hook only (profile lock + local `phx.server` OOM). A single
  human browser session remains the one open confidence step across waves 2+3 (an agent can't
  clear the profile lock / local OOM).
- **Not yet merged to `main`** — integration/merge of the `-p` perfecter branch is the
  remaining mechanical step; nothing shipped outside the loop.

**Next.** Wave 4 `board-group-filter` (swimlane group-by goal/priority/label + shareable filter
chips through the pure organizer, MEDIUM) — can proceed once wave 3 merges; its handler is
disjoint but it edits `board_live.ex` render+assigns, so serialize behind the wave-3 merge to
avoid the same file-collision the single-slice cuts have avoided all epic. Wave 5 (web/PortableDoc
parity + docs/glyph-parity gate) closes reach. The interactive core of the wish is now DONE.
