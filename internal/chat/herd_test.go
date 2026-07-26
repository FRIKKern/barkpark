package chat

import (
	"testing"
	"time"
)

// herd_test.go — the frozen-clock proofs for every named herd reducer rule
// (charter D52h/D53h). No shell, no IO, no real clock: hNow is the injected
// instant every assertion pins against.

var hNow = time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)

func hISO(t time.Time) string { return t.Format(time.RFC3339Nano) }

func strp(s string) *string { return &s }

// seedHerd builds a herd from flips (test shorthand).
func seedHerd(rows ...HerdRow) HerdState {
	h := HerdState{Rows: map[string]HerdRow{}}
	for _, r := range rows {
		h.Rows[r.SessionID] = r
	}
	return h
}

// TestHerdSeedColdMountsFromList proves the cold mount: the list roster maps
// onto rows (state, agent_state_at as both clocks, title), and a summary
// without agent_state mounts honestly as "unknown" — never a fabricated state.
func TestHerdSeedColdMountsFromList(t *testing.T) {
	at := hNow.Add(-2 * time.Minute)
	h := herdSeed(HerdState{}, []SessionSummary{
		{ID: "a", Title: "fix auth", AgentState: "working", AgentStateAt: hISO(at)},
		{ID: "b", Title: "old server row"},
	})
	ra := h.Rows["a"]
	if ra.AgentState != "working" || ra.Title != "fix auth" {
		t.Fatalf("seed must mount state+title, got %+v", ra)
	}
	if !ra.LastFlipAt.Equal(at) || !ra.LastFrameAt.Equal(at) {
		t.Fatalf("seed must mount agent_state_at as both clocks, got %+v", ra)
	}
	if h.Rows["b"].AgentState != "unknown" {
		t.Fatalf("a stateless summary mounts as unknown, got %q", h.Rows["b"].AgentState)
	}
}

// TestHerdSeedNeverRegressesLiveTruth proves a re-list (an older point-in-time
// read) cannot clobber a fresher LIVE flip — the stream outranks the list.
func TestHerdSeedNeverRegressesLiveTruth(t *testing.T) {
	flipAt := hNow.Add(-10 * time.Second)
	h := seedHerd(HerdRow{SessionID: "a", AgentState: "blocked", Title: "held", LastFlipAt: flipAt, LastFrameAt: flipAt})
	// the list read predates the live flip
	got := herdSeed(h, []SessionSummary{
		{ID: "a", Title: "held", AgentState: "working", AgentStateAt: hISO(hNow.Add(-time.Minute))},
	})
	if got.Rows["a"].AgentState != "blocked" {
		t.Fatalf("an older list read must not regress a live flip, got %q", got.Rows["a"].AgentState)
	}
	// a list read at least as fresh as the flip adopts the list state
	got = herdSeed(h, []SessionSummary{
		{ID: "a", AgentState: "idle", AgentStateAt: hISO(hNow)},
	})
	if got.Rows["a"].AgentState != "idle" {
		t.Fatalf("a fresher list read must overlay, got %q", got.Rows["a"].AgentState)
	}
}

// TestHerdSnapshotOverlaysNeverTruncates is the D52h roster law: a (50-capped)
// snapshot upserts every listed session but rows absent from it are KEPT.
func TestHerdSnapshotOverlaysNeverTruncates(t *testing.T) {
	h := seedHerd(
		HerdRow{SessionID: "kept", AgentState: "idle", Title: "cold row"},
		HerdRow{SessionID: "flip", AgentState: "idle", Title: "held title"},
	)
	got := herdSnapshot(h, []fleetStateFrame{
		{SessionID: "flip", AgentState: "working", TS: hISO(hNow), Title: strp("snap title")},
		{SessionID: "new", AgentState: "blocked", TS: hISO(hNow), Title: strp("brand new")},
	})
	if len(got.Rows) != 3 {
		t.Fatalf("snapshot must never truncate the roster, got %d rows", len(got.Rows))
	}
	if got.Rows["kept"].Title != "cold row" || got.Rows["kept"].AgentState != "idle" {
		t.Fatalf("a row absent from the snapshot must be untouched, got %+v", got.Rows["kept"])
	}
	if got.Rows["flip"].AgentState != "working" || got.Rows["flip"].Title != "snap title" {
		t.Fatalf("a listed row must overlay state + non-null title, got %+v", got.Rows["flip"])
	}
	if got.Rows["new"].AgentState != "blocked" {
		t.Fatalf("a snapshot-only session still upserts, got %+v", got.Rows["new"])
	}
}

// TestHerdFlipIsIdempotentUpsert proves a double-emitted flip lands the
// identical row (map upsert, no counters, no toggles).
func TestHerdFlipIsIdempotentUpsert(t *testing.T) {
	f := fleetStateFrame{SessionID: "a", AgentState: "working", TS: hISO(hNow), Title: nil}
	once := herdFlip(HerdState{}, f)
	twice := herdFlip(once, f)
	if once.Rows["a"] != twice.Rows["a"] {
		t.Fatalf("re-applying a flip must be idempotent:\n once %+v\ntwice %+v", once.Rows["a"], twice.Rows["a"])
	}
	r := twice.Rows["a"]
	if r.AgentState != "working" || !r.LastFlipAt.Equal(hNow) || !r.LastFrameAt.Equal(hNow) {
		t.Fatalf("flip must set state + both clocks, got %+v", r)
	}
}

// TestHerdFlipNullTitleKeepsHeldTitle is the D45h title law: live flips carry
// title:null BY DESIGN — nil (and empty) never blank the held title, a real
// title refreshes it.
func TestHerdFlipNullTitleKeepsHeldTitle(t *testing.T) {
	h := seedHerd(HerdRow{SessionID: "a", AgentState: "idle", Title: "held title"})
	got := herdFlip(h, fleetStateFrame{SessionID: "a", AgentState: "working", TS: hISO(hNow), Title: nil})
	if got.Rows["a"].Title != "held title" {
		t.Fatalf("a NULL flip title must keep the held title, got %q", got.Rows["a"].Title)
	}
	got = herdFlip(got, fleetStateFrame{SessionID: "a", AgentState: "working", TS: hISO(hNow), Title: strp("  ")})
	if got.Rows["a"].Title != "held title" {
		t.Fatalf("a blank flip title must keep the held title, got %q", got.Rows["a"].Title)
	}
	got = herdFlip(got, fleetStateFrame{SessionID: "a", AgentState: "idle", TS: hISO(hNow), Title: strp("fresh")})
	if got.Rows["a"].Title != "fresh" {
		t.Fatalf("a real title must refresh, got %q", got.Rows["a"].Title)
	}
}

// TestHerdHeartbeatBumpsLastFrameOnly proves the heartbeat rule: LastFrameAt
// advances, AgentState and LastFlipAt are untouched, and an unknown session id
// is ignored (the roster is list-sourced).
func TestHerdHeartbeatBumpsLastFrameOnly(t *testing.T) {
	flipAt := hNow.Add(-2 * time.Minute)
	h := seedHerd(HerdRow{SessionID: "a", AgentState: "working", LastFlipAt: flipAt, LastFrameAt: flipAt})
	got := herdHeartbeat(h, "a", hNow)
	r := got.Rows["a"]
	if !r.LastFrameAt.Equal(hNow) {
		t.Fatalf("heartbeat must bump LastFrameAt, got %v", r.LastFrameAt)
	}
	if r.AgentState != "working" || !r.LastFlipAt.Equal(flipAt) {
		t.Fatalf("heartbeat must touch NOTHING else, got %+v", r)
	}
	// an out-of-order (older) tick never rewinds the clock
	got = herdHeartbeat(got, "a", hNow.Add(-time.Hour))
	if !got.Rows["a"].LastFrameAt.Equal(hNow) {
		t.Fatalf("an older tick must not rewind LastFrameAt, got %v", got.Rows["a"].LastFrameAt)
	}
	// unknown session: ignored, roster untouched
	got = herdHeartbeat(got, "ghost", hNow)
	if _, ok := got.Rows["ghost"]; ok {
		t.Fatal("a heartbeat must never mount a row")
	}
}

// TestHerdTitleRenamesInPlaceOnly is the D69h title-fold proof: the frame
// renames the row and touches NOTHING else — state and BOTH clocks are
// untouched, so a rename can never un-stall a wedged session (the lie the fold
// must not tell). A blank title keeps the held one, and a title for a session
// the herd does not hold never mounts a row (the herdHeartbeat rule).
func TestHerdTitleRenamesInPlaceOnly(t *testing.T) {
	flipAt := hNow.Add(-10 * time.Minute) // already past herdStallAfter
	h := seedHerd(HerdRow{SessionID: "a", AgentState: "working", Title: "held", LastFlipAt: flipAt, LastFrameAt: flipAt})
	if !herdStalled(h.Rows["a"], hNow) {
		t.Fatal("precondition: the row must be stalled before the rename")
	}

	got := herdTitle(h, "a", "  renamed elsewhere  ")
	r := got.Rows["a"]
	if r.Title != "renamed elsewhere" {
		t.Fatalf("title frame must rename the row (trimmed), got %q", r.Title)
	}
	if r.AgentState != "working" || !r.LastFlipAt.Equal(flipAt) || !r.LastFrameAt.Equal(flipAt) {
		t.Fatalf("title frame must touch NOTHING else, got %+v", r)
	}
	if !herdStalled(r, hNow) {
		t.Fatal("a rename must NEVER un-stall a wedged session (it is not a sign of life)")
	}

	// a blank title keeps the held one (the shared trimTitle law)
	if got = herdTitle(got, "a", "   "); got.Rows["a"].Title != "renamed elsewhere" {
		t.Fatalf("a blank title must keep the held one, got %q", got.Rows["a"].Title)
	}
	// unknown session: ignored, roster untouched
	if got = herdTitle(got, "ghost", "nobody"); len(got.Rows) != 1 {
		t.Fatalf("a title must never mount a row, got %d rows", len(got.Rows))
	}
}

// TestApplyFleetFrameFoldsTheTitleFrame proves the WIRE half of D69h: the
// id-less {session_id,title} frame (chat_controller.fleet_title_frame/2's exact
// shape) decodes and lands on the row — the fold this client did not have, so a
// session renamed elsewhere no longer wears a stale title until the next
// snapshot. A session-id-less or malformed frame is ignored, never a crash.
func TestApplyFleetFrameFoldsTheTitleFrame(t *testing.T) {
	h := seedHerd(HerdRow{SessionID: "a", AgentState: "idle", Title: "old title", LastFlipAt: hNow, LastFrameAt: hNow})
	got, ok := applyFleetFrame(h, "title", []byte(`{"session_id":"a","title":"Fix the auth redirect loop"}`))
	if !ok {
		t.Fatal("a title frame must apply")
	}
	if got.Rows["a"].Title != "Fix the auth redirect loop" {
		t.Fatalf("the title frame must fold onto the row, got %q", got.Rows["a"].Title)
	}
	if got.Rows["a"].AgentState != "idle" || !got.Rows["a"].LastFrameAt.Equal(hNow) {
		t.Fatalf("the title frame must carry no state/liveness, got %+v", got.Rows["a"])
	}
	if _, ok := applyFleetFrame(h, "title", []byte(`{"title":"orphan"}`)); ok {
		t.Fatal("a session-id-less title frame must be ignored")
	}
	if _, ok := applyFleetFrame(h, "title", []byte(`{not json`)); ok {
		t.Fatal("malformed JSON must be ignored, never a crash")
	}
}

// TestHerdStallBadgeFreshFromFrames is the D53h stall proof: working + no
// frame for >150s (the NEW herd const, NOT workflowStallAfter) wears the
// badge; any fresh frame — a heartbeat included — clears it for free; blocked
// and idle sessions never stall; a clockless row never stalls.
func TestHerdStallBadgeFreshFromFrames(t *testing.T) {
	if herdStallAfter != 150*time.Second {
		t.Fatalf("herdStallAfter must be the charter's 150s, got %v", herdStallAfter)
	}
	if herdStallAfter == workflowStallAfter {
		t.Fatal("herdStallAfter must be DISTINCT from the D41 agent-stall const")
	}
	old := hNow.Add(-herdStallAfter - time.Second)
	stalled := HerdRow{SessionID: "a", AgentState: "working", LastFlipAt: old, LastFrameAt: old}
	if !herdStalled(stalled, hNow) {
		t.Fatal("working + no frame past the threshold must stall")
	}
	// a heartbeat un-stalls with no state change
	h := herdHeartbeat(seedHerd(stalled), "a", hNow)
	if herdStalled(h.Rows["a"], hNow) {
		t.Fatal("a fresh heartbeat must clear the stall badge for free")
	}
	for _, state := range []string{"blocked", "idle", "unknown"} {
		if herdStalled(HerdRow{AgentState: state, LastFrameAt: old}, hNow) {
			t.Fatalf("%s must never wear the stall badge", state)
		}
	}
	if herdStalled(HerdRow{AgentState: "working"}, hNow) {
		t.Fatal("a row that never saw a frame timestamp cannot honestly stall")
	}
}

// TestHerdAttentionSort proves the sort law: blocked > stalled > working >
// idle (unknown below idle), tie-break LastFlipAt desc then session id asc —
// fully deterministic.
func TestHerdAttentionSort(t *testing.T) {
	old := hNow.Add(-herdStallAfter - time.Minute)
	h := seedHerd(
		HerdRow{SessionID: "idle1", AgentState: "idle", LastFlipAt: hNow},
		HerdRow{SessionID: "work1", AgentState: "working", LastFlipAt: hNow, LastFrameAt: hNow},
		HerdRow{SessionID: "stall1", AgentState: "working", LastFlipAt: old, LastFrameAt: old},
		HerdRow{SessionID: "block1", AgentState: "blocked", LastFlipAt: old},
		HerdRow{SessionID: "gone1", AgentState: "unknown", LastFlipAt: hNow},
	)
	roster := []string{"idle1", "work1", "stall1", "block1", "gone1"}
	got := herdOrder(h, roster, hNow)
	want := []string{"block1", "stall1", "work1", "idle1", "gone1"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("attention order = %v, want %v", got, want)
		}
	}

	// tie-break inside a band: freshest flip first, then session id
	h2 := seedHerd(
		HerdRow{SessionID: "b", AgentState: "working", LastFlipAt: hNow.Add(-time.Minute), LastFrameAt: hNow},
		HerdRow{SessionID: "a", AgentState: "working", LastFlipAt: hNow.Add(-time.Minute), LastFrameAt: hNow},
		HerdRow{SessionID: "z", AgentState: "working", LastFlipAt: hNow, LastFrameAt: hNow},
	)
	got2 := herdOrder(h2, []string{"b", "a", "z"}, hNow)
	want2 := []string{"z", "a", "b"}
	for i := range want2 {
		if got2[i] != want2[i] {
			t.Fatalf("tie-break order = %v, want %v", got2, want2)
		}
	}
}

// TestHerdCursorFollowsSessionAcrossResort proves the D52h cursor law at the
// reducer level: the cursor is a session ID, so after a flip resorts the herd
// the same session is still under it — resolved against the fresh order.
func TestHerdCursorFollowsSessionAcrossResort(t *testing.T) {
	h := seedHerd(
		HerdRow{SessionID: "a", AgentState: "working", LastFlipAt: hNow, LastFrameAt: hNow},
		HerdRow{SessionID: "b", AgentState: "idle", LastFlipAt: hNow.Add(-time.Minute)},
	)
	h.Cursor = "b"
	before := herdOrder(h, []string{"a", "b"}, hNow)
	if before[1] != "b" {
		t.Fatalf("precondition: b sorts last while idle, got %v", before)
	}
	// b flips blocked → resorts to the top; the cursor STRING still names b
	h2, ok := applyFleetFrame(h, "state", []byte(`{"session_id":"b","agent_state":"blocked","ts":"`+hISO(hNow)+`","title":null}`))
	if !ok {
		t.Fatal("state frame must apply")
	}
	after := herdOrder(h2, []string{"a", "b"}, hNow)
	if after[0] != "b" {
		t.Fatalf("b must resort to the attention top, got %v", after)
	}
	if h2.Cursor != "b" {
		t.Fatalf("the cursor must still name session b, got %q", h2.Cursor)
	}
}

// TestApplyFleetFrameParsesTheThreeShapes proves the D45h wire shapes decode
// (snapshot wrapper, flat state flip, id-less heartbeat) and that junk frames
// are ignored rather than crashing the herd.
func TestApplyFleetFrameParsesTheThreeShapes(t *testing.T) {
	h, ok := applyFleetFrame(HerdState{}, "snapshot",
		[]byte(`{"sessions":[{"session_id":"a","agent_state":"working","ts":"`+hISO(hNow)+`","title":"first"}]}`))
	if !ok || h.Rows["a"].AgentState != "working" || h.Rows["a"].Title != "first" {
		t.Fatalf("snapshot frame must mount rows, got %+v", h.Rows["a"])
	}
	h, ok = applyFleetFrame(h, "state",
		[]byte(`{"session_id":"a","agent_state":"blocked","ts":"`+hISO(hNow)+`","title":null}`))
	if !ok || h.Rows["a"].AgentState != "blocked" || h.Rows["a"].Title != "first" {
		t.Fatalf("state frame must flip + keep the title, got %+v", h.Rows["a"])
	}
	h, ok = applyFleetFrame(h, "heartbeat",
		[]byte(`{"session_id":"a","ts":"`+hISO(hNow.Add(time.Minute))+`"}`))
	if !ok || !h.Rows["a"].LastFrameAt.Equal(hNow.Add(time.Minute)) {
		t.Fatalf("heartbeat frame must bump LastFrameAt, got %+v", h.Rows["a"])
	}
	if _, ok := applyFleetFrame(h, "mystery", []byte(`{}`)); ok {
		t.Fatal("an unknown event must be ignored")
	}
	if _, ok := applyFleetFrame(h, "state", []byte(`{not json`)); ok {
		t.Fatal("malformed JSON must be ignored, never a crash")
	}
}
