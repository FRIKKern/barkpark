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

// changeMsg is pushed into the program by the apiclient change seams. Both a
// real SSE mutation frame and the NDJSON poll fallback mark the board dirty and
// (re)arm the debounce; live distinguishes them. live==true (OnChange, a real
// SSE frame) is the only thing that refreshes lastLiveEvent and so the only
// thing that can hold the ● live connection state — a poll-fallback change
// (live==false, OnChangeFallback) refetches but reads honestly as ◐ polling.
type changeMsg struct{ live bool }

// pulseMsg is pushed by the apiclient OnLivePulse seam: the SSE stream received
// a frame (the welcome event on subscribe, a `: keepalive` comment — sent every
// 30s of quiet — or a mutation), so the stream is verifiably connected right
// now. It carries no "data changed" meaning: it only refreshes lastLiveEvent
// (and upgrades a ◐ polling dot to ● live), never marks dirty and never
// refetches. This is what keeps the dot honest over a QUIET dataset — without
// it, ● live could only ever be held by mutation frames, and a healthy idle
// stream would read as polling.
type pulseMsg struct{}

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

// snapshotMsg is the result of a refetch. The connection state is NOT derived
// from what drove the fetch — applySnapshot reads the single truth of whether
// a live SSE frame was seen recently (liveIsFresh). keepStrip marks the
// reconciling refetch a successful claim/close fires itself: that snapshot IS
// the action landing, so it must not wipe the action's own confirmation off
// the strip (any other snapshot clears a stale strip + disarms the close guard).
type snapshotMsg struct {
	snap      Snapshot
	err       error
	keepStrip bool
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
func (m Model) refetchCmd(keepStrip bool) tea.Cmd {
	fetch := m.fetch
	client := m.client
	return func() tea.Msg {
		snap, err := fetch(client)
		return snapshotMsg{snap: snap, err: err, keepStrip: keepStrip}
	}
}

// --- reducers ----------------------------------------------------------------

// handleChange marks the board dirty and re-arms the debounce for BOTH a live
// SSE frame and a poll-fallback change (either way the board must refetch). It
// records the moment of the last live event ONLY when the change is live, so a
// client leaning entirely on the poll fallback never spoofs the ● live state.
func (m Model) handleChange(msg changeMsg) (Model, tea.Cmd) {
	m.dirty = true
	if msg.live {
		m.lastLiveEvent = m.now()
	}
	m.debounceGen++
	return m, m.scheduleDebounce(m.debounceGen)
}

// handlePulse records proof-of-life from the SSE stream and re-derives the
// connection state under the same single truth applySnapshot uses (liveIsFresh
// — trivially fresh right after the bump). ConnOffline is NOT upgraded: a
// failed refetch means the DATA path is broken, and only a successful fetch
// (applySnapshot) may clear that — a live stream with unreachable reads must
// keep the honest ✗. No dirty bit, no debounce, no refetch: a pulse says the
// pipe is open, not that anything changed.
func (m Model) handlePulse() (Model, tea.Cmd) {
	m.lastLiveEvent = m.now()
	if m.ui.Conn != ConnOffline {
		m.ui.Conn = ConnLive
	}
	return m, nil
}

// handleDebounce fires the coalesced refetch — but only for the newest
// generation and only if something is actually dirty.
func (m Model) handleDebounce(msg debounceMsg) (Model, tea.Cmd) {
	if msg.gen != m.debounceGen || !m.dirty {
		return m, nil
	}
	m.dirty = false
	return m, m.refetchCmd(false)
}

// handleBackstop refetches unconditionally and re-arms the ticker.
func (m Model) handleBackstop() (Model, tea.Cmd) {
	return m, tea.Batch(m.refetchCmd(false), m.scheduleBackstop())
}

// applySnapshot swaps in a freshly-rebuilt board and updates the connection
// state honestly. The state follows ONE truth — whether a real live SSE frame
// was seen within liveStale (liveIsFresh) — regardless of what drove THIS
// refetch (a live event, a debounce, or the periodic backstop):
//
//   - refetch failed      → ConnOffline, KEEP the last good board.
//   - success, live fresh → ConnLive   (a real SSE frame within liveStale).
//   - success, live stale → ConnPolling (we are leaning on the NDJSON poll).
//
// This is what makes the ●/◐ dot honest: a poll-fallback change refetches and
// swaps the board but never bumps lastLiveEvent (see handleChange), so a client
// stuck reconnecting — refreshing purely off the poll — reads ◐ polling, never
// ● live. A backstop refetch does not itself imply polling either: if a live
// frame is still recent, the stream is healthy and the state stays ● live.
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
	if m.liveIsFresh() {
		m.ui.Conn = ConnLive
	} else {
		m.ui.Conn = ConnPolling
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
	// OnChange = a real SSE mutation frame (live==true, holds ● live);
	// OnChangeFallback = the NDJSON poll fallback (live==false, reads ◐ polling);
	// OnLivePulse = any stream frame at all (welcome/keepalive/mutation), which
	// keeps ● honest while the dataset is QUIET. Wiring all three means a
	// poll-driven change still refetches, but only genuine stream traffic can
	// bump lastLiveEvent — so the connection dot never lies in either direction.
	c.OnChange = func() { p.Send(changeMsg{live: true}) }
	c.OnChangeFallback = func() { p.Send(changeMsg{live: false}) }
	c.OnLivePulse = func() { p.Send(pulseMsg{}) }
	go c.StartSSE(token)
}
