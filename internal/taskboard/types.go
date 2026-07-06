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

// NextKind discriminates a NEXT intent-strip row (charter wave-12 D60): a
// resumable (a lease dropped this task mid-work — the truest follow-up) or the
// priority head of the ready queue (what the system is about to pick up).
type NextKind int

const (
	nextResume NextKind = iota // a lease expired mid-work — the truest follow-up
	nextReady                  // the priority head of the ready queue
)

// NextItem is one row of the NEXT intent strip (charter wave-12 D60/D61). Each
// is a real cursor stop — c claims it. A resumable carries the lease-expiry time
// its row shows ("lease expired 8m"); a ready item leaves it zero.
type NextItem struct {
	Task           Task
	Kind           NextKind
	LeaseExpiredAt time.Time // Event.At for nextResume; zero for nextReady
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
	// OrphansFocusSet is the loose bucket's focus neighborhood (charter D51 /
	// wave-11): the kept-orphan doc ids the focus window picks around an active or
	// blocked loose task — its context — plus the <=2 done-cue ids. Non-empty puts
	// the loose bucket in modeFocus (it shows this neighborhood, not all rows);
	// empty means header+rollup only. See computeFocus.
	OrphansFocusSet map[string]bool
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
	Stale int
	// Next is the pinned NEXT intent strip (charter wave-12 D60/D61): resumables
	// (leases dropped mid-work) FIRST, then the priority head of the ready queue,
	// capped at nextMax. Each is a real cursor stop (c claims it). Rendered as a
	// tiny strip under NOW; empty => the strip collapses to nothing.
	Next []NextItem
	// NextReadyMore is the honest remainder count for the NEXT strip's dim
	// "+N ready" tail: ready candidates that did not fit the nextMax budget after
	// the resumables. Resumables are NEVER counted here (they are follow-up, not
	// "ready"). A pointer to the spine below, never a cursor stop.
	NextReadyMore int
	Counts        map[string]int
	Events        []Event
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
	// LastActivity is the epic's recency clock (charter D49 / wave-11): the newest
	// lastActivity across the WHOLE member set (root + every descendant, INCLUDING
	// the folded done/cancelled and the NOW-pinned claims), computed BEFORE any
	// fold strips rows — so a mass-close's freshness is not thrown away with the
	// folded rows. sortEpics ranks by it (after Active, after repo-mention), so the
	// most-recently-worked epic floats to the top and dormant ones sink.
	LastActivity time.Time
	// FocusSet is the epic's focus neighborhood (charter D51 / wave-11): the
	// kept-child doc ids the focus window picks around the active/blocked work — up
	// to ~2 parents, ~3 ready siblings, ~3 children per seed, merged across seeds —
	// plus the <=2 done-cue ids. Non-empty puts the epic in modeFocus (it shows
	// this neighborhood, not head-of-5); empty means header+rollup only until the
	// user expands. See computeFocus.
	FocusSet map[string]bool
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
	// LastActivity is the cluster's recency clock (charter D49 / wave-11): the
	// newest lastActivity across its WHOLE pre-fold member set. sortClusters ranks
	// by it (after Active), mirroring Epic.LastActivity.
	LastActivity time.Time
	// FocusSet is the cluster's focus neighborhood (charter D51 / wave-11),
	// mirroring Epic.FocusSet — the member doc ids the focus window picks plus the
	// <=2 done-cue ids. Non-empty → modeFocus; empty → header+rollup only.
	FocusSet map[string]bool
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
