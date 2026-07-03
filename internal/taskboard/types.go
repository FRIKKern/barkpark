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
