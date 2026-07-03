package taskboard

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
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
	m.fetch = func(*apiclient.Client) (Snapshot, error) {
		fetches++
		return Snapshot{FetchedAt: clk.now()}, nil
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

	// A failed refetch → ConnOffline, board preserved.
	good := m.board
	m, _ = m.applySnapshot(snapshotMsg{err: errors.New("dial tcp: refused")})
	if m.ui.Conn != ConnOffline {
		t2.Fatalf("failed refetch conn = %v, want ConnOffline", m.ui.Conn)
	}
	if len(m.board.Orphans) != len(good.Orphans) {
		t2.Fatal("failed refetch clobbered the last good board")
	}
}

// A live refresh rebuilds and reorders the whole board; the selection must
// follow the TASK the user is on (by doc id), not the raw cursor index.
func TestApplySnapshotKeepsSelectionOnSameTask(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return time.Unix(7000, 0) }
	m.board = Board{Orphans: []Task{t("a"), t("b"), t("c")}}
	m.ui.Cursor = 2 // on "c"

	// The refetch reorders: "c" moves to the top.
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Orphans: []Task{t("c"), t("a"), t("b")}}
	}
	m, _ = m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(7000, 0)}})
	if m.ui.Cursor != 0 {
		t2.Fatalf("cursor = %d after reorder, want 0 (still on task c)", m.ui.Cursor)
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
	go c.StartSSE("")

	select {
	case <-fired:
	case <-time.After(3 * time.Second):
		t2.Fatal("SSE mutation frame did not fire OnChange")
	}

	// Model side: the change event coalesces into a refetch that hits /snap.
	fetchedAt := time.Unix(2000, 0)
	m := newModel(c, "", Config{})
	m.now = func() time.Time { return fetchedAt }
	// Inject build so the assertion does not depend on the wiring stub's policy
	// (which the lead deletes at merge); this test owns its own tiny board rule.
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }
	m.fetch = func(_ *apiclient.Client) (Snapshot, error) {
		resp, err := http.Get(srv.URL + "/snap")
		if err != nil {
			return Snapshot{}, err
		}
		defer resp.Body.Close()
		var body struct {
			DocID string `json:"doc_id"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return Snapshot{}, err
		}
		return Snapshot{Tasks: []Task{{DocID: body.DocID, Title: body.DocID}}, FetchedAt: fetchedAt}, nil
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

	drive := func(m Model, live bool) Model {
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
	m.fetch = func(*apiclient.Client) (Snapshot, error) {
		return Snapshot{Tasks: []Task{t("x")}, FetchedAt: clk.now()}, nil
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
