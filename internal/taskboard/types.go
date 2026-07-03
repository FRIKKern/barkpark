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
	// Suggested is a derived cluster key this unkeyed task plausibly belongs to
	// (best member-title Jaccard >= 0.4), rendered as a dim "+key?" chip and
	// applied only by the explicit t verb. "" when none.
	Suggested string
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
	// OrphansFolded is the count of terminal (done/closed/cancelled) orphans
	// older than the fold threshold, hidden into a single "+N done" line the
	// same way an epic folds its stale children — so a flat queue of long-closed
	// tasks collapses to a short honest tail instead of burying the live rows.
	OrphansFolded int
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
	Dormant    bool   // idle >7d -> renders as one header line
}

// Cluster is a DERIVED relatedness group: loose tasks sharing a cluster key
// (their strongest organizing label). It renders and navigates exactly like an
// Epic section, but the grouping is inferred from tags, not authored structure.
type Cluster struct {
	Key        string // the full tag, e.g. "proj:sheets-parity"
	Tasks      []Task // band-ordered like epic children
	DoneFolded int    // terminal members older than 24h, folded to a count
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
