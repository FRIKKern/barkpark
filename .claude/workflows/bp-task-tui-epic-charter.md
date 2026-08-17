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
    [SUPERSEDED 2026-07-23 / D98]: this "spec §6 aspirational" finding is stale — `design/check.mjs`
    Part B ("§6") now gates cross-surface lifecycle parity (green; `node design/check.mjs`). The gate
    covers the EMITTED chain (Go board `tokens_gen.go` / `paper-surface.css` / Studio `--life-*` +
    `studio/tokens_gen.ex` vs `tokens.lifecycle`); pdrender's in-body chip vocabulary
    (`inline.go taskStatusGlyph`) is hand-written and stays OUTSIDE the gate — that gap is D43.

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
| 24 | Dispatch frontier: `area:`-aware interference model + greedy MWIS `Frontier` fn + `bp task frontier` verb + TUI IndependentReady switch (D67–D74) | L | 13 (this wave, CUT) |
| 25 | CMUX bridge: `bp cmux` builtin (hook/dispatch/install/status) — pane-owns-a-task claim/renew/close-or-resume loop + frontier→agent-pane dispatch, fail-safe, no server change (D75–D81) | L | 14 (this wave, CUT) |

**D56 (2026-07-05, user direction — reverses D14):** a claimed task renders in NOW *and* stays IN
PLACE in its section — a spinner row heading its neighborhood (childBand 0), worker shown. Why (user,
verbatim): "What is showing Now should be showing in context of their list - we want to see the list
below Now be updated to match it - and show whats going on." NOW is the glanceable summary; the list
below tells the same story in context. The D14 de-dup helpers (dedupNowFromEpics/dedupNowFromClusters/
stripNow) are deleted; NOW anchors now add themselves to the focus window and seed context.


**D57 (2026-07-05, user direction):** the "+N more / +N done" fold line is a SELECTABLE cursor stop —
enter (or l) on it expands its section to the full list; a second enter toggles back, mirroring the
header. User verbatim: "where we see 11 more etc - we should be able to highlight and open and see
the rest." Emitted with Ref=fold key + RK=rowMore by the ONE spineRows producer, so cursor-parity
stays structural; selected state draws the ▎ marker in the indent gutter.

**Heartbeat retimed (decision 16 amendment, 2026-07-05):** frameCadence 1s → 100ms per user direction
("it should feel tempo") — a full braille rotation per second, matching spec §2's ~80-100ms/frame.
The aliveness budget is untouched: zero ticks at rest, idle board byte-stable.

### Wave-12 architect decisions (2026-07-06 — the ACTIVITY BAND, evolved; wish AMENDMENT 5)

RE-CUT: the earlier bottom-console amendments (a fixed activity console / sticky feed / NOW-band
relocation) are RETRACTED by the final wish — "we dont really want the activity console… make the
activity part on top really good… cover more intent + what agent is working on stuff." The bottom
one-line `renderTicker` is UNTOUCHED (it is console enough). Everything stays where it is; the
pinned TOP band gains WHO + INTENT. All claims verified against the tree (render.go / components.go /
board.go / program.go / types.go) and against a read-only guerrilla dump.

58. **No console; the pinned TOP band gains WHO + INTENT, inside `Render` only (board frame 0).**
    Compose reading frames (task detail / paper) get NEITHER — zero `compose.go` change; the reading-
    frame compose goldens stay byte-identical (only `compose_wide_120`, which embeds the board in its
    left pane, legitimately reflects the collapsed empty NOW band). *Why:* the wish wants the top part
    really good, not a new surface.

59. **WHO — NOW collapses to ONE agent-first line per claim (Doey grammar).** `NowCard` returns a
    single line: `‹marker›‹spinner› ‹worker(blue subject)› ‹title› …… ‹N/M› ‹ticking lease-tinted
    age›`. The worker LEADS the text (agent-first — "what agent is working on"); the epic breadcrumb
    is DROPPED (D56 shows the claim in-context in the spine). The 2-line NowCard + its `nowCardMeta`
    line-2 rebuild are retired. Below `dropMetaBelow` the row sheds to spinner+worker+title. *Why:*
    Doey's worker_ticker is the exemplar — one tight attributed row per live agent.

60. **INTENT — a tiny NEXT strip under NOW, ≤`nextMax=3` cursor rows.** `renderNextBand` renders
    directly under NOW with a DIM "NEXT" label (intent is subordinate to active work; NOW's label is
    bold — the weight encodes active > intent). Resumables FIRST (`↩ resume '<title>' · lease expired
    <age>` — `↩` amber, meta dim), then the P0-first ready head (`○ Pn title`), then a display-only dim
    `+N ready` tail (a pointer to the spine, NOT a cursor stop, sheds first under height pressure).
    This is NEVER the wave-11-killed READY-TO-CLAIM wall (D52) — it is capped, honest intent, and each
    NEXT row is a real cursor stop `c` claims. `↩` is the ONE new glyph (glyph-budget allowlisted).

61. **`Board.Next []NextItem` + `NextReadyMore int`, BuildBoard-owned `resolveNext()`.** Resumable =
    a `task.lease_expired` event bareID-joined to a non-terminal, unclaimed, not-since-reclaimed/closed
    task; deduped by bareID (freshest lease kept). Ready head = ready tasks excluding NOW + resumables,
    P0-first via the existing `priorityRank`, then recency; concatenated resumables ++ ready head, ≤
    `nextMax` total; `NextReadyMore` counts only ready candidates that did not fit (resumables are
    follow-up, never "ready"). `taskByID` also searches `board.Next` (a resumable can be a folded orphan
    absent from Now/Epics/Clusters/Orphans). Live-proven read-only on guerrilla (a real `drafts.*`
    resumable + a real P0 ready head + `+80 ready`).

62. **NEXT ready rows use `claimTask`'s ready-gate; NEXT resumable rows claim SERVER-ARBITRATED
    (bypass the local ready-gate).** A live resumable is `open` and outside prime's clamped ready
    overlay, so the local gate would wrongly refuse it — but it was provably claimable moments ago and
    the SERVER is the real arbiter (an honest strip renders on a genuine refusal). The `c` handler routes
    a `rowNext` resumable straight to `claimCmd`; every other row keeps the ready-gate path. `x`/`o` on a
    NEXT row use the unchanged handlers (x honestly refuses an unclaimed resumable; o builds the Studio
    link).

63. **Cursor parity extended to NEXT: `rowNext` pinned at `[len(Now), len(Now)+len(Next))`.**
    `visibleRows` emits the NEXT rows after NOW and before the spine (height-independent — always
    `len(Next)` rows; the renderer's fold is purely visual). `flattenSpine`'s pinned offset moves
    `len(Now) → len(Now)+len(Next)`. The band collapses to NOTHING when NOW+NEXT are both empty (no
    labels, no blank spacers — the all-clear lives in the momentum header). Under height pressure NEXT
    sheds (folds to `+N intent`) before the spine drops below `minSpine=4`; NOW is last to shed. The
    ONE `spineRows` producer is UNTOUCHED (NEXT is a pinned-band row above the spine, not a spineRow).
    Guarded by `TestNextCursorParity` (a board WITH next rows) alongside the existing parity guards,
    UNWEAKENED.

**D64 (2026-07-05/06, wish Amendment 5 — completion ≠ activity):** a section with zero WORKABLE
children (nothing in_progress/ready/blocked/open) keeps its D49 recency rank only through a
finishedGraceAfter=1h window — during grace the ≤2 done cues render so the completion is SEEN —
then it Demotes: spineRows relocates it to the finished shelf at the board bottom (after orphans,
above the W10-B tombstones), one header+rollup line, still selectable/expandable (explicit overrides
win, D54). Why (user, verbatim): "we should not spend long time showing done epics at top - it will
go to bottom after a short while." Guards: TestFinishedEpicDecay (grace boundary both sides) + the
livecorpus goldens (the dormant 2/2 epic now pins the shelf).


**D65 (2026-07-06, user directive "What is set as 'Next' must be deeply curated"):** the NEXT ready
head is SCORED, not priority-sorted: continuity with live/dropped neighborhoods (+200, "finish what
we started"), unblock leverage (+30/dependent, cap 5), well-formedness (+100 for >=2 acceptance
criteria — an agent can actually finish it), priority points (P0 80 / P1 60 / P2 30 / else 10), and
a zombie discount (-50 past 7d untouched). Every ready pick renders its dominant reason dim
("continues <root>", "unblocks N") — a deeply-curated pick explains itself. Weights are transparent
constants; guards TestNextCurationSignals + the restated TestNextReadyHeadP0First.

**D66 (same directive, second half — "base next on all the different spots not impacting each
other"):** the strip is a PARALLEL-SAFE dispatch head: at most ONE pick per root neighborhood (the
blast-radius key the data carries), so the ≤3 rows are independent moves, never one epic's queue.
Board.IndependentReady counts distinct ready neighborhoods — the label reads "NEXT · N independent",
the honest "how many agents could run right now" capacity. The FULL blast-radius/dispatch model
(labels/papers/deps as interference signals, a frontier verb, 50-agent ambition) is chartered as the
NEXT WAVE, not squeezed in here.

### Wave-13 architect decisions (2026-07-06 — the DISPATCH FRONTIER; wish "figure out how many we can take on at once … 50 agents when they don't impact each other … careful but ambitious")

Full design: `/Users/pelle/.claude/jobs/c06ba8c5/tmp/dispatch-frontier-design.md` (→ Publish as paper
`dispatch-frontier`). All coverage numbers below verified READ-ONLY against guerrilla 2026-07-06 (332
tasks: open 87 / done 232 / cancelled 12 / blocked 1; 58 leaf-ready workable). This wave deepens
D65/D66 from "one pick per root" into a real `area:`-aware interference model + a dispatch verb.

67. **The blast-radius KEY is the CODE SURFACE (`area:`), with proj/root as the conservative
    fallback — NOT root alone.** VERIFIED shape: `proj:` (93% of open) ≈ `design_doc` (26%, 1:1 with
    root) ≈ root — all three encode "same epic," NONE encodes "same surface." Two different epics both
    rewriting Studio carry different root/proj/paper AND zero dep edge, so every reliably-carried
    signal calls them independent and they are not. `neighborhoodKey(t) = proj else design_doc else
    rootOf` (proj FIRST so `proj:loop`'s two roots — `schema-workspace-safety-goal` +
    `security-hardening-goal`, verified — MERGE into one blast radius; strictly more careful than
    D66). `interferes(a,b)`: HARD if a `blocks` edge either direction, OR (both carry `area:` and their
    area sets OVERLAP), OR (≥1 lacks `area:` and same `neighborhoodKey`); NONE if both carry `area:`
    and areas are DISJOINT (this is what lets two tasks in ONE epic touching different surfaces run in
    parallel — the road to "50"); UNKNOWN for metadata-thin strangers. *Why:* real merge-collision is
    surface overlap; the model must key on it, using the epic as the safe proxy only when the surface
    is unknown.

68. **STRANGERS default = independent-but-FLAGGED (`unproven`), with a careful dial — not
    blanket-conflict.** A stranger with no `area:` cannot tell us its surface class, so a
    "strangers-of-the-same-class conflict" rule would be GUESSING conflict (collapses the frontier to
    ~1) exactly as dishonestly as guessing safety. Correct move: dispatch the independent set, REPORT
    the `unproven` flag + a `bp task lint` nudge, and expose `--proven-only` (careful: emit only
    `isolated` picks, solo the rest) beside the ambitious default. The correctness invariant is
    absolute regardless of dial: **the model NEVER calls two tasks sharing a HARD signal (root/proj/
    paper/dep/area-overlap) independent.** The only residual risk — two metadata-thin strangers
    secretly sharing a surface — is precisely what the `area:` convention (D69) exists to erase.

69. **THE MISSING CONVENTION: a ~12-entry closed `area:` vocabulary (area:api/studio/web/tui/cli/sdk/
    pdrender/sheets/onix/docs/infra), the code-surface key — 3% covered today (only cloud-console).**
    It is the ENABLER of intra-epic parallelism, not just a safety net: with `area:` on both tasks,
    interference is precise (overlap-only), so same-epic disjoint-surface tasks parallelize. Rides the
    §5/§6 hygiene arm: `bp task lint` nudges a workable leaf that carries no `area:`; the guided editor
    offers the closed picker. HONEST partial-adoption degradation is the contract: both have area →
    precise; either lacks → conservative neighborhood proxy (missing metadata always buys LESS
    parallelism, never more); two area-less strangers → independent+`unproven`. BONUS derivation: an
    epic's `phase:<n>-<slug>` bands already NAME surfaces (aesthetic-unification's studio/web/cli/
    paper-components) — derive a provisional `~area:` from the band slug, marked provisional in the
    blast-radius listing, so the biggest offender becomes partly-parallelizable before one label is
    hand-authored.

70. **THE FRONTIER ALGORITHM: greedy maximal-weight independent set over the interference graph,
    D65-scored as the selection preference, deterministic.** `Frontier(snapshot, detailIndex, now,
    opts) []Pick`: candidates = ready leaves (same derivation BuildBoard uses); score via
    resolveNext's EXISTING scorer (one scoring truth); sort `(score desc, doc_id asc)`; walk, admit a
    candidate iff it does not `interferes` with any already-admitted pick; cap at `--max N` (default
    unbounded → the honest full capacity). Each pick carries dominant reason (D65), a blast-radius
    listing (its neighborhoodKey + area set incl `~`derived + the candidates it DISPLACED), and a risk
    class (D71). Greedy (exact MWIS is NP-hard) is safe here because the graph is tiny/near-disjoint,
    deterministic, and never admits a conflicting pair. *Why:* the wish wants the LARGEST honest
    frontier; greedy-by-curation-score gives ambition, the predicate gives correctness.

71. **RISK CLASS per pick — where CAREFUL bites.** `isolated` (has area:, provably disjoint — batch
    freely; the only class `--proven-only` emits); `neighborhood` (no area:, sole rep of its
    neighborhood — safe by proxy, can't fan out within its epic until area: lands; carries the lint
    nudge); `unproven` (no area:, coexists with other area-less strangers — independent by assumption,
    counted in the footer tally); `shared-surface`→`solo:true` (area set ≥3 = a broad epic, OR area
    overlaps a higher-scored pick → the loser is DROPPED and listed under the winner's displaced set).
    Careful bites at four points: (1) an area overlap always drops the lower-scored pick; (2) a missing
    area: caps its whole neighborhood to ONE pick; (3) `--proven-only` collapses to the isolated set;
    (4) the ambitious default still emits unproven picks but NEVER hides the flag, so "50 agents" only
    prints when 50 spots are genuinely non-interfering. WORKED EXAMPLE (live): the 58 leaf-ready →
    **15 independent neighborhoods** (honest current capacity is ~15, not 50 — the tool says 15);
    `proj:design-system` (aesthetic-unification, 24 children, rewrites the token manifest across ALL
    surfaces) is the mega blast radius — once `~area:` derives from its bands it goes SOLO and
    `cloud-console`/`gui-tui-parity`/`pd-doctrine` (all touching Studio/pdrender) drop as displaced.

72. **SURFACES — ONE model, two surfaces (no drift), one reserved.** (a) `bp task frontier
    [-o json|table] [--max N] [--proven-only]`: client-side builtin, intercepted in internal/cli
    before manifest dispatch (the manifest `task` noun has ls/ready/prime/get/claim/close/next/move
    and NO `frontier` — verified, so the intercept shadows nothing); table = row-per-pick + capacity/
    proven-tally footer, json = full Pick array for an orchestrator. (b) TUI `Board.IndependentReady`
    switches to `len(Frontier(...))` — the SAME Go function feeds the "NEXT · N independent" label and
    the CLI verb, so they can never diverge. (c) RESERVED design-only, DO NOT BUILD: `bp task next
    --frontier` — atomically claim the top-k picks from distinct neighborhoods via the existing
    epoch-CAS claim endpoint, 409-skip + back-fill; deferred because it couples dispatch to mutation
    and wants the orchestrator loop's retry/lease policy (out of scope).

73. **OUT OF SCOPE (verified) + the dep-edge-target finding.** Server/API changes: NONE. Dep-edge
    TARGETS ARE readable via the EXISTING `GET /v1/graph/:id` (verified: returns `edges[{kind:blocks/
    parent/design_doc, from_id, to_id}]` + `nodes` to resolve uuid→doc_id, per connected component) —
    but slice 1 does NOT need it: every `blocks` edge in the live corpus is WITHIN a root tree (all
    airdrop-epic-internal), so the ready-gate + one-pick-per-neighborhood already cover within-tree
    deps; `graph.show` is a SLICE-2 precision enrichment (fold a cross-neighborhood block edge into
    HARD, should one ever appear), still a pure read. Also out: Studio UI; actually orchestrating
    agents (the epic-loop layer's job — this initiative gives it `Frontier` to act on); authoring the
    `area:` labels (the §5 hygiene arm + a Publish-phase seeding task, not code here). The model must
    ship working at 3% `area:` coverage and improve as labels land.

74. **SLICE PLAN.** SLICE 1 (buildable NOW — no server work, no missing data): pure `frontier.go`
    (`neighborhoodKey`/`areasOf`/`interferes`/`Frontier`/`Pick`, reusing resolveNext's scorer +
    rootOfBare over the already-fetched snapshot) + `independentReady = len(Frontier(...))` + the
    `bp task frontier` builtin; table-driven interference truth + a frontier fixture (proj:loop merges,
    area-overlap drops loser, area-disjoint same-root both admit, deterministic, --max/--proven-only) +
    a read-only livecorpus assertion (15 neighborhoods, aesthetic-unification SOLO under band-derived
    areas). SLICE 2: `bp task lint` area-missing nudge + guided-editor picker; optional `graph.show`
    cross-neighborhood block precision. SLICE 3 (Publish + ongoing): seed `area:` labels on the live
    epics, watch `unproven` shrink. SLICE 4 (RESERVED): `bp task next --frontier`. Guards stay green
    UNWEAKENED (cursor-parity structural via the single spineRows producer; NEXT/glyph-budget/semrole
    parity untouched — the frontier adds a function + a verb, not board vocabulary).

### Wave-14 architect decisions (2026-07-06 — the CMUX BRIDGE; wish "a cmux pane that IS a Barkpark worker + one-command frontier dispatch")

Full design: `/Users/pelle/.claude/jobs/c06ba8c5/tmp/cmux-bridge-design.md` (→ Publish as paper
`cmux-bridge`). This deepens the dispatch frontier (D67–D74) from "compute the honest capacity" into
"ACT on it": a cmux pane auto-owns a task (claim→renew→close-or-resume) and `bp cmux dispatch` spawns
the frontier into fresh agent panes. All code claims re-confirmed against the tree 2026-07-06 (not
trusted from the brief): `ResolveWorker` honors `BARKPARK_WORKER_ID` (actions.go:203);
`TaskClaimN`/`TaskCloseN` are the only mutation seams — NO heartbeat endpoint (client.go:892/923);
`Get("task",id)` returns `(Doc,false)` on any error (client.go:670); `Frontier`/`FetchSnapshotFull`/
`Board.IndependentReady` are the wave-13 shared model; the `task frontier` intercept (cli.go:146) is
the pattern to mirror; zero `CMUX_`/`CLAUDE_CODE_SESSION_ID` refs exist in Go today (greenfield).

75. **ONE client-side `bp cmux` builtin — hook/dispatch/install/status — intercepted in cli.go before
    manifest dispatch, NO server/API change.** `case "cmux": return runCmux(out, g, ctx, rest[1:])`
    in the noun switch (mirrors `runCloud`/`runAgent`); `runCmux` switches on the sub-verb. `cmux` is
    a free noun (not a manifest noun; the manifest `task` verbs are ls/ready/prime/get/claim/close/
    next/move — verified), so the intercept shadows nothing. Every mutation the bridge makes rides the
    EXISTING claim/close endpoints and the single-doc read; the frontier snapshot is the one
    `/v1/tasks` round-trip the board already fetches. *Why:* same headless-CMS, many-surfaces law — a
    new surface over proven endpoints, gated on the Go suite alone.

76. **Worker id is SURFACE-KEYED via one `CmuxWorkerID()` helper — the PANE owns the task, not the
    agent.** `taskboard.CmuxWorkerID()` (beside `ResolveWorker`): `BARKPARK_WORKER_ID` else
    `cmux-<CMUX_SURFACE_ID>` else `cmux-<CMUX_WORKSPACE_ID>` else `ResolveWorker()`. `CMUX_SURFACE_ID`
    is durable + pane-unique + invariant for the pane's life; `CLAUDE_CODE_SESSION_ID` differs per
    agent and subagents SHARE the pane's `CMUX_*`. Surface-keying means every subagent renews the
    pane's ONE claim (re-claim under the same worker = renewal, never a 409); a session-keyed id would
    make a subagent's claim collide with the lead's. Tier-1-first makes `BARKPARK_WORKER_ID` (which the
    install shell-line sets to `cmux-$CMUX_SURFACE_ID`) always win and stay stable; because
    `ResolveWorker` also checks it first, the tiers are consistent and degrade to `tui-<hostname>`
    outside cmux. One function, unit-tested across the env matrix, used by every subcommand. *Why:*
    the fencing lease is a per-pane resource; the id must track the pane, not the agent.

77. **Hook-event → bp-action mapping, with the HONEST close default = acceptance-gated, never
    turn-boundary.** `bp cmux hook <event>` reads the Claude hook JSON on stdin + env (`BARKPARK_TASK`;
    worker via `CmuxWorkerID`) and runs ALONGSIDE cmux's own `cmux claude-hook` (adds, never replaces).
    SessionStart → `DoClaim` (renewal-safe). PreToolUse → THROTTLED renew (re-claim, ≤1/60s via an
    on-disk stamp under `{UserConfigDir}/barkpark/cmux/`). Stop **and** SessionEnd → **close IFF the
    task has ≥1 `acceptance_criteria` and ALL are `met` (read via `Get("task",id)`); else do NOTHING**
    → the 300s lease TTL expires → `task.lease_expired` → the built `↩ resume` (wave 12). Notification/
    UserPromptSubmit/unknown → no-op. `Stop` fires at EVERY turn boundary, not "done", so an
    unconditional close would false-close an interactive multi-turn agent after turn 1; the
    acceptance gate is the ONE rule that is honest for both a one-shot dispatched agent and an
    interactive pane (a task with no criteria can't be proven done → leave for resume; erring toward
    not-closing is the honest failure mode, and the direct incentive for the §5/§6 authoring-quality
    gate). Close observes the LIVE epoch by re-claiming right before close (renewal-safe; no epoch
    persisted across the SessionStart/Stop process boundary; a foreign worker holding an expired lease
    → our re-claim 409s → no close, no theft). *Why:* the WHO/INTENT/resume machinery already exists;
    the bridge only feeds it truthful transitions.

78. **CARDINAL fail-safe: a hook NEVER breaks the agent.** Every `bp cmux hook` path exits 0 (incl a
    top-level `recover()`), writes NOTHING to stdout (some events feed hook stdout back into the
    agent's context — diagnostics go to stderr, only under `--dry-run`/`BP_CMUX_DEBUG`), and uses a
    bounded ~4s network timeout so a hung server never stalls a turn. Missing `BARKPARK_TASK` /
    unreadable task / unreachable server / malformed stdin / unknown event are all silent no-ops; the
    acceptance gate reads "can't read the task" as "can't prove acceptance" → leave claimed. `--dry-run`
    prints the bp call it WOULD make and mutates nothing. *Why:* a non-zero exit or stray stdout from a
    hook can abort/stall/poison the agent — the lease TTL is the backstop, so a missed action costs at
    most an honest resume, never a hang.

79. **`bp cmux dispatch [--max N] [--proven-only] [--dry-run]` reads the SHARED `taskboard.Frontier`
    (imported, never reimplemented) and spawns one agent pane per pick — dry-run-first.** Fetch the
    snapshot, BuildBoard, call `Frontier(snap, details, board.Now, now, FrontierOpts{Max,ProvenOnly})`,
    and per pick emit `cmux new-surface --type agent-session --env BARKPARK_TASK=<doc_id> --prompt
    <taskPrompt>`. Worker id is NOT passed at dispatch — the new pane derives its own
    `BARKPARK_WORKER_ID=cmux-$CMUX_SURFACE_ID` from its freshly-injected surface id (a dispatched pane
    and a hand-attached pane derive the worker identically; a dispatch-assigned id would fork that
    invariant — rejected). `--dry-run` (DEFAULT when `cmux` is absent from PATH) PRINTS the launch plan
    and spawns/mutates nothing; only spawns (`exec .Start`, never Wait) when cmux is on PATH and
    --dry-run is off. `--max`/`--proven-only` mirror the frontier verb (ambition / careful dials). The
    exact `cmux new-surface` flag spelling is confirmed at build against `cmux new-surface --help`
    (dry-run-first is precisely so the operator eyeballs the invocation before any spawn). *Why:* one
    interference model, two consumers (the CLI count and now the spawner) — they can never drift.

80. **`bp cmux install` is PRINT-FIRST — never clobber `~/.claude/settings.json`.** `--print` (default,
    the only slice-1 behavior) emits the Claude Code settings hooks block (SessionStart/Stop/SessionEnd
    → `bp cmux hook <event>`; PreToolUse catch-all `matcher` → renew) PLUS the guarded shell line
    `[ -n "$CMUX_SURFACE_ID" ] && export BARKPARK_WORKER_ID="cmux-$CMUX_SURFACE_ID"`, with copy-paste
    instructions naming both `~/.claude/settings.json` and the shell profile / cmux pane-init, and the
    emphasis that our hooks run ALONGSIDE cmux's own (additive per event). A `--merge [--yes]` mode
    (RESERVED) carefully folds our four entries into an existing settings.json — deduped by exact
    command string, foreign hooks preserved, backup-first, diff + consent, idempotent, print-only
    fallback on malformed JSON. The hooks JSON schema is validated against the installed Claude Code
    version at build. *Why:* "show, don't clobber without consent" + this phase's read-only posture.

81. **SLICE PLAN + out-of-scope.** SLICE 1 (buildable NOW, no server change): `CmuxWorkerID`
    (cb-worker-id) + `bp cmux hook` (cb-hook-entrypoint + cb-hook-failsafe) + `bp cmux status`
    (cb-status-verb) + `bp cmux install --print` (cb-install-print) — the full pane-owns-a-task loop,
    tested with fake-stdin × event × env matrix against httptest + the exit-0 fail-safe matrix.
    SLICE 2 (needs wave-13 `df-frontier-fn` merged): `bp cmux dispatch` (cb-dispatch-verb). SLICE 3:
    `bp cmux install --merge` (cb-install-merge) + docs (cb-docs-card, fold into the CLI card, 7-card
    cap). SLICE 4 (RESERVED, cb-next-frontier-claim): claim-before-spawn dispatch reusing the wave-13
    reserved `bp task next --frontier` atomic multi-claim to close the SessionStart-claim race. OUT OF
    SCOPE (verified): server/API changes (none — no heartbeat exists, liveness IS renew-or-expire); the
    orchestrator retry/lease loop; authoring `area:` labels (dispatch quality is bounded by wave-13's
    coverage, not this bridge). Guards stay green UNWEAKENED — the bridge adds functions + a noun, not
    board vocabulary.


**D82 (2026-07-06, live-loop bug found by proving it):** the cmux Stop hook's auto-close FAILED in the
realistic case — an agent that marks its own acceptance criteria met changes the doc after claiming,
which trips the server's work-digest fence (doc_changed_since_claim); the renewal re-claim keeps the
stale digest, so close 409'd and the fail-safe silently swallowed it → the task lease-expired into a
resume instead of closing. FIX: hookStopClose reads the FRESH rev after re-claim and passes it as
observed_rev (new apiclient.TaskCloseRevN + taskboard.DoCloseRev) — strict full-rev CAS is the
server's sanctioned digest-fence bypass, and the worker match still prevents theft. Confirmed with a
real end-to-end loop against guerrilla (claim → patch criteria met → Stop closes) and guarded by
TestHookStopClosesOnlyWhenAllMet asserting observed_rev on the close body. LESSON: a hook that fails
safe (exit 0) HIDES its own failures — only a real live loop, not unit tests + dry-run, surfaced this.


### Wave-15 architect decisions (2026-07-07 — INVERT THE PANE; wish AMENDMENT 6 "reverse things — the top part on bottom")

The user's wish, verbatim: "We need the top part of tui to be on bottom - i dont like fixed on top -
better bottom - reverse things." The SCROLLING TASK LIST becomes the top region and fills from the
top; the pinned band (momentum + progress + NOW + NEXT) moves to the BOTTOM, fixed directly above the
ticker/footer. Everything from waves 8–14 (focus windows, finished-shelf decay, curated NEXT, cmux
workers in NOW, the Compose gutter) is unchanged — ONLY the vertical placement and the cursor index
space invert. This is a pure `internal/taskboard` render+shell slice: `spine.go` (the ONE spineRows
producer), `compose.go`, `components.go` and pdrender are UNTOUCHED; no server/API change.

83. **The pinned band relocates to the BOTTOM as fixed status chrome; the momentum line + progress
    bar + truncation note DESCEND with it.** `Render` reassembles top→bottom as `[identityTop] [spine
    — scrolls] [band: NEXT then NOW] [momentum + progress + trunc] [ticker] [action strip?] [footer]`.
    `renderHeader` splits into `renderIdentityTop` (the one identity line, pinned top) and
    `renderStatusFooter` (momentum + progress + the "showing N of M" note, now fixed BOTTOM chrome).
    The status chrome is NEVER sheddable — exactly as the header block was never sheddable up top.
    *Why:* the user reads a status bar at the bottom "like a status bar"; momentum nearest the footer.

84. **Intra-band order + cursor order both flow top→bottom = NEXT above NOW, and the cursor walks the
    LIST first then descends into the band.** Vertically the band paints NEXT (dim label, intent)
    ABOVE NOW (bold label, live claims) so NOW sits nearest the momentum status bar. The cursor follows
    the visual order: spine selectable rows own the FIRST indices, then NEXT, then NOW at the very
    bottom. `j` from cursor 0 (top of the list) walks the list down, crosses into NEXT, then NOW; `k`
    reverses. *Why:* cursor order == visual order is the one honest rule for an inverted pane; the crux
    of the slice.

85. **The thin identity line STAYS pinned at the very top — it is orientation, not activity.**
    `barkpark · tasks · ⇄ guerrilla ● live · 2m` answers "what am I looking at / is it live"; it is a
    fixed title, not a live status readout, so it does not belong in the descending activity band. It
    stays as the single orienting line at the top. *Why:* a title that scrolls or floats to the bottom
    stops orienting; the live status (momentum/progress) is what belongs down with the ticker.

86. **The cursor index space flips in LOCKSTEP through ONE base `S = selectableSpineCount(b, st)`.**
    Today the band owned `[0, lenNow)[lenNow, lenNow+lenNext)` before the spine; now the spine owns
    `[0, S)`, NEXT owns `[S, S+lenNext)`, NOW owns `[S+lenNext, …)`. `S` is computed once in `Render`
    from the SAME `spineRows` producer and passed as `base` to `renderNextBand` (base=S) and
    `renderNowBand` (base=S+lenNext); `flattenSpine`'s `selIdx` re-bases to 0; `visibleRows` emits the
    spine selectable subset FIRST, then NEXT, then NOW. Because both the shell (`visibleRows`) and the
    renderer (`flattenSpine` + the band renderers) read the one producer and the one `S`, cursor-parity
    stays STRUCTURAL — the ▎ marker lands on the painted line at every index by construction, top→
    bottom. *Why:* one source of truth for the reorder; parity can't desync.

87. **The band budgets off the BOTTOM; the spine keeps ≥ minSpine (4) and the band sheds from the top.**
    `bandBudget = height − len(identityTop) − 2 blanks − len(chrome) − minSpine`. NOW reserves its lines
    FIRST (last to shed); NEXT gets the remainder and folds first (`+N intent`), its display-only `+N
    ready` tail shedding before that. An empty NOW+NEXT collapses the band to NOTHING — no labels, no
    blank spacers (the all-clear lives in the momentum "0 in flight") — so an idle board stays byte-
    stable. *Why:* the list is the hero region now; the sheddable band protects it from starving from
    the bottom, mirroring the old top-shed behavior.

88. **Goldens regenerate; reading-frame goldens stay byte-identical; guards walk unweakened.** Every
    board + `compose_wide_120` + livecorpus + motion/still/firstpaint golden inverts and is regenerated
    with `-update` (deliberate, eyeballed, never hand-edited); the reading-frame goldens
    (`compose_task_*`, `detail_*`, `paper_*`) MUST NOT change (a diff there = the inversion leaked into
    a reader, a bug). The cursor-parity guards (`TestNextCursorParity`, `TestPinnedRowParityUnderHeight
    Pressure`, `TestCursorParity*`) keep their exhaustive per-index ▎ walk, re-based to the tail; a new
    `TestInvertedIndexOrder` pins spine→NEXT→NOW explicitly. Glyph-budget + semrole parity green — the
    inversion adds NO vocabulary. *Why:* the flip is placement-only; the gates prove it changed nothing
    about what a row means, only where it sits.


### Post-wave-15 reconciliation (2026-07-09 — Amendment 7 + #1878 landed WITHOUT a charter entry)

Two merges reshaped the board after wave 15 and are the CURRENT truth (the wave-15 log above is
partially stale — read it through this note):

- **Amendment 7 (#1868, commit 92a618f8): the pinned NOW/NEXT band is RETIRED — the spine is the
  whole board.** `renderNowBand`/`renderNextBand`/`selectableSpineCount` base-offsets are GONE; the
  cursor space is just the spine `[0, S)`. Band-era tests (`TestNextCursorParity`,
  `TestPinnedRowParityUnderHeightPressure`, `TestInvertedIndexOrder`) were retired with it — the
  living cursor-parity family is `TestCursorParityShellRender` (program_test.go:114) +
  `TestVisibleRows*` / `TestCursorParity*` (program_test.go:79,215,253,385,433,465). A stale comment
  at spine.go:17 still names `renderNowBand` — fix rides wave-16 slice 1.
- **#1878: scrolling slides 1 line at a time** — `slideTop` (render.go:119) is the minimal-slide
  primitive for BOTH the board spine (`SpineTopFor`, render.go:97) and reading-frame cursor-follow
  (`followStop`); the window holds still mid-viewport and slides 1:1 at the edge, never a
  recenter jump. This is the motion law every scroll input (keyboard AND mouse) must ride.

### Wave-16 architect decisions (2026-07-09 — THE MOUSE; wish AMENDMENT 8 "the tasks TUI goes mouse-friendly at Claude-Code-TUI quality")

All claims below verified against the tree 2026-07-09 (bubbletea v1.3.10 source read from the
module cache; taskboard line refs current at cut time).

89. **The mouse is a PEER of the keyboard, never a second interaction model.** Every mouse gesture
    resolves to an EXISTING reducer verb: wheel = the existing 1-line motion, click = cursor
    movement, second click = enter, verb clicks = c/x/o. Mouse reporting is ON by default via
    `tea.WithMouseAllMotion()` — NOT cell-motion: in v1.3.10 cell-motion reports motion only while
    a button is held (screen.go:55-63), so hover REQUIRES all-motion (screen.go:70-86). A terminal
    without mouse reporting sees a byte-identical board: no mouse event → no model change → all
    existing goldens frozen. Wheel arrives one MouseMsg per notch (Button=WheelUp/WheelDown,
    Action=Press, no release) — map each notch to ±1.

90. **The hit map: ONE producer, one parallel slice — never coordinate math in Update.**
    `flattenSpine` (render.go:437, the sole consumer of `spineRows`) gains a parallel
    `[]LineTarget` (`{Kind, CursorIndex}`; kinds: spine-row / scroll-up / scroll-down / chrome /
    none) recorded PER-EMIT inside the same emit/markSel closures — per-emit, not per-row, because
    `TaskRow` returns `[]string` via a range loop (render.go:463-465) and is multi-line-ready even
    though every branch is 1 line today. `Render`'s signature stays FROZEN; the seam is a pure
    sibling `HitMapFor(b, st, width, height, now) []LineTarget` mirroring `SpineTopFor` exactly
    (same avail math, same slideTop, same windowSpine clip; the `↑/↓ N more` overwrite lines become
    scroll-affordance targets, never stale cursor stops). Compose's origin offsets (leading blank
    line, left gutter gl, breadcrumb row, wide panes) are applied ONCE in a compose-level hit-map
    wrapper. **bubblezone considered and REJECTED**: it injects/strips zero-width markers in the
    view string — a second coordinate producer that fights D42 (spineRows is the ONE producer) and
    byte-stable goldens.

91. **Hit-map parity is golden-tested with the multi-line-safe invariant.** Assert:
    (a) `len(hitmap) == len(painted frame lines)`; (b) every visibleRows cursor index appears on
    ≥1 CONTIGUOUS painted lines (NOT "exactly once" — that breaks the day a row wraps);
    (c) the line(s) tagged index i are exactly the ▎-marked line(s) (SelectionMarker, U+258E);
    (d) non-selectables (separators, phase bands, dead-epic lines, ↑/↓ affordances, chrome) carry
    non-cursor kinds. Mirror `TestCursorParityShellRender`'s exhaustive per-index walk.

92. **Wheel semantics per region.** Board: wheel = `moveCursor(±1)` — j/k parity. (A scroll-only
    wheel is impossible: Update force-syncs `SpineScroll = SpineTopFor(...)` after every message
    (program.go:279), so a bumped scroll snaps back the same tick; the cursor step IS the #1878
    1-line motion.) Reading frames (FrameTask/FramePaper): wheel = `freeScroll(±1)` — prose pans,
    cursor stays put, and the next j/k minimal-slides back per D18, automatically.

93. **Click semantics.** Click a selectable row = select (move ▎, reuse the moveCursor/clamp
    path); click the already-selected row = activate (exactly `enter`: descend on a task row,
    fold/unfold on a section header); double-click = two presses = the same thing, for free.
    Reading rails: click a stop = select it; click the selected stop = `descend()`. Clicks are
    "non-x input": they clear the action strip and disarm `pendingClose` — EXCEPT a click on the
    close affordance, which drives `closeTask` verbatim (two clicks = the existing two-step
    confirm; the pendingClose machine at program.go:575-588 is click-agnostic; CAS epoch logic
    untouched).

94. **Hover is the taskboard's FIRST legitimate background tint; color = state law, zero new
    colors.** New `palette` fields read EXISTING semrole chrome tokens (desk precedent:
    cmd/barkpark/styles.go:48,104): hover = `chrome-cursor-bg` (subtle), pressed =
    `chrome-selection-bg` (stronger; verb affordances only — row clicks act on press, so rows get
    hover only). The flash stays foreground-only (D17 untouched; motion_test's
    GetBackground==NoColor guards stay green) — hover is a NEW style, never a flashStyle
    extension. Rectangularity: `padTo(width)` ONLY the hovered row. The hover golden follows
    `TestFlashPaintedInFrame` (forced TrueColor profile, styled-with ≠ styled-without) but asserts
    per-line TrimRight equality instead of strict strip equality (the pad adds trailing spaces);
    the no-hover render stays byte-identical so every existing golden is frozen.

95. **Never-flickers under the motion firehose.** All-motion emits one event per cell crossed.
    The model stores the current hover target and mutates state ONLY when the resolved target
    CHANGES — same-target motion returns the model unchanged (unchanged View → renderer diff →
    zero repaint). The hover-changed guard IS the debounce; no timers, no new cadence (the 100ms
    heartbeat stays armed only while Alive()).

96. **Etiquette: the app owns only a toggle and a footnote.** Mouse reporting disables native
    click-drag text selection in EVERY terminal; the bypass is TERMINAL-owned (Option in iTerm2,
    Shift in most xterm-family terminals) and cannot be implemented app-side. The app ships:
    (a) runtime toggle `M` — `tea.DisableMouse()` / `tea.EnableMouseAllMotion()` as Cmds;
    (b) a dim footer note in the existing hint vocabulary (sheds FIRST under width pressure,
    before the verb hints). Footer verbs (`c claim · x close · o studio`) become click targets via
    per-verb X-span targets on the footer line — BOARD footer only this wave (the reading footer
    keeps omitting c/x/o; surfacing them there is a separate decision).

97. **Narrow-first; wide is a column threshold, and the depth-0 preview is inert.** The v1
    substrate covers the narrow frame completely. Wide (≥110) routing is a pure X-threshold on
    Compose's assembly (x < 46 → board pane; x ≥ 48 → right pane; the 2-col gutter is dead space)
    — its own small slice. The depth-0 right pane is a non-interactive preview (cursor=-1, no
    stops): clicks there no-op honestly. Wheel routes by X the same way. Also adopted as wave-16
    finishing work: `readingViewportHeight` (program.go:1231) is 1 larger than composeAt's real
    painted window in BOTH modes (narrow h-2 vs painted h-3; wide h-1 vs h-2 — Compose eats one
    row for the leading blank), so freeScroll under-scrolls by one line; fix + parity test ride a
    dedicated slice.

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
  [SUPERSEDED 2026-07-23 / D98]: stale — `design/check.mjs` Part B ("§6") now exists and gates the
  emitted lifecycle chain green; pdrender in-body chips (`inline.go taskStatusGlyph`) remain the
  one ungated residue — D43.
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
  [SUPERSEDED 2026-07-23 / D98]: a live cross-file gate now exists — `design/check.mjs` Part B
  ("§6") gates the emitted lifecycle chain (green). Only pdrender's in-body chips
  (`inline.go taskStatusGlyph`) stay outside it — that residue is D43.
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

### Wave 12 2026-07-06 (SHIPPED + integration-probed — the activity band evolved: WHO + INTENT, D58–D63)

Final branch `loop-epic/tui12-activity-band-p` (2008054b) probed clean onto `origin/main` (184f15cb) in
a throwaway worktree — fast-forward-clean merge, no conflicts. **Gates:** `internal/taskboard` full suite
GREEN including `-race` (4.4s); `go vet` clean; `TestGoldenGlyphBudget` + the `↩` allowlist entry pass;
`docs-anchors-check` PASS (12 pre-existing warnings) and `check-doc-budgets` PASS (card count exactly 7).
The 8 new wave-12 guards all pass: `TestNowCardIsAgentFirst`/`TestNowAgentRowForDormantEpicClaim` (WHO
grammar), `TestNextResumableFirst`/`TestNextReadyHeadP0First`/`TestNextResumeClaimBypassesGate` (INTENT +
server-arbitrated resumable claim), `TestNextCursorParity` + the perfecter's `TestPinnedRowParityUnderHeightPressure`
(the cursor-parity fix at heights 13–16), `TestActivityBandCollapsesWhenIdle` + `TestRenderEmptyBoardIsHonest`.
The 4 `-race` cgo build failures (cli/hetzner/cmd) are a **pre-existing environment toolchain issue** (clang
rejects `-E`; reproduces on the untouched base, `CGO_ENABLED=0` builds clean) — wave 12 touches only
`internal/taskboard`.

**REQUIRED live read-only dump at 56 & 72 (via `-tags liveprobe`, guerrilla, never mutating):** 321 tasks,
9 epics, 82 ready. The band read HONESTLY: `now=0` in flight at this moment (the 177 "live-claims" are DONE
tasks retaining a worker — correctly excluded by the NOW in_progress guard), so the WHO band collapsed to
nothing and INTENT took over — `NEXT` showed the P0-first ready head (User-principal seam · Cloud console ·
Sheets-parity, all P0) with the honest `+79 ready` tail, dim subordinate label, NO `READY TO CLAIM` wall.
Every line width-safe at 56/72. **The one honest gap:** because the live queue had zero in_progress claims
and no fresh resumable in the 100-event window at probe time, the WHO agent-rows and the `↩ resume` path
were NOT exercised against live data this run — they are covered only by fixtures/goldens (which do carry
claims + a lease_expired resumable). The band is thus proven truthful and non-decorative (it manufactures
nothing when there is no activity), but a WHO-live-verification with a real in_progress claim remains a
fixture-only assurance until the next agent wave populates the queue.

**Verdict: SHIP.** The band delivers the wish ("show all activity going on with the agents") as far as truth
allows: WHO when agents are live, INTENT (capped, honest) when they are not — one eye-catch, decisively not
a rebirth of the killed READY wall. The perfecter's cursor-parity fix is real, guarded, and in the merge.

**Next wave inherits (unchanged + one added):** the RESERVED pdrender/walker glyph-unify slice (D43), the
TUI docs slice, real blocker-ref rendering, the §5/§6 hygiene arm — PLUS the richer-intent enrichments the
task system could carry but doesn't yet surface: a resumable's `previous_worker` on its NEXT row (noted
reserved), assignee-planned (claimed-but-not-started) tasks as a distinct WHO-adjacent signal, and
"deps about to unblock" (a blocked task whose blocker just closed) — all server-data-permitting follow-ups,
not board bugs.

### Wave 13 2026-07-06 (CUT: the DISPATCH FRONTIER — D67–D74; design + charter, NOT yet built)

**The wish:** "figure out how many tasks we can take on at once … base next on all the different spots
not impacting each other … 50 agents when they don't impact each other … careful but ambitious." Deepens
D65/D66's "one pick per root" into a real `area:`-aware interference model + a dispatch verb.

**Verified READ-ONLY against guerrilla 2026-07-06 (332 tasks; NEVER mutated):**
- Coverage: parent/root 84% (0 dangling), `proj:` 93% of open, `phase:` 81%, `design_doc` 26%,
  **`area:` only 3% (THE GAP — only cloud-console)**. `proj:` ≈ `design_doc` ≈ root (all "same epic,"
  none "same surface"); `proj:loop` is the ONE cross-root merge (schema-safety + security-hardening).
- **Dep-edge TARGETS ARE readable via the EXISTING `GET /v1/graph/:id`** (edges `{kind:blocks/parent/
  design_doc, from_id, to_id}` + nodes to resolve uuid→doc_id, per component). Every `blocks` edge in
  the corpus is WITHIN a root tree → slice 1 does NOT need it (ready-gate + neighborhood covers it);
  `graph.show` is a slice-2 precision enrichment. No server change in scope.
- **Worked frontier (live):** 58 leaf-ready → **15 independent neighborhoods** (honest capacity ~15,
  NOT 50 — the tool must say 15). `proj:design-system` (aesthetic-unification, 24 children, all
  surfaces) is the mega blast radius that goes SOLO once `~area:` derives from its phase bands.

**The model:** blast-radius key = code surface (`area:`), with proj/root as the conservative proxy when
area is absent; `interferes` = HARD (blocks-edge | same-neighborhood-when-area-absent | area-overlap),
NONE (both-area & disjoint — the intra-epic-parallel unlock, the road to 50), UNKNOWN (strangers →
independent+`unproven`, with a `--proven-only` careful dial). Correctness invariant: never call two tasks
sharing a HARD signal independent. `Frontier` = greedy MWIS, D65-scored, per-pick reason + blast-radius
listing + risk class (isolated/neighborhood/unproven/shared-surface-solo). One Go fn, two surfaces
(`bp task frontier` verb + TUI `IndependentReady`), no drift.

**Design:** `/Users/pelle/.claude/jobs/c06ba8c5/tmp/dispatch-frontier-design.md` (interference model +
`area:` convention + algorithm + worked live examples + surfaces + slice plan + paper outline + the §5
task tree written out for the Publisher to transcribe). Paper to publish: `dispatch-frontier`.

**SLICE 1 is buildable NOW** (no server work, no missing data): pure `frontier.go` over the
already-fetched snapshot (reuse resolveNext's scorer + rootOfBare) + `bp task frontier` builtin +
`IndependentReady = len(Frontier(...))`; table-driven interference truth + a livecorpus assertion. All
existing guards stay green unweakened (cursor-parity structural; NEXT/glyph-budget/semrole untouched —
adds a function + a verb, not board vocabulary).

**DIRECTION — slice-1 VERIFIED + integration-probed 2026-07-06 (branch `feat/dispatch-frontier-v1` @ e0680fd8, NOT merged):**
- *Artifacts (read-only vs guerrilla):* paper `dispatch-frontier` renders HTTP 200; task tree is §5-clean
  — goal `dispatch-frontier-goal` (P1, no parent) `child_count=8` with all 8 children listed; every child
  `parent_id=dispatch-frontier-goal`, `design_doc=dispatch-frontier` (under `content.*`), verb-first title,
  why/approach/out-of-scope description (374–646 chars), 2–6 acceptance criteria `{criterion,evidence:"",met:false}`,
  priority ladder P1(goal)/P1·P1·P1(slice-1)/P2·P2·P2(convention)/P3(graph)/P4(reserved). ALL 9 published+open,
  **ZERO draft dups** (scanned 343 tasks — no `drafts.df-*`/`drafts.dispatch-*`). Nothing mutated.
- *Integration probe:* clean merge onto `origin/main` (`f30556a5` already in origin/main → only frontier files,
  no `bake-server-image.sh` noise). Gates GREEN: `CGO_ENABLED=0 go build ./...` ✓ · `go vet ./internal/{taskboard,cli}/...` ✓ ·
  `CC=/usr/bin/clang go test ./internal/taskboard/... ./internal/cli/...` ✓ · `go test -race ./internal/taskboard/...` ✓.
- *Live verb (read-only):* `bp task frontier` → 22 independent · 3 proven · 19 unproven. Table renders the full spec
  (glyph·id·title·score·P·reason·[risk]·area + footer + indented ↳ displaced lines); `-o json` full Pick array;
  `--max N` truncates; `--proven-only` collapses to the 3-pick safe floor (all `proven:true`, all `risk:isolated`).
- *Honesty confirmed:* the model dogfoods — the 3 proven picks ARE the area-labelled dispatch tasks
  (df-cli-frontier-verb/cli, df-frontier-fn/tui, df-area-vocabulary/docs). The documented FALSE-INDEPENDENT #1 is
  LIVE and honest: T1 `df-frontier-fn`(area:tui) and T3 `df-cli-frontier-verb`(area:cli) BOTH admit despite T3's
  "Deps: T1" — precisely the cross-neighborhood dep-edge lie that slice-2 `graph.show` closes. Flagged, not hidden.
- *Nits (non-blocking):* (1) JSON top-level `independent` stays 22 under `--proven-only` while `picks` is 3 — a
  scripter reading `.independent` gets the full-frontier count, not the returned set; trust `len(.picks)`. (2) piped
  (non-TTY) default emits JSON not table — conventional but undocumented. Neither is a model-correctness defect.

### Wave 14 2026-07-06 (CUT: the CMUX BRIDGE — D75–D81; design + charter, NOT yet built)

**The wish:** a cmux pane that IS a Barkpark worker — claim the task it owns on session-start, renew the
lease while the agent works, close on proven acceptance (else lease-expire into the built `↩ resume`), and
`bp cmux dispatch` spawns the wave-13 dispatch frontier into fresh agent panes ("send out N agents when they
don't collide" in one keystroke). Deepens D67–D74 from "compute the honest capacity" to "act on it."

**Verified/re-confirmed against the tree 2026-07-06 (read-only; nothing mutated):** `ResolveWorker` honors
`BARKPARK_WORKER_ID` else `tui-<hostname>` (actions.go:203); `TaskClaimN`/`TaskCloseN` are the ONLY mutation
seams — **no heartbeat endpoint exists**, so liveness = re-claim-to-renew + 300s TTL + `task.lease_expired`
(client.go:892/923); `Get("task",id)` returns `(Doc,false)` on ANY read error — the ideal fail-safe for the
acceptance gate (client.go:670); `Frontier`/`FetchSnapshotFull`/`Board.IndependentReady` are the shared
wave-13 model to IMPORT (dispatch never reimplements interference); the `task frontier` intercept at
cli.go:146 is the exact mirror pattern; **zero `CMUX_`/`CLAUDE_CODE_SESSION_ID` references exist in the Go
tree — greenfield.** Feasibility findings (protected `CMUX_*` env, the `claude` hook shim firing
`cmux claude-hook <event>`, surface≠session) taken from the wave-14 feasibility research.

**The design — the cardinal invariant is fail-safe.** A hook NEVER breaks the agent: every `bp cmux hook`
path exits 0 (incl a top-level recover), writes NOTHING to stdout, bounded ~4s network, `--dry-run` mutates
nothing; a missed action costs at most an honest resume (the lease TTL is the backstop). The close default is
**acceptance-gated, never turn-boundary** — Stop fires every turn, so close only when ≥1 criterion exists and
ALL are met; else leave for resume. Worker id is **surface-keyed** (`cmux-<CMUX_SURFACE_ID>`) so all subagents
in a pane renew the pane's ONE claim. Dispatch reads the SHARED `taskboard.Frontier` and is dry-run-first
(default when cmux is absent from PATH). Install is print-first (never clobber `~/.claude/settings.json`).

**Design:** `/Users/pelle/.claude/jobs/c06ba8c5/tmp/cmux-bridge-design.md` (worker-id derivation + hook-event
→ bp-action table + acceptance-gated-close honesty + fail-safe rules + dispatch dry-run behavior + install
block + slice plan + paper outline + the §5 `cb-*` task tree written out for the Publisher to transcribe).
Paper to publish: `cmux-bridge`.

**SLICE 1 is buildable NOW** (no server change): `CmuxWorkerID` (cb-worker-id) + `bp cmux hook`
(cb-hook-entrypoint + cb-hook-failsafe) + `bp cmux status` (cb-status-verb) + `bp cmux install --print`
(cb-install-print). SLICE 2 (needs wave-13 `df-frontier-fn` merged): `bp cmux dispatch` (cb-dispatch-verb).
SLICE 3: `bp cmux install --merge` (cb-install-merge) + docs (cb-docs-card). SLICE 4 (RESERVED): claim-before-
spawn dispatch (cb-next-frontier-claim). All existing guards stay green UNWEAKENED — the bridge adds functions
+ a noun, not board vocabulary. Publisher: file the `cmux-bridge-goal` tree (§11 of the design), publish the
`cmux-bridge` paper, link the goal into the dispatch-frontier family (it consumes `Frontier`).

### Wave 14 2026-07-06b (SHIPPED + PUBLISHED + integration-probed — the CMUX bridge, slices 1+2 built)

Publisher + Builder + Direction all landed; direction ran a real merge-onto-`origin/main` integration probe.

**Published (guerrilla, read-only-verified by direction):** paper `cmux-bridge` ("CMUX × Barkpark — a pane
that IS a worker") renders HTTP 200 at `/papers/cmux-bridge` with all 7 sections (wish / what cmux gives us /
worker-id derivation / hook contract / dispatch / install / honest limits). Task tree = 10 docs, ALL
`_draft=false`, **zero draft duplicates**: goal `cmux-bridge-goal` (P1) triple-linked into the frontier family
(`parent_id=dispatch-frontier-goal` + label `proj:dispatch-frontier` + `design_doc=cmux-bridge`); 9 children
each `design_doc=cmux-bridge`, correct parents/priorities, criteria shape `{criterion,met:false,evidence}` with
counts matching the design EXACTLY (worker-id 3, hook-entrypoint 5, hook-failsafe 3, status 4, install-print 3,
dispatch 5, install-merge 4, docs 3, next-frontier-claim 2). Note: the `/v1/tasks` list projection strips
`design_doc`/`acceptance_criteria` — verify those via a `drafts`-perspective `/v1/data/query` read, not the list.

**Built** on `feat/bp-cmux-bridge-v1` (1 commit `c34774d5`, +1691 lines, client-side only — `cloud/`/`api`
untouched): `internal/taskboard/cmux.go` (`CmuxWorkerID` four-tier), `internal/cli/cmux_hook.go` (the fail-safe
adapter), `cmux_dispatch.go`, `cmux_install.go`, `cmux_cmd.go` (`runCmux` + `status`), the `case "cmux"`
intercept in `cli.go`, and a behavior-preserving `apiclient.Get`→`GetPerspective` refactor so the acceptance
gate reads the drafts overlay. **KEY BUILD CORRECTION:** the real cmux spawn primitive is
`cmux new-workspace --name --cwd --command` (env inline in `--command`), NOT the design's feasibility-research
`new-surface --type agent-session --env --prompt` (which does not exist) — adjusted in ONE place.

**Integration probe (direction, throwaway worktree merged onto `origin/main` 448dced9):** merge is CLEAN (no
conflicts, branch had diverged from an older base). Full gate GREEN on the merged tree — `CGO_ENABLED=0 go
build ./...`, `CC=clang go vet` (cmux/taskboard/apiclient), `CC=clang go test` (all ok incl the `cli` package
5.2s), `go test -race ./internal/taskboard/...` ok, gofmt clean. Live read-only runs against guerrilla:
`bp cmux install --print` emits the exact hooks block + guarded shell line (never writes settings.json);
`bp cmux dispatch --dry-run` printed one `cmux new-workspace` per pick for 22 live frontier picks (exit 0, no
spawn, no mutation); dispatch WITHOUT `--dry-run` while cmux is absent from PATH auto-degraded ("dry-run (cmux
not on PATH)") and spawned nothing; `bp cmux status` live-proved `CmuxWorkerID` tier-2 (derived
`cmux-<CMUX_SURFACE_ID>` from THIS pane's real surface env). **Fail-safe matrix confirmed** — missing task,
unknown task, unknown event, malformed stdin, and unreachable server ALL exit 0 with empty stdout; grep proved
no `os.Exit` and no stdout write on the hook path, a top-level `recover()` at cmux_hook.go:75, a 4s network
timeout, and dispatch importing the SHARED `taskboard.Frontier` + `.Start()` (never `Wait`). The adapter is
fail-safe: a hook cannot break the agent.

**Merge steps for the lead** (from repo root, main stays on main): `git fetch origin main` →
`git worktree add --detach <tmp> origin/main` → `git -C <tmp> merge --no-ff feat/bp-cmux-bridge-v1` (clean) →
gate as above → open the PR from `feat/bp-cmux-bridge-v1`. NOT pushed by direction (probe only).

**Remaining after merge:** slice-3 `cb-install-merge` + `cb-docs-card` (docs card must fold into the existing
CLI card — 7-card cap — and anchor the `case "cmux"` intercept for docs-anchors-check); slice-4 reserved
`cb-next-frontier-claim` (claim-before-spawn, wants the orchestrator loop). Honest limits carried from design:
dispatch quality is bounded by `area:` label coverage (~unset today — every probe pick showed `area: unset`
except the cb-* tasks); the SessionStart-claim race (two dispatchers / a human already on the task) is the
reserved atomic-claim-first fix; `drainHookStdin` has no wall-clock deadline (matches cmux's own contract —
Claude closes stdin — judged not worth over-engineering for v1).

### Wave 15 2026-07-07 (SHIPPED + live-eyeballed — INVERT THE PANE; wish AMENDMENT 6, D83–D88)

**The flip.** The scrolling task list is now the TOP region (fills from under the identity line); the pinned
band (NEXT above NOW) + momentum line + progress bar + truncation note descend to the BOTTOM as fixed status
chrome, directly above the ticker + footer. The identity line (`barkpark · tasks · ⇄ guerrilla ● live`) STAYS
pinned at the very top (D85 — orientation, not activity). Vertical order top→bottom:
`[identity] [LIST — scrolls] [NEXT] [NOW] [momentum + progress] [ticker] [footer]`. Waves 8–14 behavior
(focus windows, finished-shelf decay, curated NEXT, cmux workers in NOW, the Compose gutter) is untouched —
only vertical placement + cursor order inverted.

**The crux — cursor index space flips in lockstep (D86).** One base `S = selectableSpineCount(b, st)` computed
once in `Render` from the ONE `spineRows` producer: spine owns `[0, S)`, NEXT owns `[S, S+lenNext)`, NOW owns
`[S+lenNext, …)`. `render.go`: `Render` reassembled top→bottom with the band budgeted off the bottom
(D87, `minSpine=4`); `renderHeader` split into `renderIdentityTop` + `renderStatusFooter`; `renderNowBand` /
`renderNextBand` take a `base` param and offset every cursor comparison; `flattenSpine` selIdx re-based to 0;
new `selectableSpineCount`. `program.go`: `visibleRows` emits the spine selectable subset FIRST, then NEXT, then
NOW — so the shell and renderer read the same producer + same S and cursor-parity is STRUCTURAL.

**Gates GREEN (host, CC=/usr/bin/clang).** `CGO_ENABLED=0 go build ./...`, `go vet ./internal/taskboard/...`,
`go test ./internal/taskboard/... ./internal/cli/... -count=1`, `go test -race ./internal/taskboard/...` — all
ok; gofmt clean. Cursor-parity guards kept their exhaustive per-index ▎ walk, RE-BASED to the tail
(`TestNextCursorParity`, `TestPinnedRowParityUnderHeightPressure` sweeping h=13..30 at ci=S+k, `TestCursorParity*`);
`TestVisibleRowsOrderAndKinds`/`WithClusters` hard-index expectations updated to spine→NEXT→NOW; a new
`TestInvertedIndexOrder` pins the order explicitly; `livecorpus_test` finds the momentum line by its "in flight"
marker (no longer line index 1). Glyph-budget + semrole parity green — the flip added NO vocabulary.

**Goldens regenerated deliberately + eyeballed.** Every board frame + `compose_wide_120` + livecorpus +
motion/still/firstpaint golden inverts (18 testdata files). Reading-frame goldens (`compose_task_*`, `detail_*`,
`paper_*`) stayed BYTE-IDENTICAL — confirming the inversion never leaked into a reader. A second `-update` pass
produced zero further diff (deterministic).

**Live read-only eyeball vs guerrilla (56 + 72).** Fetched the real corpus and rendered the inverted frame
headless. Line 1 = identity strip; the list scrolls at the top (epics recency-ranked, phase bands, `↓ 62 more
below` overflow); at the bottom NEXT (`NEXT · 28 independent`, resumables, `+97 ready` tail) sits ABOVE NOW
(live claim), then momentum (`⠿ 1 in flight · ○ 100+ ready · ✓ 243 done  68%`) + progress bar + ticker + footer.
Cursor walk proven on live data at 72: ci=0 → top list row, ci=S-1=72 → last spine row, ci=S=73 → first NEXT
row, ci=75 → third NEXT row — the ▎ flows top→bottom through the list and continues into the band. NEVER mutated
a live task.

**Next wave.** Charter §6 hygiene + human polish + the D43 pdrender glyph-unify remain (unchanged by this wave —
placement-only). Nothing new opened.

### Wave 16 2026-07-09 (CUT: THE MOUSE — wish AMENDMENT 8; D89–D97; hit-map substrate + wheel + click + hover + verbs)

**The wish.** `bp tasks` goes mouse-friendly at Claude-Code-TUI quality: wheel scrolls exactly like
the 1-line keyboard scroll (#1878, never a recenter jump), click a full-width row to select, click
again to descend, hover tints with existing theme tokens, footer verbs clickable (close keeps its
two-step confirm as two clicks), honest degrade (no mouse reporting → byte-identical board), and
mouse-mode etiquette (terminal-owned text-selection bypass named in a dim footnote + runtime `M`
toggle). Decisions D89–D97 above; laws untouched: spineRows stays the ONE producer (D42), flash
stays fg-only (D17), never-flickers, detail-ceiling, alignment=rectangularity.

**Ledger.** task-tui-goal stays lifecycle done (the glanceable/live/never-flickers goal shipped —
never flip it back). Children-of-done IS accepted by the ledger (taskboard-thread-chrome-tokens
precedent, 2026-07-08), but this wave groups under ONE published wave-goal task **task-tui-mouse**
(parent_id=task-tui-goal) with the five slices as its children — keeps the epic tree readable and
gives the wave a single closable spine.

**The wave (integration order; gates per slice: `CC=/usr/bin/clang go build ./... && go vet
./internal/taskboard/... && go test ./internal/taskboard/...`):**

1. **ttm-s1-hitmap-soul** (large) — LineTarget hit map from flattenSpine's emit closure +
   `HitMapFor` pure sibling + compose-level origin wrapper; `tea.WithMouseAllMotion()`;
   `case tea.MouseMsg` in reduce: wheel (board = moveCursor ±1, reading = freeScroll ±1),
   click-select / click-descend on board rows + reading rail stops; ↑/↓ more lines = scroll
   targets; fix stale spine.go:17 comment. Parity tests per D91; existing goldens byte-frozen.
2. **ttm-s2-reading-viewport-clamp** (small, independent) — fix readingViewportHeight off-by-one
   (narrow h-3, wide h-2) + a parity test pinning it to composeAt's painted window.
3. **ttm-s3-hover-tint** (medium, atop S1) — palette hoverBg/pressedBg from chrome-cursor-bg /
   chrome-selection-bg; hover-target state with change-only mutation (D95); padTo only the hovered
   row; TrueColor hover golden per D94.
4. **ttm-s4-click-verbs-etiquette** (medium, atop S1) — footer verb X-span targets (c/x/o, board
   footer), close = two clicks through pendingClose; `M` mouse toggle; dim selection-etiquette
   footnote that sheds first; footer golden updates.
5. **ttm-s5-wide-pane-routing** (small, atop S1) — ≥110-col X-threshold routing (board pane /
   gutter / right pane), depth-0 preview inert, crumb-row offset for right-pane reading frames.

Concurrent-cycle note: unified-aesthetic w2 also touches theme.go's palette/buildPalette — S3
rebases before PR and keeps token edits to one field + one builder line each (chrome_gen.go is
generated, never hand-edited).

### Wave 16 2026-07-10 (REVIEWED: the mouse wave — all five slices green + review-fixed; integration is the lead's real work)

**What landed (all gates green — `CC=/usr/bin/clang go build ./... && go vet ./internal/taskboard/... && go test ./internal/taskboard/...` — on every final branch):**

- **ttm-s1 hit-map soul** (`…mousea-0-r`): `hitmap.go` LineTarget{Kind,CursorIndex} over spine-row/scroll-up/scroll-down/chrome/none; `HitMapFor` mirrors Render's avail/slideTop/windowSpine line-for-line; `ComposeHitMap` applies every origin offset ONCE (leading blank + breadcrumb/footer); `flattenSpine` records targets PER-EMIT inside its own closures — the hit map is the SECOND consumer of the one spine producer (D42), bubblezone rejected. Wheel = `moveCursor(±1)` (board, rides #1878) / `freeScroll(±1)` (reading); left press = select-then-activate (task descends, header folds, rail descends); scroll-affordance click = one wheel step. `tea.WithMouseAllMotion()` wired. `TestHitMapBoardParity` walks EVERY cursor index against the real painted `View()` — the D91 tripwire is structural. Zero goldens changed.
- **ttm-s2 reading-viewport clamp** (original branch, no fixes needed): `readingViewportHeight` now mirrors Compose→composeAt's height chain exactly (floor 8, −1 blank row, re-floor 8, then −2 narrow / −1 wide); freeScroll reaches the last body line, no stuck ↓-more. Parity proven against the REAL paint across h=8..30 both modes; both tests fail on the pre-fix helper.
- **ttm-s3 hover tint** (`…backgro-2-r`): first background paint — `hoverBg`/`pressedBg` read from EXISTING chrome roles (chrome-cursor-bg / chrome-selection-bg, zero new colors); `hoverPaint` squares the ONE hovered row with padTo then re-arms the bg across the row's embedded `\x1b[0m` resets; `setHoverTarget`'s changed-guard IS the debounce (no timers); any key clears the tint; selectable rows only. No-hover frames byte-identical; flash stays foreground-only (D17). NOTE: inert at runtime until wired into the merged mouse reducer (built parallel to s1 by design).
- **ttm-s4 clickable footer verbs + etiquette** (original branch, no fixes needed): `buildBoardFooter` emits per-verb X-spans tracking the shed/truncate ladder (etiquette footnote sheds FIRST, then "move", then truncate; a clipped verb loses its span); verb click == key press through `handleBoardKey` — close stays the two-step pendingClose machine as two clicks with the observed CAS epoch; `M` toggles `tea.DisableMouse`/`EnableMouseAllMotion` with `UIState.MouseReleased`; footnote copy "opt/shift-click selects · M mouse" / "mouse off · M on" (terminal-owned bypass, never claims app passthrough). 3 footer goldens regenerated (100-col lines only; the footnote sheds at ≤80). Self-contained `footerVerbAt` re-derives footer geometry — NOT layered on s1's hit map (s1 was absent in its worktree).
- **ttm-s5 wide two-pane routing** (`…threshold--4-r`): `handleWideMouse` routes by pure X/Y over the SAME geometry composeAt paints — x<46 board / dead 2-col gutter / x≥48 right (crumb +1 Y once); depth-0 preview fully inert; depth>0 rail-stop click via the extracted `readingWindowTop` (paint and hit-test share one offset, byte-neutral — `compose_wide_120` untouched); wheel = cursor step (board) / freeScroll (reading). NOT reachable until the lead wires it into the merged reducer.

**Reviewer fixes (on the `-r` branches):** s1 `composeInner` now delegates to `boardGeometry` (killed a third verbatim copy of the gutter math) and **ignores mouse Release** — a paired release must never disarm a press-armed two-step (would have broken s4's two-click close at integration); s3 un-spliced `handleKey`'s doc comment from `setHoverTarget`; s5 `wideGeom` gains composeAt's height re-floor and `boardPaneMouse` mirrors Render's internal 8-floor (≤8-row wide terminals were off by one), and click-again now ACTIVATES (board) / DESCENDS (rail) — the slice's own "identical semantics to narrow" instruction, matching s1's grammar and the wish's "click again to expand".

**Charter debt: D89–D96 exist only in the wave-16 task briefs, not in this file.** For the record: D89 = one compose-level offset seam (`ComposeHitMap`), D91 = hit-map⇄paint parity tripwire, D92/D42-ext = hit map as second consumer of the ONE spine producer, D93 = honest degrade (no mouse reporting → keyboard untouched), D94/D95 = hover/pressed backgrounds from existing chrome tokens + changed-guard debounce (never-flickers), D96 = clickable footer verbs + M toggle + selection-etiquette footnote. The next strategist should backfill a proper decision block.

**Integration map (the lead's real work — the five branches deliberately collide in program.go):**
1. Suggested order: s2 (disjoint fix) → s1 (the soul) → s3 → s4 → s5, gating after each.
2. s1 and s4 BOTH define `handleMouse`, the `tea.MouseMsg` case, and `WithMouseAllMotion` in program.go — merge into ONE reducer: `MouseReleased` guard first (s4), then Motion → row hover via `setHoverTarget` (s3, resolve through s1's ComposeHitMap) + footer-verb hover (s4), then Release → ignore (s1-r), then left press → `footerVerbAt` FIRST (s4; the footer is chrome in s1's map, so order matters), else ComposeHitMap dispatch (s1); wide → `handleWideMouse` (s5) replacing s1's wide no-op.
3. s1's flattenSpine returns 3 values; s3 (hover paint in flattenSpine) and s5 (`boardLineOwners`, 2-value call) collide — rebase s3's `paint()` into s1's emit closures; prefer s1's per-emit targets over s5's one-line-per-row `boardLineOwners` where convenient (s5's helper is correct today but multi-line-unsafe by construction).
4. s3+s4 both append to theme.go's style var block and types.go's UIState (HoverTarget vs MouseReleased/HoverFooterVerb — distinct fields, both stay); s4's `renderFooter(st, width)` signature + 3 regenerated goldens must survive the merge.
5. After integration: `MouseReleased` must also gate s1's row clicks + s3's row hover (not just footer verbs), and wide mode should stop being hover-dead if cheap (s3 painted flattenSpine, which wide's left pane shares — verify).
6. s5's builder stamped evidence via doc patch under the active claim — the lead's `bp task close` may 409 `doc_changed_since_claim`; standard same-worker re-claim self-heal.

**Honest gaps:** nobody has driven a real terminal — every behavior is proven by constructed `tea.MouseMsg` at computed coordinates; the etiquette footnote is invisible below ~96 inner cols (sheds by design — most portrait panes never see it); reading-frame rail stops have no hover tint (needs the merged reducer + threading HoverTarget into the frame renderers); wide-mode footer verbs expose no click targets (honest, documented).

**Next wave:** (1) the INTEGRATION slice above — one merged mouse reducer, full-suite + goldens + a LIVE tmux mouse drive against guerrilla (wheel, click-select, double-click descend, verb clicks, M toggle, shift-click selection) — the wish's "feels native" bar can only be judged in a real terminal; (2) hover for reading-frame rails + wide panes once the reducer is one; (3) charter backfill of D89–D96; (4) the D43 pdrender glyph-unify and §6 hygiene still stand from wave 15.

### Wave 17 2026-07-23 (DECIDE: post-wave-16 reconciliation + reconcile-then-finish; Arm E config E6; D98–D103)

Run as research-program **Arm E (E6)** — Fable architect × Fable grade × freshness-gated lean
survey (paper `task-tui-wave-2026-07-23`; parent research epic task-09f4775e7ccc2cca). The wish's
asserted backlog was partially stale; this entry makes the wave-log true again, then the wave
finishes what is genuinely open. Verification basis: 5-Sonnet lean survey + 6 deep verifiers with
run-proofs (see the wave paper).

**D98 — Post-wave-16 reconciliation (the wave-16 entry above is now READ THROUGH THIS NOTE).**
Four merges reshaped the mouse-era board after wave 16 closed and were never recorded here:

- **#3908 (f315c80e2, 2026-07-17): hover TRANSFORMS from background paint to accent-FOREGROUND
  grammar.** D94/D95's "hoverBg/pressedBg from existing chrome tokens, padTo the row" background-
  tint law is RETIRED, not extended: the hovered row re-renders whole in bold chrome-accent
  foreground (chat Phases-pane grammar), zero background; `faintStyle`/`faintPaint`/`hoverBg` are
  gone. The never-flickers changed-only guard (D95) survives unchanged. `render.go` only; ledger
  task task-5baf1fe7daa9e0ae (done, was orphaned — re-parented under task-tui-goal this wave).
- **#4240 (755c9d4cd, 2026-07-19): D97's "depth-0 right pane is a non-interactive preview" is
  RETIRED.** The right pane now scrolls (`previewScroll`), click-ENTERS the previewed task,
  and live-previews the hovered board row; `enterTask` is single-open descent; `openTaskRefs`
  caps the checked radio to the one deepest open task. Ledger task task-713856c53559145b (done,
  was orphaned — re-parented under task-tui-goal this wave).
- **#2397 (91531b27b, 2026-07-11, task-737067baa53cbcfd): picker-style hover + checked radio.**
  Found only by this wave's uncapped git sweep — merged the day after wave 16 closed. Its HOVER
  half was retired outright by #3908; its CHECKED-RADIO half (entered task's board-row glyph
  renders ●, `OpenTasks` derived from the stack at compose time) SURVIVES in `compose.go` today.
  Recorded here so the surviving mechanism has a home; task re-parented under task-tui-goal.
- **#4393 (aeefae415, 2026-07-19): cross-epic dependency, not a task-tui decision.** Owned by
  task-lifecycle-visibility (ledger owner tlv-s2-tokens-manifest-chain) but regenerates
  internal/taskboard's `tokens_gen.go`/`board.go`/`semrole` chain directly — considering ◌ +
  researching ◎ join the 9-state LIFE_ORDER. Confirms and WIDENS the still-open D43 gap:
  `internal/pdrender/inline.go` `taskStatusGlyph` is a hardcoded 5-case switch unaware of ◌/◎.
- (minor, same window) 228808699 (2026-07-13, detail_render.go attempts/now-pulse) and #3760
  (340203ad8, 2026-07-16, context threading into the SSE listener, live.go) — small, recorded,
  no D-numbers. Out of scope by diff: #3761 (internal/cli error envelopes only), #4153 (api/lib
  Elixir `?view=brief` only — its own commit message says taskboard untouched).

**Correction, not new backfill: line 2032's "Charter debt: D89–D96 exist only in the wave-16 task
briefs, not in this file" was ALREADY FALSE when written.** Commit 4fc8bb136 (2026-07-10T00:00:39)
added the full D89–D97 numbered block (lines ~1216–1300) fifty-three minutes before b2a8a8f46
(00:53:49) wrote that debt note; task-tui-mouse's close-time description (23:17:34 the prior day)
already cites "decisions D89–D97". No backfill work remains — the wish's "D89–D96 backfill" item
was a false premise, caught pre-build.

**Ledger corrections (recorded, executed via bp this wave):** the wish's epic id
task-3be0030a7769861d is a MIS-POINTER — 28-revision history proves it was always the foreign
sealed chat-tui task wsc-ad-tui (paste error, not a ledger mutation). The epic spine is and stays
**task-tui-goal** (carries wave_status + wave_paper). task-70eb8244dd1e702a ("TUI locks strip",
foreign epic expressive-agent-loops, labels files:internal/taskboard/) is EXCLUDED from this wave,
not adopted: its PR #2457 is merged on main but the task sits open/unclaimed with the merge
criterion unstamped — stale foreign bookkeeping, named here so a concurrent claim is visible.

**D99 — Rail-stop hover is a NEW state, depth>0 only, in the post-#3908 grammar.** `HoverTarget`
(a task-Ref string) structurally cannot key a (frame, stop) rail stop — the slice adds
`HoverStop int` (-1 = none) with the same change-only debounce as `setHoverTarget` (D95). Writer:
extend `wideMouseMotion` for the right pane by FACTORING `rightPaneMouse`'s stop resolution
(compose.go:677-695) into ONE shared helper so click and hover agree line-for-line (D42
one-producer discipline). Paint: `windowFrame` gains a hover-stop parameter and paints the hovered
stop's body line via the SAME `hoverStyle` accent-foreground grammar — one hover language per
screen. SCOPING LAW: the wide depth-0 PREVIEW has NO stops (`previewLines` passes stops=nil,
cursor=-1) — there is nothing to hover-paint there; #4240 already completed depth-0 hover
behavior (left tints, right previews). Goldens stay byte-frozen (all render at rest; new field
defaults -1); every new paint test forces color via `withChrome(t)` — the default profile emits
no SGR, so an unforced hover-paint test passes vacuously.

**D100 — D43 closes Go-side as a GUARDED delegate, not a naive one and not a fourth table.**
`taskStatusGlyph` delegates to `glyphForRole(roleForStatus(status))` — the UNSTYLED accessor (the
chip is Dim-wrapped; `glyphForStatus` would double-style) — but ONLY for the known set {open,
in_progress, blocked, done, cancelled}; everything else keeps the ▸ unknown-status guard
(roleForStatus's default maps ANY unknown to "open"/○, which would silently collapse ▸ —
run-proven). Consequences, run-proven: in_progress ◐→⠋ (steady braille, inherits the STEADY_
PROGRESS exception free), done ●→✓ (teal), blocked ⊘→! (silent vocabulary shift, zero existing
coverage — reviewer told here), cancelled ✕ unchanged; exactly two taskchip_test assertion
deltas; ZERO golden diffs (no golden sets TaskResolver). The Elixir twin (`walk.ex task_glyph`,
byte-identical fork, ready delegate target `status_vocab.ex`) stays NAMED BACKLOG **for scope
discipline** — the earlier "felix PRs #5777/#5779 open" fence reason is FALSE (both MERGED,
neither touches walk.ex); the deferral survives only as scope, and the record says so.

**D101 — Help copy is sourced from SHIPPED behavior, never from the task's own stale prose.**
ttm-followup-help-copy's AC1 + purpose fields claimed "divider dragging" and "column-local
scrolling/resizing" — grep-proven NEVER-EXISTED gestures (the wide split is X-threshold routing;
the unit is a PANE, not a column). ACs and purpose scrubbed at Decide. The true gesture set help
must teach: wheel scrolls the pane under the pointer (board cursor step / reading free-scroll /
depth-0 preview scroll), click selects, click-on-selected activates (= Enter; a double-click is
two presses, for free — no separate code path), M toggles mouse capture, opt/shift-click is the
terminal-native selection bypass ("opt/shift-click selects · M mouse"). Additive help-text-only
change; zero golden coupling.

**D102 — "Spec §6" drift gate: RECORD + CLOSE, with a bounded carve-out.** The three "spec §6 is
aspirational" wave-log claims were true when written and are now superseded (annotations stamped
above): `design/check.mjs` Part B ("§6") gates the emitted lifecycle chain green (9 states ×
glyph/colour/frames across Go board + paper-surface.css + Studio `--life-*` + `tokens_gen.ex`,
plus done/closed-teal ≠ status.ok-green tripwire); Part A byte-freezes 18 emitted artifacts. NOT
covered: pdrender's hand-written in-body chips — that residue IS D43 (D100). DISTINCT §6: the
charter's "§5/§6 authoring-quality/hygiene" arm (save-gate, completeness score, `bp task lint`)
is a DIFFERENT §6 and is NOT addressed or closed by this disposition.

**D103 — The internal/cli test hang is a pre-existing pipe-buffer deadlock; fix the harness, not
the CLI.** `captureExecuteCode` (cli_test.go) redirects os.Stdout to a fresh os.Pipe() and drains
only AFTER Execute() returns; on small-pipe-buffer hosts (~512B effective) printLoginHelp's 1952-
byte help text deadlocks the writer → `go test ./...` panics at the 10m timeout in
TestExecuteBuiltinHelpHonoursGlobalHelp. Byte-identical on origin/main (9 behind, 0 ahead —
NOT wave-introduced); invisible on Linux CI (64KiB pipes). Fix = drain concurrently
(goroutine + io.Copy started before Execute). Mutation proof is built in: the isolated run fails
in ~15s before the fix, passes after.

**The wave (3 slices, all round 1, disjoint files; builders OPUS per E6; gates per slice in the
task briefs — all dry-run green at Decide):**

1. **ttw17-rail-stop-hover** (medium) — D99. internal/taskboard: types.go + compose.go +
   program.go + compose_test.go (+ detail_render.go only if the paint seam demands it).
2. **ttw17-d43-chip-delegate** (small) — D100. internal/pdrender: inline.go + taskchip_test.go
   (+ a delegate-parity tripwire test so the chip vocabulary can't silently re-fork).
3. **ttm-followup-help-copy** (small, pre-existing task, ACs corrected per D101) —
   internal/cli: tasks_board_cmd.go + tasks_board_cmd_test.go.

**D103 slice WITHDRAWN at Decide (concurrent-epic dedup, not a scope cut):** filing the pipe-
capture fix tripped the ledger's duplicate tripwire — **pdf-bl-go-test-pipe-deadlock**
(personal-dev-fleet Wave C, rider PDF-D65b) already carries the SAME fix on the SAME file
(internal/cli/cli_test.go), with criteria 0–1 already stamped met (fix built, awaiting merge).
W17 does NOT duplicate it: the D103 root-cause record above stands, the W17 slice was deleted,
and until that PR merges no W17 gate runs a bare `go test ./internal/cli` without `-run` filters
on small-pipe hosts.

**Named backlog (filed as published tasks, not faked):** the LIVE tmux mouse "feels native" drive
(cannot be proven offline); the D43 Elixir half (walk.ex → status_vocab delegate + gate coverage
for both in-body chip forks — scope-discipline deferral, fence claim corrected per D100).

Next D-number: D104.

### Wave 17 2026-07-23 (REVIEWED: all 3 slices green, zero review fixes, pushed + PRs open — Arm E config E6)

**Arm E (E6) verdict-relevant facts:** Fable architect + Fable-graded review + freshness-gated
lean survey produced 3/3 gate-green slices with ZERO reviewer fixes and zero premise failures
caught post-build (the two premise corrections — the D89–D96 backfill false premise and the
ttm-followup-help-copy divider/column false ACs — were both caught at Decide, pre-build, which is
the system working). Token/escape accounting vs E4's 2.4M is the research epic's to tally
(task-09f4775e7ccc2cca); nothing in this wave's quality signals kills the stacking claim.

**Landed (review-verified, gates re-run green, pushed):**
- **ttw17-rail-stop-hover** → PR #5837 (`loop-epic/reading-frame-rail-stops-gain-hover-pain-0`).
  D99 exactly as chartered: HoverStop int on UIState, change-only setHoverStop (D95),
  `rightPaneStopAt` factored as the ONE click+hover stop resolver (D42), windowFrame hover-stop
  paint via hoverStyle with overflow-marker skip + alias-copy. Reviewer independently
  mutation-tested the paint (disabling it reds TestWideRailHoverPaintsStop) and verified
  newModel is the sole prod UIState constructor (the -1 default is safe). Narrow-mode
  reading-frame hover = honest named residue.
- **ttw17-d43-chip-delegate** → PR #5838 (`loop-epic/pdrender-in-body-task-chip-delegates-to--1`).
  D100 guarded delegate; ▸ sentinel preserved; blocked ⊘→! silent shift named in PR body.
  NOTE for a future slice: `ready`/`closed` in-body chips still render ▸ (outside D100's 5-status
  set) — widening the delegate is a candidate once the Elixir twin lands.
- **ttm-followup-help-copy** → PR #5839 (`loop-epic/bp-tasks-help-footer-teach-the-shipped-m-2`).
  D101 mouse block, behavior-sourced, phantom-guarded (divider/resize/"drag the"), mutation-provable.

**Ledger:** all 3 tasks honestly in_progress with criteria 0–N-1 evidence-stamped mid-claim and
the merge criterion open for the LEAD; both backlog tasks published (ttw17-bl-live-tmux-drive,
ttw17-bl-d43-elixir-walkex). Zero ledger fixes needed. Grade: A (commentary in the wave paper
task-tui-wave-2026-07-23).

**Next wave (dispatch order):** (1) LEAD merges #5837/#5838/#5839 (disjoint files, any order;
Go-only gates — may merge on their own gate per repo law) and closes each task's merge criterion.
(2) ttw17-bl-live-tmux-drive — the LIVE tmux "feels native" mouse drive (wheel, click-select,
double-click descend, verb clicks, M toggle, shift-click) against guerrilla; cannot be proven
offline, do not fake it. (3) ttw17-bl-d43-elixir-walkex — walk.ex task_glyph → status_vocab
delegate + drift coverage for both in-body chip forks, closing D43 cross-surface. (4) Narrow-mode
reading-frame hover (the named residue of D99) once a narrow right-pane resolver exists.
(5) Candidate: widen the chip delegate to ready/closed alongside the Elixir twin.

### Wave 18 2026-07-23 (DECIDED: the finish pass — mouse-finish + one-status-language; Arm E config E6+E7)

**Premise-smoke verdict:** the wish's nav-shell/subtraction/reading-renderer premise was REFUTED
at Strategize (all sites git-shown built on origin/main; nav stack = program.go, subtraction +
reading renderers shipped wave 5, mouse waves 9–17). Pivoted per the wish's own instruction to
the charter's REAL open residue — W17's next-wave dispatch items 4–5. Verify round ran 4
assignments, all green, and caught three stale premises in the direction itself (D107).

**D104 — Wave 18 is two package-disjoint Go slices, wide-footer rider OUT.**
Slice 1 `ttw18-narrow-rail-hover` (internal/taskboard, medium): narrow-mode reading-frame
rail-stop hover — the named D99 residue. Slice 2 `ttw18-chip-full-manifest` (internal/pdrender,
small): widen the in-body chip delegate from 5 statuses to the full 9-status manifest. Both
offline-golden-provable, both merge on the Go gate (D21: never couple a Go wave to an Elixir
deploy). The wide-mode footer-verb click rider is HONEST-OUT: survey proved it is a second
feature (new footer-row geometry, restructuring handleWideMouse's unconditional pendingClose
clear vs narrow's verb-first ordering, a third hover branch, tests), its absence is test-locked
(TestFooterVerbAtDegradesHonestly) and was a deliberate wave-16 decision — filed as backlog
`ttw18-bl-wide-footer-verb-clicks`, never a rider on slice 1 (compose.go collision).

**D105 — Slice 1 mechanics + the one-producer hardening.** No hit-map extension exists or is
needed: ComposeHitMap/frameHitTargets already tag narrow reading-frame rail stops as
LineSpineRow with CursorIndex in exactly windowFrame's hoverStop index space (click-proven by
TestHitMapClickReadingRail; motion-parity run-proven under non-zero scroll — 9/9 stops,
hitmapY−2 == the one repainted row). The fix: (a) mouseMotion (program.go:670, Board-only today
by explicit comment) gains a reading-frame branch resolving hits[y] → setHoverStop (reused
as-is, D95 change-only debounce), mirroring wideMouseMotion's unconditional dual-set pattern;
(b) compose.go:148 swaps the hardcoded −1 for m.ui.HoverStop (mirrors wide's line 191;
run-proven golden-byte-neutral at rest — neutral-NOW because no narrow fixture sets HoverStop,
not neutral-by-construction). (c) HARDENING (ruled in): frameHitTargets must CALL
readingWindowTop instead of its inlined top-math copy — verify proved the two copies agree only
algebraically today (the one way this slice silently paints the wrong row under scroll), so make
D42 one-producer structural, plus a scrolled parity test that fails on drift. (d) Hover-paint
tests force color via `lipgloss.SetColorProfile(termenv.TrueColor)` — NOT withChrome, which only
swaps the branding fixture (a literal reading of the old phrasing writes a vacuous-green paint
test). (e) cursor==hoverStop gets its own assertion: the ▎ bar survives (stripped text
byte-identical), only the color collapses to the hover accent.

**D106 — Slice 2 stays an explicit allowlist; no script edit.** taskStatusGlyph (inline.go:239)
widens its switch from {open,in_progress,blocked,done,cancelled} to all 9 manifest statuses
(+ready ○, closed ✓, considering ◌, researching ◎), still delegating to
glyphForRole(roleForStatus(...)); it must NEVER become a passthrough — roleForStatus's default
folds unknowns to open/○ and would swallow the ▸ unknown-sentinel. The D100 tripwire
(TestTaskChipGlyphDelegatesToGatedVocabulary) widens in lockstep — mutation-proven vacuous today
for the 4 joiners and proven able to fail when widened (red: `taskStatusGlyph("ready") = "▸",
must delegate to glyphForRole(roleForStatus) = "○"`). scripts/status-manifest-check.sh needs NO
edit: it gates gridblocks.go's roleForStatus/roleGlyph, which the delegate rides. Cross-surface
parity note for the PR: Go's in_progress chip stays the static ⠋ (roleGlyph["progress"], a
documented manifest exception) vs Elixir walk.ex's ⠿ still-frame — deliberate per-surface
divergence (felix D114); parity is asserted on the 8 STATIC glyphs only.

**D107 — three stale premises in the strategic direction, corrected by verify:** (1) the Elixir
twin PR #5915 (walk.ex → StatusVocab delegate) ALREADY MERGED (ca5fac3a2, 06:03Z) — slice 2 is
present-tense parity, Go is the last diverging surface NOW; (2) "force color via withChrome" was
a misnomer (see D105d); (3) the "800k/573k/487k" tokens-per-slice curve is part-phantom: 573k
appears nowhere in the corpus, E4/E6 were meter-corrected to 62.32M/38.87M all-axis, E7's 1.95M
is not yet re-based — Review appends W18's scoreboard-t4 row with a METER.md tier-3 read or the
honest "not metered" placeholder, never the phantom triple.

**D108 — ledger hygiene executed at Decide:** PR #5840 (W17 wave log) merged FIRST (same charter
tail as this append — conflict vector removed); the 4 merge-criterion-only tasks
(ttw17-rail-stop-hover #5837, ttw17-d43-chip-delegate #5838, ttm-followup-help-copy #5839,
ttw17-bl-d43-elixir-walkex #5915) re-claimed and closed on git-proven merges. Backlog filed:
ttw18-bl-wide-footer-verb-clicks (priority 3) and ttw18-bl-go-toolchain-skew (go.mod 1.25.0 vs
local go1.26.2 — real, latent, gofmt clean today; priority 4). ttw17-bl-live-tmux-drive stays
first-in-line named backlog (cannot be proven offline; do not fake).

**Wave plan (both round 1, disjoint packages, builders=opus, gates dry-run green at Decide):**
1. **ttw18-narrow-rail-hover** (medium) — D99 close-out + D105. internal/taskboard: program.go
   (mouseMotion) + compose.go (line 148 + readingWindowTop unification in hitmap.go) +
   hitmap.go + new tests in compose_test.go/hitmap_test.go/motion tests.
   Gate: `CC=/usr/bin/clang go build ./... && go vet ./internal/taskboard/... && go test
   ./internal/taskboard/... && gofmt -l internal/taskboard` (empty).
2. **ttw18-chip-full-manifest** (small) — D43/D100 close-out + D106. internal/pdrender:
   inline.go + taskchip_test.go, strict two-file lockstep.
   Gate: `CC=/usr/bin/clang go build ./... && go vet ./internal/pdrender/... && go test
   ./internal/pdrender/... && gofmt -l internal/pdrender` (empty) + `bash
   scripts/status-manifest-check.sh` still exit 0.

Wave paper: task-tui-wave-2026-07-23b. Scoreboard row (Review's step) under
task-09f4775e7ccc2cca per D107(3).

### Wave 18 2026-07-23 (REVIEWED: both slices green, zero review fixes, pushed + PRs open — Arm E config E6+E7)

**Arm E (E6+E7) verdict-relevant facts:** second consecutive wave with ZERO reviewer fixes —
the reviewer independently re-ran three of the builders' mutation proofs (compose.go:148 → -1
reds all three narrow paint tests; a +1 top-math drift in frameHitTargets reds the scrolled
parity test with the exact predicted message; slice 2's switch-narrowed-to-5 reds with the
exact predicted `taskStatusGlyph("ready")` line) and both gates green on the exact pushed
heads. The wish's original nav-shell premise was refuted at Strategize (stale ~6x, as the
user predicted); the pivot to the charter's real residue (W17 dispatch items 4–5) was the
system working, and both premise-smokes at build time confirmed genuinely-unbuilt before
spending an edit.

**Landed (review-verified, gates re-run green, pushed):**
- **ttw18-narrow-rail-hover** → PR #6002 (`loop-epic/narrow-mode-reading-frame-rail-stops-gai-0`).
  D99 closed + D105 exactly as chartered: mouseMotion reading-frame branch → setHoverStop
  (D95 debounce reused unmodified, wide's dual-set mirrored), compose.go:148 wired to
  m.ui.HoverStop, and the D42/D105c hardening — frameHitTargets now CALLS readingWindowTop
  (inline top-math copy deleted). Five tests incl. the truecolor-forced paint trio and the
  windowed Scroll=8 hit⇄paint parity tripwire. Goldens byte-frozen at rest.
- **ttw18-chip-full-manifest** → PR #6003 (`loop-epic/in-body-task-chips-speak-the-full-9-stat-1`).
  D43 closed Go-side + D106: taskStatusGlyph's guarded allowlist widened 5→9 in strict
  two-file lockstep with its tripwire test; ▸ sentinel preserved; status-manifest-check.sh
  untouched and all-PASS. With #5915 already merged (D107), BOTH in-body chip forks now
  delegate — D43's cross-surface one-status-language is done pending merge.

**Ledger:** both tasks honestly in_progress, criteria evidence-stamped mid-claim, merge
criterion open for the LEAD. One reviewer addition: **ttw18-bl-narrow-reading-width-skew**
(P3) files the builder-flagged pre-existing fork — narrow stop/scroll math measures at
readingWidth() (full m.width) while composeAt/hit-map paint at boardGeometry width (−3/−4
gutter); latent until a title wraps differently at the two widths; same drift class D105c
just killed for the window top. Grade: A (commentary in wave paper task-tui-wave-2026-07-23b).

**Next wave (dispatch order):** (1) LEAD merges #6002 + #6003 (package-disjoint, any order,
Go gate only) and closes each task's merge criterion. (2) ttw17-bl-live-tmux-drive — the
LIVE tmux feels-native mouse drive is now the LAST mouse item standing and blocks judging
the wish's native bar; cannot be proven offline, do not fake it. (3)
ttw18-bl-narrow-reading-width-skew — one width producer for narrow reading frames (the last
known hit⇄paint drift vector). (4) ttw18-bl-wide-footer-verb-clicks (P3) if the mouse story
is to be uniform. (5) ttw18-bl-go-toolchain-skew stays P4 latent.

### Wave 19 2026-08-17 (DECIDED: prove it native + one grammar — the D109 reconciliation wave)

**Premise-smoke verdicts (run, not assumed):** the wish's epic id `task-tui-epic` does NOT exist —
the epic spine is `task-tui-goal` (bp not_found vs published, re-confirmed at Decide). The wish's
literal build command `go build .` fails at repo root (no Go files; main is `./cmd/barkpark`).
D40's "showing N of M" mandate git-shown and read for coverage (line 567). dr-w35-s1 is a
DEPLOY-RELIABILITY reconcile (D594), not a prior D109 draft — D109 is authored fresh here.

**D109 — Reconciliation: ten taskboard-adjacent merges landed after this charter's last commit
(2026-07-23); four are load-bearing on charter law and are hereby read INTO law.**
(a) **#6129** (48bf746a1c, 2026-07-25) shipped the pointer-DRAGGABLE wide divider with
`DetailsPaneRatio` PERSISTED in `~/.config/barkpark/taskboard-preferences.json` (atomic write on
drag release only, tolerant load, ratio (0,1) exclusive — preferences.go), plus the
criteria-first + purpose-dossier reading order. This RETIRES D101's phantom-scrub as refuted
(the drag gesture now exists: compose.go wideDragging/resizeWidePanes; live-drive-proven
including persistence across kill+relaunch), AMENDS the zero-persistent-settings flavor
(details_pane_ratio is the FIRST and only persisted TUI setting — a gesture-set physical
preference, not a mode/toggle; the no-settings-SCREEN law stands), and SUPERSEDES D15's content
order (criteria checklist + purpose dossier now lead, before stamps/timeline/prose — a thin task
still stays thin is retained as intent). (b) **#11564** (5ea0637910) RETIRES the D11/D18
breadcrumb ROW (Breadcrumb/crumbSeg survive only as a trail renderer; every +1 crumb Y-offset
removed) and introduces `docLayout` as the ONE reading-column seam. (c) **#11570** (c0c37aab03)
re-anchors the doc-column cap on D24's 72-cell measure (docLayout caps at 72, centered).
(d) **#11624** (a0715cf5cc) dresses the reading document as a sheet: ─ top edge + │ side rails
via `renderDocPane`, the one painter. Non-load-bearing: #6033 (32MiB fetch bound), #8133
(disposition strip), #8604 (refuse empty envelope), #8648 (poison-parity tests), #6002 (D99
close-out); #8281 is internal/cli, not taskboard. Stale citations corrected: mouseMotion is
program.go:795 (and HAS the reading-frame branch), footerVerbAt is program.go:925. Residue
ordered: prune the retired '›' breadcrumb glyph from readingGlyphExtras + its stale
allowedGlyphs comment (W19 hygiene slice).

**D110 — The SGR tmux drive protocol is PROVEN end-to-end; the drive graduates from spike to
committed harness + judged verdict.** W19 verify drove the REAL compiled binary in detached
tmux 3.4 (130x40 and 70x24, `new-session -d -x/-y` alone fixes geometry; `send-keys -l` with
ANSI-C `$'\033[<…'` delivers, hex `-H` equivalent) against guerrilla: wheel(65), click
press/release(0 M/m), hover motion(35) accent paint, divider drag (press-on-gutter/motion-32/
release) with prefs rewrite 0.6054→0.4444 AND persistence across kill+relaunch, exact 2-col
gutter hover bounds, M toggle — ALL LANDED. Grammar truths the harness must encode: (1) there
is NO click-again-descend — a single click is select+activate (leaf descends on FIRST click;
a second click on an epic root FOLDS it); (2) shift-click(4) reaching the app acts as a plain
click — the bypass is TERMINAL-native selection, by construction unprovable via send-keys;
(3) the M-toggle footer mode note is invisible below a 102-col inner board width — ACCEPTED as
shed-ladder design, never scored as a drive failure; (4) evidence law: frames churn (spinners,
elapsed stamps, live SSE) — diffs MUST normalize or compare single rows, and coordinates MUST
be located from a capture (read the │ columns), never hard-coded (the persisted ratio moves
them). Recipe ledger row: tooling/grip/ledger/task-tui-w19-tmux-sgr-drive-protocol-2026-08-17.md.
One live defect-candidate observed (conn header flapped ✗ offline ↔ ● live while the CLI
reached guerrilla) is FILED (ttw19-bl-conn-state-flap), not fixed blind in-wave.

**D111 — Wide footer verbs RE-DERIVED against the live dragged geometry (supersedes the filed
fixed-46 premise).** boardPaneCols is a live dragged/persisted width clamped
[minBoardWidth=24, innerW−paneGutter2−minReadingWidth]; verb spans shed RIGHT-TO-LEFT one at a
time (mutation-probed: on the sub-60 footer line o clips <57, x <46, c <36; ZERO spans only
≤35 — refuting the filed all-or-nothing premise), and thresholds are line-form-dependent
(the ≥60 line shifts them), so acceptance asserts against buildBoardFooter's ACTUAL emitted
spans at boardW, never literal columns. The fix shape: footerVerbAt gains a wide branch
(spans rebuilt at m.boardPaneCols(innerW), offset by the wide pad, honestly !ok when the verb
is shed); handleWideMouse gains narrow's verb-first early-out ABOVE the unconditional
pendingClose/Strip clear at compose.go:653-654 (probe-proven side effect today) WITHOUT
regressing the chrome-click clear; TestFooterVerbAtDegradesHonestly's wide assertion is flipped
DELIBERATELY (mutation-proven a real tripwire — removing the m.wide gate reds it today); D96's
verb-click==key-press parity governs dispatch (two-step x arm/fire survives a verb click).

**D112 — Width-skew NARROWED to the floor mismatch; the unguarded seam RE-TARGETED to the wide
preview resolvers.** The filed measure/paint fork is GONE (both narrow sides route
docLayout(m.width−gutter)); the probe-quantified residual is readingWidth() missing composeAt's
width<20→20 floor — a 1-3 cell gap at m.width 19-22 only (gap 0 at ≥23). The task re-scopes to
that floor alignment + a mutation-provable regression test; the old "RED on the old fork" DoD
is unproducible and retired. Seam truth by mutation: compose.go:258 (the direction's named
site) is GUARDED (−2 reds 5 tests) — but rightPaneStopAt (`inner − 1`) and scrollPreview
(`len(body) − (inner − 1)`) are UNGUARDED (full suite green on −2 at both). The slice extracts
one shared top-edge avail seam (mirroring docBodyRow) that renderDocPane/composeAt/
rightPaneStopAt/scrollPreview all call, plus tests that red on drift at both wide-preview
resolvers (the D105c class, third instance).

**D113 — Honesty + latency: D40's "showing N of M" finally ships; the two fetches parallelize.**
(a) Board.TaskCount is populated (board.go) but NEVER rendered — the live board shows TRUE
totals (prime counts sum 6733) atop a 1000-row window with zero disclosure; the '+' on ready is
ReadyHeadClamped only. Ship the momentum-line note (`· showing N of M`) gated on
TaskCount < summed prime counts, with its own shed priority (never a mid-token clip); fixtures
stay non-truncated so existing goldens stay byte-frozen, and a NEW truncated fixture test
proves the note. (b) FetchSnapshotFull fetches list THEN prime strictly sequentially; both are
server-TTFB-bound and guerrilla parallelizes (concurrency roughly halved wall time on quiet
runs) — parallelize the two fetches preserving the both-required/honest-degraded-on-any-failure
contract. Magnitude deliberately NOT quoted: measured under swap-thrash, the numbers are the
load (measure-on-a-quiet-host law). (c) RATIFIED as intentional, no slice: task prose renders
NoColor while paper bodies render ANSI256 — color=state governs task FACTS; the paper is a
document surface (D20 stands with this decision number on it).

**Ledger hygiene executed at Decide:** ttw18-narrow-rail-hover CLOSED done (work merged as
#6002/425001b42a, ancestor-proven; criteria 0-4 were builder-stamped, merge criterion stamped
now). ttw18-chip-full-manifest CLOSED done (#6003/e024eea1e2 ancestor-proven).
ttw18-bl-go-toolchain-skew CLOSED cancelled — premise refuted (CI honors the go.mod 1.25.0 pin
via go-version-file everywhere that matters; local go1.26.2 is a forward-compatible minor-ahead;
no local/CI gofmt disagreement); the stale "pinned go 1.24.2" comment in cli-release.yml rides
the W19 hygiene slice. Find-jump stays FILED not promoted (ttw19-bl-find-jump, considering):
zero user signal anywhere in wish/amendments/design docs; the only charter-safe shape is a
transient Esc-dismissable /-jump (navigation, not reconfiguration — wish law "no mode maze"
stands); the structural argument (board sees 1000 of 6733 rows) is recorded, the promotion
gate is an explicit user taste signal. Cross-fence finding FILED (ttw19-bl-drafts-now-drop):
the drafts.* NOW-band drop has NO Go-side filter (BuildBoard's NOW predicate is pure
claim/worker/lifecycle) — the drop is the /v1/tasks published-list contract, an api/ ruling
outside this wave's internal/ fence. CI gating gap FILED into the hygiene slice: go-tests.yml
whitelists internal/pdrender/testdata/** but NOT internal/taskboard/testdata/** — a
taskboard-golden-only PR runs no Go suite.

**Wave plan (7 slices; rounds are law; builders opus except the drive; gates in the task
briefs, dry-run at Decide; wave paper task-tui-wave-2026-08-17):**
1. **ttw17-bl-live-tmux-drive** (large, FABLE, round 1) — D110. The committed re-runnable
   harness under scripts/taskboard-drive/ + the full gesture matrix at 130x40 and 70x24 against
   guerrilla + the epic's first honest feels-native verdict, recorded on the task and ledger.
   No internal/ code edits (collision-free by construction).
2. **ttw18-bl-wide-footer-verb-clicks** (medium, opus, round 1) — D111. program.go + compose.go
   + mouse_test.go ONLY (reuse buildBoardFooter/verbSpans; render.go belongs to slice 4).
3. **ttw19-showing-n-of-m** (small, opus, round 1) — D113a. render.go + render_test.go.
4. **ttw19-concurrent-snapshot-fetch** (small, opus, round 1) — D113b. detail_data.go (+ test).
5. **ttw19-golden-and-gating-hygiene** (small, opus, round 1) — D109 residue + gating gap:
   glyph '›' prune, dragged-divider golden compose_wide_dragged_120, go-tests.yml testdata
   path, cli-release.yml comment.
6. **ttw18-bl-narrow-reading-width-skew** (medium, opus, ROUND 2, after slices 2+5 merge —
   compose.go/compose_test.go collision fence, not a code dependency) — D112. Floor alignment +
   shared avail seam + mutation-provable tests at rightPaneStopAt/scrollPreview.
7. **ttw19-docs-tui-currency** (small, opus, round 1) — net-neutral rewrites of
   docs/cards/tui.md (≤2400B) and docs/cheatsheets/tui.md (≤2400B): mouse first-class, persisted
   divider, sheet reading document; + spineRows Code anchor. Gates run from the builder's OWN
   worktree (the primary checkout false-reds docs-anchors-check via mainbase/ pollution).

Next D-number: D114.

### Wave 19 2026-08-17 (REVIEWED: all 6 round-1 slices green, one review fix, pushed + PRs open)

**Review facts:** the reviewer re-ran every gate on the final heads — including the FULL live
tmux drive (25/25 asserts pass, exit 0, on tmux 3.4 against guerrilla — an independent fourth
consecutive all-pass run) and slice 3's suite under `-race` — plus an octopus integration merge
of all six branches onto origin/main with `go build ./cmd/barkpark` + `go test ./internal/...`
fully green (30 packages). ONE review fix: the cheatsheet's mouse row said "click again
activates", contradicting the drive-proven one-gesture grammar (single click = select+activate)
and the card's own prose — fixed on the `-5-r` branch, both doc gates re-run green (2397B/2400B).

**Landed (review-verified, gates re-run green on final heads):**
- **ttw17-bl-live-tmux-drive** → `loop-epic/the-live-tmux-drive-ships-as-a-committed-0`.
  D110 closed: committed harness `scripts/taskboard-drive/drive.sh` (build → detached tmux
  130x40 + 70x24 → SGR bytes per gesture → located/normalized asserts → evidence + report),
  feels-native verdict in `tooling/grip/ledger/task-tui-w19-feels-native-verdict-2026-08-17.md`:
  all 9 scored gestures PASS vs the lazygit bar; shift-click NOT SCORED per D110. Two defects
  are owned open tasks: ttw19-bl-conn-state-flap (re-observed), ttw19-bl-wide-focus-oneway
  (NEW: Enter→Esc strands keyboard j/k in the preview; the one feels-native miss).
- **ttw18-bl-wide-footer-verb-clicks** → `loop-epic/wide-mode-footer-verbs-become-clickable--1`.
  D111 exactly as chartered: footerVerbAt wide branch against live boardPaneCols, verb-first
  early-out above the pendingClose clear (two-step x survives, chrome clicks still disarm),
  D96 hover tint via HoverFooterVerb; 5 new wide tests all deriving coords from
  buildBoardFooter's real spans.
- **ttw19-showing-n-of-m** → `loop-epic/the-board-discloses-its-1000-row-horizon-2`. D113a:
  momentum line gains a dim `showing N of M` on its own shed rung (criteria tally sheds first,
  note drops WHOLE); summedLifecycleCounts matches TaskCount's population; zero golden churn.
- **ttw19-concurrent-snapshot-fetch** → `loop-epic/the-two-snapshot-fetches-fly-in-parallel-3`.
  D113b: list + prime GETs overlap under a WaitGroup; two-arrival-barrier stub proves overlap
  (builder negatively proved it trips a sequential fetch); either-error → same degraded outcome,
  list-error precedence keeps old semantics; `-race` clean.
- **ttw19-golden-and-gating-hygiene** → `loop-epic/sheet-era-glyph-and-golden-hygiene-retir-4`.
  D109 residue: '›' pruned from readingGlyphExtras (zero goldens carry it), dragged-divider
  golden compose_wide_dragged_120 + divider-column assert, go-tests.yml now whitelists
  internal/taskboard/testdata/** (both triggers), cli-release.yml comment corrected.
- **ttw19-docs-tui-currency** → `loop-epic/the-tui-card-and-cheatsheet-finally-spea-5-r`
  (the one -r final branch). Card + cheatsheet speak mouse/divider/sheet under the 2400B caps;
  spineRows Code anchor CI-pins the one-producer law; reviewer's click-grammar fix on top.

**Ledger:** all six slice tasks honestly in_progress, criteria evidence-stamped mid-claim, only
the lead-owned merge criterion open. Zero ledger fixes needed — first wave in memory where the
board needed no correction. Grade: A- (commentary in wave paper task-tui-wave-2026-08-17).

**Next wave (dispatch order):** (1) LEAD merges the six round-1 PRs (file-disjoint by
construction; slice 5's final branch is `-5-r`) and closes each merge criterion; drive-harness
PR's evidence dir churns on re-runs by design. (2) THEN dispatch **ttw18-bl-narrow-reading-width-skew**
(round 2 — waits ONLY on the compose.go/compose_test.go collision fence with slices 2+5, both
now merged): D112 floor alignment + the shared top-edge avail seam + mutation-proofs at
rightPaneStopAt/scrollPreview. (3) **ttw19-bl-wide-focus-oneway** is the highest-value NEW
board defect (keyboard route back from preview focus — the one feels-native miss). (4)
ttw19-bl-conn-state-flap needs a live-channel diagnosis. (5) ttw19-bl-find-jump stays
considering pending a user taste signal.
