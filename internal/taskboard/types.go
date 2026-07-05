package taskboard

import "time"

// Task is the board's view of one /v1/tasks envelope.
type Task struct {
	DocID     string
	Title     string
	Lifecycle string // open|ready|in_progress|blocked|done|closed (as served)
	Kind      string
	ParentID  string
	Priority  string
	Labels    []string
	Claim     *Claim
	Criteria  *Criteria // nil when the envelope omits criteria_progress
	// TwinOf is the doc id of a suspected near-duplicate (same cluster/parent,
	// title-token Jaccard >= 0.6), "" when none. Surfacing only — never auto-merged.
	TwinOf string
	// TwinTitle is the partner's title, precomputed alongside TwinOf so an
	// expanded row can name the twin in words a human reads ("twin ⧉ 'Add a SUM
	// function'") instead of an opaque doc id. "" when TwinOf is "" or the
	// partner title was empty; the renderer falls back to TwinOf then.
	TwinTitle string
	// CriteriaItems is the decoded content.acceptance_criteria list: criterion
	// text + met (met === true only, mirroring the server's tolerance contract
	// in Barkpark.Tasks.Criteria). Malformed entries keep their slot with empty
	// text so len(CriteriaItems) always equals Criteria.Total when both exist.
	// Empty when the task has no criteria.
	CriteriaItems   []CriterionItem
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

// CriterionItem is one acceptance-criteria checklist entry.
type CriterionItem struct {
	Criterion string
	Met       bool
}

// Event is one recent task.% mutation from prime.
type Event struct {
	Mutation string
	DocID    string
	At       time.Time
}

// Snapshot is the raw fetched state: /v1/tasks list + prime extras.
type Snapshot struct {
	Tasks  []Task
	Counts map[string]int // lifecycle_status -> count
	Events []Event
	// ReadyHeadClamped is true when prime's ready head came back at the server
	// clamp maximum (limit=100): the readiness overlay is then honest-but-partial
	// beyond the top of the queue, so the ready count renders with a "+" suffix.
	ReadyHeadClamped bool
	FetchedAt        time.Time
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
	Now      []Task    // unexpired claims, updated desc
	Epics    []Epic    // attention-ranked
	Clusters []Cluster // derived label clusters, freshest-first (after authored epics)
	Orphans  []Task    // surviving loose tasks, band-ordered
	// OrphansFolded is the count of terminal (done/closed) orphans older than the
	// fold threshold, hidden into a single "+N done" line the same way an epic
	// folds its stale children — so a flat queue of long-closed tasks collapses to
	// a short honest tail instead of burying the live rows.
	OrphansFolded int
	// OrphansCancelledFolded is the count of CANCELLED loose tasks (charter
	// wave-10 W10-B). Cancelled work never renders as a row at any age — it folds
	// entirely into the section's trailing "· N cancelled" tail, so abandoned rows
	// stop occupying the pane. Distinct from OrphansFolded so the tail reads
	// "+N done · M cancelled" and the done tally never absorbs abandoned work.
	OrphansCancelledFolded int
	// OrphansActive is true when the loose "(no epic)" bucket owns at least one
	// NOW task (an in_progress live claim). It is the orphan bucket's twin of
	// Epic.Active / Cluster.Active: the ONE auto-fold input for the orphan header
	// (foldedOrphans defaults folded unless OrphansActive), so the loose pile —
	// the flat-queue live shape's bulk — collapses to a single header line unless
	// the work you are actually running lives in it (wave-7 decisions 32/33).
	OrphansActive bool
	// ReadyHead is the top readyHeadMax ready tasks across the WHOLE corpus,
	// ordered priority-ascending (P0/P1 first; non-numeric/absent last) then
	// updated_at desc. It powers the claim-forward READY TO CLAIM band that
	// replaces the empty-NOW dead-line: when nothing is claimed the band offers
	// the next tasks to claim so active work is never a dead end (wave-7 D35).
	ReadyHead []Task
	// ReadyTotal is the count of EVERY ready task the board holds, so the READY
	// TO CLAIM band's "+K more ready" tail is honest about the depth of the queue
	// behind the shown head.
	ReadyTotal int
	// ReadyHeadClamped rides through from the Snapshot: the ready count shown in
	// the header wears a "+" when the prime ready head hit the server clamp.
	ReadyHeadClamped bool
	// TaskCount is the number of task envelopes the list fetch returned. Compared
	// against the summed lifecycle Counts (the true corpus total) it lets the
	// header say "showing N of M" when the 1000-row list clamp truncated the
	// board, instead of quietly presenting a partial queue as the whole.
	TaskCount int
	// Stale is the count of non-terminal tasks untouched longer than the warn
	// threshold (3d) — the header's "N stale" instrument. 0 renders nothing.
	Stale  int
	Counts map[string]int
	Events []Event
}

type Epic struct {
	Root       Task
	Children   []Task // policy-ordered
	DoneFolded int    // count of done children folded away
	// CancelledFolded is the count of cancelled children folded entirely away
	// (charter wave-10 W10-B) — cancelled work never renders as a row, at any
	// age. When the epic ROOT itself is cancelled the whole section collapses to
	// one dim tombstone line at the bottom of the board (spineDeadEpic).
	CancelledFolded int
	Dormant         bool // idle >7d (computed; no longer drives folding, see Active)
	// Active is true when the epic owns at least one NOW task (an in_progress
	// live claim) — the ONE auto-fold input (wave-7 decision 32): an epic folds
	// to a single header line by DEFAULT and auto-EXPANDS only when it holds the
	// work you are actually running. Computed in BuildBoard against the same
	// nowSet the NOW de-dup uses, so "the active group" is exactly "the group
	// with a task pinned in NOW". An explicit user fold/unfold still overrides.
	Active bool
}

// Cluster is a DERIVED relatedness group: loose tasks sharing a cluster key
// (their strongest organizing label). It renders and navigates exactly like an
// Epic section, but the grouping is inferred from tags, not authored structure.
type Cluster struct {
	Key        string // the full tag, e.g. "proj:sheets-parity"
	Tasks      []Task // band-ordered like epic children
	DoneFolded int    // terminal members older than 24h, folded to a count
	// CancelledFolded is the count of cancelled members folded entirely away
	// (charter wave-10 W10-B), mirroring Epic.CancelledFolded.
	CancelledFolded int
	// Active mirrors Epic.Active for a derived cluster: true when the cluster
	// owns a NOW task, folding the section by default and auto-expanding only the
	// cluster whose work is actually running (wave-7 decision 32).
	Active bool
}

type ConnState int

const (
	ConnLive ConnState = iota
	ConnPolling
	ConnOffline
)

// UIState is the interaction state the renderer needs. It is the BOARD frame's
// (stack level 0) interaction state; pushed reading frames carry their own
// Cursor/Scroll on the Frame struct (frames.go). Cursor here indexes the
// flattened visible-row list the board paints.
type UIState struct {
	Cursor         int             // index into the flattened visible-row list
	CollapsedEpics map[string]bool // root doc_id -> user-collapsed
	Conn           ConnState
	LastSync       time.Time
	Strip          ActionStrip // the one-line action status above the footer
	// Frame is the animation frame index: advanced by the heartbeat tick ONLY
	// while the board is alive (Alive()), 0 at rest and in cold paints.
	// Injected like now() so motion states golden deterministically.
	Frame int
	// Flashes maps doc_id -> when its last observed change landed (live
	// snapshot diff in applySnapshot). Render derives the one-shot fading
	// highlight via FlashLevel; the heartbeat prunes expired entries. Never
	// populated by a first snapshot or a cache load — cold paints are still.
	Flashes map[string]time.Time
}

// ActionStrip is the single role-colored status line rendered directly above
// the footer: a confirmation on a landed claim/close (RoleOK, green), an
// honest refusal or arm-prompt otherwise (RoleWarn/RoleDanger). An empty
// Message renders no line at all. It is cleared on the next keypress or the
// next applied snapshot — never a modal, never sticky.
type ActionStrip struct {
	Message string
	Role    Role
}
