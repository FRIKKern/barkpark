# Epic charter — Barkpark portrait task TUI (`bp tasks`)

Wish: **the BEST portrait task interactive TUI** — a tall, narrow, always-glanceable live pane.
ONE simple view, no toggle farm, very automatic: organized by epics, active work on top,
latest-updated first, connected to the repo you're standing in, actively helping the user
understand what's going on. Loop until perfection. Wish doc: `.claude/workflows/bp-task-tui-wish.md`.

**AMENDED 2026-07-04** (wish doc top section + `doey-ui-lessons.md`): a LOT more simple and
beautiful (subtract wave-3/4 density); a real Doey-DETAIL-grade task reading view; read the
task's Paper in the TUI via internal/pdrender; tasks-within-tasks at arbitrary depth on one
navigation stack; adaptive wide-two-pane / portrait-push from one set of pure renderers.
Amendment-era decisions: D11–D18 below. Waves 1–4 are MERGED on main
(#1007, #1026, #1057, #1067, flicker fix #1100).

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

### Amendment-era decisions (2026-07-04 — the simple/beautiful/deep pivot)

Wish amendment: `.claude/workflows/bp-task-tui-wish.md` top section. Doey study:
`.claude/workflows/doey-ui-lessons.md`. All data claims below LIVE-VERIFIED against
guerrilla (read-only, 2026-07-04: 158 tasks — 150 with description, 92 with
acceptance_criteria (entries carry `criterion/met/evidence/index`), 71 design_doc,
20 papers[], claim carries `worker/epoch/ts_iso/expired_at/previous_worker`).

11. **A navigation STACK replaces inline expand — the ONE detail mechanism.**
    `[]Frame` in UIState; board = frame 0; enter descends, esc ascends (no-op at root);
    breadcrumb derived from the stack; per-frame cursor+scroll restored on pop; cycle
    guard: pushing a ref already on the stack pops back to that frame. `expandedDetail`
    + `UIState.Expanded` are DELETED. *Why:* the wish's "actually READ a task" and
    "tasks within tasks within tasks" are structurally impossible inline; two detail
    mechanisms is exactly the busy-ness the user complained about. (Overrules D8's
    "enter expand" and the wave-1 vision line — amendment #6 latitude.)

12. **Adaptive composition, zero toggles: two-pane ≥110 cols, full-frame push below.**
    Renderers stay pure (data,width,clock)→string; ONE compositor picks: wide = board
    pinned left (46 cols) + 2-col gutter + stack-top right; narrow = stack-top
    full-frame. Threshold 110 with ±4 hysteresis so tmux resize never flaps. At depth 0
    in wide mode the right pane previews the cursor-target task's detail (free — detail
    is zero-fetch, D13); papers render only when pushed (no preview-fetch machinery).
    *Why:* the exemplar is Doey's wide two-pane, the 2026-07-03 portrait constraint is
    still real; one renderer set + two compositions honors both without a mode key.

13. **Zero server change this wave — the wire already carries everything.**
    (a) Detail = ZERO extra fetches: the `/v1/tasks` list envelope ships the full
    `content` map per task (verified in params.ex `render_doc` — `content: content` —
    and live). (b) Children = client-side `parent_id` index over the already-fetched
    corpus. (c) Task→paper = `content.design_doc` ∪ `papers[]` (both on the wire).
    (d) Paper→tasks = SNAPSHOT INVERSION (`design_doc==slug || slug ∈ papers[]`) —
    **NOT `GET /v1/graph/:id/tasks`**: live-verified it returns count:0 for
    `tickets-epic-wish` (4+ tasks name it) because `Tasks.driven_tasks` rides
    published-coalesced `reverse_referencers` and the live corpus is drafts.*. Fixing
    that projector is a RESERVED server slice. (e) Paper fetch = one direct
    `GET /v1/data/doc/:dataset/paper/:slug?perspective=drafts` (live-verified:
    `result.blocks` present, slug is `_id`) — never paper_cmd.go's fetch-all-then-match.
    (f) A per-task mutation-events endpoint is RESERVED; the detail timeline derives
    client-side from inserted_at → claim(ts_iso/worker/previous_worker/expired_at) →
    last_worked_at → updated_at(+close_reason). *Why:* every hop is a proven read; the
    epic stays pure-Go and every slice gates on the Go suite alone.

14. **The subtraction pass is a first-class slice that consciously reverses wave-3/4
    density** (each reversal named here is charter-covered): ONE steady health glyph
    per row carries status+liveness (StatusGlyph's frame-cycling clock faces DELETED);
    spine rows collapse to one line (glyph + monochrome title + one dim right-aligned
    token); chips, criteria meters, twin ⧉ glyphs and suggested `+key?` chips (and the
    `t` verb) leave the LIST — they reappear in detail where a reader asked for them;
    `EpicBar` ▰-bars deleted (dim `7/12` digits stay); NOW de-dup — a claimed task
    renders ONLY in the NOW band (2-line cards there stay), never again inside its
    epic/cluster; ticker compressed to one dim line and `workingLine` verb-cycling
    deleted; selection = `▎` left bar (the glyph gutter carries exactly one
    vocabulary). KEPT because they are information, not decoration: flash-on-change,
    ticking lease age + escalation tint, cluster GROUPING (structure is what makes the
    flat live queue legible), stale tint. *Why:* "a lot more simple and beautiful" is
    the wish's first clause; Doey's core lesson is one glyph per row + monochrome-dim
    text + color only where it means state.

15. **Detail content model (Doey-DETAIL-grade, conditional sections — a thin task
    stays thin):** bold title; `glyph lifecycle · P? · kind · worker` meta line; hybrid
    timestamps `2h ago (Jul 04, 15:12)` everywhere; derived status timeline (D13f);
    description/design as typography via mdlite→pdrender at a ≤72-cell measure;
    acceptance-criteria checklist (✓/○ + per-item evidence); labels as dim monochrome
    text; deps in words ("blocks 2 tasks"); claim block incl. previous_worker + expiry;
    blocked_reason/close_reason/resolution_note strips; code_refs; then two selectable
    rails: CHILDREN (→ TaskDetail) and PAPERS (→ PaperRead). Honest truncation
    (`… and N more`) as a hard rule.

16. **mdlite-minimal: task prose renders through a tiny markdown→`[]pdrender.Block`
    adapter — one typography engine, no glamour, no goldmark.** v1 covers exactly what
    the live corpus uses (149/150 descriptions are plain prose): paragraphs, `- `
    bullets, fenced code, ATX headings; anything unrecognized degrades to a paragraph,
    never errors; pdrender itself is NOT modified. *Why:* charter law (one rendering
    stack) + task text becomes typographically identical to papers for free.

17. **Paper frame = pdrender wholesale** (Decode → DefaultRegistry(theme).RenderDoc,
    the paper_cmd.go pipeline) with a taskboard→pdrender.Theme bridge, render cached by
    (slug, rev, width) — Doey's markdown-cache lesson; TaskResolver wired to the live
    snapshot so in-body wikilink task chips show real status (display-only — no
    in-body cursor targets in v1); below the paper, the snapshot-derived "Tasks driven
    by this paper" rail IS the frame's stops. A paper with `body_html` but zero blocks
    (exists live) renders an honest "HTML-only paper — o opens in browser" state.

18. **Cursor grammar — two orthogonal motions, no modes:** j/k moves between
    selectable stops (viewport follows, clamped to one screenful per press); space/u/d
    free-scroll for reading prose; the next j/k snaps the viewport back to the cursor;
    enter always descends on the cursor's stop; esc always ascends. Footer stays one
    line per frame kind.

### Wave-5 architect decisions (2026-07-04 — verified against the tree, not strategist claims)

19. **SEQUENCING REVERSAL — subtraction + the reading renderers ship THIS wave; the
    navigation SHELL is the NEXT wave, onto the calm board.** The subtraction pass and
    the D11/D12/D18 shell BOTH rewrite `render.go` + `program.go` (verified: those are
    the two largest files and both own the Update/View + board-render internals) — they
    are irreconcilable as parallel isolated-builder slices. So this wave builds the
    file-disjoint pieces (data substrate, detail renderer, paper renderer) AND lands the
    calm board; the shell wires them into the stack next wave — exactly the proven
    wave-1→wave-2 rhythm (build pure pieces, then integrate). *Why:* it makes "a LOT more
    simple and beautiful" the first visible PR of the pivot, and every new frame is born
    against the calm board instead of being re-skinned later. Overrules the roadmap's
    "slice 18 last" ordering (strategists 1 & 2 called this).

20. **NO theme bridge — pdrender renders papers and task prose through
    `DefaultRegistry(DarkTheme()/LightTheme())` selected by Profile.** VERIFIED:
    `pdrender.Theme` has unexported fields and only `DarkTheme()`/`LightTheme()`
    constructors — a "map the board's statusRole palette onto Heading/Dim/Rule"
    injection is IMPOSSIBLE without editing pdrender, which charter law forbids.
    pdrender's dark palette already rides the same zinc/blue/emerald family the board
    uses, so they harmonize with no bridge. Construction is exactly
    `reg := DefaultRegistry(DarkTheme()); reg.RenderDoc(blocks, RenderCtx{Width: measure,
    Theme: DarkTheme(), Profile: p})`. Corrects every strategist "taskboard→pdrender.Theme
    bridge" claim.

21. **Server stays untouched this wave — the per-task events endpoint (RESERVED slice
    19) is NOT promoted.** The detail status timeline derives from the envelope
    (inserted_at → claim(worker/previous_worker/ts_iso/expired_at) → last_worked_at →
    updated_at+close_reason) and is built as an INTERNAL derivation so a future events
    endpoint can enrich it WITHOUT changing `RenderTaskDetail`'s frozen signature. *Why:*
    coupling a 4-slice Go wave to an Elixir deploy is the exact cross-stack sequencing
    failure this epic keeps avoiding; the derived timeline honestly covers Doey's
    exemplar (created → claimed(worker) → [reclaimed prev→new] → done). (Rejects
    strategist 5's promote-slice-19; keeps it RESERVED as chartered.)

22. **Chip HUES retired entirely — labels are dim monochrome text everywhere;
    `chips.go`'s hash-to-hue engine is DELETED.** Overrules wave 3 (#1057) and the
    doey-ui-lessons hash-hue ambition. *Why:* a label is identity, not state; under the
    epic's own law ("color = state, never decoration") hued chips are decoration, and the
    user's "simpler and beautiful" verdict on the busy result outranks the old ambition.
    Cluster GROUPING stays (structure is what makes the flat guerrilla queue legible) —
    only the paint goes. Doey renders tags detail-only and uniformly muted; this matches
    the exemplar.

23. **Inline expand is SHRUNK this wave, not deleted.** The subtraction slice removes
    list density and shrinks `expandedDetail` to a minimal title+description+criteria
    stub so `enter` stays alive; `UIState.Expanded` and the field SURVIVE until the shell
    wave replaces the whole mechanism with the stack (D11). *Why:* deleting the only
    detail mechanism one wave before the stack lands would leave `enter` dead mid-wave.
    (Adjusts D11/D14's "delete now" — the deletion moves to the shell wave.)

24. **Fixed reading measure: prose wraps at `min(paneWidth − gutter, 72)` cells at EVERY
    width, via one pure `measure()` helper both the detail and paper frames call; extra
    width becomes margin.** *Why:* terminal typography dies past ~72 cells, and the
    adaptive compositor's wide right pane (100+ cols) would otherwise feed pdrender an
    unbounded width and produce unreadable prose. Golden it at 60/80/100 so the cap is
    asserted. (Adopts strategist 3's helper.)

25. **`FetchSnapshotFull` EXTENDS the existing `fetch.go` decode — zero new network.**
    VERIFIED: `fetch.go`'s `taskWire` already carries `Content json.RawMessage` per task
    and already reads `acceptance_criteria` out of it. FetchSnapshotFull decodes the rest
    of `content` (description, design, design_doc, papers[], per-criterion evidence,
    blocked_reason, close_reason, resolution_note, code_refs, last_worked_at) plus
    `claim.previous_worker` / `claim.expired_at` (add both to `claimWire`) into a
    `DetailIndex`, in the SAME one `/v1/tasks?limit=1000` round-trip. No second fetch,
    no server change (ratifies D13a-c with the decode site named).

### Wave-5 slice ownership (parallel, file-disjoint — verified zero overlap)

- **Substrate** owns `frames.go` (frozen, byte-identical), `detail_data.go`
  (`FetchSnapshotFull`, `ChildrenOf`, `DrivenTasks`, `PaperRefs`), `fetch.go` additions.
- **Detail** owns `detail_render.go`, `mdlite.go` (`MarkdownBlocks` — **ownership MOVED
  here from the substrate signature list**, because RenderTaskDetail's goldens need REAL
  mdlite output; a stub would fake them), `detail_*.txt` goldens. Includes `frames.go`
  byte-identical. Renders labels as plain dim text (never imports `chips.go`).
- **Paper** owns `paper.go`, `internal/apiclient/client.go` (`PaperDoc`), `paper_*.txt`
  goldens. Includes `frames.go` byte-identical. In-body chips use pdrender's own
  `TaskChip` seam (never `chips.go`).
- **Subtraction** owns `render.go`, `components.go`, `anim.go`, `chips.go` (deleted),
  `board.go` (NOW de-dup only), `program.go` (verb/ticker trim + shrunk expand), and the
  `golden_60/80/100.txt` regen. Does NOT touch `frames.go`, `fetch.go`, `types.go`
  (fields stay declared; it only stops RENDERING the retired ones).

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

## Frozen wave-5 contract (frames.go — verbatim in every slice branch)

Every wave-5 slice includes this EXACT file at `internal/taskboard/frames.go`
(identical bytes merge cleanly — the wave-1 gambit). Slices that need another
slice's function stub it in a clearly-marked `wiring_stub.go` the lead DELETES
at integration.

```go
package taskboard

// frames.go — FROZEN wave-5 (amendment-era) contract. Byte-identical in every
// slice branch; wiring_stub.go files are deleted by the lead at merge.

import "time"

// TaskDetail is the full reading model of one task, hydrated from the SAME
// /v1/tasks list envelope the board already fetches (charter D13: the wire
// already carries content — zero extra fetches).
type TaskDetail struct {
	Task // the board row (identity, lifecycle, claim, criteria, twins)

	Description    string
	Design         string    // content.design ("" when absent)
	DesignDoc      string    // content.design_doc — a paper slug ("" when absent)
	Papers         []string  // content.papers — paper slugs
	Evidence       []string  // per-criterion evidence, index-aligned with Task.CriteriaItems ("" when absent)
	BlockedReason  string
	CloseReason    string
	ResolutionNote string
	CodeRefs       []string
	Assignee       string
	PreviousWorker string    // claim.previous_worker ("" when absent)
	ClaimExpiredAt time.Time // claim.expired_at (zero when absent)
	LastWorkedAt   time.Time // content.last_worked_at (zero when absent)
}

// DetailIndex maps doc_id -> TaskDetail for every task in the snapshot.
type DetailIndex map[string]TaskDetail

// FrameKind discriminates navigation-stack frames.
type FrameKind int

const (
	FrameBoard FrameKind = iota // level 0 — the board; always the stack bottom
	FrameTask                   // TaskDetail reading view
	FramePaper                  // rendered paper + driven-tasks rail
)

// Stop is one selectable target inside a frame's rendered body.
type Stop struct {
	Line  int       // 0-based index into the frame's body lines
	Kind  FrameKind // what enter pushes (FrameTask or FramePaper)
	Ref   string    // task doc_id or paper slug
	Label string    // breadcrumb segment for the pushed frame
}

// Frame is one level of the navigation stack.
type Frame struct {
	Kind   FrameKind
	Ref    string // task doc_id / paper slug ("" for the board)
	Title  string // breadcrumb segment ("" for the board → "tasks")
	Cursor int    // index into the frame's current Stops
	Scroll int    // free-scroll line offset (0 = follow cursor)
}

// PaperState is the async fetch/render state of one FramePaper.
type PaperState struct {
	Slug      string
	Loading   bool
	Err       string // honest error line ("" when none)
	Title     string
	Rev       string
	BlocksRaw []byte // raw blocks JSON (nil while loading / on error)
	HTMLOnly  bool   // doc had body_html but zero blocks → browser-handoff state
}
```

Frozen wave-5 signatures (implemented by the named slice; others stub in
`wiring_stub.go`):

- **Substrate slice:** `func FetchSnapshotFull(c *apiclient.Client) (Snapshot, DetailIndex, error)`
  (same one round-trip as FetchSnapshot; decodes Task AND TaskDetail in one pass),
  `func ChildrenOf(tasks []Task, docID string) []Task` (inserted_at asc),
  `func DrivenTasks(tasks []Task, details DetailIndex, slug string) []Task`
  (design_doc==slug || slug ∈ papers[], band-ordered like epic children),
  `func (d TaskDetail) PaperRefs() []string` (design_doc first, ∪ papers[], deduped),
  `func MarkdownBlocks(src string) []pdrender.Block`.
- **Detail slice:** `func RenderTaskDetail(d TaskDetail, children []Task, cursor, width int, now time.Time) ([]string, []Stop)`
  — full body lines + stops; the shell windows by Frame.Scroll/height.
- **Paper slice:** `func FetchPaper(c *apiclient.Client, dataset, slug string) (PaperState, error)`,
  `func RenderPaperFrame(ps PaperState, driven []Task, chipSource []Task, cursor, width int, now time.Time) ([]string, []Stop)`,
  and apiclient `func (c *Client) PaperDoc(dataset, slug, perspective string) ([]byte, error)`
  (raw `result` JSON from `GET /v1/data/doc/:dataset/paper/:slug`).
- **Shell slice:** stack push/pop with the D11 cycle guard,
  `func Breadcrumb(stack []Frame, width int) string` (middle-truncating; first+last
  segments always survive), the D12 compositor, the D18 key grammar.

Cross-slice compile note (amended by D23): THIS wave the subtraction slice SHRINKS
`expandedDetail` (keeps `enter` alive) and leaves `UIState.Expanded` declared. The
NEXT-wave shell slice stops using `UIState.Expanded` + the `t` verb and installs the
stack; the LEAD deletes `expandedDetail` and the field at the shell integration —
this keeps every branch independently compilable across both waves.

Ownership amendment (D19): `MarkdownBlocks` is implemented by the DETAIL slice
(`mdlite.go`), not the substrate slice — RenderTaskDetail's goldens need real mdlite
output, so a substrate stub would produce fake goldens. `frames.go` itself only
imports `time`, so this changes no frozen bytes.

### Wave-9 architect decisions (2026-07-04 — the DETAILED-DIRECTION redesign; wish AMENDMENT 3 + the design-language spec)

Source of truth: `.claude/workflows/bp-task-design-language-spec.md` (read whole) and the
mockup transcribed in `bp-task-tui-wish.md` AMENDMENT 3. The user put the calm board beside the
mockup and said **make it look like the mockup**. This deliberately reverses PART of the wave-5
subtraction (D14): structure + MEANINGFUL color come back (spec's "color = state, never
decoration" — hue on lifecycle, priority-severity, blockers; plain labels stay dim monochrome).
The subtraction's GOOD parts stay: dim labels, done recedes, honest truncation, one view / no
toggle-farm. All claims verified against the tree (theme.go/components.go/render.go/board.go/
program.go/detail_render.go), not trusted from strategists.

36. **Adopt the spec §1 glyph+color vocabulary as the board's canonical set — the paper
    `task-list` component already ships it; the TUI must MATCH it.** Split `open` (○ dim-white,
    ~42% foreground — faint backlog) vs `ready` (○ FULL foreground — the unchecked box, claim it);
    `in_progress` → the animated Braille spinner `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` in blue (replaces the steady ●);
    `blocked` → `!` amber (replaces ◐); `done` → `✓` **teal glyph, dim title** (recedes, but the
    check is teal not grey); `cancelled` → `✕` dim. *Why:* Amendment 3 is a direct "match the
    mockup" order; §1 is the shared manifest both surfaces read; reverses wave-5's steady 4-glyph
    set on purpose (D14 was the calm pass, this is the scheduled §4/§7 TUI catch-up).

37. **`RoleFor` is UNTOUCHED — the semrole parity test stays green; the spec palette is a
    GLYPH-RENDERING layer, not a role remap.** in_progress→info, blocked→warn, done→ok,
    ready/open/cancelled→neutral still holds (`TestRoleForParityWithSemrole` iterates
    `semrole.TaskLifecycles()` and must not change). The brightness ladder (open 50% / ready 100%)
    and the teal done-GLYPH are neutral/ok RENDERING refinements inside those roles, NOT new
    tokens — do not add semrole tokens. Add a dedicated `doneColor` (teal `#0d9488`/`#2dd4bf`)
    distinct from `okColor` (green, cloud health/"live·up·online") so restyling the done glyph
    never shifts deploy-table semantics. Refresh the terminal hex to the spec's exact AdaptiveColor
    values (info `#2563eb`/`#60a5fa`, warn `#d97706`/`#fbbf24`, danger `#dc2626`/`#f87171`, ready =
    near-foreground `#18181b`/`#e7edf2`, open ≈ dim `~#5f6b78`, cancelled `#a1a1aa`/`#71717a`).
    *Why:* the one parity gate that actually EXISTS in-repo is semrole; there is no `design/check`
    hex gate yet (verified — spec §6 is aspirational), so "drift gate green" here = semrole parity +
    the glyph-budget guard; don't fork semrole, don't collateral-damage the CLI/cloud role hues.

38. **Motion rides the EXISTING heartbeat (`anim.Alive` + `UIState.Frame`) — the spinner frame
    index is `Frame % 10`, NEVER wall-clock, so an idle board stays byte-stable and goldens hold.**
    The seam already exists (anim.go schedules a tick only while `Alive()`; Frame is injected like
    `now`); only the CONSUMPTION is new — in_progress rows on the board (NOW cards, spine rows,
    detail meta + timeline + children rails) paint the frame'th spinner glyph. `NO_MOTION`/
    reduced-motion freezes on a single steady `⠿`; the done-flash ×3 rides the EXISTING one-shot
    flash ladder (`FlashLevel`) fired on the done-transition only (never first paint / cache-primed
    — `changedDocIDs` + the empty-prev suppression already guarantee this). ASCII escape hatch
    (config flag / no-Braille font) swaps to `( )` ready · `[~]` wip · `[!]` blocked · `[v]` done ·
    `[x]` cancelled. *Why:* charter D-heartbeat law; the byte-stable-idle golden invariant is
    load-bearing — a free-running ticker would break it.

39. **The RICH ROW gets meaningful columns back (spec §3), reversing part of D14's one-token
    subtraction (Amendment 3 schedules exactly this).** Layout: `▎glyph  ID · title  ……  PRIORITY
    N/M worker`, plus a `! cause` blocker badge (amber, inline) on blocked rows so a stuck task
    says WHAT blocks it without opening. Priority is color-SEVERITY (P0/P1 red, P2 amber, P3/P4
    dim); criteria is the bare `N/M` (tabular); worker rides the row in blue when claimed. Width
    degrade order (right→left shed): worker → criteria → priority; the `! cause` badge sheds LAST
    (most load-bearing); below `dropMetaBelow` keep glyph+title only. *Why:* the mockup's row
    carries state at a glance; the calm monochrome-label + honest-truncation discipline stays.

40. **MOMENTUM HEADER + progress bar (spec §0 — the north-star "feel alive / always feel
    progress" acceptance test).** Replace the header's plain counts strip (render.go line-2
    `countsStrip`) with `⟨spinner⟩ N in flight · ○ N ready · ✓ N done   NN%` (icons + color, done
    teal, `NN%` right-aligned) and a proportional progress-BAR row beneath it (filled = done/total,
    or overall criteria %). Keep the honest `· N stale` and `showing N of M` notes. The spinner in
    the header rides the same heartbeat frame (D38). *Why:* it is the mockup's #2 element and the
    spec's whole-initiative criterion — the always-on progress read.

41. **PHASE BANDS with an HONEST fallback (the GROUPING SHIFT) — never fabricate phases not in
    the data.** Section headers restyle to the mockup: `NAME ·········· [Wcode · ]done/total` — a
    dotted leader + a criteria/child ROLLUP, via the ONE shared `renderSectionHeader` (dashes →
    dots, the rail → a rollup token). Phase grouping derives a phase code from an explicit
    `phase:*` label OR a W-code parsed from the title (`W1`, `W3–4`, `W5.2`); WHEN present a
    section splits into ordered phase sub-bands, each a DISPLAY-ONLY (non-cursor) band label with
    its own rollup; WHEN ABSENT (the guerrilla reality — almost nothing carries phase metadata)
    the existing epic/cluster/orphan grouping stands, only restyled. The wave-8 head-of-5 per-
    category cap still applies. *Why:* the mockup groups by phase, the live corpus rarely does —
    faithful derivation, not invention; phase labels stay display-only so the cursor index space
    is unchanged (parity guards hold trivially).

42. **ONE SPINE BUILDER — extract `spineRows(b, st) []SpineRow` that both `visibleRows` and
    `flattenSpine` consume, making cursor-parity STRUCTURAL instead of conventional.** Today the
    two paths (program.go `visibleRows` → `[]row`, render.go `flattenSpine` → lines) are hand-
    aligned and kept honest only by the two guards. Nested subtasks + phase labels would amplify
    that risk. So a single ordered producer emits `SpineRow{Kind, Depth, Ref, Selectable}` encoding
    the WHOLE order+fold rule (NOW/ready head, section headers, phase band labels, nested tasks,
    "+K more"/"+N done", separators); `visibleRows` = the `Selectable` subset, `flattenSpine`
    renders each row (a header/label/more-line is `Selectable:false`, exactly the display-only set
    today). Nested subtasks (arbitrary depth) walk the direct parent→child tree WITHIN a section
    (indent + `↳`) for DISPLAY — `rootOf` still does the grouping. *Why:* charter law ("fold+order
    single-sourced; ONE spine builder both consume"); this is the safe way to add depth.

43. **DETAIL + PAPER frames adopt the same vocabulary; pdrender in-body chips stay READ-ONLY.**
    `detailGlyph` → the spec set (spinner in_progress, `!` blocked, teal `✓`, `✕` cancelled, ○
    open/ready split); the detail body already carries the mockup's sections (meta line, hybrid
    stamps, derived timeline, CRITERIA ✓/○ + `↳` evidence, DEPENDENCIES-in-words, CHILDREN, PAPER
    `▸`) — align glyphs/colors + make the timeline's in_progress mark the live spinner. pdrender's
    in-body task-chip glyphs (`walk.ex`/`inline.go`: ◐ in_progress, ⊘ blocked, ● done) CLASH with
    the new board set but are OFF LIMITS this wave (pdrender read-only) — their unification is the
    RESERVED cross-surface slice (Elixir walker + pdrender + Studio parity), acknowledged, not
    touched. *Why:* parity-artifact match; one rendering stack; the cross-surface change is its own
    gated epic.

44. **Regenerate ALL goldens deliberately (board+detail+paper+compose at 60/80/100) and EXTEND
    the glyph-budget allowlist consciously — the two cursor-parity guards stay green UNWEAKENED.**
    The whole vocabulary changed, so regen with `-update -update-paper` and EYEBALL every frame
    against the mockup before trusting it. Promote to the BOARD allowlist: the 10 spinner frames
    `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` + the frozen `⠿`, `✕` cancelled, and `↳` (subtasks now nest on the BOARD, not
    only in reading frames) — each with a note; `!` is ASCII (free). `TestCursorParityShellRender`
    and `TestCursorParityWithClusters` must hold without weakening — the single `spineRows` source
    (D42) is what makes that automatic. *Why:* the guard is the anti-creep tripwire; extending it
    is a deliberate act, and per-slice green is never trusted after a vocabulary change.

### Wave-10 architect decisions (2026-07-05 — NAMED phase bands + cancelled folding; the SECTIONING catch-up)

The user put the wave-9/9b board (rich rows correct) beside the mockup again: the remaining gap is
SECTIONING. The data was CURATED 2026-07-05 so the mockup is now HONEST — the curated epics carry real
`phase:<n>-<slug>` labels (verified read-only against guerrilla, not trusted: `aesthetic-unification-epic`
has 38 direct children — 24 across bands `phase:1-spine`…`phase:6-enforce`, 14 unphased done; the dead
`unified-aesthetic-goal` is a cancelled ROOT + 7 cancelled children; `task-754439` a cancelled childless
root; 9 cancelled nodes total). All claims tree- and live-verified.

45. **NAMED phase bands, re-added from the NEW data (W10-A) — this REVERSES wave-9b's D-B removal, and
    the reversal is honest: the DATA changed, not the principle.** wave-9b (D-B) removed the within-epic
    sub-bands because the corpus then had bare W-codes only, so they rendered as bare "W6"/"W2" orphan
    lines that doubled the row-title's own code. The 2026-07-05 curation gives every curated child exactly
    one `phase:<n>-<slug>` label, so bands are now NAMED (title-cased slug — `phase:5-paper-components` →
    "Paper Components", acronym allowlist tui/cli/…), ORDERED by `<n>`, and carry a real
    `Wcode · done/total` rollup. An epic with >=2 phase-labeled children splits into ordered sub-bands
    under its header (unphased children FIRST, directly under the epic header); the Wcode is DERIVED from
    the band's children's title prefixes (W1.2/W1.3 → "W1"; a band spanning W3.8+W4.10 → the merged
    "W3–4" en-dash range), omitted when underivable. Bands are DISPLAY-ONLY (`Selectable:false`) emitted
    by the ONE `spineRows` producer, so cursor-parity stays STRUCTURAL. The wave-8 head cap moves to
    PER-BAND (<=5/band; the epic's own cap lifts when bands render, else nothing fits). An epic with NO
    phase-labeled children renders EXACTLY as before — regression-neutral for the uncurated majority
    (VERIFIED: not one existing golden changed). *Why:* the mockup groups by phase and the data now
    honestly does too; NEVER fabricate a phase not in the data (the `phase:<n>-<slug>` regex ignores the
    structural `phase:goal`/`phase:build`/… sentinels and the bare `phase:W1` form).

46. **The band indent is DECOUPLED from tree depth so a band's direct child never wears a spurious ↳.**
    `TaskRow` gained an explicit `guide bool` (was `depth>0`): a phase band's direct child indents one
    level (Depth+1) with `Guide:false`, a real subtask below it keeps `Guide:true`. `renderSectionHeader`
    grew `renderSectionHeaderIndent(indent…)` — bands reuse the EXACT dotted-leader + rollup grammar one
    level in, so a band header can never drift from a section header. *Why:* ↳ means "subtask", not
    "indented"; conflating them would lie about the tree.

47. **CANCELLED work folds away ENTIRELY (W10-B) — never a row, at any age.** `buildEpic`/`buildCluster`/
    `foldStaleOrphans` route cancelled into a dedicated `CancelledFolded` (Epic/Cluster) /
    `OrphansCancelledFolded` (Board) count, distinct from `DoneFolded`; the trailing dim line reads
    "+N done · M cancelled" (or "+M cancelled" alone). A section whose ROOT is cancelled collapses to ONE
    dim tombstone line at the BOTTOM of the board (after clusters/orphans), so dead epics stop occupying
    prime space (`spineDeadEpic`, display-only). The momentum % EXCLUDES cancelled from the denominator
    (abandoned work leaves both numerator and denominator); NOW/READY already exclude it. `✕` stays in the
    glyph allowlist (the ticker/legend may still name a cancelled event) but NEVER paints a board row.
    *Why:* the mockup shows no cancelled anywhere; abandoned work is noise, and a live board buried 8 dead
    ✕ rows mid-screen.

48. **Guard BOTH features on the real-corpus fixture + a live read-only dump; goldens regenerated, never
    hand-edited.** `livecorpus_test.go` gained a banded epic (3 bands incl a merged "W3–4", unphased-first,
    a done·cancelled tail), a fully-cancelled tombstone epic, and cluster/orphan cancelled folds; the
    52/56/64/72 goldens + the invariant assertions (band rollups intact, band names present, ZERO `✕`
    rows, the cancelled tail survives) pin it. The en-dash `–` was added to the BOARD glyph allowlist
    (one note: the W3–4 range) — the only new glyph. REQUIRED live dump (read-only, guerrilla, never
    mutating) confirmed: 6 named bands with rollups inside `aesthetic-unification-epic`
    ("Spine ··· W1 · 0/4" … "Paper Components ··· W5 · 0/11" + a per-band "+6 more"), the dead
    `unified-aesthetic-goal` reduced to a dim bottom tombstone, ZERO `✕` rows, 67% (cancelled excluded),
    and every uncurated epic/cluster unchanged. *Why:* wave 9 shipped green-but-wrong on the live corpus
    once already (the whole reason livecorpus exists); per-slice green is never trusted without the live eye.

### Wave-11 architect decisions (2026-07-05 — the ACTIVITY-FOCUS retune; wish AMENDMENT 4)

The user put the wave-10 board beside a screenshot where the **auth epic dumped ~25 fresh `✓`
rows** (they were <24h old, so the age-based "terminal >24h folds" rule let them all through) and
said (verbatim in AMENDMENT 4): "i just want 1 list, with the stuff that been recently worked on …
the epic/goals … based on recently worked on … we dont want to see … long list finished stuff
blocking the view … see 3 siblings, 3 children, maybe 1,2 parents … if this is within proximity of
another task that is active … it should be giving more perspective … we dont make many lists, but
try to cover more that is relevant in one eye catch." All claims below were verified against the
tree (spine.go / board.go / render.go / program.go / types.go), not trusted from strategists, and
against a read-only guerrilla dump. This is a POLICY retune of the ONE opinionated view — no new
toggles, no data model beyond fields on Epic/Cluster/Board.

49. **`lastActivity` is the recency clock, and RECENCY RANKS sections (the wish's #2).** Define
    `lastActivity(task) = max(UpdatedAt, Claim.ClaimedAt when claimed, and every `Event.At` whose
    `Event.DocID` (bareID-normalized) names the task)` — all three already on the wire
    (`Snapshot.Events` from prime's `recent_events`, `Claim.ClaimedAt`, `UpdatedAt`); ZERO new
    fetches. `lastActivity(section) = max over the section's WHOLE member set INCLUDING folded
    done/cancelled and the NOW-pinned claims` (computed in BuildBoard from the full `groups[root]`
    slice + an events index, BEFORE any fold strips rows — so a mass-close's recency is not thrown
    away with the folded rows, the exact bug that would otherwise SINK a just-worked epic once D50
    folds its closes). Store it on `Epic.LastActivity` / `Cluster.LastActivity` / a Board field for
    the loose bucket. `sortEpics` key becomes `(active desc, repo-mentioned desc, lastActivity
    desc)`: **a section owning a live in_progress claim ALWAYS outranks recency alone** (the wish's
    #1 rule; `active` = the existing `Epic.Active`/`nowSet` test), the repo boost (D7) stays as a
    subordinate tiebreak, and `epicFreshest`/`clusterFreshest` (kept-children-only `UpdatedAt`) are
    REPLACED by `LastActivity`. Dormant epics need no special-case — low `lastActivity` sinks them
    naturally (the wish's "dead/dormant sinks to the bottom"). Tiers stay ordered epics → clusters →
    orphans → dead-epic tombstones (authored structure before derived; recency orders WITHIN a
    tier); cross-tier interleave is a deliberately-deferred refinement (bounds this wave's risk).
    *Why:* the big picture must read top-down as "what this system is working on now → lately →
    dormant," and events + claim-time are the recency signals `UpdatedAt` alone misses.

50. **DONE NEVER FLOODS — drop the 24h age rule; age no longer grants a done row (the wish's #3,
    the observed failure).** `buildEpic`/`buildCluster`/`foldStaleOrphans` stop gating done rows on
    `now.Sub(UpdatedAt) > doneFoldAfter`. New rule: sort a section's terminal-DONE children by
    `lastActivity` desc, KEEP at most `doneCueMax = 2` freshest as a dim completion cue (they ride
    the existing `childBand==6` bottom band), fold ALL the rest into `DoneFolded` **regardless of
    age**. Cancelled is unchanged (W10-B: `CancelledFolded`, any age, never a row). The ≤2 cue rows
    render only when the section actually shows child rows (active-focus or explicit-expand); a
    collapsed / inactive section shows none (D51), so the auth epic's ~25 fresh closes collapse to
    `+23 done` instead of a wall. `doneFoldAfter` / `staleBandAfter` stay for the stale-band demotion
    of NON-terminal rows (unchanged); only the terminal-fold age gate is deleted. *Why:* finished
    work is a completion CUE, not the content — two freshest is the celebration, the count is the
    honesty; this is the single most load-bearing line of the retune.

51. **FOCUS WINDOWS replace the wave-8 head-of-5 (the wish's #4) — active sections show the active
    work's NEIGHBORHOOD, inactive sections show header+rollup ONLY.** The default view of a section
    is now a MODE, not a count:
    - **explicit collapse** (`CollapsedEpics[key]==true`, via `h`) → 0 child rows (header only).
    - **explicit expand** (`==false`, via `l`/`enter`) → ALL kept children (the head/per-band caps
      lift — "expand still reveals all"; the permanent `+N done · M cancelled` fold tail stays,
      folded terminal rows are a count, never un-folded).
    - **no entry, ACTIVE section** → the FOCUS WINDOW: a `FocusSet map[string]bool` of kept-child
      doc ids computed in BuildBoard. Seeds = each of the section's NOW tasks (the claims, stripped
      from `Children` into NOW — used as context ANCHORS) plus every `blocked` kept child. Context
      per seed, drawn from the section's kept children: its parent chain UP (≤`focusParents = 2`),
      its `ready` siblings sharing the seed's `ParentID` (≤`focusSiblings = 3`, priority then
      recency), its direct children (`ParentID==seed`, ≤`focusChildren = 3`). Union across ALL seeds
      → ONE neighborhood (two active tasks in the same epic MERGE automatically — never two lists for
      one story, the wish's explicit ask). Add the ≤2 done-cue doc ids. Cap the window at
      `focusWindowMax ≈ 12` kept-child rows; the remainder is an honest `+N more`. Parents are in the
      set so `nestTasks` anchors the `↳` tree (context reads "under its parent").
    - **no entry, INACTIVE section** → 0 child rows; the dotted-leader header with its `done/total`
      rollup IS the big-picture line (no `+N more` tail — the rollup is the summary). `l`/`enter`
      reveals all.
    `sectionShown(st,key,active,n) int` is replaced by a `sectionMode(...) → {collapsed, expanded,
    focus, header}` selector both spine consumers read; `spineRows.section()` gains the mode +
    `FocusSet` and, in `focus` mode, FILTERS the kept children to `FocusSet` BEFORE nest+band while
    computing every band/section rollup over the WHOLE band (charter law: **a phase band appears iff
    the window picks a row from it; band rollups stay whole-band**). `groupHeadMax` and the per-band
    head cap are DELETED (the focus window supersedes them). *Why:* "cover more that is relevant in
    one eye catch" — the neighborhood around live work, not an arbitrary first-5, and calm empty
    space for everything the user has not opened.

52. **KILL the READY TO CLAIM band — ONE list (the wish's #1).** Delete `renderReadyHead`,
    `showReadyHead`, the `rowReadyClaim` kind + its branches in `visibleRows`/`flattenSpine`/
    `activateBoard`, and the `ready_head_*.txt` goldens + their tests. `renderNowBand` renders NOW
    when there are live claims and an honest calm all-clear otherwise (no second list). `flattenSpine`'s
    pinned offset is always `len(b.Now)`. Claim-forward SURVIVES exactly as the wish keeps it: the
    cursor lands on any ready row in the spine and `c` claims it (already wired), the footer still
    teaches `c claim`, and NOW pins the claim the instant it flips in_progress. The `Board.ReadyHead`/
    `ReadyTotal` fields + `readyHead()` are removed once the band is gone (no other consumer — the
    header's ready count is the independent `readyCountLabel`); update the fetch/cache/board tests
    that referenced them. *Why:* the head duplicated rows from the sections below — a second list for
    the same tasks, the exact "many lists" the user rejected.

53. **ROBUST TO BAD HYGIENE BY POLICY (the wish's #5), not by hoping the data is clean.** The retune
    survives the two live-corpus pathologies structurally: (a) a **mass close** (20+ done in a day)
    folds to `+N done` via D50 (age-independent) and STILL ranks its epic high via D49 (folded rows
    keep their `lastActivity` in the section max) — the flood is impossible and the recency is
    preserved; (b) **expired/stale claims** never enter NOW (the load-bearing in_progress-only leak
    guard in BuildBoard — 119 expired claims correctly excluded on the live corpus, keep it) and
    never make a section spuriously "active." The §5/§6 authoring-quality tasks (save-gate,
    completeness score, `bp task lint`, guided editor) are the ENFORCEMENT arm that fixes hygiene at
    the source; the board's job is to stay legible while the data is messy. *Why:* the user named the
    flood as "maybe just bad task hygiene" — the board must not depend on good hygiene to read well.

54. **NO NEW TOGGLES; explicit user overrides ALWAYS beat the automatic policy; bands compose with
    windows.** The one opinionated view stands (calm-board law). The 3-state expand mechanics
    (`h`/`l`/`enter` writing `CollapsedEpics`) are UNCHANGED and win over the focus/header default in
    both directions (an explicit expand shows all even in an inactive section; an explicit collapse
    hides all even in an active one). Phase bands (W10-A), nested `↳` subtasks (W9), the momentum
    header + progress bar (D40), the NOW band (D14), and the semrole/glyph vocabulary (D36–D39) are
    all untouched — this wave changes ONLY which rows a section shows and how sections rank. The ONE
    `spineRows` producer (D42) remains the sole order+fold source both `visibleRows` and
    `flattenSpine` consume, so cursor-parity stays STRUCTURAL through the window filter. *Why:* the
    layout is the opinion; the retune sharpens the opinion, it does not add controls.

55. **GUARD the retune on an EXTENDED real-corpus fixture with TEETH, goldens regenerated
    deliberately.** `livecorpus_test.go` drives the guard through `BuildBoard` (so it exercises the
    D49–D51 POLICY, not a hand-built Board) from a Snapshot carrying: a **mass-close flood** (20+
    done <24h in one epic → must fold to `+N done`, zero flood), **two live claims in neighboring
    subtrees of one epic** (→ prove the windows MERGE into one neighborhood, both parents' context in
    one section), a **dormant epic** (low recency → sinks near the bottom, header+rollup only), and a
    **recency spread** across epics (→ prove the top-down recency order). The 52/56/64/72 goldens +
    new invariant assertions pin it: NO `READY TO CLAIM` substring anywhere, NO active section with
    >`doneCueMax` done rows, sections in `lastActivity` order, the merged window reads as one
    neighborhood, and the existing D-A..E / W10 invariants + `tasks`-never-truncated all still hold.
    Verify the guard has TEETH (revert any one of D49/D50/D51/D52 → a golden or assertion fails).
    Both cursor-parity guards + `TestCursorParityBandedEpic` + `TestCursorParityWithPhaseAndNesting`
    stay green UNWEAKENED; the glyph-budget + semrole-parity guards stay green (no new glyphs — the
    retune adds no vocabulary). *Why:* wave 9 shipped green-but-wrong on the live corpus once; a
    per-slice green is never trusted without the live eye and a teeth-checked guard.

## Roadmap (integration order)

| # | Slice | Size | Wave |
|---|-------|------|------|
| 1 | Data spine: types + FetchSnapshot + BuildBoard policy (pure, fixture-tested) | M | 1 ✅ (#1007) |
| 2 | Theme + component kit + portrait Render, goldens at 60/80/100 cols | L | 1 ✅ (#1007) |
| 3 | Bubble Tea shell: `bp tasks` builtin, nav/expand, SSE live loop, honest conn states | L | 1 ✅ (#1007) |
| 4 | Action core: DoClaim/DoClose (epoch CAS) / Studio URL, httptest-proven | S | 1 ✅ (#1007) |
| 5 | Repo correlator: git-log/branch text scan → badges + rank boost (pure, fixtures) | M | 1 ✅ (#1007) |
| 6 | Integration wave: stubs deleted, keys wired, optimistic flip + rollback, live e2e | M | 2 ✅ (#1026) |
| 7 | statusRole reconciliation onto merged #979 seam | S | 2 ✅ (#1026) |
| 8 | First-paint snapshot cache + empty/offline/syncing goldens | M | ✅ (cache.go landed; async first fetch) |
| 9 | Pulse/decay change-highlighting | M | 2 ✅ (#1026/#1067; flicker fix #1100) |
| 10 | Live-queue tuning: clusters, staleness, twins, chips | M | 3 ✅ (#1057) |
| 11 | Terminal degradation: forced-profile goldens + ASCII fallback | S | 3 ✅ (render_degrade) |
| 12 | Docs: tui.md anchors current through wave 3 | S | 3 ✅ |
| 14 | Detail substrate: TaskDetail/children/driven-tasks decode (pure data, D25) | M | 5 (this wave) |
| 15 | RenderTaskDetail + mdlite — the Doey-DETAIL-grade reading view (D15/D16/D24) | L | 5 (this wave) |
| 16 | Paper frame: pdrender wholesale (DarkTheme, no bridge — D20) + driven-tasks rail (D17) | M | 5 (this wave) |
| 18 | The subtraction pass: calm board, chip-hue retirement, NOW de-dup, shrunk expand (D14/D22/D23) | L | 5 (this wave) |
| 17 | Navigation shell: stack + breadcrumb + cursor grammar + adaptive compositor (D11/D12/D18) — onto the calm board | L | 6 (next wave, after subtraction lands) |
| 21 | The detailed-direction redesign: spec vocabulary (spinner/!/✕/open-ready split/teal done) + momentum header & progress bar + phase bands & rollups + rich row & blocker badge + one spineRows builder (nested ↳) + detail/paper glyph align + full golden regen (D36–D44) | L | 9 (this wave) |
| 22 | Sectioning: NAMED phase bands from `phase:<n>-<slug>` (ordered, rollups, merged W-range, per-band cap) + cancelled folds entirely away (done·cancelled tail + dead-epic tombstone) + momentum % excludes cancelled (D45–D48) | M | 10 (this wave) |
| 23 | Activity-focus retune: recency ranks sections (`lastActivity` = updated∪claim∪events, fold-inclusive) + done never floods (fold-all-but-≤2, drop 24h age rule) + focus windows replace head-of-5 (active=neighborhood, inactive=header+rollup) + kill READY TO CLAIM (one list) + robust-to-bad-hygiene by policy + teeth-checked livecorpus guard (D49–D55) | L | 11 (this wave) |
| 13 | RESERVED: server-side one-call board endpoint — only if payload/N+1 proves it live | M | — |
| 19 | RESERVED: per-task mutation-events endpoint (`GET /v1/tasks/:doc_id/events`) — only if the derived timeline proves too thin in live use | M | — |
| 20 | RESERVED: drafts-aware `driven_tasks`/graph projector fix (D13d found it published-only) — server-side, own epic gate | M | — |

**D56 (2026-07-05, user direction — reverses D14):** a claimed task renders in NOW *and* stays IN
PLACE in its section — a spinner row heading its neighborhood (childBand 0), worker shown. Why (user,
verbatim): "What is showing Now should be showing in context of their list - we want to see the list
below Now be updated to match it - and show whats going on." NOW is the glanceable summary; the list
below tells the same story in context. The D14 de-dup helpers (dedupNowFromEpics/dedupNowFromClusters/
stripNow) are deleted; NOW anchors now add themselves to the focus window and seed context.


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
verb); trimmed discoverable detail to stay at 2398/2400 (never raised the cap). Perfecter
corrections: the card briefly claimed "first paint from a cached snapshot" — slice 8's cache
was NEVER BUILT (roadmap row 8 is still open; what shipped is amendment E: Init fires the
first fetch async and frame 1 paints the honest syncing state), so the card now states the
async-first-fetch truth; and "unkeyed" → "loose tasks by shared label" (in code, *unkeyed*
is the suggestion-side vocabulary — clusters group loose tasks that HAVE a shared key).

**Deferred to when wave 4 merges:** document heartbeat/aliveness-budget + checklist grammar in
tui.md; extend live_probe's decode guard to CriteriaItems (per-item text non-empty, met ==
#checked); the true "watch the NOW card tick / working-verb cycle / one-shot flash+fold at rest"
observation — a headless run can verify the still-at-rest mechanism but not the animation itself.

### Wave 2026-07-04 (wave 5 CUT: the simple/beautiful/deep pivot — architect decisions D19–D25)

**Reconciled reality:** waves 1–4 + #1100 MERGED on main (git log confirms #1007/#1026/#1057/
#1067/#1100 on `internal/taskboard`). The board is live and busy; this wave pivots to calm + deep.

**Verified against the tree before cutting (not trusted from strategists):** pdrender's public
API is `Decode([]byte)→[]Block`, `DefaultRegistry(Theme)`, `RenderDoc(blocks, RenderCtx)`,
`DarkTheme()/LightTheme()`, `RenderCtx{Width,Theme,Profile,TaskResolver}`; pdrender imports only
lipgloss+stdlib and explicitly forbids apiclient/taskboard (import direction taskboard→pdrender
is LEGAL). `pdrender.Theme` fields are UNEXPORTED with no color-injecting constructor → **no theme
bridge is possible** (D20). `fetch.go` already decodes `content` as `json.RawMessage` per task →
FetchSnapshotFull is a decode extension, zero new fetch (D25). Paper route confirmed router.ex:1247.

**The cut (4 file-disjoint parallel slices — the shell is held to wave 6):** subtraction and the
nav shell both rewrite render.go+program.go, so they cannot parallelize; the shell moves to the
next wave onto the calm board (D19). This wave: (1) detail substrate, (2) RenderTaskDetail+mdlite,
(3) paper frame, (4) the subtraction pass. Zero file overlap verified; `frames.go` frozen
byte-identical in slices 1–3; subtraction owns render/components/anim/chips/board/program +
golden regen and touches none of the others' files.

**What the next (shell) wave inherits:** a calm board (frame 0), a tested `RenderTaskDetail`
`([]string,[]Stop)`, a tested `RenderPaperFrame` `([]string,[]Stop)`, `FetchSnapshotFull`+
`DetailIndex`+`ChildrenOf`+`DrivenTasks`+`PaperRefs`, and `apiclient.PaperDoc`. It must: install
the `[]Frame` stack (board=frame 0), D11 cycle guard + per-frame cursor/scroll restore, the D12
compositor (two-pane ≥110 / push <110, ±4 hysteresis, depth-0 zero-fetch detail preview), D18
cursor grammar, the breadcrumb, then DELETE `UIState.Expanded`/`expandedDetail`/`t` verb for good,
and update docs/cards/tui.md + fix the go-1.24.2/1.25.0 doc drift.

### Wave 2026-07-04b (wave 5 GREEN: all four slices built + perfected; direction ran a real integration probe)

**Landed (on `-p` branches, ready for lead integration; NOT yet merged):** all four slices
GREEN with SHIP verdicts. Substrate (`d8ffc76e`-p): FetchSnapshotFull/ChildrenOf/DrivenTasks/
PaperRefs, +996/−24, fixture+live-probe tested, zero new network (D25 held). Detail
(`3c5e04d6`-p): RenderTaskDetail + real mdlite, +1925, goldens at 60/80/100, D15/D16/D24 all
honored, prose renders through the SAME pdrender engine as papers. Paper (`7d3fd43b`):
apiclient.PaperDoc + FetchPaper/RenderPaperFrame, DarkTheme direct (D20 held, the earlier
theme-bridge attempt was correctly restarted), (slug,rev,width) render cache. Subtraction
(`83a946bc`): net −504 lines — chips.go DELETED, one 4-glyph vocabulary, ONE-line ticker,
NOW de-dup, ▎ selection, shrunk expand (D23), glyph_budget_test allowlist guard.

**Direction integration probe (octopus merge of all four `-p` onto origin/main `cdd1e209`,
throwaway worktree, suites run):** the merge is FILE-clean (frames.go byte-identical across
slices 1–3, sha 42010d13; zero path overlap; #1111 touches no taskboard/apiclient/pdrender
file) but NOT SYMBOL-clean. The lead's integration checklist, each verified mechanical:

1. **`criteriaFraction` collision** — detail_render.go:443 declares
   `criteriaFraction(d TaskDetail) (met, total int)`; the subtraction's components.go:197
   declares `criteriaFraction(c *Criteria) string`. Rename the detail one to
   `detailCriteriaFraction` (2 sites, detail_render.go only). Verified compiles.
2. **`StatusGlyph` arity** — paper.go:270 calls the OLD two-arg `StatusGlyph(t.Lifecycle, 0)`;
   the subtraction deleted the frame param. Drop the `0`, then regenerate `paper_80.txt` with
   `-update-paper` (the stale golden carries the retired ◴/☐ vocabulary).
3. **Glyph-budget policy decision** — glyph_budget_test.go sweeps ALL `testdata/*.txt` against
   the tight board allowlist, and the detail/paper goldens legitimately carry a READING-frame
   vocabulary (— • → ↳ ═ ▌ ▍ ▸ ⧉ from mdlite bullets, timeline arrows, evidence hooks,
   pdrender rules/quote bars, the detail twin line). Do NOT just grow the one list: split into
   two closed allowlists (board surface stays tight; `detail_*`/`paper_*` get the documented
   reading set). The guard WORKED — it caught the cross-slice vocabulary drift it was built for.
4. Delete `wiring_stub.go` (detail slice's PaperRefs stub) — semantics identical to the
   substrate's real one.
5. With fixes 1–4 applied in the probe: `go build ./...` + full taskboard/apiclient/pdrender
   suites GREEN and `-race` CLEAN (0 warnings). Use `CC=/usr/bin/clang` on this host.

**Perfecter must-knows carried forward:** (a) TWO worktree stashes hold recoverable WIP — the
substrate worktree's "parallel-slice-wip" (a subtraction duplicate; discard) and the subtraction
worktree's stash of leaked SHELL-wave WIP (compose.go/stack.go/program.go nav-stack edits —
recover before cleaning if the shell wave wants a head start). (b) frames.go is deliberately
gofmt-dirty (charter-frozen bytes); dedupe at integration, and if it should be clean, fix the
CHARTER block first. (c) DESIGN CALL TO RATIFY at integration: epic/cluster header digits now
count only the section's displayed+folded rows (claims live in NOW), so denominators shift as
claims come/go — self-consistent but differs from the vision line's `7/12`; log the ratified
reading. (d) Now-unreferenced-but-tested: DoRelabel/TaskRelabel, Meter/scaleFill — shell wave
deletes or consumes. (e) Suggested/TwinOf computed but board no longer renders them (detail's
twin line does). (f) detailGlyph renders neutral `·` for cancelled — fine, revisit only if a
dedicated glyph is wanted. (g) pdrender's colored-code-collapse bug is REAL, hit both detail
(worked around via NoColor prose profile) and will hit papers — warrants the RESERVED pdrender
fix as its own gated slice. (h) FetchSnapshot now delegates to FetchSnapshotFull and discards
the DetailIndex — accepted D25 cost; the shell should keep the index instead.

**Learned:** the frozen-bytes contract prevents FILE conflicts, not SYMBOL conflicts — two
slices declared the same package-level helper name and one called another's pre-subtraction
signature. Next multi-slice wave: freeze shared-helper SIGNATURES in the charter too, or
require slice-private helpers to carry a frame prefix (detailX/paperX). Also: goldens created
in one slice can be invalidated by a sibling slice's vocabulary change in the same wave —
integration must always re-run golden regen + the budget guard, never trust per-slice green.

**Next wave (6 — the shell, slice 17, where the wish becomes USER-VISIBLE):** integrate wave 5
first (the checklist above), then ONE integration-shaped wave: the `[]Frame` stack + D11 cycle
guard + per-frame cursor/scroll, D12 adaptive compositor (two-pane ≥110/push <110, ±4
hysteresis, depth-0 detail preview), D18 grammar + breadcrumb, DELETE
Expanded/expandedDetail/`t` for good, consume-or-delete the orphaned helpers, docs/cards/tui.md
update + go-1.25 drift fix, and a LIVE guerrilla run (the reading frames have never met the
real corpus). Nothing else — until the shell lands, the user cannot see ANY of wave 5's depth.

### Wave 2026-07-04c (wave 5 INTEGRATED by the lead)

All four slices merged to `integrate/tui-wave5` (sequential, zero file conflicts — the
frozen-bytes contract held). Checklist applied exactly: (1) detail's helper renamed
`detailCriteriaFraction` (2 sites); (2) paper.go on one-arg `StatusGlyph` + `paper_80.txt`
regenerated (retired ◴/☐ gone); (3) glyph budget split into TWO closed allowlists —
board stays tight, `detail_*`/`paper_*` get the documented 9-rune reading set
(— • → ↳ ═ ▌ ▍ ▸ ⧉) via `readingGlyphExtras`; (4) `wiring_stub.go` deleted. Full
taskboard/pdrender/apiclient/cli suites green, `-race` clean, vet clean, CGO_ENABLED=0
build green.

**RATIFIED (design call c):** epic/cluster header digits count only the section's
displayed+folded rows — claims live in NOW with a breadcrumb, so denominators shift as
claims come and go. The header describes what's under it; the vision line's static `7/12`
reading is superseded.

**NEW for wave 6 (found at integration):** pdrender's in-body task-chip glyphs
(`taskStatusGlyph`, inline.go — ○ open/◐ in_progress/⊘ blocked/● done/✕ cancelled) are
kept in LOCKSTEP with the Elixir walker's `task_glyph/1`, and they CLASH with the board's
wave-5 vocabulary (● in_progress/◐ blocked/✓ done) — on one paper frame the in-body chip
and the driven-rail can show the same task with contradictory glyphs. Unifying is a
CROSS-SURFACE change (Elixir walker + pdrender + parity tests + Studio HTML) — schedule it
with the RESERVED pdrender fix (colored-code collapse), NOT as a quiet local edit.

### Wave 2026-07-04d (wave 9 CUT: the detailed-direction redesign — architect decisions D36–D44)

**The wish (Amendment 3):** the user put the calm wave-5/7/8 board beside the design-language
mockup and said *make it look like the mockup*. This is the TUI catch-up spec §4/§7 scheduled;
the paper `task-list` component already ships the vocabulary (verified: `components.ex` has the
Braille-spinner CSS + blue/amber/teal). It deliberately reverses PART of the wave-5 subtraction —
structure + MEANINGFUL color return — while KEEPING its good parts (dim labels, done recedes,
honest truncation, one view).

**Verified against the tree before cutting (not trusted from strategists):**
- The ONLY in-repo cross-surface parity gate is `TestRoleForParityWithSemrole` (iterates
  `semrole.TaskLifecycles()` against `RoleFor`). There is NO `design/check` hex gate — spec §6 is
  aspirational. So `RoleFor` stays byte-identical (D37) and "drift-gate green" = semrole parity +
  the glyph-budget guard, both kept green.
- Current board vocabulary is the wave-5 CALM set (`StatusGlyph`: ● in_progress / ◐ blocked /
  ○ ready·open / ✓ done — all steady, `done` rendered DIM via `roleStyle(RoleOK)=dimStyle`). The
  redesign changes glyphs+colors, NOT the role map.
- `visibleRows` (program.go, `[]row`) and `flattenSpine` (render.go, lines) are TWO hand-aligned
  paths held honest only by `TestCursorParity*`. Nested subtasks + phase labels make a single
  `spineRows` producer mandatory (D42) — extract it so parity is structural.
- The animation seam is already built: `anim.Alive` gates the heartbeat, `UIState.Frame` is the
  injected frame index (0 at rest). The spinner is pure CONSUMPTION of `Frame % 10` (D38); the
  idle board stays byte-stable by construction — do NOT start a free-running ticker.
- pdrender's in-body task chips (`walk.ex`/`inline.go`: ◐/⊘/●) clash with the new set but are
  OFF LIMITS (pdrender read-only). Unification stays the RESERVED cross-surface slice.

**The cut — ONE large coupled slice (the whole `internal/taskboard` vocabulary changes at once;
parallel worktrees WOULD collide on theme/components/render/board/program/detail/goldens).** No
file-disjoint companion exists: even the ASCII/NO_COLOR fallback and the glyph-budget update touch
the shared theme/components + the goldens. So a single builder owns it end-to-end, then a perfecter
pass, then the REQUIRED live guerrilla run. What the next wave inherits if capacity runs out: a
board that reads like the mockup, and the RESERVED pdrender/walker glyph-unify slice still open.

### Wave 2026-07-05 (wave 9 GREEN + direction integration probe — the redesign matches the mockup)

**Landed (on `loop-epic/tui9-…-p`, ready for lead merge; NOT yet on origin/main):** the single
coupled slice, 2 commits (`3a60558a` feat + `cad68a5a` polish), **entirely inside
`internal/taskboard/`** — 38 files, +1117/−582. `origin/main` (`2ebba80f`) is an exact ancestor of
the branch, so the lead merge is a **fast-forward (zero conflicts)** — no octopus, no symbol
collision this time (single-builder, single-package cut, unlike wave 5's 4-slice symbol clashes).

**Direction integration probe (throwaway worktree on the `-p` HEAD, gates run with
`CC=/usr/bin/clang`):**
- `go build ./...` GREEN · `go vet ./internal/taskboard/...` clean.
- Full `internal/taskboard` suite GREEN; `-race` CLEAN (0 warnings).
- Adjacent suites GREEN: `internal/cli`, `internal/cli/cloud`, `internal/apiclient`,
  `internal/pdrender`.
- **Both cursor-parity guards hold UNWEAKENED** (`TestCursorParityShellRender`,
  `TestCursorParityWithClusters`) **plus the new** `TestCursorParityWithPhaseAndNesting` (the polish
  commit's guard that finally exercises the redesign's nested + phase-band structure — previously
  untested). `TestRoleForParityWithSemrole` GREEN (RoleFor byte-identical, D37 held).
  `TestGoldenGlyphBudget` GREEN (allowlist consciously extended: 10 spinner frames + `⠿` + `✕` + `↳`
  + progress-bar cells, each noted; `!` is ASCII).
- **LIVE guerrilla render** (read-only `FetchSnapshot`→`BuildBoard`→`Render` at 60/80 cols on the
  real corpus: 207 tasks, 54 ready / 149 done / 72%, **0 genuinely in_progress**). It reads like the
  mockup: momentum header `⠸ 0 in flight · ○ 54 ready · ✓ 149 done  72%` + a proportional progress
  BAR; dotted-leader section headers with `done/total` rollups (`Aesthetic Unification … ··· 14/38`);
  colored rich rows (glyph · id·title · P-severity priority · N/M criteria); arbitrary-depth `↳`
  nested subtasks (real on the deploy-button tree); folded done (`+9 done`, `+40 more ready`); honest
  scroll affordance (`↓ 58 more below`); `▎` selection bar; footer matches. The header spinner
  renders the live Frame glyph (`⠸`).

**Code-verified D-decisions (not just tests):** D37 `doneColor` teal `#0d9488/#2dd4bf` is a real
new token DISTINCT from `okColor` `#10b981/#34d399`; D42 there is ONE `spineRows(b,st)` in `spine.go`
consumed by BOTH `render.go` (flattenSpine) and `program.go` (visibleRows) — parity is now
STRUCTURAL; D38 spinner rides `Frame%10` with `⠿` freeze under `NO_MOTION` (no wall-clock); the TUI
status hexes in `theme.go` are BYTE-EQUAL to the spec §1 table (`#60a5fa` blue / `#fbbf24` amber /
`#2dd4bf` teal / `#f87171` red / `#e7edf2` ready / `#5f6b78` open).

**Honest findings / what "drift gate green" really means here:**
- There is NO in-repo `design/check` hex gate (spec §6 is aspirational — re-confirmed). The paper
  `task-list` PortableDoc component the wish cites as "already ships the vocabulary" is NOT in this
  checkout (it is the aesthetic-unification epic's artifact, built elsewhere). So shared-vocabulary
  conformance is enforced by: (a) the TUI hexes == spec §1 table exactly, (b) `RoleFor`↔`semrole`
  parity, (c) the glyph-budget guard — all three GREEN. There is no live cross-file diff to run.
- **pdrender in-body chips still drift and that is CHARTERED (D43).** `walk.ex task_glyph` (and its
  `inline.go` twin) still render `○ open / ◐ in_progress / ⊘ blocked / ● done / ✕ cancelled` — the
  OLD set — so a wikilink chip inside a rendered paper can show a task with a different glyph than the
  board's new spinner/`!`/teal-`✓`. This is the RESERVED cross-surface slice (Elixir walker +
  pdrender + Studio parity), acknowledged and untouched this wave.
- **Empty-title rows render honestly-thin, not as a named gap.** The live `quality` cluster shows
  `○ ` and `↳ ✓` rows with no title (genuine under-filled corpus tasks). The renderer can't invent a
  title — correct honesty — but spec §5's "visibly thin with a NAMED gap" is the authoring-quality
  layer (a different initiative, not this wave's redesign).
- **Blocker badge is the word, not the cause.** The wire carries only dependency COUNTS, not blocker
  refs, so the amber badge reads "blocked" — the acknowledged "else the word" fallback in D39. A real
  `! <cause>` needs the RESERVED per-task blocker-ref enrichment.
- **NOW band + spinner motion + done-flash could not be visually captured** on the live corpus (0
  genuinely in_progress — the NOW leak-guard correctly excludes the 119 EXPIRED claims). The header
  spinner glyph, the motion goldens, and `TestCursorParityWithPhaseAndNesting` cover the mechanism;
  the animation itself needs a live in_progress task to watch.
- Harness note: `⇄ —` server name in the probe is a harness artifact (`Chrome` injection is set by
  the program before first paint; my raw `Render` call used the empty default) — the real `bp tasks`
  shows `⇄ guerrilla`. Not a bug.

**Lead merge = fast-forward `-p` onto origin/main; nothing to reconcile.** After merge: docs slice
(tui.md wave-9 delta + the still-open go-1.24.2/1.25.0 drift) + the RESERVED pdrender/walker
glyph-unify cross-surface slice remain the only open TUI work; the redesign itself is at the bar.

### Wave 2026-07-05b (wave 10 GREEN: NAMED phase bands + cancelled folding — the SECTIONING catch-up)

**Landed (on `loop-epic/tui10-phase-bands`, one conventional commit, entirely inside `internal/taskboard/`
except the charter):** the two features D45–D48. All gates green: `CGO_ENABLED=0 go build ./...`,
`go vet ./internal/taskboard/...`, `CC=/usr/bin/clang go test ./internal/taskboard/... ./internal/cli/...`,
`-race` CLEAN. Both cursor-parity guards + `TestCursorParityWithPhaseAndNesting` hold UNWEAKENED, plus a
NEW `TestCursorParityBandedEpic` on the real `phase:<n>-<slug>` bands (the previous fixture used bare
W-codes, which no longer band). `TestRoleForParityWithSemrole` + `TestGoldenGlyphBudget` green (one new
board glyph: the en-dash `–` for the W3–4 range, noted).

**Verified read-only against guerrilla BEFORE building (not trusted from the task):** the curated data is
real — `aesthetic-unification-epic` has 38 direct children (24 across `phase:1-spine`…`phase:6-enforce`,
14 unphased done); `unified-aesthetic-goal` is a cancelled root + 7 cancelled children; `task-754439` a
cancelled childless root; 9 cancelled nodes total. The `parity-page` tasks do NOT chain to a
`parity-page` epic (their `parent_id` is `parity-page`, the doc is `drafts.parity-page` — a data
mismatch, READ-ONLY, not ours to fix): they render as a `gui-tui-parity` cluster / orphans, unbanded,
which is correct (banding is epic-only, >=2 phased children).

**REQUIRED live dump (read-only, never mutated) at 52/56/64/72:** `aesthetic-unification-epic` renders
6 NAMED bands with rollups — "Spine ··· W1 · 0/4", "Studio ··· W2 · 0/3", "Web ··· W3 · 0/2",
"CLI ··· W4 · 0/2", "Paper Components ··· W5 · 0/11" (with a per-band "+6 more"), "Enforce ··· W6 · 0/2" —
the 14 unphased done components render FIRST (capped, "+9 more"); the dead `unified-aesthetic-goal`
collapses to a dim bottom tombstone; ZERO `✕` rows anywhere; momentum 67% (cancelled excluded, else 65%);
every uncurated epic ("Enterprise-ready auth", "Time-Boxed Airdrop Grants", …) and the `gui-tui-parity`
cluster render EXACTLY as before.

**Code-verified decisions (not just tests):** ONE `spineRows` producer emits `spinePhaseBand` /
`spineDeadEpic` (both `Selectable:false`) so BOTH `visibleRows` and `flattenSpine` read them — parity is
structural; `phaseBands`/`deriveBandCode`/`titleCaseSlug` live in `spine.go`; `TaskRow` grew an explicit
`guide bool` (band indent ≠ ↳ nesting); `renderSectionHeaderIndent` is the shared indented header;
`buildEpic`/`buildCluster`/`foldStaleOrphans` route cancelled into `CancelledFolded` (any age);
`progressPct` drops the `cancelled` Counts key. Not one PRE-EXISTING golden changed — the phase-less
majority is regression-neutral by construction.

**Honest scope notes:** the per-band done/cancelled tail is EPIC-LEVEL (buildEpic folds terminal children
before the phase labels are grouped), so a banded epic's folds surface as one trailing
"+N done · M cancelled" under all bands rather than attributed to a specific band's mockup line
("+2 more done — folded" under Paper Components) — honest, and re-attributing would require preserving
folded children's phase labels (deferred, low value). A single-band epic (>=2 phased children all sharing
one phase) still bands (named header + rollup) — harmless. The dead-epic tombstone is non-selectable
(a tombstone is not actionable); if inspecting a cancelled epic ever matters, make it selectable later.

**Next:** docs slice (tui.md wave-9/10 delta + the go-1.24.2/1.25.0 drift) + the RESERVED pdrender/walker
glyph-unify cross-surface slice remain the open TUI work.

### Wave 2026-07-05c (wave 11 CUT: the activity-focus retune — architect decisions D49–D55)

**The wish (AMENDMENT 4):** the user saw the auth epic dump ~25 fresh `✓` rows (the age-based
"terminal >24h folds" rule let all the <24h closes through) and the READY TO CLAIM head duplicate
rows from the sections below. Verdict: ONE list, ranked by recency of activity, done never floods,
focus windows of active work + its context (3 siblings / 3 children / 1-2 parents, merged when
actives are near), inactive sections collapse to header+rollup, robust to bad hygiene by policy.

**Verified against the tree before cutting (not trusted from strategists):**
- `Snapshot.Events` (prime `recent_events` → `{Mutation, DocID, At}`, decoded in fetch.go) is carried
  to `Board.Events` but NEVER read by ranking — `sortEpics` uses `epicFreshest` = max `UpdatedAt`
  over KEPT (post-fold) children only, so a mass-close's recency is ALREADY partly lost (folded-done
  `UpdatedAt` never counts) and events are unused. D49 fixes both: `lastActivity` reads events +
  claim-time and is computed over the FULL member set before folding.
- The flood is `buildEpic`/`buildCluster`/`foldStaleOrphans`'s `isTerminal && now.Sub(UpdatedAt) >
  doneFoldAfter` gate — done <24h renders as a row (childBand 6). D50 deletes the age gate.
- The READY TO CLAIM band is `renderReadyHead` + `showReadyHead` + `rowReadyClaim`, gating the pinned
  band when `len(Now)==0 && len(ReadyHead)>0`; `Board.ReadyHead`/`ReadyTotal`/`readyHead()` feed only
  it (header ready count is the independent `readyCountLabel`). D52 removes the lot.
- `sectionShown` (program.go) is the ONE shown-count rule; `spineRows.section()` (spine.go) consumes
  `shown` and does nest+band. The focus window is a SELECTION not a count, so D51 replaces the count
  with a `sectionMode` + `FocusSet` filter applied inside `section()` before nest+band, rollups still
  whole-band. `groupHeadMax` / per-band cap are deleted.
- Cursor-parity is structural through the single `spineRows` producer (D42) — the window is a filter
  inside it, so `visibleRows` (Selectable subset) and `flattenSpine` stay in lockstep automatically.
- `livecorpus_test.go` hand-builds a Board (isolating render); D55 drives it through `BuildBoard` so
  the goldens actually guard the D49–D51 policy, with the flood/merge/dormant/recency fixture.

**The cut — ONE large coupled slice (the whole `internal/taskboard` section policy changes at once:
board.go ranking+fold, types.go section fields, spine.go window/mode, render.go NOW-band+section
loops, program.go mode+visibleRows, + full golden regen). No file-disjoint companion exists — the
window touches every layer of the one spine.** Single builder end-to-end, then a perfecter pass, then
the REQUIRED read-only guerrilla dump at 56 and 72 (confirm the auth epic's ~25 closes fold to `+N
done`, sections order by recency, no READY TO CLAIM, active context reads as one neighborhood; NEVER
mutate live tasks).

**What the next wave inherits if capacity runs out:** an activity-focused board; open TUI work stays
the docs slice + the RESERVED pdrender/walker glyph-unify cross-surface slice.

**D51-a (lead amendment, same wave):** a section with NO live seeds but touched within 48h
(focusFallbackHorizon) seeds its focus window from its ≤2 freshest READY tasks (freshestReady →
computeFocus selfSeeds) instead of collapsing to a bare header. Why: the live corpus proved the pure
policy renders an all-headers board with zero actionable rows when nothing is in_progress — big
picture without "what to work on next" is dead space of another kind (Amendment 4 verbatim). Sections
older than the horizon keep the pure big-picture header. Teeth: disabling the horizon fails 8
livecorpus assertions.


### Wave 11 2026-07-05 (SHIPPED + integration-probed — the activity-focus retune, D49–D55)

**Merged clean** onto origin/main (`b316ee63`) in a throwaway worktree, zero conflicts. All gates
GREEN unweakened: `CGO_ENABLED=0 go build ./...`, `go vet`, `CC=clang go test` (taskboard + cli +
cloud + setup), `CC=clang go test -race ./internal/taskboard/...`. Named guards pass: 4×
CursorParity, RoleForParity (semrole), GlyphBudget (zero allowlist edits), LiveCorpusGolden(w52/56/
64/72), LiveCorpusInvariants, TestActivityFocus. Deletions verified GONE from src (ReadyHead/
readyHead/rowReadyClaim/showReadyHead/ReadyTotal/renderReadyHead/doneFoldAfter/epicFreshest/
clusterFreshest/groupHeadMax/sectionShown/epicShown/clusterShown/orphansShown; the three
`ready_head_*.txt` fixtures gone) — only surviving refs are comments and the intentionally-kept
`ReadyHeadClamped` (header ready-count label, D52).

**Teeth INDEPENDENTLY re-verified** (not just trusted): breaking D50 (`doneCueMax` 2→999, fold
disabled) fails BOTH `TestLiveCorpusGolden` (frame diverges) AND `TestActivityFocus`
(`auth DoneFolded = 0, want >=18`). One gotcha recorded for the next assessor: `go test` served a
`(cached)` PASS under a source mutation — always add `-count=1` when teeth-checking, and note the
D50 assertions live in `TestActivityFocus`, not `TestLiveCorpusInvariants`.

**Live read-only guerrilla dump (56 + 72, 305 tasks / 195 done):** all four confirmations HOLD — the
auth epic's 27 closes fold to a header line (29/30, no `✓` wall), sections rank recency-desc (auth
15:58 → parity 15:46 → rail 15:41 → … → dormant cloud-fleet 07-03 sinks last), NO READY TO CLAIM
band, robust under bad hygiene (no flood). **BUT** the focus-neighborhood eye-catch (point 4) is NOT
demonstrable on the current live queue: the single live `in_progress` claim
(`content-writepath-sandbox-flake`) is a childless root orphan (parent="", 0 siblings, 0 ready, 0
blocked), so `computeFocus` correctly returns empty → header mode, and every epic/cluster is
`active=false` (the claim is in none of them). The whole live board therefore renders header+rollup
lines only — correct-by-policy for a low-active board, the wish's "big picture," and proven robust,
but the neighborhood window is only visible in the golden fixture. **Eyeball once someone claims a
task that sits INSIDE a populated subtree** (ready siblings/children present) — that is when W11's
signature behavior lights up.

**Honest tension to watch (not a regression):** with 80 ready tasks and one context-less claim, the
board shows ~17 collapsed headers + large trailing dead space and ZERO ready rows without expanding.
This is exactly D51 policy ("no activity → header+rollup; expand reveals all") and claim-forward
still works (cursor to any ready row after `l`/enter + `c`), but it sits on the knife-edge of the
wish's "i dont want too much dead space without me expanding." A board that is mostly dormant epics
now reads as mostly empty. Whether that is "clean big-picture" or "too empty to act on" is a live
judgment the user should eyeball. The §5/§6 hygiene arm (save-gate, completeness score, `bp task`
lint, guided editor) is the real fix — a well-tended queue with genuine in_progress work is where
this design pays off; the board is now robust to bad hygiene but cannot manufacture activity that
isn't there.

**Next wave inherits:** the RESERVED pdrender/walker in-body glyph-unify cross-surface slice (D43,
board vs paper-chip clash), the TUI docs slice, real blocker-ref rendering (blocked rows show `!` but
not the causing task), and the §5/§6 hygiene-enforcement tasks — now the highest-leverage TUI-epic
work, since the board's correctness is bounded by queue hygiene.
