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
	// TwinOf is the doc_id of this task's nearest title-duplicate within its own
	// group (epic siblings, cluster peers, or the loose-orphan pile) when their
	// titles overlap past the twin threshold — the board's "these two look like
	// the same work" marker. Empty when the task has no near-duplicate.
	TwinOf string
	// Suggested is the Key of the cluster an UNCLUSTERED orphan's title most
	// resembles (past the suggestion threshold) — an advisory "this probably
	// belongs with …" hint that never actually moves the row. Empty otherwise.
	Suggested       string
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
	Now   []Task // unexpired claims, updated desc
	Epics []Epic // attention-ranked
	// Clusters are derived label-sections carved out of the loose-orphan pile:
	// tasks that share a project/area/most-shared label gather under one Key so
	// the flat "(no epic)" queue self-organizes by what relates. Freshest-member
	// first; each holds its own terminal fold.
	Clusters []Cluster
	Orphans  []Task // surviving loose tasks (no cluster key), band-ordered
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
	// Stale is the count of non-terminal tasks ANYWHERE on the board whose last
	// movement is older than the staleness threshold — the "you have N tasks
	// going cold" number the header makes impossible to miss, so the queue never
	// quietly accumulates outdated work.
	Stale  int
	Counts map[string]int
	Events []Event
}

// Cluster is a derived label-section of the loose-orphan pile: every loose task
// whose resolved cluster Key is the same gathers here, so a flat queue relates
// itself without any hand-filed hierarchy. It folds its own stale terminal rows
// exactly like an Epic (DoneFolded) and band-orders its survivors.
type Cluster struct {
	Key        string // the shared label that names the section (e.g. "proj:sheets-parity")
	Tasks      []Task // policy-ordered members (band order, stale sinks, recent-terminal tail)
	DoneFolded int    // count of terminal members folded away
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
	Strip          ActionStrip // the one-line action status above the footer
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
