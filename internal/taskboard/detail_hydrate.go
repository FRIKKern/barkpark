package taskboard

import (
	tea "github.com/charmbracelet/bubbletea"
)

// detail_hydrate.go is the OTHER HALF of `?view=board`.
//
// The live board's list/poll path asks for the board projection (corpusCache.
// listView), which deletes `content` from every card — 105,755,961 B of corpus
// walk becomes 13,035,765 B. The board ROW loses nothing by that: the criteria
// ladder and the completeness badge are rebuilt from `content_digest` (fetch.go,
// criteriaItemsFromMarks / ScoreCompleteness). The DetailIndex is a different
// story — it is the TaskDetail reading model, and description, brief, evidence,
// code_refs, purpose and the blocked/closed/disposition strips live ONLY in the
// deleted echo.
//
// THE FAILURE MODE THIS FILE EXISTS TO PREVENT. Those fields do not blank the
// pane; RenderTaskDetail simply omits each empty section, so the reader gets a
// SHORTER pane that looks like a real one — the same shape of lie the lower-
// but-plausible completeness score would have been. So the board pays for the
// prose exactly where a reader asks for it: one always-full row GET
// (FetchTaskDetailByID) for the row that is open or previewed, and nothing for
// the other ~9,000.
//
// THREE PROPERTIES, each of which a lazier version gets wrong:
//
//  1. THE OVERLAY SURVIVES A RE-LIST. applySnapshot replaces m.details
//     wholesale every few seconds; a hydration written there would be erased by
//     the next tick and silently re-fetched forever. m.hydrated is a separate
//     map that snapshots do not touch, and detailFor reads it FIRST.
//  2. IT IS KEYED BY REV, NOT BY PRESENCE. A hydrated row whose rev has moved
//     is stale prose, so the next ensure re-fetches it. Holding it because "we
//     already have one" is how a detail pane goes quietly out of date.
//  3. ONE REQUEST IN FLIGHT AT A TIME. The preview target changes on every j/k,
//     so an unguarded ensure would issue one GET per keystroke. The guard makes
//     a fast scroll cost ONE request, not one per row: intermediate targets are
//     skipped and the settled target is fetched when the flight lands.
//
// A failed hydration does not blank anything — the pane keeps rendering its
// honest board-row-only shape, the same shape every row not in the index has
// always rendered. What it DOES do is record the ATTEMPT, not the verdict:
// m.attempted remembers which rev of which row was already asked for, so a
// server that cannot answer (a pre-route server, the hermetic fixture, an
// outage) is asked ONCE per row-version and not once per keystroke. Without
// that, `cursor_home`'s 60-key burst in the tmux drive harness turns into 60
// round-trips racing the keystrokes — which is a request storm dressed as a
// retry policy, and it is how this seam first broke a green harness.
//
// An explicit OPEN is the one gesture that clears the attempt (pushFrame), so
// a reader who descends into a row after a transient failure gets a fresh try
// while a cursor sweeping the board does not.

// taskDetailLoadedMsg delivers one FetchTaskDetailByID result back to the
// update loop. err is carried rather than dropped so the handler can tell "this
// row has no prose" from "this fetch failed" — the first is cacheable, the
// second is not.
type taskDetailLoadedMsg struct {
	ref string
	d   TaskDetail
	err error
}

// detailFor is the ONE reader of a task's TaskDetail inside the TUI: the
// hydrated overlay when it is current, else the snapshot's index entry, else a
// thin wrap of the board row. Both call sites (the pushed FrameTask and the
// wide preview pane) go through here so they can never disagree about which
// copy is the good one.
func (m Model) detailFor(ref string) (TaskDetail, bool) {
	row, haveRow := m.taskByID(ref)
	if d, ok := m.hydrated[ref]; ok && (!haveRow || d.Rev == row.Rev) {
		// Re-embed the LIVE row: the hydration's own card was decoded at fetch
		// time, and the snapshot's copy is the one every other surface agrees
		// with (syncDetails does exactly this for the index).
		if haveRow {
			d.Task = row
		}
		return d, true
	}
	if d, ok := m.details[ref]; ok {
		return d, true
	}
	if haveRow {
		return TaskDetail{Task: row}, true
	}
	return TaskDetail{}, false
}

// detailSubject names the ONE row whose prose is currently on screen: the
// pushed FrameTask's subject, or — at board depth in wide mode — the hovered or
// cursored row the right pane previews. "" means nothing on screen renders
// prose, so nothing needs hydrating.
func (m Model) detailSubject() string {
	if top := m.topFrame(); top.Kind == FrameTask {
		return top.Ref
	}
	if !m.wide {
		return ""
	}
	if t, ok := m.hoverPreviewTask(); ok {
		return t.DocID
	}
	if m.topFrame().Kind == FrameBoard {
		if t, ok := m.taskUnderCursor(); ok {
			return t.DocID
		}
	}
	return ""
}

// ensureTaskDetail returns the hydration command for ref, or nil when one is
// not needed or not allowed: no ref, no client, a current hydration already in
// hand, another request already in flight (property 3 above), or this exact
// row-version already asked for once.
func (m *Model) ensureTaskDetail(ref string) tea.Cmd {
	if ref == "" || m.client == nil || m.hydrating != "" {
		return nil
	}
	row, haveRow := m.taskByID(ref)
	if d, ok := m.hydrated[ref]; ok && (!haveRow || d.Rev == row.Rev) {
		return nil
	}
	if at, ok := m.attempted[ref]; ok && (!haveRow || at == row.Rev) {
		// Asked once for this row-version already. Bounded by construction.
		return nil
	}
	if m.attempted == nil {
		m.attempted = map[string]string{}
	}
	m.attempted[ref] = row.Rev
	m.hydrating = ref
	client := m.client
	return func() tea.Msg {
		d, err := FetchTaskDetailByID(client, ref)
		return taskDetailLoadedMsg{ref: ref, d: d, err: err}
	}
}

// forgetHydrationAttempt clears the once-per-row-version attempt record, so the
// next ensure will ask again. The ONE caller is an explicit frame open — see
// the file header for why a cursor sweep is not allowed to do this.
func (m *Model) forgetHydrationAttempt(ref string) {
	delete(m.attempted, ref)
}

// handleTaskDetailLoaded stores a landed hydration and clears the in-flight
// guard. A failure stores NOTHING in the overlay — see the file header.
func (m Model) handleTaskDetailLoaded(msg taskDetailLoadedMsg) (Model, tea.Cmd) {
	if m.hydrating == msg.ref {
		m.hydrating = ""
	}
	if msg.err != nil {
		return m, nil
	}
	if m.hydrated == nil {
		m.hydrated = map[string]TaskDetail{}
	}
	m.hydrated[msg.ref] = msg.d
	return m, nil
}
