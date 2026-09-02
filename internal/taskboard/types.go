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
	Completeness    Completeness
	DependencyCount int
	DependentCount  int
	InsertedAt      time.Time
	UpdatedAt       time.Time
}

type Claim struct {
	Worker    string
	Epoch     int
	ClaimedAt time.Time
	// Now is the worker's live now-line pulse (charter D9): content.claim.now,
	// written atomically with the lease renewal by `bp task pulse`. Nil when the
	// claim carries no pulse (every claim written before the pulse verb shipped).
	Now *ClaimPulse
}

// ClaimPulse is the decoded content.claim.now — {"text","ts","criterion"?}
// (charter D9, the pinned wire shape). Criterion is the acceptance_criteria
// index the pulse names (the criterion the worker is on RIGHT NOW — the board
// spins exactly that ladder rung while the pulse is live), -1 when the pulse
// names none. Staleness is derived from At against the claim lease TTL — a
// pulse is a statement about NOW, so an old one must visibly decay, never
// masquerade as current activity.
type ClaimPulse struct {
	Text      string
	At        time.Time
	Criterion int
}

type Criteria struct{ Met, Total int }

// CriterionItem is one acceptance-criteria checklist entry.
type CriterionItem struct {
	Criterion string
	Met       bool
	// Evidence is the proof text the met-flip carries (content.acceptance_
	// criteria[N].evidence). A met with empty evidence is not a sealed row —
	// the server refuses that flip — so a read-back that finds one has found a
	// write that did NOT land the way it was asked for. Empty on an unmet row.
	Evidence string
	// Attempts is the honest-miss trail (charter D8): `bp task stamp --miss`
	// appends {note,ts,worker} WITHOUT flipping met, bounded server-side to the
	// 5 most recent. A recorded attempt on an unmet criterion is what turns its
	// ladder rung amber — the board shows the honest miss, not just the seal.
	Attempts []CriterionAttempt
	// Withdrawals is the correction trail (D745): `bp task stamp --withdraw`
	// LOWERS met to false, leaves Evidence exactly where it was, and appends
	// {note,ts,worker,superseded_evidence} here. Unlike Attempts it is
	// UNBOUNDED server-side, because silently dropping a correction is the
	// defect the verb exists to end. A row carrying withdrawals is a row whose
	// proof was refuted at least once — read it before trusting Evidence, which
	// is deliberately the SUPERSEDED text on a withdrawn row.
	Withdrawals []CriterionWithdrawal
}

// CriterionWithdrawal is one recorded withdrawal of a stamped proof (D745's
// withdrawals[] entry): who withdrew it, when, why, and the evidence that
// stamp had carried. It is the signed replacement for the prose convention it
// supersedes — reviewers used to write "[WITHDRAWN BY WAVE REVIEW …]" into the
// evidence itself because no verb could lower the flag, and every board went on
// counting those criteria MET.
type CriterionWithdrawal struct {
	Note   string
	At     time.Time
	Worker string
	// SupersededEvidence is the proof text this withdrawal retired, snapshotted
	// when it was withdrawn — so it stays legible even if the criterion is
	// later re-stamped over.
	SupersededEvidence string
}

// CriterionAttempt is one recorded miss on a criterion (charter D8's
// attempts[] entry): who tried, when, and the honest note about what fell
// short. It never counts toward met — stamp records progress, close seals.
type CriterionAttempt struct {
	Note   string
	At     time.Time
	Worker string
}

// Missed reports whether the criterion carries a recorded attempt without the
// met seal — the amber "!" rung on the board's criteria ladder. A met
// criterion is never "missed" (the seal supersedes the trail), and an
// untouched one (no attempts) stays the dim ○.
func (c CriterionItem) Missed() bool { return !c.Met && len(c.Attempts) > 0 }

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
	// EventCursor is the last /v1/tasks/events id the board had accounted for
	// when this snapshot was cached — the resume point for the cheap keyset poll
	// (events.go), NOT board data. It rides the snapshot only because the cache
	// file is the one per-scope thing the board already persists; a zero value
	// (an older cache, a fresh scope) just means the next launch walks the feed
	// up to the tip once before the adaptive loop settles.
	EventCursor int64 `json:"event_cursor,omitempty"`
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
	// Reason is the D65 curation justification a ready row shows ("continues
	// <root>", "unblocks N") — every deeply-curated pick explains itself.
	Reason string
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
	// IndependentReady is the D66 parallel-capacity read: how many DISTINCT
	// root neighborhoods hold ready work right now — the number of agents that
	// could run in parallel without stepping on each other's blast radius.
	IndependentReady int
	// CriteriaMet/CriteriaTotal is the corpus-wide acceptance-criteria tally
	// (charter D11: the momentum header counts criteria, not just tasks) —
	// summed over every fetched task's criteria_progress, excluding cancelled
	// work (the same denominator law as progressPct). Total 0 = no criteria in
	// the corpus, and the momentum header shows no criteria segment at all.
	CriteriaMet   int
	CriteriaTotal int
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
	// Workable is whether the epic still holds ≥1 non-terminal child (charter
	// D64): the input to the finished-decay rule — completion is not activity.
	Workable bool
	// Demoted is the D64 verdict: finished (no workable children) AND past the
	// finishedGraceAfter window — spineRows relocates the section to the
	// finished shelf at the bottom, above the cancelled tombstones.
	Demoted bool
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
	Workable     bool
	Demoted      bool
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
	// ConnProblem is a short, truthful reason the snapshot path is degraded.
	// Empty means the ordinary Conn label applies. It distinguishes a rejected
	// or invalid snapshot from a genuinely unreachable server.
	ConnProblem string
	// Paused is the keyset poll's visible slow state (events.go): a poll that
	// took longer than slowReadThreshold or failed outright. The board says
	// "paused (server slow) · retry in Ns" and backs off, instead of leaning
	// harder on a server that is already queueing — the measured failure mode
	// this loop exists to end. It is a SEPARATE field from ConnProblem on
	// purpose: the two describe different reads (the cheap poll vs. the snapshot
	// pair) and must never clobber each other's label.
	Paused bool
	// RetryAt is when the next poll is armed for, shown alongside Paused so the
	// operator can see the board is waiting on a schedule rather than wedged. A
	// zero value renders nothing.
	RetryAt  time.Time
	LastSync time.Time
	Strip    ActionStrip // the one-line action status above the footer
	// SpineScroll is the board viewport's remembered top line (Amendment 8:
	// minimal scrolling — the cursor walks a stable window, and the window
	// slides only when the cursor would leave it, 1:1 with the cursor's line
	// movement, never a re-centering jump). The shell re-syncs it after every
	// update via SpineTopFor; Render recomputes the same slide at paint time,
	// so a stale value only ever costs one self-healing clamp, never a hidden
	// cursor.
	SpineScroll int
	// Frame is the animation frame index: advanced by the heartbeat tick ONLY
	// while the board is alive (Alive()), 0 at rest and in cold paints.
	// Injected like now() so motion states golden deterministically.
	Frame int
	// Flashes maps doc_id -> when its last observed change landed (live
	// snapshot diff in applySnapshot). Render derives the one-shot fading
	// highlight via FlashLevel; the heartbeat prunes expired entries. Never
	// populated by a first snapshot or a cache load — cold paints are still.
	Flashes map[string]time.Time
	// HoverTarget is the Ref (task doc_id / fold key) of the selectable spine
	// row currently under the mouse pointer, "" for none (charter D94/D95). It
	// is resolved by the ttm-s1 compose-level hit map from a Motion MouseMsg and
	// committed through a bounded trailing debounce, so an all-motion stream
	// coalesces crossed rows and never renders every intermediate preview.
	// Render restyles exactly this row in the accent foreground
	// (hoverStyle — the chat Phases-pane selection grammar); every other row is
	// untouched, at full brightness. A "" target paints nothing, so a board
	// with no mouse is byte-identical. Cleared on any key input, so the
	// keyboard flow is untouched.
	HoverTarget string
	// HoverStop is the index of the reading-frame rail stop currently under the
	// mouse pointer in the WIDE right pane, -1 for none (charter D99). It is the
	// reading-frame twin of HoverTarget — a SEPARATE field, never an overload:
	// resolved by wideMouseMotion from a Motion MouseMsg through the SAME stop
	// producer the click router reads (rightPaneStopAt), set through the
	// change-only setHoverStop guard (the debounce IS the change guard, charter
	// D95). windowFrame repaints exactly this stop's body line in the accent
	// FOREGROUND (hoverPaint/hoverStyle) — distinct from the cursor stop's ▎ bar
	// the body already carries. -1 paints nothing, so a reading frame with no
	// pointer is byte-identical (goldens, keyboard flow). The depth-0 preview has
	// no stops (previewLines passes stops=nil), so it is always -1 there (#4240).
	// Cleared on any key input, so the keyboard flow is untouched.
	HoverStop int
	// MouseReleased is the mouse-mode toggle (charter D96): false (the zero
	// value, and the program's start state) means mouse reporting is ON — the
	// board's footer verbs are clickable and hover tints; true means the user
	// pressed M to RELEASE the mouse so the terminal owns clicks again (native
	// text selection). The footer reflects the mode and clears any hover while
	// released. It is UIState (not a Model field) so the frozen-signature Render
	// can read it — mouse mode is render state, the click plumbing is the shell.
	MouseReleased bool
	// HoverFooterVerb is the board footer verb (c/x/o) the pointer is currently
	// over, 0 when none — set on mouse motion, cleared when the pointer leaves
	// the spans or the mouse is released. The footer paints the hovered verb with
	// a background tint (the terminal's hover vocabulary); at rest (0) the footer
	// is one dim span, byte-identical to the pre-mouse footer, so goldens stay calm.
	HoverFooterVerb rune
	// OpenTasks marks the ONE task currently entered — the deepest FrameTask on
	// the navigation stack (single-open: at most one entry, never a pile of
	// checks). The board renders that row's status glyph as the reader-open ◆
	// (ASCII '@'): enter marks the row, esc clears it — the reader
	// vocabulary, visible in the wide two-pane where the board stays pinned
	// beside the reading frame. It is DERIVED from Model.stack at compose time
	// (openTaskRefs, compose.go), never stored shell state, so it cannot desync
	// from the breadcrumb; nil while nothing is open, so an at-rest render is
	// byte-identical.
	OpenTasks map[string]bool
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
