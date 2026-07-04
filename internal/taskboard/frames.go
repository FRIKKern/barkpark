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
