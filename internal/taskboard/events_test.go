package taskboard

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// events_test.go pins the board's request budget (task-e2f5ecca0be9a6d1). The
// measured defect was a COUNT — three open boards produced 360 GET /v1/tasks +
// 219 GET /v1/tasks/prime in five minutes — so the tests that matter here count
// requests against a real httptest server rather than asserting on shapes.

// --- the interval ladder -----------------------------------------------------

func TestNextPollInterval_Ladder(t *testing.T) {
	// The whole adaptive schedule as a table: 2s after a delta, doubling while
	// idle, hard-capped at 30s, and back to 2s the moment anything moves.
	cases := []struct {
		name  string
		cur   time.Duration
		delta bool
		want  time.Duration
	}{
		{"start idle", basePollEvery, false, 4 * time.Second},
		{"4s idle", 4 * time.Second, false, 8 * time.Second},
		{"8s idle", 8 * time.Second, false, 16 * time.Second},
		{"16s idle doubles to the ceiling", 16 * time.Second, false, 30 * time.Second},
		{"at the ceiling it stays", 30 * time.Second, false, 30 * time.Second},
		{"ceiling + delta snaps back", 30 * time.Second, true, basePollEvery},
		{"base + delta stays at base", basePollEvery, true, basePollEvery},
		{"a sub-base current is floored, not halved", 10 * time.Millisecond, false, basePollEvery},
		{"zero current is floored", 0, false, basePollEvery},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := nextPollInterval(c.cur, c.delta); got != c.want {
				t.Fatalf("nextPollInterval(%v, delta=%v) = %v, want %v", c.cur, c.delta, got, c.want)
			}
		})
	}
}

func TestNextPollInterval_CeilingIsNeverExceeded(t *testing.T) {
	// Walk the ladder from the floor for far longer than it takes to saturate:
	// the doubling must clamp, not overflow past 30s on some later step.
	d := basePollEvery
	for i := 0; i < 40; i++ {
		d = nextPollInterval(d, false)
		if d > maxPollEvery {
			t.Fatalf("interval exceeded the ceiling on step %d: %v > %v", i, d, maxPollEvery)
		}
	}
	if d != maxPollEvery {
		t.Fatalf("interval settled at %v, want the ceiling %v", d, maxPollEvery)
	}
}

// --- the request-count contract ---------------------------------------------

// countingServer answers the board's whole fetch surface and tallies every
// route. It is THE instrument for this PR: the claim is about how many requests
// the loop makes, and only a server can testify to that.
type countingServer struct {
	mu     sync.Mutex
	counts map[string]int
	// events is the scripted feed: pop one page per poll, and once the script is
	// exhausted answer "caught up" forever (cursor echoed, no events).
	events []TaskEventsPage
	srv    *httptest.Server
}

func newCountingServer(t *testing.T, pages ...TaskEventsPage) *countingServer {
	t.Helper()
	cs := &countingServer{counts: map[string]int{}, events: pages}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/tasks/events", func(w http.ResponseWriter, r *http.Request) {
		cs.bump("events")
		page := cs.nextPage()
		w.Header().Set("Content-Type", "application/json")
		evs := "["
		for i, e := range page.Events {
			if i > 0 {
				evs += ","
			}
			evs += fmt.Sprintf(`{"id":%d,"event":"task.claim","doc_id":"t-%d","rev":"r","at":"2026-08-01T00:00:00Z"}`, e.ID, e.ID)
		}
		evs += "]"
		fmt.Fprintf(w, `{"ok":true,"events":%s,"cursor":%d,"has_more":%t}`, evs, page.Cursor, page.HasMore)
	})
	mux.HandleFunc("/v1/tasks/prime", func(w http.ResponseWriter, r *http.Request) {
		cs.bump("prime")
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true,"counts":{"open":1},"ready":[],"recent_events":[]}`)
	})
	mux.HandleFunc("/v1/tasks", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("lifecycle_status") == "in_progress" {
			cs.bump("tasks_in_progress")
		} else {
			cs.bump("tasks")
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true,"docs":[{"doc_id":"t-1","title":"One","lifecycle_status":"open","kind":"task"}]}`)
	})
	cs.srv = httptest.NewServer(mux)
	t.Cleanup(cs.srv.Close)
	return cs
}

func (cs *countingServer) bump(route string) {
	cs.mu.Lock()
	cs.counts[route]++
	cs.mu.Unlock()
}

func (cs *countingServer) nextPage() TaskEventsPage {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	if len(cs.events) == 0 {
		return TaskEventsPage{OK: true, Cursor: 0}
	}
	p := cs.events[0]
	cs.events = cs.events[1:]
	return p
}

// snapshotCounts is the tally as a plain map, taken under the lock.
func (cs *countingServer) snapshotCounts() map[string]int {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	out := make(map[string]int, len(cs.counts))
	for k, v := range cs.counts {
		out[k] = v
	}
	return out
}

func (cs *countingServer) get(route string) int {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.counts[route]
}

func (cs *countingServer) client() *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: cs.srv.URL})
}

// runCmd executes a tea.Cmd to completion (batches included) and returns every
// message it produced, so a test can drive the loop one hop at a time without a
// tea.Program and without any wall-clock waiting.
func runCmd(cmd tea.Cmd) []tea.Msg {
	if cmd == nil {
		return nil
	}
	msg := cmd()
	switch m := msg.(type) {
	case tea.BatchMsg:
		var out []tea.Msg
		for _, c := range m {
			out = append(out, runCmd(c)...)
		}
		return out
	case nil:
		return nil
	default:
		return []tea.Msg{msg}
	}
}

// pollModel is a Model wired to a real server through the real seams, with the
// clock injected so elapsed is deterministic — and with the TIMER seam replaced
// by one that fires immediately. The real tea.Tick would make these tests SLEEP
// the whole interval ladder (2s→30s per hop); the requests being counted are
// still real, only the waiting is not.
func pollModel(cs *countingServer, clock func() time.Time) Model {
	m := newModel(cs.client(), "", Config{BaseURL: cs.srv.URL})
	m.now = clock
	m.tick = func(_ time.Duration, fn func(time.Time) tea.Msg) tea.Cmd {
		return func() tea.Msg { return fn(clock()) }
	}
	return m
}

// TestDebounceNudgesThePollNotTheHeavyPair pins the new coalescing contract: an
// SSE burst no longer buys a snapshot refetch, it buys ONE cheap question. This
// is the half of the change that a shape test can see — the request counts are
// in TestPoll_NoDelta_DoesNotReList and the budget runs.
func TestDebounceNudgesThePollNotTheHeavyPair(t *testing.T) {
	cs := newCountingServer(t)
	m := pollModel(cs, steadyClock())

	m, _ = m.handleChange(changeMsg{live: true})
	if !m.dirty {
		t.Fatal("an SSE change did not mark the board dirty")
	}
	m, cmd := m.handleDebounce(debounceMsg{gen: m.debounceGen})
	if cmd == nil {
		t.Fatal("the debounce produced no command")
	}
	for _, out := range runCmd(cmd) {
		if _, ok := out.(snapshotMsg); ok {
			t.Fatal("an SSE change fired the heavy list+prime pair directly — it must ask the feed first")
		}
	}
	if got := cs.get("tasks"); got != 0 {
		t.Fatalf("GET /v1/tasks = %d from one SSE frame, want 0", got)
	}
	if m.pollEvery != basePollEvery {
		t.Fatalf("interval after an SSE nudge = %v, want the floor %v", m.pollEvery, basePollEvery)
	}
}

// steadyClock never advances, so every poll measures as instantaneous — the
// "server is healthy" case.
func steadyClock() func() time.Time {
	at := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	return func() time.Time { return at }
}

func TestPoll_NoDelta_DoesNotReList(t *testing.T) {
	// THE CORE CLAIM. A caught-up feed must produce ZERO list and ZERO prime
	// requests, no matter how many times the loop ticks. Before this change the
	// equivalent path was an unconditional refetch per tick.
	cs := newCountingServer(t)
	m := pollModel(cs, steadyClock())

	const ticks = 10
	for i := 0; i < ticks; i++ {
		nm, cmd := m.handleEventsPoll(eventsPollMsg{gen: m.eventsGen})
		m = nm
		msgs := runCmd(cmd)
		if len(msgs) != 1 {
			t.Fatalf("tick %d: poll produced %d messages, want 1", i, len(msgs))
		}
		res, ok := msgs[0].(eventsResultMsg)
		if !ok {
			t.Fatalf("tick %d: poll produced %T, want eventsResultMsg", i, msgs[0])
		}
		if res.err != nil {
			t.Fatalf("tick %d: poll failed: %v", i, res.err)
		}
		// Run whatever the result armed. Discarding it would make the request
		// counts below VACUOUS: a re-list the test never executes cannot be
		// counted, and the assertion would stay green through the exact
		// regression it exists to catch.
		nm2, cmd2 := m.handleEventsResult(res)
		m = nm2
		for _, out := range runCmd(cmd2) {
			if snap, ok := out.(snapshotMsg); ok {
				m, _ = m.applySnapshot(snap)
			}
		}
	}

	if got := cs.get("events"); got != ticks {
		t.Fatalf("events polls = %d, want %d", got, ticks)
	}
	if got := cs.get("tasks"); got != 0 {
		t.Fatalf("GET /v1/tasks = %d over %d idle ticks, want 0 — a no-delta tick must not re-list", got, ticks)
	}
	if got := cs.get("prime"); got != 0 {
		t.Fatalf("GET /v1/tasks/prime = %d over %d idle ticks, want 0", got, ticks)
	}
	// And the interval must have backed off to the ceiling rather than sitting
	// at the floor burning a poll every 2s forever.
	if m.pollEvery != maxPollEvery {
		t.Fatalf("interval after %d idle ticks = %v, want the ceiling %v", ticks, m.pollEvery, maxPollEvery)
	}
}

func TestPoll_Delta_ReListsExactlyOnce(t *testing.T) {
	// One event on the feed → exactly one snapshot refetch (which is the
	// list+prime+in-flight triple), and then silence again while the feed is
	// caught up. Not zero (the board must actually refresh) and not one per
	// subsequent tick (the storm).
	cs := newCountingServer(t, TaskEventsPage{OK: true, Events: []TaskEvent{{ID: 7}}, Cursor: 7})
	m := pollModel(cs, steadyClock())

	relists := 0
	for i := 0; i < 5; i++ {
		nm, cmd := m.handleEventsPoll(eventsPollMsg{gen: m.eventsGen})
		m = nm
		res := firstEventsResult(t, runCmd(cmd))
		nm2, cmd2 := m.handleEventsResult(res)
		m = nm2
		for _, out := range runCmd(cmd2) {
			if snap, ok := out.(snapshotMsg); ok {
				relists++
				m, _ = m.applySnapshot(snap)
			}
		}
	}

	if relists != 1 {
		t.Fatalf("re-lists = %d over 5 ticks with ONE event, want exactly 1", relists)
	}
	if got := cs.get("tasks"); got != 1 {
		t.Fatalf("GET /v1/tasks = %d, want 1", got)
	}
	if got := cs.get("prime"); got != 1 {
		t.Fatalf("GET /v1/tasks/prime = %d, want 1", got)
	}
	if m.eventCursor != 7 {
		t.Fatalf("cursor = %d, want 7 — the delta must advance the resume point", m.eventCursor)
	}
}

func TestPoll_DrainWalksPagesWithoutReListingPerPage(t *testing.T) {
	// A cold cursor (0) sits behind the whole backlog. The catch-up walk must
	// page forward WITHOUT re-listing per page — the one re-list is owed at the
	// end. Three full pages then a final empty one: 4 polls, 1 re-list.
	cs := newCountingServer(t,
		TaskEventsPage{OK: true, Events: []TaskEvent{{ID: 100}}, Cursor: 100, HasMore: true},
		TaskEventsPage{OK: true, Events: []TaskEvent{{ID: 200}}, Cursor: 200, HasMore: true},
		TaskEventsPage{OK: true, Events: []TaskEvent{{ID: 300}}, Cursor: 300, HasMore: true},
		TaskEventsPage{OK: true, Cursor: 300},
	)
	m := pollModel(cs, steadyClock())

	relists := 0
	for i := 0; i < 4; i++ {
		nm, cmd := m.handleEventsPoll(eventsPollMsg{gen: m.eventsGen})
		m = nm
		res := firstEventsResult(t, runCmd(cmd))
		nm2, cmd2 := m.handleEventsResult(res)
		m = nm2
		for _, out := range runCmd(cmd2) {
			if snap, ok := out.(snapshotMsg); ok {
				relists++
				m, _ = m.applySnapshot(snap)
			}
		}
		if i < 3 && relists != 0 {
			t.Fatalf("re-listed during the catch-up walk at page %d — the walk must be list-free", i)
		}
	}
	if relists != 1 {
		t.Fatalf("re-lists after a 3-page drain = %d, want exactly 1", relists)
	}
	if m.eventCursor != 300 {
		t.Fatalf("cursor after the drain = %d, want 300", m.eventCursor)
	}
	if m.drainOwed || m.drainPages != 0 {
		t.Fatalf("drain state not cleared: owed=%v pages=%d", m.drainOwed, m.drainPages)
	}
}

func TestPoll_SlowRead_RendersPausedWithRetryTime(t *testing.T) {
	// A read that blows the 2s budget is a server telling us it is queueing.
	// The board must SAY so, name the retry time, back off — and NOT consume the
	// read (no cursor advance, no re-list), so nothing is silently dropped.
	at := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	cs := newCountingServer(t, TaskEventsPage{OK: true, Events: []TaskEvent{{ID: 9}}, Cursor: 9})
	m := pollModel(cs, func() time.Time { return at })
	m.ui.LastSync = at.Add(-time.Minute) // past the syncing… first paint

	slow := eventsResultMsg{
		gen:     m.eventsGen,
		page:    TaskEventsPage{OK: true, Events: []TaskEvent{{ID: 9}}, Cursor: 9},
		elapsed: 3 * time.Second,
	}
	m, cmd := m.handleEventsResult(slow)

	if !m.ui.Paused {
		t.Fatal("a 3s read did not raise the paused state")
	}
	if m.ui.RetryAt.IsZero() {
		t.Fatal("paused with no retry time — the operator cannot tell waiting from wedged")
	}
	if want := at.Add(m.pollEvery); !m.ui.RetryAt.Equal(want) {
		t.Fatalf("RetryAt = %v, want now+interval %v", m.ui.RetryAt, want)
	}
	if m.pollEvery != 4*time.Second {
		t.Fatalf("interval after a slow read = %v, want it backed off to 4s", m.pollEvery)
	}
	if m.eventCursor != 0 {
		t.Fatalf("a slow read advanced the cursor to %d — it must not be consumed", m.eventCursor)
	}
	for _, out := range runCmd(cmd) {
		if _, ok := out.(snapshotMsg); ok {
			t.Fatal("a slow read fired a re-list — paused means paused")
		}
	}

	// And it must be VISIBLE, with the retry time, in the identity strip.
	line := headerLine1(m.ui, 120, at)
	if !strings.Contains(ansi.Strip(line), pausedLabel) {
		t.Fatalf("header did not render the paused state: %q", ansi.Strip(line))
	}
	if !strings.Contains(ansi.Strip(line), "retry in 4s") {
		t.Fatalf("header did not render the retry time: %q", ansi.Strip(line))
	}

	// A healthy read clears it again.
	m, _ = m.handleEventsResult(eventsResultMsg{gen: m.eventsGen, page: TaskEventsPage{OK: true, Cursor: 9}})
	if m.ui.Paused || !m.ui.RetryAt.IsZero() {
		t.Fatal("a healthy read did not clear the paused state")
	}
}

func TestPoll_ErrorBacksOffAndDoesNotStorm(t *testing.T) {
	// An erroring feed must back off exactly as an idle one does — never retry
	// at the floor forever, and never re-list on the way.
	m := pollModel(newCountingServer(t), steadyClock())
	for i := 0; i < 6; i++ {
		var cmd tea.Cmd
		m, cmd = m.handleEventsResult(eventsResultMsg{gen: m.eventsGen, err: errors.New("boom")})
		for _, out := range runCmd(cmd) {
			if _, ok := out.(snapshotMsg); ok {
				t.Fatalf("errored poll %d fired a re-list", i)
			}
		}
		if !m.ui.Paused {
			t.Fatalf("errored poll %d did not raise the paused state", i)
		}
	}
	if m.pollEvery != maxPollEvery {
		t.Fatalf("interval after 6 errors = %v, want the ceiling %v", m.pollEvery, maxPollEvery)
	}
}

func TestPoll_NoOverlappingReads(t *testing.T) {
	// A slow tick must not queue another. While a read is in flight the chain
	// holds no timer, and a stray tick under the live generation is dropped —
	// not answered with a second read.
	cs := newCountingServer(t)
	m := pollModel(cs, steadyClock())

	m, cmd := m.handleEventsPoll(eventsPollMsg{gen: m.eventsGen})
	if cmd == nil {
		t.Fatal("first tick produced no read")
	}
	if !m.pollInFlight {
		t.Fatal("first tick did not mark the read in flight")
	}
	m2, cmd2 := m.handleEventsPoll(eventsPollMsg{gen: m.eventsGen})
	if cmd2 != nil {
		t.Fatal("a tick arriving while a read is in flight started a SECOND read")
	}
	_ = m2

	// The nudge path has the same duty: it must not start a read either.
	nudge := (&m).nudgePoll()
	if nudge != nil {
		t.Fatal("nudgePoll started a read while one was already in flight")
	}
	if !m.pollNudged {
		t.Fatal("nudgePoll during a read did not record the nudge for armNextPoll")
	}
	// …and the recorded nudge must collapse the NEXT arm to the floor.
	m.pollEvery = maxPollEvery
	m, _ = m.handleEventsResult(eventsResultMsg{gen: m.eventsGen, page: TaskEventsPage{OK: true, Cursor: 0}})
	if m.pollNudged {
		t.Fatal("the nudge was not consumed by armNextPoll")
	}
	if m.pollEvery != basePollEvery {
		t.Fatalf("interval after a nudged result = %v, want the floor %v", m.pollEvery, basePollEvery)
	}
}

func TestTickRefetch_DropsRatherThanQueues(t *testing.T) {
	// The heavy read has the same no-overlap rule: a delta landing while a
	// snapshot fetch is still out is DROPPED, not stacked behind it.
	m := pollModel(newCountingServer(t), steadyClock())
	m.fetchInFlight = true
	if cmd := m.tickRefetchCmd(); cmd != nil {
		t.Fatal("a tick queued a second snapshot fetch while one was in flight")
	}
	// applySnapshot releases the gate on EVERY arm, error included.
	m, _ = m.applySnapshot(snapshotMsg{err: errors.New("read failed")})
	if m.fetchInFlight {
		t.Fatal("a failed snapshot left the re-list gate stuck shut — the board would wedge on the backstop")
	}
	if cmd := m.tickRefetchCmd(); cmd == nil {
		t.Fatal("the gate did not reopen after the fetch completed")
	}
}

func TestBackstopIsTheSafetyNetNotTheRefreshPath(t *testing.T) {
	// The 30s unconditional list+prime pair was the board's floor cost. Pin the
	// retime so it cannot silently drift back.
	if defaultBackstopEvery < 5*time.Minute {
		t.Fatalf("backstop is %v — it is the safety net now, not the refresh path (the keyset poll is)", defaultBackstopEvery)
	}
}

func TestManualRefresh_ReListsAndCollapsesTheInterval(t *testing.T) {
	// `r` on a board parked at the 30s idle ceiling: one immediate re-list AND
	// the interval back at the floor.
	cs := newCountingServer(t)
	m := pollModel(cs, steadyClock())
	m.pollEvery = maxPollEvery
	m.ui.Paused = true
	m.ui.RetryAt = m.now().Add(maxPollEvery)

	m, cmd := m.manualRefresh()
	if m.pollEvery != basePollEvery {
		t.Fatalf("interval after r = %v, want the floor %v", m.pollEvery, basePollEvery)
	}
	if m.ui.Paused || !m.ui.RetryAt.IsZero() {
		t.Fatal("r did not clear the stale paused state")
	}
	sawSnapshot, sawPoll := false, false
	for _, out := range runCmd(cmd) {
		switch out.(type) {
		case snapshotMsg:
			sawSnapshot = true
		case eventsPollMsg:
			sawPoll = true
		}
	}
	if !sawSnapshot {
		t.Fatal("r did not fire a full re-list")
	}
	if !sawPoll {
		t.Fatal("r did not re-arm the poll chain at the floor")
	}
	if got := cs.get("tasks"); got != 1 {
		t.Fatalf("GET /v1/tasks after r = %d, want 1", got)
	}
}

// --- the wire contract -------------------------------------------------------

func TestFetchTaskEvents_SendsCursorAndDecodes(t *testing.T) {
	var gotSince, gotLimit string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotSince = r.URL.Query().Get("since")
		gotLimit = r.URL.Query().Get("limit")
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true,"events":[{"id":42,"event":"task.closed","doc_id":"task-a","rev":"r1","at":"2026-08-01T00:00:00Z"}],"cursor":42,"has_more":true}`)
	}))
	defer srv.Close()

	page, err := FetchTaskEvents(apiclient.New(apiclient.Config{BaseURL: srv.URL}), 41, 0)
	if err != nil {
		t.Fatalf("FetchTaskEvents: %v", err)
	}
	if gotSince != "41" {
		t.Fatalf("since = %q, want 41 — the cursor IS the request", gotSince)
	}
	if gotLimit != "500" {
		t.Fatalf("limit = %q, want the server page maximum 500", gotLimit)
	}
	if len(page.Events) != 1 || page.Events[0].ID != 42 || page.Events[0].DocID != "task-a" {
		t.Fatalf("decoded events = %+v", page.Events)
	}
	if page.Cursor != 42 || !page.HasMore {
		t.Fatalf("cursor=%d has_more=%v, want 42/true", page.Cursor, page.HasMore)
	}
}

func TestFetchTaskEvents_RefusesABodyWithNoEnvelope(t *testing.T) {
	// A 200 that is not the feed (an older server, a proxy's own JSON) must be a
	// REFUSAL. Reading it as "caught up at 0" would restart the catch-up walk on
	// every poll — a storm dressed as a quiet board.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"message":"not the feed"}`)
	}))
	defer srv.Close()

	if _, err := FetchTaskEvents(apiclient.New(apiclient.Config{BaseURL: srv.URL}), 0, 10); err == nil {
		t.Fatal("an envelope-less 200 was accepted as an empty page")
	}
}

func TestFetchTaskEvents_NeverMovesTheCursorBackward(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true,"events":[],"cursor":3,"has_more":false}`)
	}))
	defer srv.Close()

	page, err := FetchTaskEvents(apiclient.New(apiclient.Config{BaseURL: srv.URL}), 99, 10)
	if err != nil {
		t.Fatalf("FetchTaskEvents: %v", err)
	}
	if page.Cursor != 99 {
		t.Fatalf("cursor regressed to %d from since=99 — history would replay forever", page.Cursor)
	}
}

// --- cursor persistence ------------------------------------------------------

func TestEventCursorSurvivesTheSnapshotCache(t *testing.T) {
	// The second launch must not walk the whole backlog again.
	dir := t.TempDir()
	cs := newCountingServer(t)
	m := pollModel(cs, steadyClock())
	m.cacheDir = dir
	m.cacheKey = "k"
	m.eventCursor = 4242

	at := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{Counts: map[string]int{"open": 1}, FetchedAt: at}})

	next := newModel(cs.client(), "", Config{BaseURL: cs.srv.URL})
	next.cacheDir, next.cacheKey = dir, "k"
	next.primeFromCache()
	if next.eventCursor != 4242 {
		t.Fatalf("resumed cursor = %d, want 4242 — a cold cursor means walking the whole feed again", next.eventCursor)
	}
}

// --- helpers -----------------------------------------------------------------

func firstEventsResult(t *testing.T, msgs []tea.Msg) eventsResultMsg {
	t.Helper()
	for _, m := range msgs {
		if res, ok := m.(eventsResultMsg); ok {
			if res.err != nil {
				t.Fatalf("poll failed: %v", res.err)
			}
			return res
		}
	}
	t.Fatalf("no eventsResultMsg among %d messages", len(msgs))
	return eventsResultMsg{}
}
