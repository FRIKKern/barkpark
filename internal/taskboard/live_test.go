package taskboard

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// fakeClock is a hand-advanced clock so the live-loop's time-dependent decisions
// (debounce staleness, ConnLive vs ConnPolling) are deterministic under test.
type fakeClock struct{ t time.Time }

func (f *fakeClock) now() time.Time      { return f.t }
func (f *fakeClock) add(d time.Duration) { f.t = f.t.Add(d) }

// A burst of SSE change events must collapse to exactly ONE refetch: only the
// newest debounce generation fires, every stale one is a no-op. This is the
// coalescing guarantee — a noisy stream never triggers a fetch storm.
func TestDebounceCoalescesBurstToOneRefetch(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.eventsOff = true
	// LEGACY ARM. The debounce no longer coalesces into a REFETCH — it coalesces
	// into one cheap keyset poll, which then decides whether the heavy pair runs
	// (task-e2f5ecca0be9a6d1, events.go). eventsOff selects the preserved
	// fallback loop this test was written against, so what it guards — the
	// generation-tag coalescing itself — is still pinned; the new path's
	// coalescing is pinned by TestDebounceNudgesThePollNotTheHeavyPair and the
	// request-count tests in events_test.go.

	// Three change events arrive in a burst. Each re-arms the debounce (gen 1→3);
	// none of them refetches yet (they only schedule the debounce timer).
	var cmd interface{}
	for i := 0; i < 3; i++ {
		clk.add(50 * time.Millisecond)
		m, cmd = m.handleChange(changeMsg{live: true})
		if cmd == nil {
			t2.Fatalf("change %d returned no debounce command", i+1)
		}
	}
	if m.debounceGen != 3 {
		t2.Fatalf("debounceGen = %d after 3 changes, want 3", m.debounceGen)
	}

	// Stale debounce timers (gen 1, 2) must NOT refetch.
	if _, c := m.handleDebounce(debounceMsg{gen: 1}); c != nil {
		t2.Fatal("stale debounce gen=1 fired a refetch")
	}
	if _, c := m.handleDebounce(debounceMsg{gen: 2}); c != nil {
		t2.Fatal("stale debounce gen=2 fired a refetch")
	}

	// The newest generation fires exactly one refetch.
	fetches := 0
	m.fetch = func(*apiclient.Client) (Snapshot, DetailIndex, error) {
		fetches++
		return Snapshot{FetchedAt: clk.now()}, nil, nil
	}
	m2, c := m.handleDebounce(debounceMsg{gen: 3})
	if c == nil {
		t2.Fatal("newest debounce gen=3 did not fire a refetch")
	}
	if _, ok := c().(snapshotMsg); !ok {
		t2.Fatal("debounce command did not produce a snapshotMsg")
	}
	if fetches != 1 {
		t2.Fatalf("burst produced %d fetches, want 1", fetches)
	}

	// Dirty is now cleared; a repeat of the same generation is a no-op.
	if _, c := m2.handleDebounce(debounceMsg{gen: 3}); c != nil {
		t2.Fatal("debounce fired again after the flag was already cleared")
	}
}

// A change-driven refetch reads as ConnLive; a failed refetch reads as
// ConnOffline and KEEPS the last good board.
func TestApplySnapshotConnStates(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(5000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board {
		return Board{Orphans: s.Tasks}
	}

	// Change-driven success → ConnLive + LastSync stamped + board swapped.
	m.lastLiveEvent = clk.now()
	fetched := clk.now()
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{Tasks: []Task{t("a")}, FetchedAt: fetched}})
	if m.ui.Conn != ConnLive {
		t2.Fatalf("change-driven refetch conn = %v, want ConnLive", m.ui.Conn)
	}
	if !m.ui.LastSync.Equal(fetched) {
		t2.Fatalf("LastSync = %v, want %v", m.ui.LastSync, fetched)
	}
	if len(m.board.Orphans) != 1 {
		t2.Fatalf("board not swapped: %d orphans, want 1", len(m.board.Orphans))
	}

	// A failed refetch → ConnOffline, board preserved, and the strip says WHY
	// (a silently dark board reads as "no tasks" — the 8 MiB cap incident).
	good := m.board
	m, _ = m.applySnapshot(snapshotMsg{err: errors.New("dial tcp: refused")})
	if m.ui.Conn != ConnOffline {
		t2.Fatalf("failed refetch conn = %v, want ConnOffline", m.ui.Conn)
	}
	if m.ui.ConnProblem != "offline" {
		t2.Fatalf("transport failure label = %q, want offline", m.ui.ConnProblem)
	}
	if len(m.board.Orphans) != len(good.Orphans) {
		t2.Fatal("failed refetch clobbered the last good board")
	}

	// Recovery clears the stale failure reason as well as the degraded state.
	m.lastLiveEvent = clk.now()
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{Tasks: []Task{t("b")}, FetchedAt: clk.now()}})
	if m.ui.ConnProblem != "" {
		t2.Fatalf("successful recovery retained stale problem %q", m.ui.ConnProblem)
	}
}

// timeoutErr is a minimal net.Error-shaped timeout — the shape http.Client.Do
// wraps inside *url.Error when a request deadline (client Timeout or context)
// fires. Its Error() text deliberately avoids the word "timeout"/"deadline" so
// the tests below can only pass through the TYPED classification, never a
// string match.
type timeoutErr struct{}

func (timeoutErr) Error() string   { return "await response: budget blown" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

// snapshotTimeoutError builds a client-timeout error wrapped exactly as
// getJSONCtx wraps transport errors ("GET %s: %w" around http.Client.Do's
// *url.Error) — the shape applySnapshot actually receives from a slow fetch.
func snapshotTimeoutError() error {
	return fmt.Errorf("GET %s: %w", "/v1/tasks?limit=1000",
		&url.Error{Op: "Get", URL: "http://x/v1/tasks?limit=1000", Err: timeoutErr{}})
}

// snapshotRefusedError builds a genuine-unreachability transport error (dial
// tcp connection refused) in the same typed *url.Error wrapping — a real dead
// server, which must STAY in the offline class.
func snapshotRefusedError() error {
	return fmt.Errorf("GET %s: %w", "/v1/tasks?limit=1000",
		&url.Error{Op: "Get", URL: "http://x/v1/tasks?limit=1000",
			Err: errors.New("dial tcp 127.0.0.1:4000: connect: connection refused")})
}

func TestSnapshotErrorLabelsAreTruthful(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"cap", errors.New("response exceeds 33554432 bytes"), "snapshot too large"},
		{"401", errors.New("GET /v1/tasks: status 401"), "unauthorized"},
		{"403", errors.New("GET /v1/tasks: status 403"), "forbidden"},
		{"404", errors.New("GET /v1/tasks: status 404"), "snapshot unavailable"},
		{"decode", errors.New("decode tasks list: invalid character"), "invalid snapshot"},
		{"5xx", errors.New("GET /v1/tasks: status 503"), "server error"},
		{"dial-tcp string", errors.New("dial tcp: connection refused"), "offline"},
		// The timeout class is TYPED (errors.As + url.Error.Timeout / errors.Is
		// context.DeadlineExceeded) — the *url.Error row's text contains no
		// "timeout"/"deadline" word at all, so only the typed path can label it.
		{"typed client timeout", snapshotTimeoutError(), labelServerTimeout},
		{"mid-body context deadline", fmt.Errorf("GET %s: %w", "/v1/tasks/prime?limit=100", context.DeadlineExceeded), labelServerTimeout},
		// A typed *url.Error that is NOT a timeout (connection refused,
		// Timeout()==false) keeps the honest offline class — dial-tcp stays ✗.
		{"typed dial refused", snapshotRefusedError(), "offline"},
	}
	for _, tc := range cases {
		if got := snapshotErrorLabel(tc.err); got != tc.want {
			t.Errorf("%s: snapshotErrorLabel(%q) = %q, want %q", tc.name, tc.err, got, tc.want)
		}
	}
}

// A live refresh rebuilds and reorders the whole board; the selection must
// follow the TASK the user is on (by doc id), not the raw cursor index.
func TestApplySnapshotKeepsSelectionOnSameTask(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return time.Unix(7000, 0) }
	m.board = Board{Orphans: []Task{t("a"), t("b"), t("c")}, OrphansActive: true, OrphansFocusSet: focusOf("a", "b", "c")}
	// Rows: 0 loose-bucket header, 1 a, 2 b, 3 c. The focused loose bucket shows
	// all three loose tasks, so "c" is the last navigable row.
	m.ui.Cursor = 3 // on "c"

	// The refetch reorders: "c" moves to the top of the loose bucket.
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Orphans: []Task{t("c"), t("a"), t("b")}, OrphansActive: true, OrphansFocusSet: focusOf("a", "b", "c")}
	}
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(7000, 0)}})
	// After the reorder "c" is the first loose task → row 1 (row 0 is the header).
	if m.ui.Cursor != 1 {
		t2.Fatalf("cursor = %d after reorder, want 1 (still on task c)", m.ui.Cursor)
	}
}

// Two in-flight refetches can complete out of order (a slow debounce-driven
// fetch racing the backstop). A success frame OLDER than what is already on
// screen must be dropped — the board never rolls backward.
func TestApplySnapshotDropsStaleOutOfOrderFrame(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return time.Unix(8000, 0) }
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board {
		return Board{Orphans: s.Tasks}
	}

	// Newer frame lands first.
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{Tasks: []Task{t("new")}, FetchedAt: time.Unix(8000, 0)}})
	// A slower, older frame straggles in afterwards — it must be ignored.
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{Tasks: []Task{t("old")}, FetchedAt: time.Unix(7990, 0)}})

	if len(m.board.Orphans) != 1 || m.board.Orphans[0].DocID != "new" {
		t2.Fatalf("stale frame rolled the board back: %+v", m.board.Orphans)
	}
	if !m.ui.LastSync.Equal(time.Unix(8000, 0)) {
		t2.Fatalf("LastSync = %v, want the newer frame's stamp", m.ui.LastSync)
	}
}

// The state-revert flicker regression: a snapshot with a FRESH FetchedAt (newer
// CLIENT wall clock) but a STALE row (older server UpdatedAt) must NOT downgrade
// a row the user just saw advance. FetchedAt orders fetches, not data — the
// FetchedAt guard passes here, so the per-row forward-only merge is what saves
// the row. On the unfixed blind-replace this FAILS: the claimed row reverts to
// unclaimed, then the next poll restores it → CLAIMED→unclaimed→CLAIMED flicker.
func TestApplySnapshotForwardMergeIgnoresStaleRow(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(9000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.lastLiveEvent = clk.now()
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board {
		return Board{Orphans: s.Tasks}
	}

	tOld := time.Unix(1000, 0) // stale server time
	tNew := time.Unix(2000, 0) // fresh server time

	// Snapshot A: row "x" is CLAIMED, server UpdatedAt = tNew. (First snapshot is
	// a cold paint — no flashes — and seeds prevTasks.)
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{
		Tasks: []Task{claimed("x", "worker", 4, tNew)}, FetchedAt: clk.now()}})
	if m.board.Orphans[0].Claim == nil {
		t2.Fatal("setup: snapshot A did not land the claimed row")
	}

	// Snapshot B: NEWER client FetchedAt (passes the out-of-order guard) but the
	// row is STALE — unclaimed, server UpdatedAt = tOld (an older server read that
	// a backstop/reconcile fetch happened to stamp with a later wall clock).
	clk.add(time.Second)
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{
		Tasks:     []Task{Task{DocID: "x", Title: "x", Lifecycle: lifeReady, UpdatedAt: tOld}},
		FetchedAt: clk.now()}})

	// The board must STILL show the row claimed — the stale snapshot cannot revert it.
	if got := m.board.Orphans[0]; got.Claim == nil {
		t2.Fatalf("stale snapshot reverted the claimed row (the flicker): %+v", got)
	}
	if !m.board.Orphans[0].UpdatedAt.Equal(tNew) {
		t2.Fatalf("kept row lost its server UpdatedAt: %v, want %v", m.board.Orphans[0].UpdatedAt, tNew)
	}
	// And the kept row must NOT spuriously flash (it did not actually move).
	if _, flashed := m.ui.Flashes["x"]; flashed {
		t2.Fatalf("a row kept because the incoming copy was stale spuriously flashed: %v", m.ui.Flashes)
	}
}

// The 30s backstop keeps the board fresh when the SSE stream silently drops.
// A refetch's connection state follows the freshness of the last LIVE event,
// not what drove the fetch: while a live event is recent the stream is trusted
// → ConnLive; once no live event has arrived for longer than liveStale the
// board honestly degrades to ConnPolling even though the backstop keeps it
// fresh.
func TestBackstopReportsPollingWhenStreamStale(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(9000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(Snapshot, RepoContext, time.Time) Board { return Board{} }

	// A recent live event: a backstop refetch still trusts the stream → Live.
	m.lastLiveEvent = clk.now()
	clk.add(10 * time.Second) // < liveStale (35s)
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: clk.now()}})
	if m.ui.Conn != ConnLive {
		t2.Fatalf("backstop with a fresh live event conn = %v, want ConnLive", m.ui.Conn)
	}

	// Stream drops: no live event for longer than liveStale → Polling.
	clk.add(40 * time.Second) // now 50s since lastLiveEvent, > liveStale
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: clk.now()}})
	if m.ui.Conn != ConnPolling {
		t2.Fatalf("backstop after a dropped stream conn = %v, want ConnPolling", m.ui.Conn)
	}

	// handleBackstop always arms a refetch + reschedules itself.
	_, cmd := m.handleBackstop()
	if cmd == nil {
		t2.Fatal("handleBackstop returned no command")
	}
}

// End-to-end over httptest: a real SSE mutation frame fires the apiclient
// OnChange seam, and a change-driven refetch pulls a fresh snapshot over HTTP
// and swaps it into the model as ConnLive. Events signal; the refetch is truth.
func TestSSEEventDrivesRefetchAndSwap(t2 *testing.T) {
	// serverDone releases the parked SSE handler at teardown. Closing it BEFORE
	// srv.Close() avoids the classic httptest deadlock (Close blocks on an
	// in-flight request while the handler blocks on the connection).
	serverDone := make(chan struct{})

	// One root handler: the apiclient scopes the listen path to
	// /w/<ws>/p/<project>/v1/data/listen/<dataset>, so match on the suffix rather
	// than an exact route. /snap is the refetch's truth endpoint.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/listen/"):
			// Emit one mutation frame, then hold the connection open (so the client
			// parks in its read loop instead of EOFing into a fast reconnect) until
			// the test tears the server down or the client disconnects.
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			if f, ok := w.(http.Flusher); ok {
				_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"n1\"}\n\n"))
				f.Flush()
			}
			select {
			case <-serverDone:
			case <-r.Context().Done():
			}
		case r.URL.Path == "/snap":
			_ = json.NewEncoder(w).Encode(map[string]string{"doc_id": "n1"})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	defer close(serverDone)

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL, Dataset: "production"})
	fired := make(chan struct{}, 1)
	c.OnChange = func() {
		select {
		case fired <- struct{}{}:
		default:
		}
	}
	go c.StartSSE(context.Background(), "")

	select {
	case <-fired:
	case <-time.After(3 * time.Second):
		t2.Fatal("SSE mutation frame did not fire OnChange")
	}

	// Model side: the change event coalesces into a refetch that hits /snap.
	fetchedAt := time.Unix(2000, 0)
	m := newModel(c, "", Config{})
	m.now = func() time.Time { return fetchedAt }
	m.eventsOff = true
	// LEGACY ARM. The debounce no longer coalesces into a REFETCH — it coalesces
	// into one cheap keyset poll, which then decides whether the heavy pair runs
	// (task-e2f5ecca0be9a6d1, events.go). eventsOff selects the preserved
	// fallback loop this test was written against, so what it guards — the
	// generation-tag coalescing itself — is still pinned; the new path's
	// coalescing is pinned by TestDebounceNudgesThePollNotTheHeavyPair and the
	// request-count tests in events_test.go.
	// Inject build so the assertion does not depend on the wiring stub's policy
	// (which the lead deletes at merge); this test owns its own tiny board rule.
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }
	m.fetch = func(_ *apiclient.Client) (Snapshot, DetailIndex, error) {
		resp, err := http.Get(srv.URL + "/snap")
		if err != nil {
			return Snapshot{}, nil, err
		}
		defer resp.Body.Close()
		var body struct {
			DocID string `json:"doc_id"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return Snapshot{}, nil, err
		}
		return Snapshot{Tasks: []Task{{DocID: body.DocID, Title: body.DocID}}, FetchedAt: fetchedAt}, nil, nil
	}

	m, _ = m.handleChange(changeMsg{live: true})
	if !m.dirty {
		t2.Fatal("change event did not mark the board dirty")
	}
	m, cmd := m.handleDebounce(debounceMsg{gen: m.debounceGen})
	if cmd == nil {
		t2.Fatal("debounce did not schedule a refetch")
	}
	msg, ok := cmd().(snapshotMsg)
	if !ok {
		t2.Fatalf("refetch produced %T, want snapshotMsg", cmd())
	}
	m, _ = m.applySnapshot(msg)

	// The injected build files tasks under Orphans; the swap is observable there.
	if len(m.board.Orphans) != 1 || m.board.Orphans[0].DocID != "n1" {
		t2.Fatalf("board did not swap in the refetched task: %+v", m.board.Orphans)
	}
	if m.ui.Conn != ConnLive {
		t2.Fatalf("post-refetch conn = %v, want ConnLive", m.ui.Conn)
	}
	if !m.ui.LastSync.Equal(fetchedAt) {
		t2.Fatalf("LastSync = %v, want %v", m.ui.LastSync, fetchedAt)
	}
}

// handleChange must refetch (mark dirty + re-arm the debounce) for BOTH a live
// SSE frame and a poll-fallback change, but only a LIVE change may refresh
// lastLiveEvent — the timestamp that holds the ● live connection state. A
// fallback change leaves it untouched, so a poll-only client reads ◐ polling.
func TestHandleChangeLiveVsFallbackTimestamp(t2 *testing.T) {
	cases := []struct {
		name  string
		live  bool
		bumps bool
	}{
		{"live SSE frame bumps lastLiveEvent", true, true},
		{"poll fallback leaves lastLiveEvent untouched", false, false},
	}
	for _, tc := range cases {
		t2.Run(tc.name, func(t2 *testing.T) {
			clk := &fakeClock{t: time.Unix(1000, 0)}
			m := newModel(nil, "", Config{})
			m.now = clk.now

			// A known, STALE baseline so a bump is unambiguously observable.
			baseline := time.Unix(500, 0)
			m.lastLiveEvent = baseline
			clk.add(10 * time.Second)

			m, cmd := m.handleChange(changeMsg{live: tc.live})
			if cmd == nil {
				t2.Fatal("handleChange returned no debounce command (both sources must refetch)")
			}
			if !m.dirty {
				t2.Fatal("handleChange did not mark the board dirty")
			}
			if m.debounceGen != 1 {
				t2.Fatalf("debounceGen = %d, want 1 (the debounce must re-arm either way)", m.debounceGen)
			}
			if tc.bumps {
				if !m.lastLiveEvent.Equal(clk.now()) {
					t2.Fatalf("live change lastLiveEvent = %v, want %v", m.lastLiveEvent, clk.now())
				}
			} else if !m.lastLiveEvent.Equal(baseline) {
				t2.Fatalf("fallback change moved lastLiveEvent to %v, want it left at %v", m.lastLiveEvent, baseline)
			}
		})
	}
}

// The connection dot is honest end-to-end through the reducers: a poll-fallback
// change (live==false) refetches and swaps the board but reads ◐ ConnPolling,
// while a real SSE frame (live==true) within liveStale reads ● ConnLive — even
// though both take the exact same debounce → refetch → applySnapshot path. This
// is the whole point of the seam split: the dot follows the SOURCE, not the fact
// that a refetch happened.
func TestConnStateFollowsChangeSourceNotRefetch(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(6000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }
	// LEGACY ARM. The debounce no longer coalesces into a REFETCH — it coalesces
	// into one cheap keyset poll, which then decides whether the heavy pair runs
	// (task-e2f5ecca0be9a6d1, events.go). eventsOff selects the preserved
	// fallback loop this test was written against, so what it guards — the
	// generation-tag coalescing itself — is still pinned; the new path's
	// coalescing is pinned by TestDebounceNudgesThePollNotTheHeavyPair and the
	// request-count tests in events_test.go.

	drive := func(m Model, live bool) Model {
		m.eventsOff = true
		m, _ = m.handleChange(changeMsg{live: live})
		_, cmd := m.handleDebounce(debounceMsg{gen: m.debounceGen})
		if cmd == nil {
			t2.Fatal("change did not schedule a refetch")
		}
		msg, ok := cmd().(snapshotMsg)
		if !ok {
			t2.Fatalf("refetch produced %T, want snapshotMsg", cmd())
		}
		m, _ = m.applySnapshot(msg)
		return m
	}

	// A poll-fallback change → refetch → ConnPolling (lastLiveEvent never bumped).
	m.fetch = func(*apiclient.Client) (Snapshot, DetailIndex, error) {
		return Snapshot{Tasks: []Task{t("x")}, FetchedAt: clk.now()}, nil, nil
	}
	m = drive(m, false)
	if m.ui.Conn != ConnPolling {
		t2.Fatalf("poll-fallback-driven refetch conn = %v, want ConnPolling", m.ui.Conn)
	}

	// A real SSE frame within liveStale → refetch → ConnLive.
	clk.add(time.Second)
	m = drive(m, true)
	if m.ui.Conn != ConnLive {
		t2.Fatalf("live-SSE-driven refetch conn = %v, want ConnLive", m.ui.Conn)
	}
}

// A pulse (any SSE stream frame: welcome/keepalive/mutation) is proof-of-life
// only. It must bump lastLiveEvent and upgrade ◐ ConnPolling to ● ConnLive
// immediately — the dot should turn honest moments after the stream connects,
// not a backstop cycle later — WITHOUT marking dirty or scheduling a refetch
// (a keepalive every 30s must never cause fetch traffic on a quiet dataset).
func TestPulseUpgradesPollingToLiveWithoutRefetch(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(2000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.ui.Conn = ConnPolling

	m, cmd := m.handlePulse()

	if cmd != nil {
		t2.Fatal("handlePulse scheduled a command; a pulse must never refetch")
	}
	if m.dirty {
		t2.Fatal("handlePulse marked the board dirty; a pulse carries no data change")
	}
	if !m.lastLiveEvent.Equal(clk.now()) {
		t2.Fatalf("lastLiveEvent = %v, want %v", m.lastLiveEvent, clk.now())
	}
	if m.ui.Conn != ConnLive {
		t2.Fatalf("conn after pulse = %v, want ConnLive", m.ui.Conn)
	}
}

// GENUINE unreachability is the sticky class: a refetch that died with a typed
// dial-tcp connection refused (Timeout()==false — the server is GONE, not slow)
// reads ✗ ConnOffline, and a pulse must NOT clear it — offline means the DATA
// path failed, and a live stream with unreachable reads is still a broken
// board. Only a refetch that actually SUCCEEDS lifts it; the pulse still bumps
// lastLiveEvent, so that recovery lands straight on ● ConnLive (no polling
// limbo). This is the honesty guard's half of the timeout split — the lift for
// the timeout class lives in TestPulseLiftsTimeoutDegradedState.
func TestPulsePreservesOfflineUntilRefetchSucceeds(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(3000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }

	// Arrive at offline through the real classification path, not by fiat: a
	// typed connection-refused transport error is genuine unreachability.
	m, _ = m.applySnapshot(snapshotMsg{err: snapshotRefusedError()})
	if m.ui.Conn != ConnOffline {
		t2.Fatalf("conn after refused refetch = %v, want ConnOffline (the server is gone)", m.ui.Conn)
	}
	if m.ui.ConnProblem != "offline" {
		t2.Fatalf("refused refetch label = %q, want offline", m.ui.ConnProblem)
	}

	m, _ = m.handlePulse()
	if m.ui.Conn != ConnOffline {
		t2.Fatalf("conn after pulse while offline = %v, want ConnOffline (data path is still broken)", m.ui.Conn)
	}

	// The data path recovers within liveStale of the pulse → straight to Live.
	clk.add(5 * time.Second)
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: clk.now()}})
	if m.ui.Conn != ConnLive {
		t2.Fatalf("conn after recovery refetch = %v, want ConnLive (a pulse was seen %v ago)", m.ui.Conn, 5*time.Second)
	}
	if m.ui.ConnProblem != "" {
		t2.Fatalf("recovery retained stale problem %q", m.ui.ConnProblem)
	}
}

// The timeout class is NOT offline: a snapshot fetch that blew its budget
// degrades to ◐ + "server timeout" (KEEPING the last good board), and SSE
// proof-of-life lifts exactly that state back to ● — the pipe proving itself
// alive contradicts "gone", never "slow". The label stays until a snapshot
// actually LANDS: the pulse proves the stream, not the data path.
func TestPulseLiftsTimeoutDegradedState(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(4000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }

	// Seed a good board so the timeout's board-preservation is observable.
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{Tasks: []Task{t("a")}, FetchedAt: clk.now()}})

	// A slow fetch times out with NO recent live frame → honest ◐ degraded,
	// never ✗ offline, board kept.
	clk.add(time.Minute)
	m, _ = m.applySnapshot(snapshotMsg{err: snapshotTimeoutError()})
	if m.ui.Conn == ConnOffline {
		t2.Fatal("a client timeout read ✗ ConnOffline — the conn dot called a slow fetch offline")
	}
	if m.ui.Conn != ConnPolling {
		t2.Fatalf("timeout with stale stream conn = %v, want ConnPolling", m.ui.Conn)
	}
	if m.ui.ConnProblem != labelServerTimeout {
		t2.Fatalf("timeout label = %q, want %q", m.ui.ConnProblem, labelServerTimeout)
	}
	if len(m.board.Orphans) != 1 {
		t2.Fatal("timeout clobbered the last good board")
	}

	// SSE proof-of-life lifts the timeout-class dot to ● — but the label stays:
	// the data on screen is still stale, and only a landed snapshot may say the
	// fetch path recovered.
	m, _ = m.handlePulse()
	if m.ui.Conn != ConnLive {
		t2.Fatalf("conn after pulse over timeout class = %v, want ConnLive (the stream proved the pipe)", m.ui.Conn)
	}
	if m.ui.ConnProblem != labelServerTimeout {
		t2.Fatalf("pulse cleared the timeout label (got %q) — only a landed snapshot may", m.ui.ConnProblem)
	}

	// The landed snapshot clears the label.
	clk.add(time.Second)
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{Tasks: []Task{t("a")}, FetchedAt: clk.now()}})
	if m.ui.ConnProblem != "" {
		t2.Fatalf("landed snapshot retained stale problem %q", m.ui.ConnProblem)
	}
	if m.ui.Conn != ConnLive {
		t2.Fatalf("conn after landed snapshot = %v, want ConnLive", m.ui.Conn)
	}
}

// A timeout while the SSE stream is FRESH holds ● outright — the dot must not
// flap ● → ◐ → ● across one slow fetch when the pipe is verifiably alive the
// whole time. The "server timeout" label still surfaces the degraded data path.
func TestTimeoutWithFreshStreamHoldsLive(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(4500, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }
	m.lastLiveEvent = clk.now()
	m.ui.Conn = ConnLive

	m, _ = m.applySnapshot(snapshotMsg{err: snapshotTimeoutError()})
	if m.ui.Conn != ConnLive {
		t2.Fatalf("timeout with fresh stream conn = %v, want ConnLive (no flap through ◐)", m.ui.Conn)
	}
	if m.ui.ConnProblem != labelServerTimeout {
		t2.Fatalf("timeout label = %q, want %q", m.ui.ConnProblem, labelServerTimeout)
	}
}

// ── Flash ladder wiring (charter decision 17) ────────────────────────────────

// upd builds an orphan task with an explicit UpdatedAt so the snapshot diff has
// something to move.
func upd(id string, updated time.Time) Task {
	return Task{DocID: id, Title: id, Lifecycle: lifeReady, UpdatedAt: updated}
}

// The FIRST snapshot of a session flashes nothing (a board you just opened is
// still); a later snapshot whose tasks moved stamps a flash for each changed id.
func TestApplySnapshotStampsFlashesOnDiffButNotFirstSnapshot(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(9000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }

	t0 := time.Unix(8000, 0)
	// First snapshot: cold paint, no flashes even though a task is present.
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{
		Tasks: []Task{upd("a", t0)}, FetchedAt: clk.now()}})
	if len(m.ui.Flashes) != 0 {
		t2.Fatalf("first snapshot stamped %d flashes, want 0 (cold paints are still)", len(m.ui.Flashes))
	}

	// Second snapshot: "a" moved (UpdatedAt advanced) → exactly one flash stamped
	// at the current clock.
	clk.add(time.Second)
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{
		Tasks: []Task{upd("a", t0.Add(time.Minute))}, FetchedAt: clk.now()}})
	if _, ok := m.ui.Flashes["a"]; !ok {
		t2.Fatalf("a moved task did not flash: %v", m.ui.Flashes)
	}
	if got := m.ui.Flashes["a"]; !got.Equal(clk.now()) {
		t2.Fatalf("flash stamped at %v, want the current clock %v", got, clk.now())
	}
	// The fresh flash makes the board alive → the heartbeat is armed.
	if !m.frameOn {
		t2.Fatal("a fresh flash did not arm the heartbeat")
	}
}

// A snapshot that leaves the board at rest (no claims, all flashes decayed)
// stops the heartbeat, resets Frame to 0 — deterministic rest — and prunes the
// decayed flash entries (nothing else would once the ticker is stopped).
func TestApplySnapshotResetsFrameWhenGoingStill(t2 *testing.T) {
	base := time.Unix(10000, 0)
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return base }
	m.build = func(Snapshot, RepoContext, time.Time) Board { return Board{} } // empty, at rest
	// Pretend a heartbeat was running with a stamped frame and a flash that has
	// fully decayed (level 0 — it must not keep the board alive, and it must not
	// outlive this snapshot).
	m.frameOn, m.frameGen, m.ui.Frame = true, 1, 4
	m.ui.Flashes = map[string]time.Time{"old": base.Add(-10 * time.Second)}
	// Prime LastSync so this is not the first snapshot (and not "syncing").
	m.ui.LastSync = base.Add(-time.Minute)

	m, cmd := m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: base}})
	if cmd != nil {
		t2.Fatal("a board that went still armed a frame cmd")
	}
	if m.frameOn {
		t2.Fatal("frameOn stayed true after the board went still")
	}
	if m.ui.Frame != 0 {
		t2.Fatalf("Frame = %d after going still, want 0", m.ui.Frame)
	}
	if len(m.ui.Flashes) != 0 {
		t2.Fatalf("decayed flashes survived the snapshot: %v (stale entries would leak for the session)", m.ui.Flashes)
	}
}

// ── snapshot transport budget (D114) ─────────────────────────────────────────

// A REAL transport deadline classifies typed end-to-end: getJSONCtx against a
// stalling server, the context deadline fires mid-request, and the wrapped
// error lands in the timeout class — never the default "offline" bucket the
// pre-fix path fell into.
func TestSnapshotFetchDeadlineClassifiesAsTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, err := getJSONCtx(ctx, newClient(srv.URL), "/v1/tasks?limit=1000")
	if err == nil {
		t.Fatal("a 30ms deadline against a 300ms server did not error")
	}
	if !isSnapshotTimeout(err) {
		t.Fatalf("deadline error %q did not classify as the timeout class", err)
	}
	if got := snapshotErrorLabel(err); got != labelServerTimeout {
		t.Fatalf("deadline error labeled %q, want %q", got, labelServerTimeout)
	}
}

// The snapshot budget is SCOPED: FetchSnapshotFull succeeds against a server
// slower than the shared apiclient's interactive timeout, because the snapshot
// path carries its own per-request deadline (snapshotFetchTimeout) instead of
// inheriting the client's. The first half proves the guard can fail — the SAME
// client's own transport really does die on this server — so a regression that
// routes the snapshot back through the interactive client reds this test.
func TestSnapshotBudgetIndependentOfInteractiveClientTimeout(t *testing.T) {
	listBody, primeBody := fixtureParts(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(120 * time.Millisecond) // slower than the interactive budget below
		switch r.URL.Path {
		case "/v1/tasks":
			_, _ = w.Write(listBody)
		case "/v1/tasks/prime":
			_, _ = w.Write(primeBody)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	// The one shared apiclient keeps a deliberately TINY interactive timeout —
	// the pre-fix 5s inheritance scaled down so the test runs in milliseconds.
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "test-token", Timeout: 20 * time.Millisecond})

	// Mutation guard: the interactive transport really would kill this fetch.
	if _, err := c.GetConditionalBounded(srv.URL+"/v1/tasks?limit=1000", "", maxBoardFetchBytes); err == nil {
		t.Fatal("the interactive client outlived its own 20ms timeout — this guard is vacuous")
	}

	// The snapshot path rides its own budget, so the same slow server completes.
	snap, details, err := FetchSnapshotFull(c)
	if err != nil {
		t.Fatalf("FetchSnapshotFull under a 20ms interactive client timeout: %v (the snapshot budget leaked into the shared client, or vice versa)", err)
	}
	if len(snap.Tasks) == 0 {
		t.Fatal("snapshot fetched under the scoped budget carried no tasks")
	}
	if len(details) == 0 {
		t.Fatal("snapshot fetched under the scoped budget carried no detail index")
	}
}

// TestSnapshotErrorLabelReadsTypedStatusNotBodyText is the regression pin for
// the string-match-standing-in-for-a-typed-fact class (parent
// task-ce8f04315a6d1f10, sibling of run.go's mediaUploadFileArg): the HTTP
// status of a refused snapshot fetch is a TYPED int at the point it is known
// (getJSONAttempt reads resp.StatusCode), but it used to be flattened into the
// error's TEXT and re-parsed by snapshotErrorLabel with
// strings.Contains(s, "status 401"). That text also carries bodyHint(body) —
// up to 120 characters of the SERVER'S OWN RESPONSE BODY, which nothing in this
// binary controls. Any body that happens to SPELL another status (a gateway
// forwarding "upstream returned status 404") or the oversize words
// ("exceeds … bytes") hijacks the classification, and the operator's identity
// strip names the wrong failure: a 403 reads "unauthorized", a 500 reads
// "snapshot unavailable" (a permanent-looking class, so nobody retries), a 404
// reads "snapshot too large".
//
// Every error here is produced by the REAL fetch path against a real httptest
// server (or by the real decoder), never hand-built, so the test pins the whole
// pipe: status -> error -> label.
func TestSnapshotErrorLabelReadsTypedStatusNotBodyText(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		// A 403 whose body explains itself by naming a DIFFERENT status.
		{"403 body quoting a 401", http.StatusForbidden,
			`{"reason":"forbidden","detail":"membership probe returned status 401"}`,
			"forbidden"},
		// A 404 whose body happens to spell the oversize words.
		{"404 body quoting a byte budget", http.StatusNotFound,
			`{"reason":"not_found","detail":"prefix exceeds 0 bytes"}`,
			"snapshot unavailable"},
		// The sharpest one: a gateway 500 forwarding an upstream 404. Read as
		// "snapshot unavailable" this looks permanent; it is a retryable server
		// error.
		{"500 body quoting an upstream 404", http.StatusInternalServerError,
			`{"reason":"bad_gateway","detail":"upstream status 404"}`,
			"server error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				http.Error(w, tc.body, tc.status)
			}))
			defer srv.Close()

			_, err := getJSON(newClient(srv.URL), "/v1/tasks?limit=1000")
			if err == nil {
				t.Fatalf("status %d did not fail the fetch", tc.status)
			}
			if got := snapshotErrorLabel(err); got != tc.want {
				t.Errorf("HTTP %d misclassified by its BODY TEXT: snapshotErrorLabel(%q) = %q, want %q",
					tc.status, err, got, tc.want)
			}
		})
	}

	// The envelope-fence decode refusal (fetch.go decodeTaskListFull) also
	// embeds bodyHint. Its own comment promises the "invalid snapshot" class; a
	// 200 body that merely MENTIONS a status must not steal it.
	t.Run("decode refusal whose body quotes a status", func(t *testing.T) {
		_, _, err := decodeTaskListFull([]byte(`{"ok":true,"note":"upstream status 404 while listing"}`))
		if err == nil {
			t.Fatal("a docs-less envelope did not fail the decode")
		}
		if got := snapshotErrorLabel(err); got != "invalid snapshot" {
			t.Errorf("decode refusal misclassified by its BODY TEXT: snapshotErrorLabel(%q) = %q, want %q",
				err, got, "invalid snapshot")
		}
	})
}
