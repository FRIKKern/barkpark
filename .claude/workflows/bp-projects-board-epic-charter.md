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

**Wave 2 — realtime motion** (THIS WAVE; 1 slice — see wave-2 plan in the log)
3. `board-realtime` — subscribe `documents:#{dataset}`, light optimistic re-bucket (D9) +
   flash/slide + monotonic climbing done-today + windowed done (D10) + `:refresh` reconcile,
   seen-set guard. LARGE. *(one builder owns both board files — no parallel split.)*

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
