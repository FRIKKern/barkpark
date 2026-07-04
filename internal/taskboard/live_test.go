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
	// Rows: 0 loose-bucket header, 1 a, 2 b, 3 c. The head cap shows all three
	// loose tasks (n < groupHeadMax), so "c" is the last navigable row.
	m.ui.Cursor = 3 // on "c"

	// The refetch reorders: "c" moves to the top of the loose bucket.
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Orphans: []Task{t("c"), t("a"), t("b")}}
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

// A pulse must NOT clear ✗ ConnOffline — offline means the DATA path (refetch)
// failed, and a live stream with unreachable reads is still a broken board.
// The pulse still bumps lastLiveEvent, so the moment a refetch succeeds,
// applySnapshot derives ● ConnLive directly (no polling limbo on recovery).
func TestPulsePreservesOfflineUntilRefetchSucceeds(t2 *testing.T) {
	clk := &fakeClock{t: time.Unix(3000, 0)}
	m := newModel(nil, "", Config{})
	m.now = clk.now
	m.build = func(s Snapshot, _ RepoContext, _ time.Time) Board { return Board{Orphans: s.Tasks} }
	m.ui.Conn = ConnOffline

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
