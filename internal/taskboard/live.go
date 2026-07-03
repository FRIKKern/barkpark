package taskboard

import (
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
)

// live.go owns the live-refresh loop: the SSE dirty-bit → debounced full
// refetch, the periodic backstop poll, and the honest connection state.
//
// The one iron rule (charter decision #4): events NEVER carry truth. An SSE
// frame only says "something moved"; the refetch says WHAT is true. We refetch
// the whole snapshot and rebuild the board — never apply an event payload
// incrementally — so there is no drift and no ghost rows.

// --- message types -----------------------------------------------------------

// changeMsg is pushed into the program by the apiclient OnChange seam (a real
// SSE mutation frame, or its NDJSON poll fallback). It only marks the board
// dirty and (re)arms the debounce timer.
type changeMsg struct{}

// debounceMsg fires debounceDelay after the LAST changeMsg. It carries the
// debounce generation it was scheduled under; a stale generation (a newer
// change arrived meanwhile) is ignored, so a burst of N events collapses to a
// single refetch that runs once the stream goes quiet.
type debounceMsg struct{ gen int }

// backstopMsg is the periodic ticker that refetches unconditionally. It exists
// to survive a silently-dropped SSE stream: even if no OnChange ever fires, the
// board still refreshes every backstopEvery, and the connection state honestly
// degrades to ConnPolling when no live event has been seen recently.
type backstopMsg struct{}

// actionResultMsg carries the outcome of a claim/close command back to the
// update loop (the act verbs run off-loop so the network never blocks a
// keystroke). handleActionResult renders res on the strip and, on success,
// fires the reconciling refetch.
type actionResultMsg struct{ res ActionResult }

// snapshotMsg is the result of a refetch. viaBackstop records whether the
// periodic ticker (not a live event) drove it, which is what lets applySnapshot
// distinguish ConnLive from ConnPolling honestly. keepStrip marks the
// reconciling refetch a successful claim/close fires itself: that snapshot IS
// the action landing, so it must not wipe the action's own confirmation off
// the strip (any other snapshot clears a stale strip + disarms the close guard).
type snapshotMsg struct {
	snap        Snapshot
	err         error
	viaBackstop bool
	keepStrip   bool
}

// --- commands ----------------------------------------------------------------

// scheduleDebounce arms a one-shot timer tagged with the current generation.
func (m Model) scheduleDebounce(gen int) tea.Cmd {
	d := m.debounceDelay
	return tea.Tick(d, func(time.Time) tea.Msg { return debounceMsg{gen: gen} })
}

// scheduleBackstop arms the next periodic backstop tick. It reschedules itself
// from the backstopMsg handler, so the ticker runs for the life of the program.
func (m Model) scheduleBackstop() tea.Cmd {
	d := m.backstopEvery
	return tea.Tick(d, func(time.Time) tea.Msg { return backstopMsg{} })
}

// refetchCmd runs the (injectable) snapshot fetch off the update loop and
// delivers the result as a snapshotMsg. The fetch is captured by value so the
// command is self-contained and safe to run concurrently with further updates.
// keepStrip is set only by the post-action reconcile (see snapshotMsg).
func (m Model) refetchCmd(viaBackstop, keepStrip bool) tea.Cmd {
	fetch := m.fetch
	client := m.client
	return func() tea.Msg {
		snap, err := fetch(client)
		return snapshotMsg{snap: snap, err: err, viaBackstop: viaBackstop, keepStrip: keepStrip}
	}
}

// --- reducers ----------------------------------------------------------------

// handleChange marks the board dirty, records the moment of the last live
// event (so the backstop can tell live from polling), and re-arms the debounce.
func (m Model) handleChange() (Model, tea.Cmd) {
	m.dirty = true
	m.lastLiveEvent = m.now()
	m.debounceGen++
	return m, m.scheduleDebounce(m.debounceGen)
}

// handleDebounce fires the coalesced refetch — but only for the newest
// generation and only if something is actually dirty.
func (m Model) handleDebounce(msg debounceMsg) (Model, tea.Cmd) {
	if msg.gen != m.debounceGen || !m.dirty {
		return m, nil
	}
	m.dirty = false
	return m, m.refetchCmd(false, false)
}

// handleBackstop refetches unconditionally and re-arms the ticker.
func (m Model) handleBackstop() (Model, tea.Cmd) {
	return m, tea.Batch(m.refetchCmd(true, false), m.scheduleBackstop())
}

// applySnapshot swaps in a freshly-rebuilt board and updates the connection
// state honestly:
//
//   - refetch failed              → ConnOffline, KEEP the last good board.
//   - change-driven success       → ConnLive.
//   - backstop success, live seen  → ConnLive (SSE is still healthy).
//   - backstop success, stale/none → ConnPolling (we are leaning on the poll).
//
// Two in-flight refetches (a debounce racing the backstop) can complete out of
// order; a success frame older than what is already on screen is dropped so
// slow responses never roll the board backward. The selection follows the TASK
// (its doc id), not the raw cursor index — a live board reorders itself on
// every refresh, and the highlight silently hopping to a different task on
// each SSE frame would make the pane unusable while it breathes.
func (m Model) applySnapshot(msg snapshotMsg) (Model, tea.Cmd) {
	if msg.err != nil {
		m.ui.Conn = ConnOffline
		return m, nil
	}
	if !m.ui.LastSync.IsZero() && msg.snap.FetchedAt.Before(m.ui.LastSync) {
		return m, nil
	}
	var selected string
	if r, ok := m.currentRow(); ok {
		selected = r.docID
	}
	// Recompute repo correlation against the fresh task set BEFORE building, so
	// the "↳ git" badges and epic-rank boost track the tasks as they move. Pure
	// and cheap; a no-op (empty Mentioned) outside a git repo.
	m.repo = CorrelateRepo(m.subjects, m.branch, m.repoName, msg.snap.Tasks)
	m.board = m.build(msg.snap, m.repo, m.now())
	m.ui.LastSync = msg.snap.FetchedAt
	if !msg.keepStrip {
		// A landed snapshot clears any transient strip AND disarms the close
		// guard: the arm-prompt is the guard's only visible face, so the two
		// must never part ways (an invisibly-armed x firing a close on the next
		// press would be a trap). The one exception is the reconciling refetch a
		// successful action fired itself — wiping its own confirmation within
		// the network round-trip would make every success flash unreadably.
		m.ui.Strip = ActionStrip{}
		m.pendingClose = ""
	}
	if msg.viaBackstop && !m.liveIsFresh() {
		m.ui.Conn = ConnPolling
	} else {
		m.ui.Conn = ConnLive
	}
	if selected != "" {
		for i, r := range m.visibleRows() {
			if r.docID == selected {
				m.ui.Cursor = i
				break
			}
		}
	}
	m.clampCursor()
	return m, nil
}

// liveIsFresh reports whether a live SSE event has been seen recently enough to
// still trust the stream. lastLiveEvent's zero value (no event ever) is never
// fresh, so a program that never gets a single frame reads honestly as polling.
func (m Model) liveIsFresh() bool {
	if m.lastLiveEvent.IsZero() {
		return false
	}
	return m.now().Sub(m.lastLiveEvent) <= m.liveStale
}

// wireLive connects the apiclient change seam to a running program and starts
// the SSE listener. The listener loops for the life of the process (it has no
// stop channel — the program owning it exits the whole binary), exactly like
// the desk TUI's live wiring. Split out so Run stays readable and this seam can
// be exercised against an httptest server in tests.
func wireLive(p *tea.Program, c *apiclient.Client, token string) {
	c.OnChange = func() { p.Send(changeMsg{}) }
	go c.StartSSE(token)
}
