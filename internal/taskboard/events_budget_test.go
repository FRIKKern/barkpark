package taskboard

import (
	"sort"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// events_budget_test.go is the BEFORE/AFTER measurement, not an assertion about
// shapes: it runs one board for 60 simulated seconds against a real httptest
// server and counts what the server actually received.
//
// Both arms run the SAME code. The "before" arm is the legacy loop, still
// present and reachable as the eventsOff fallback (SSE burst → 750ms debounce →
// full refetch, plus an unconditional backstop at the old 30s cadence); the
// "after" arm is the keyset poll. Making the before a code path rather than a
// reconstruction is the point — a hand-written "this is what it used to do"
// simulation would measure the test author, not the board.
//
// TIME IS SIMULATED, REQUESTS ARE REAL. The clock is injected and the timer seam
// (Model.tick) records the delay the loop ARMED — read back, never re-derived —
// so the schedule walked here is the schedule the code chose. Only the waiting
// is fake.

// simTimer is the recording timer seam. It captures every armed tick with the
// delay the loop asked for and the message it will produce.
type simTimer struct {
	clock *time.Time
	due   []simTick
	seq   int
}

type simTick struct {
	at  time.Time
	seq int
	fn  func(time.Time) tea.Msg
}

func (s *simTimer) tick(d time.Duration, fn func(time.Time) tea.Msg) tea.Cmd {
	s.seq++
	s.due = append(s.due, simTick{at: s.clock.Add(d), seq: s.seq, fn: fn})
	// The timer itself produces no immediate message; the driver fires it when
	// the simulated clock reaches it.
	return nil
}

// pop returns the earliest armed tick at or before deadline, removing it.
func (s *simTimer) pop(deadline time.Time) (simTick, bool) {
	if len(s.due) == 0 {
		return simTick{}, false
	}
	sort.SliceStable(s.due, func(i, j int) bool {
		if s.due[i].at.Equal(s.due[j].at) {
			return s.due[i].seq < s.due[j].seq
		}
		return s.due[i].at.Before(s.due[j].at)
	})
	if s.due[0].at.After(deadline) {
		return simTick{}, false
	}
	t := s.due[0]
	s.due = s.due[1:]
	return t, true
}

// budgetRun drives one board for `window` simulated seconds and returns the
// server's request tally. sseEvery is how often a dataset SSE frame arrives (0 =
// a quiet dataset); legacy selects the pre-change loop.
func budgetRun(t *testing.T, cs *countingServer, window, sseEvery time.Duration, legacy bool) map[string]int {
	t.Helper()

	start := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	clock := start
	timer := &simTimer{clock: &clock}

	m := newModel(cs.client(), "", Config{BaseURL: cs.srv.URL})
	m.now = func() time.Time { return clock }
	m.tick = timer.tick
	if legacy {
		// The pre-change board: no keyset feed, the old 30s backstop.
		m.eventsOff = true
		m.backstopEvery = 30 * time.Second
	}

	// run applies a command's messages back through the reducer, exactly as the
	// tea runtime would, until the batch is drained.
	var run func(cmd tea.Cmd)
	run = func(cmd tea.Cmd) {
		for _, msg := range runCmd(cmd) {
			next, out := m.reduce(msg)
			if mm, ok := next.(Model); ok {
				m = mm
			}
			run(out)
		}
	}

	// Init: the full first load plus whatever tickers the loop arms.
	run(m.Init())

	deadline := start.Add(window)
	nextSSE := start
	if sseEvery > 0 {
		nextSSE = start.Add(sseEvery)
	}
	for {
		tick, ok := timer.pop(deadline)
		haveSSE := sseEvery > 0 && !nextSSE.After(deadline)
		switch {
		case ok && (!haveSSE || !nextSSE.Before(tick.at)):
			clock = tick.at
			run(func() tea.Msg { return tick.fn(clock) })
		case haveSSE:
			clock = nextSSE
			nextSSE = nextSSE.Add(sseEvery)
			run(func() tea.Msg { return changeMsg{live: true} })
		default:
			return cs.snapshotCounts()
		}
	}
}

// TestRequestBudget_60s is the number the PR body quotes. Two datasets — one
// quiet, one moving at the campaign cadence measured on guerrilla — each run
// through the legacy loop and the keyset loop.
func TestRequestBudget_60s(t *testing.T) {
	const window = 60 * time.Second

	// The measured campaign cadence: 219 prime requests / 3 boards / 300s is one
	// refetch every ~4.1s per board, and each SSE frame on a busy dataset is what
	// drove it.
	const busySSE = 4 * time.Second

	type arm struct {
		name   string
		sse    time.Duration
		legacy bool
		// feed pages the server hands out. Empty = a caught-up feed (a dataset
		// where nothing TASK-shaped moved).
		pages []TaskEventsPage
	}
	arms := []arm{
		{name: "idle/legacy", sse: 0, legacy: true},
		{name: "idle/keyset", sse: 0},
		{name: "busy/legacy", sse: busySSE, legacy: true},
		// A busy dataset whose SSE traffic is NOT task writes — the case the
		// keyset feed exists to tell apart, and the one the old loop could not.
		{name: "busy-nontask/keyset", sse: busySSE},
		// A genuinely moving task ledger: every poll finds an event.
		{name: "busy-task/keyset", sse: busySSE, pages: movingFeed(200)},
	}

	got := map[string]map[string]int{}
	for _, a := range arms {
		cs := newCountingServer(t, a.pages...)
		got[a.name] = budgetRun(t, cs, window, a.sse, a.legacy)
		t.Logf("%-22s tasks=%d prime=%d in_progress=%d events=%d",
			a.name, got[a.name]["tasks"], got[a.name]["prime"],
			got[a.name]["tasks_in_progress"], got[a.name]["events"])
	}

	// The heavy pair is what costs the server: the ~9 MB list and prime's seq
	// scan. Assert the reduction, not the exact number, so the test measures a
	// property rather than pinning a constant that a retune would falsify.
	for _, pair := range [][2]string{
		{"idle/legacy", "idle/keyset"},
		{"busy/legacy", "busy-nontask/keyset"},
		{"busy/legacy", "busy-task/keyset"},
	} {
		before, after := got[pair[0]]["prime"], got[pair[1]]["prime"]
		if after >= before {
			t.Fatalf("%s → %s: prime requests did not fall (%d → %d)", pair[0], pair[1], before, after)
		}
	}

	// An idle board must cost ZERO heavy requests after its first load.
	if n := got["idle/keyset"]["prime"]; n != 1 {
		t.Fatalf("an idle board made %d prime requests in 60s, want 1 (the initial load only)", n)
	}
	if n := got["idle/keyset"]["tasks"]; n != 1 {
		t.Fatalf("an idle board made %d list requests in 60s, want 1 (the initial load only)", n)
	}
	// A dataset whose SSE traffic touches no task must also cost nothing extra:
	// this is the whole reason the poll asks the TASK feed and not the SSE bit.
	if n := got["busy-nontask/keyset"]["prime"]; n != 1 {
		t.Fatalf("a board on a busy NON-TASK dataset made %d prime requests in 60s, want 1", n)
	}
	// And even a ledger moving on every poll is floored by the 2s interval.
	if n := got["busy-task/keyset"]["prime"]; n > int(window/basePollEvery)+1 {
		t.Fatalf("a constantly-moving ledger made %d prime requests in 60s, want at most %d (one per %v floor + the initial load)",
			n, int(window/basePollEvery)+1, basePollEvery)
	}
}

// TestRequestBudget_5min re-runs the same arms over the window the guerrilla
// reading was taken across (2026-09-01T21:43-21:46Z, five minutes, three boards
// → 360 GET /v1/tasks + 219 GET /v1/tasks/prime). It asserts nothing new — it is
// the number the PR body quotes at the measured scale, where the backstop's
// contribution to the old loop is visible (10 unconditional triples per board
// per 5 minutes, before a single SSE frame).
func TestRequestBudget_5min(t *testing.T) {
	const window = 5 * time.Minute
	const busySSE = 4 * time.Second

	for _, a := range []struct {
		name   string
		sse    time.Duration
		legacy bool
		pages  []TaskEventsPage
	}{
		{name: "idle/legacy", legacy: true},
		{name: "idle/keyset"},
		{name: "busy/legacy", sse: busySSE, legacy: true},
		{name: "busy-nontask/keyset", sse: busySSE},
		{name: "busy-task/keyset", sse: busySSE, pages: movingFeed(400)},
	} {
		cs := newCountingServer(t, a.pages...)
		got := budgetRun(t, cs, window, a.sse, a.legacy)
		t.Logf("%-22s tasks=%d prime=%d in_progress=%d events=%d  (heavy requests total=%d)",
			a.name, got["tasks"], got["prime"], got["tasks_in_progress"], got["events"],
			got["tasks"]+got["prime"]+got["tasks_in_progress"])
	}
}

// movingFeed scripts n pages that each carry one event and are never full, so
// every poll reports a delta without ever entering the catch-up walk.
func movingFeed(n int) []TaskEventsPage {
	pages := make([]TaskEventsPage, 0, n)
	for i := 1; i <= n; i++ {
		pages = append(pages, TaskEventsPage{OK: true, Events: []TaskEvent{{ID: int64(i)}}, Cursor: int64(i)})
	}
	return pages
}
