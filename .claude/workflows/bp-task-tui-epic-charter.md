# Epic charter — Barkpark portrait task TUI (`bp tasks`)

Wish: **the BEST portrait task interactive TUI** — a tall, narrow, always-glanceable live pane.
ONE simple view, no toggle farm, very automatic: organized by epics, active work on top,
latest-updated first, connected to the repo you're standing in, actively helping the user
understand what's going on. Loop until perfection. Wish doc: `.claude/workflows/bp-task-tui-wish.md`.

## Vision

You split your terminal: editor left, a 60–100-col full-height column right running `bp tasks`.
The pane is already right the moment it paints:

- **Header strip** (2 lines): repo name + branch ⇄ resolved server host + workspace/project scope,
  a live-connection dot that is honest (● live SSE / ◐ polling / ✗ offline — showing HH:MM snapshot),
  and a counts strip (`3 active · 12 ready · 4 blocked · 41 done`).
- **NOW band** (pinned, never scrolls away): every unexpired claim as a two-line card — status
  glyph, bold title, worker + ticking claim age (tint escalates as the lease nears expiry),
  criteria meter (▰▰▱ 2/3), dim epic breadcrumb.
- **Epic spine** (the scrolling body): each root goal is a rule-style section header
  (`── Cloud GUI epic ────── 7/12 ▰▰▰▰▱▱▱`), epics ordered by freshest child movement; inside,
  children latest-updated first — in_progress, then ready (▶), then blocked (showing the blocker),
  done older than a day folded to one `+9 done` line. Dormant epics (>7d idle) self-collapse to a
  single header. Orphans gather under `(no epic)` at the bottom, never lost. No borders, no boxes —
  hierarchy is a 2-col glyph gutter + indent + bold/dim contrast + vertical rhythm.
- **Activity ticker** (short fixed tail): recent task events as sentences
  (`✓ opus-3 closed 'sse-reconnect' · 2m`). A just-closed task flashes ok-green in place before
  folding away. The queue visibly breathes without being touched.
- **Footer**: one hint line — `jk move · enter expand · c claim · x close · o studio`.

Tasks whose ids appear in this repo's recent commits or branch name wear a dim `↳ git` badge and
boost their epic's rank — the pane knows which work is THIS repo's work. Colors are the product's
four semantic roles (ok/info/warn/danger — the same vocabulary as PR #979's CLI tables and the
cloud SPA); color means state, never decoration. Interaction is tiny: navigate, expand inline,
claim, close, open-in-Studio. No tabs, no modes, no settings — the layout IS the opinion.

## Decisions

All verified against the tree 2026-07-03 (not trusted from strategist claims).

1. **Dedicated portrait Bubble Tea program, `bp tasks`, in the one binary — NOT a desk-TUI retrofit.**
   The desk (cmd/barkpark/tui*.go) is a landscape Miller-columns editor; a purpose-built portrait
   model is the only way to hit the 60–100col × 100+row bar. Same stack (bubbletea v1.3.10 +
   lipgloss v1.1.0 + go-runewidth, verified in go.mod) — no second framework.

2. **All board logic lives in a new `internal/taskboard` package; `cmd/barkpark` and `internal/cli`
   stay thin.** Entry is a builtin `case "tasks":` in internal/cli/cli.go's noun switch (the noun is
   free; verified) → `internal/cli/tasks_board_cmd.go` → `taskboard.Run(cfg)`. Pure functions
   `(data, width, clock) → string` everywhere; the tea.Model is a shell. This makes goldens the
   primary gate and lets 5 builders parallelize file-disjointly.

3. **Data spine = client-side composition of two proven endpoints; no server change in wave 1.**
   `GET /v1/tasks?limit=1000` (render_doc carries parent_id, claim, labels, lifecycle_status,
   priority, criteria_progress omit-when-absent, updated_at + dependency/dependent counts — verified
   in tasks_controller/params.ex:210–302) + `GET /v1/tasks/prime` (in_progress + ready + recent
   task.% events + lifecycle_counts — verified tasks_controller.ex:77–117). A one-call
   `/v1/tasks/board` (or `prime?tree=1`) is a RESERVED later slice, taken only if payload size or
   blocked-edge N+1 proves it in live use.

4. **Live = SSE dirty-bit → debounced (750ms) full snapshot refetch; poll fallback; honest
   connection state.** Reuse internal/apiclient's StartSSE/OnChange/pollOnce (change.go, httptest
   pattern in change_test.go). Events only say "something moved"; the refetch says what's true —
   never incremental event application, so no drift, no ghost rows.

5. **Opinionated automatic organization, ZERO configuration.** One pure `BuildBoard(snapshot,
   repoCtx, now)` encodes the whole policy: NOW = unexpired claims (updated desc); epics ranked by
   max(child updated_at) with repo-relevance boost; within epic in_progress → ready → blocked →
   open (updated desc); done >24h folds to a count; epics idle >7d collapse to one line; orphans
   under "(no epic)". Injected clock; table-driven tests. The policy is code — later waves retune
   the opinion against the live guerrilla queue, never add toggles.

6. **statusRole vocabulary shared with PR #979, not forked — but wave 1 never touches its files.**
   #979 is OPEN (verified via gh: touches internal/cli/table.go, output.go,
   testdata/attention_order_cases.json). taskboard defines its lipgloss theme in terms of the same
   four role names (ok/info/warn/danger) + mapping tests; a dedicated post-merge slice reconciles
   onto the landed seam (import or extract to a shared internal package). Mapping: in_progress→info,
   lease-near-expiry/stale-claim→warn escalating to danger, blocked→warn, done→ok(dim),
   ready→neutral, offline→warn.

7. **Repo-awareness is 100% local and advisory-only.** Server/scope resolution = bp's existing
   resolveContext (flags > BARKPARK_* env > saved config) — exactly what the wish doc names; NO Go
   barkpark.json reader (no Go code references barkpark.json today; that risk is out of scope).
   Correlation = pure text scan of `git log --format=%s -100` + current branch for task doc_ids /
   drafts.* slugs → dim `↳ git` badge + epic rank boost. Boost and badge only — never filter, never
   hide; outside a git repo the board degrades silently.

8. **Act verbs stay tiny and safe: c claim, x close, o Studio, enter expand — no editing.**
   apiclient.TaskClaim(docID, workerID) and TaskClose(docID, workerID, observedEpoch) already exist
   (client.go:784–809). Worker id = BARKPARK_WORKER_ID else `tui-<hostname>` (the desk convention,
   tui-mutations.go:359). Optimistic row flip + reconcile on next refetch; x uses the double-press
   twin guard; 409/conflict renders as an honest inline strip, never a retry loop.

9. **Never a blank screen.** First paint from a best-effort cached snapshot under
   ~/.config/barkpark/ (per server+scope key) with a "syncing" dot; offline = same layout dimmed +
   honest last-synced banner. One degraded-render code path shared by loading and offline.
   (Cache slice is wave 2 — wave 1 ships fast first fetch + honest states.)

10. **Testing bar: pure funcs + goldens at 60/80/100 cols + httptest SSE/action tests + injected
    clock.** Matches the repo's existing discipline (cmd/barkpark/*.golden, apiclient
    change_test.go). No vacuous green: goldens assert full frames, action tests assert request
    bodies + epoch CAS + 409 rendering.

### Known sequencing facts / drift

- PR #979 OPEN — wave 1 is file-disjoint from it; reconcile slice queued behind its merge.
- Doc drift: docs/cards/tui.md says "HARD pin go.mod 1.24.2" but go.mod is `go 1.25.0` — fix in
  the docs slice (verify with the doc owner gate).
- cloud/ and app.js are OFF LIMITS this epic.
- `bp task …` (manifest noun, singular) is unrelated to the builtin `bp tasks` — help text must
  cross-reference both directions.

## Frozen wave-1 contract (types.go — verbatim in every slice branch)

Every wave-1 slice that needs these types includes this EXACT file at
`internal/taskboard/types.go` (identical bytes merge cleanly):

```go
package taskboard

import "time"

// Task is the board's view of one /v1/tasks envelope.
type Task struct {
	DocID           string
	Title           string
	Lifecycle       string // open|ready|in_progress|blocked|done|closed (as served)
	Kind            string
	ParentID        string
	Priority        string
	Labels          []string
	Claim           *Claim
	Criteria        *Criteria // nil when the envelope omits criteria_progress
	DependencyCount int
	DependentCount  int
	InsertedAt      time.Time
	UpdatedAt       time.Time
}

type Claim struct {
	Worker    string
	Epoch     int
	ClaimedAt time.Time
}

type Criteria struct{ Met, Total int }

// Event is one recent task.% mutation from prime.
type Event struct {
	Mutation string
	DocID    string
	At       time.Time
}

// Snapshot is the raw fetched state: /v1/tasks list + prime extras.
type Snapshot struct {
	Tasks     []Task
	Counts    map[string]int // lifecycle_status -> count
	Events    []Event
	FetchedAt time.Time
}

// RepoContext is the local git correlation result. Mentioned maps task
// doc_id -> mention count in recent commits/branch. Zero value = no repo.
type RepoContext struct {
	RepoName  string
	Branch    string
	Mentioned map[string]int
}

// Board is the fully organized, render-ready model.
type Board struct {
	Now     []Task // unexpired claims, updated desc
	Epics   []Epic // attention-ranked
	Orphans []Task
	Counts  map[string]int
	Events  []Event
}

type Epic struct {
	Root       Task
	Children   []Task // policy-ordered
	DoneFolded int    // count of done children folded away
	Dormant    bool   // idle >7d -> renders as one header line
}

type ConnState int

const (
	ConnLive ConnState = iota
	ConnPolling
	ConnOffline
)

// UIState is the interaction state the renderer needs.
type UIState struct {
	Cursor         int             // index into the flattened visible-row list
	Expanded       map[string]bool // doc_id -> inline detail open
	CollapsedEpics map[string]bool // root doc_id -> user-collapsed
	Conn           ConnState
	LastSync       time.Time
}
```

Frozen signatures (implemented by the named slice; other slices may stub in a
clearly-marked `wiring_stub.go` that the lead DELETES at merge):

- Spine slice: `func BuildBoard(s Snapshot, repo RepoContext, now time.Time) Board`
  and `func FetchSnapshot(c *apiclient.Client) (Snapshot, error)` (plus envelope decoding).
- Render slice: `func Render(b Board, st UIState, width, height int, now time.Time) string`.
- Repo slice: `func CorrelateRepo(gitLogSubjects []string, branch, repoName string, tasks []Task) RepoContext`.
- Actions slice: `func DoClaim(c *apiclient.Client, docID, worker string) ActionResult`,
  `func DoClose(c *apiclient.Client, docID, worker string, epoch int) ActionResult`,
  `func StudioTaskURL(baseURL, docID string) string`, with
  `type ActionResult struct { OK bool; Message string }` (honest one-line message on failure).

## Roadmap (integration order)

| # | Slice | Size | Wave |
|---|-------|------|------|
| 1 | Data spine: types + FetchSnapshot + BuildBoard policy (pure, fixture-tested) | M | 1 |
| 2 | Theme + component kit + portrait Render, goldens at 60/80/100 cols | L | 1 |
| 3 | Bubble Tea shell: `bp tasks` builtin, nav/expand, SSE live loop, honest conn states | L | 1 |
| 4 | Action core: DoClaim/DoClose (epoch CAS) / Studio URL, httptest-proven | S | 1 |
| 5 | Repo correlator: git-log/branch text scan → badges + rank boost (pure, fixtures) | M | 1 |
| 6 | Integration wave: delete stubs, wire actions to keys, optimistic flip + rollback, end-to-end against guerrilla | M | 2 |
| 7 | statusRole reconciliation onto merged #979 seam (shared internal package; fixture parity test) | S | 2 |
| 8 | First-paint snapshot cache + empty/offline/syncing full-frame goldens | M | 2 |
| 9 | Pulse/decay change-highlighting (updated_at diff tint, closed-task linger, fake-clock tests) | M | 2 |
| 10 | Live-queue tuning pass: run against guerrilla, retune ordering/folding opinion, resize/narrow-width polish | M | 3 |
| 11 | Terminal degradation: 256/8-color forced-profile goldens + ASCII glyph fallback | S | 3 |
| 12 | Docs: tui.md + TASK-SYSTEM.md anchors, fix go-pin drift, anchors-check green | S | 3 |
| 13 | RESERVED: server-side one-call board endpoint — only if payload/N+1 proves it live | M | — |

## Wave log

(append one entry per wave: what merged, what was learned, what the next wave should do)

### Wave 2026-07-03 (wave 1: all 5 slices GREEN + perfected; merge to main pending lead)

**Landed (on loop-epic/* + -p branches; NOT yet on origin/main at assess time):**
all five roadmap-1..5 slices built, perfected, gated green. types.go held byte-identical
across every branch (perfecters diffed it) — the frozen-contract gambit worked; the five
branches are merge-clean by construction. Data spine live-proven against guerrilla
(116 tasks decoded, 49 ready overlaid, 54 done-with-stale-claim correctly excluded from
NOW — the in_progress guard is essential, keep it). Renderer has 60/80/100-col goldens +
3 real bugs fixed (styled-truncation on truecolor, NOW-band height blowout at 7+ claims,
dead breadcrumb fallback). Shell has honest conn states + debounced full refetch; action
core's error table verified against the server's actual reason vocabulary; correlator
fixed to match bare ids (commits don't write drafts. prefixes) and live-fire proven.

**Cross-slice contracts the integration slice MUST honor:**
- Flatten rule changed by the shell slice: visibility = `epicFolded` (an explicit
  UIState.CollapsedEpics entry OVERRIDES Dormant; presence = user decision). Render must
  hide children under the SAME rule or cursor desyncs. Documented on visibleRows in program.go.
- UIState.Cursor indexes SELECTABLE rows only (tasks + orphans, not headers/folded lines).
- Renderer's package-level `Chrome` var is the repo/server injection seam — shell sets it
  before first paint (single-goroutine tea render; -race clean).
- Every branch carries a `wiring_stub.go` — lead DELETES all of them at merge.
- Slice 6 must call unexported `gatherGit` for subjects → CorrelateRepo
  (GatherRepoContext alone returns an empty Mentioned map by design).
- Claim race returns `not_ready`, not `already_claimed` — wire the c-key expectation to that.

**Learned / drift:**
- LIVE DATA IS FLAT: guerrilla = 1 epic, ~106 orphans, ~half stale done orphans that
  never fold (policy has no orphan fold; frozen types has no OrphansFolded). "(no epic)"
  will dominate the real pane. After wave 1 merges, types is no longer frozen — fix in
  wave 2, don't wait for slice 10.
- prime fetched at limit=100 → ready overlay honest-but-partial beyond top-100; renderer
  can detect >1000-task truncation via len(Tasks) vs summed Counts.
- pollOnce fallback fires the same OnChange as real SSE → a stuck-reconnect client can
  read ConnLive. Needs a seam change (wave 2 note).
- Initial fetch in Run is synchronous (up to ~5s frozen prompt vs dead server) — slice 8.
- PR #979 MERGED after the wave cut → slice 7 (statusRole reconciliation) is UNBLOCKED.
- This charter file + the wish doc are UNTRACKED — lead must commit them or doc:
  backlinks dangle.
- Pre-existing gofmt dirt: internal/cli/cloud/warmpool*.go, internal/template/template.go
  (not ours). Gate gotcha: bare `CC=clang` fails on this host (shadowing cc shim) —
  use CC=/usr/bin/clang.

**Next wave:** slice 6 (integration — the epic is invisible until stubs die and keys wire)
+ orphan-fold/done-orphan policy fix pulled forward from slice 10 (types amendment now
legal) + slice 7 (#979 seam, now unblocked) + slice 8 (first-paint cache + syncing/offline
goldens). Slice 9 (pulse/decay) only if capacity remains.

### Wave 2026-07-03e (live aliveness run on guerrilla — wave-3 verification + niggle sweep)

**Context:** cut BEFORE wave 4 (heartbeat/aliveness-budget + checklist-grammar/CriteriaItems,
loop-epic branches 18–21) landed on main. HEAD was #1057 (wave 3). So this slice paid wave-3's
outstanding live debt (2026-07-03d: amendment features were fixture-proven only) and did NOT
touch, verify, or document any wave-4 feature — the heartbeat NOW-tick, working-verb line, and
per-item checklist self-fill do not exist in this tree, so documenting them would be vaporware.

**Live run (guerrilla, real corpus 2026-07-03T14:17Z):**
- Shape: 131 tasks (open 58 / done 72 / cancelled 1), 49 ready overlaid, 71 rows with a
  retained worker. `now=0`: NONE of the 71 workers is in_progress — the live queue's claims are
  all on already-closed rows. The NOW leak-guard therefore held on the real corpus (the single
  most load-bearing live-only invariant — a fixture never exercises it).
- Board: 1 authored epic (Cloud fleet lifecycle, 9 children) + derived clusters holding the
  bulk + 3 kept orphans + 45 folded terminal orphans. LIVE DATA STILL FLAT — clusters carry
  the pile, exactly as wave 1 predicted; the categorization layer is what makes the flat
  guerrilla queue legible.
- Chip hue owed check (fuchsia-300 vs violet-300 on dark): hue gap = **38.6°** (violet 252° vs
  fuchsia 291°, both ~L83 S94). Comfortably above the ~12° glance-hazard the theme cites for
  cutting sky-300. NO adjustment needed — theme.go left unchanged.
- 67/131 tasks carry a criteria meter; every one decoded sane (0 ≤ met ≤ total, total > 0).

**Niggles the live pane exposed + fixed (tested):**
1. `live_probe_test.go` accounting guard was STALE: it summed NOW+epics+orphans but not
   `b.Clusters` (added in wave 3), so it undercounted the real corpus by ~73 rows and FALSE-
   FAILED ("accounted 58 < corpus 131") on a healthy board. Added the cluster term; guard now
   green on live data. This is a fixture-blind bug a live run is the only thing that catches.
2. Expanded twin detail named the partner's **doc id**, not its title. Fixed via the clean
   mechanism the slice named: `BuildBoard`/`assignTwins` now precomputes `Task.TwinTitle` (the
   partner's title) alongside `TwinOf`; `expandedDetail` renders it ("twin ⧉ 'Add a SUM
   function to the grid'") and falls back to the doc id only when the title is unknown, so it
   never renders a blank quote. Pure + tested (render + board + detectTwins tests).
3. Extended the live probe's decode guard to assert every `Criteria` meter is in range — the
   nearest honest analog to the slice's CriteriaItems ask, since the wave-4 per-item checklist
   type is not in this tree. Left a forward-looking comment to extend it once wave 4 lands.

**Docs:** tui.md carries the wave-3 delta (clusters, `Stale`, twins/`TwinTitle`, chips, `t`
verb, first-paint cache); trimmed discoverable detail to stay at 2396/2400 (never raised the cap).

**Deferred to when wave 4 merges:** document heartbeat/aliveness-budget + checklist grammar in
tui.md; extend live_probe's decode guard to CriteriaItems (per-item text non-empty, met ==
#checked); the true "watch the NOW card tick / working-verb cycle / one-shot flash+fold at rest"
observation — a headless run can verify the still-at-rest mechanism but not the animation itself.
