package taskboard

import (
	"strings"
	"testing"
	"time"
)

// board_view_list_path_test.go guards the `?view=board` adoption, in the two
// directions a cheapening gets it wrong: asking for the projection at all, and
// still rendering everything the board draws once it has.
//
// It runs against the SAME fakeLedger the freshness guard uses
// (relist_liveness_test.go), which now serves the REAL projection shape —
// `content` deleted, `content_digest` in its place — so a board that quietly
// kept reading `content` fails here instead of passing on a shape the live
// server never sends.

// viewsFor returns every ?view= the corpus GET was asked with.
func (l *fakeLedger) views() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.viewsSeen...)
}

// TestTheLiveBoardsListPathAsksForTheBoardProjection is c0's mechanism half.
//
// The bound c0 states is a byte count against a live ledger, which no unit test
// can assert. What a unit test CAN assert — and what the byte count is entirely
// downstream of — is that the live board's corpus GET spells the projection,
// and that a one-shot CLI verb does NOT (those verbs read prose out of the same
// list body and have nowhere to hydrate it from; see corpusCache.listView).
func TestTheLiveBoardsListPathAsksForTheBoardProjection(t *testing.T) {
	l := newFakeLedger(t, 40, 64)

	// The LIVE board's seam.
	live := newSnapshotFetcher("", "")
	if _, _, err := live(l.client()); err != nil {
		t.Fatalf("live board fetch: %v", err)
	}
	got := l.views()
	if len(got) == 0 {
		t.Fatal("the corpus GET was never made — nothing below measures anything")
	}
	for i, v := range got {
		if v != "board" {
			t.Fatalf("the live board's list GET #%d spelled ?view=%q, want %q: a board on the default shape re-downloads every row's prose on every re-list (105,755,961 B vs 13,035,765 B, guerrilla 2026-09-23)", i, v, "board")
		}
	}

	// A one-shot verb's seam, on a fresh ledger so the two populations cannot
	// be confused.
	l2 := newFakeLedger(t, 40, 64)
	if _, _, err := FetchSnapshotFull(l2.client()); err != nil {
		t.Fatalf("one-shot fetch: %v", err)
	}
	for i, v := range l2.views() {
		if v != "" {
			t.Fatalf("a one-shot verb's list GET #%d spelled ?view=%q, want the default shape: `bp task enrichment` reads Disposition/CloseReason and `bp task frontier` reads design_doc out of THIS body, and neither has a hydration path", i, v)
		}
	}
}

// TestTheLadderAndBadgeSurviveTheBoardProjection is c1: every field the board
// draws on the ROW path still renders when `content` is gone.
//
// Two of them, and both fail QUIETLY rather than blanking:
//   - the criteria ladder has THREE states (met / an honest recorded miss /
//     untouched), and the projection ships them as one character each. A
//     producer or consumer that collapses the middle one loses amber silently.
//   - the completeness badge scores seven inputs; three of them lived only in
//     `content`, so a badge scored off the survivors renders a LOWER SCORE
//     THAT LOOKS REAL.
func TestTheLadderAndBadgeSurviveTheBoardProjection(t *testing.T) {
	l := newFakeLedger(t, 3, 16)
	live := newSnapshotFetcher("", "")
	snap, _, err := live(l.client())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snap.Tasks) == 0 {
		t.Fatal("no tasks decoded off the board projection")
	}
	task := snap.Tasks[0]

	// The fixture's digest is criteria_marks "mao": met, an honest miss, untouched.
	if len(task.CriteriaItems) != 3 {
		t.Fatalf("the ladder rebuilt %d rungs from criteria_marks %q, want 3: the ladder renders ONE RUNG PER ENTRY, so a short rebuild is a short ladder", len(task.CriteriaItems), "mao")
	}
	want := []struct{ met, missed bool }{{true, false}, {false, true}, {false, false}}
	for i, w := range want {
		got := task.CriteriaItems[i]
		if got.Met != w.met || got.MarkedMissed != w.missed {
			t.Fatalf("rung %d off the projection is {met:%v missed:%v}, want {met:%v missed:%v}: the ladder has THREE states and the middle one (amber, from attempts[]) is the one a two-state rebuild drops without a blank", i, got.Met, got.MarkedMissed, w.met, w.missed)
		}
	}

	// has_description is true in the fixture's digest and the prose is GONE, so
	// a badge that scored off the surviving fields alone would come back one
	// point short — plausible, and wrong.
	for _, gap := range task.Completeness.Gaps {
		if gap == "description" {
			t.Fatalf("the completeness badge scored %s and calls `description` a GAP, but content_digest.has_description is true: the badge does not blank, it renders a lower score that looks real", completenessBadge(task.Completeness))
		}
	}
}

// TestAnOpenedRowHydratesItsProseAndKeepsItAcrossARelist is the other half of
// c1 — the fields the projection legitimately does not carry.
//
// `?view=board` deletes the whole TaskDetail reading model (description, brief,
// evidence, code_refs, purpose, the disposition strips). The board pays for
// those one opened row at a time off the always-full row route. Two things have
// to hold, and the second is the one a naive version gets wrong: applySnapshot
// replaces m.details wholesale every few seconds, so a hydration stored there
// would be erased and silently re-fetched forever.
func TestAnOpenedRowHydratesItsProseAndKeepsItAcrossARelist(t *testing.T) {
	l := newFakeLedger(t, 40, 64)
	var armed []time.Duration
	m := ledgerModel(l, &armed)
	m = driveSnapshot(t, m, m.refetchCmd(false))

	const subject = "t-0007"
	if d, _ := m.detailFor(subject); d.Description != "" {
		t.Fatalf("the board projection delivered a description (%q) — the fixture is not serving the projection and this test proves nothing", d.Description)
	}

	// Enter the row. The hook lives in Update, so drive Update, not pushFrame.
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: subject})
	nm, cmd := m.Update(nil)
	m = nm.(Model)
	if cmd == nil {
		t.Fatal("opening a row on the board projection queued NO hydration: the pane renders a SHORTER detail that looks real, which is the failure this seam exists to prevent")
	}
	for _, msg := range runCmd(cmd) {
		if hm, ok := msg.(taskDetailLoadedMsg); ok {
			m, _ = m.handleTaskDetailLoaded(hm)
		}
	}
	d, ok := m.detailFor(subject)
	if !ok || d.Description != "PROSE for "+subject {
		t.Fatalf("after hydration %s reads Description=%q (present=%v), want %q", subject, d.Description, ok, "PROSE for "+subject)
	}

	// A re-list replaces m.details wholesale. The overlay must survive it.
	m.fetchInFlight = false
	m = driveSnapshot(t, m, m.refetchCmd(false))
	if d, _ := m.detailFor(subject); d.Description != "PROSE for "+subject {
		t.Fatalf("a re-list erased the hydrated prose for %s (Description=%q): applySnapshot must never write the overlay, or every tick re-fetches every open row", subject, d.Description)
	}
	if _, calls := l.tally("task_row"); calls != 1 {
		t.Fatalf("the row route was called %d times for ONE opened row: the trade `?view=board` makes is one small GET per opened row, not one per tick", calls)
	}
}

// TestAMovedRowIsReHydrated is the staleness direction: holding a hydration
// because "we already have one" is how an open pane goes quietly out of date.
// The overlay is keyed by REV, so a row that moved is fetched again.
func TestAMovedRowIsReHydrated(t *testing.T) {
	l := newFakeLedger(t, 40, 64)
	var armed []time.Duration
	m := ledgerModel(l, &armed)
	m = driveSnapshot(t, m, m.refetchCmd(false))

	const subject = "t-0007"
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: subject})
	m = drainHydration(t, m)
	if _, calls := l.tally("task_row"); calls != 1 {
		t.Fatalf("first open: row route called %d times, want 1", calls)
	}

	// Asking again with nothing moved must NOT re-fetch.
	if cmd := (&m).ensureTaskDetail(subject); cmd != nil {
		t.Fatal("an unchanged row queued a SECOND hydration: the overlay is not being consulted, so every paint pays a round-trip")
	}

	// Move the row, re-list, ask again.
	l.mutate(subject, "MOVED", time.Now().UTC())
	m.fetchInFlight = false
	m = driveSnapshot(t, m, m.refetchCmd(false))
	m = drainHydration(t, m)
	if _, calls := l.tally("task_row"); calls != 2 {
		t.Fatalf("after the row's rev moved, the row route has been called %d times, want 2: a rev-blind overlay serves the prose of a row that no longer exists in that shape", calls)
	}
}

// TestOnlyOneHydrationIsInFlight is the cost guard. The preview target changes
// on EVERY j/k, so an unguarded ensure issues one GET per keystroke — which
// would hand back, one small request at a time, the bytes the projection saved.
func TestOnlyOneHydrationIsInFlight(t *testing.T) {
	l := newFakeLedger(t, 40, 64)
	var armed []time.Duration
	m := ledgerModel(l, &armed)
	m = driveSnapshot(t, m, m.refetchCmd(false))

	first := (&m).ensureTaskDetail("t-0001")
	if first == nil {
		t.Fatal("the first ensure queued nothing")
	}
	for _, id := range []string{"t-0002", "t-0003", "t-0004", "t-0005"} {
		if cmd := (&m).ensureTaskDetail(id); cmd != nil {
			t.Fatalf("%s queued a hydration while one was already in flight: a fast scroll would cost one round-trip per row", id)
		}
	}
	for _, msg := range runCmd(first) {
		if hm, ok := msg.(taskDetailLoadedMsg); ok {
			m, _ = m.handleTaskDetailLoaded(hm)
		}
	}
	// The flight landed; the settled target is now fetchable.
	if cmd := (&m).ensureTaskDetail("t-0005"); cmd == nil {
		t.Fatal("after the flight landed, the settled target queued nothing: the guard is stuck and no row will ever hydrate again")
	}
}

// TestAFailedHydrationIsNotCached: a transient failure must not be remembered
// as "this row has no prose", and must not blank what is already in hand.
func TestAFailedHydrationIsNotCached(t *testing.T) {
	l := newFakeLedger(t, 5, 16)
	var armed []time.Duration
	m := ledgerModel(l, &armed)
	m = driveSnapshot(t, m, m.refetchCmd(false))

	m.hydrating = "t-0001"
	m, _ = m.handleTaskDetailLoaded(taskDetailLoadedMsg{ref: "t-0001", err: errFake})
	if _, ok := m.hydrated["t-0001"]; ok {
		t.Fatal("a FAILED hydration was cached: the row would render prose-less forever and never ask again")
	}
	if cmd := (&m).ensureTaskDetail("t-0001"); cmd == nil {
		t.Fatal("after a failed hydration the row cannot be retried: the in-flight guard was never cleared")
	}
}

var errFake = errFakeType("hydration refused")

type errFakeType string

func (e errFakeType) Error() string { return string(e) }

// drainHydration runs Update's hydration hook to completion for the current
// detail subject.
func drainHydration(t *testing.T, m Model) Model {
	t.Helper()
	nm, cmd := m.Update(nil)
	m = nm.(Model)
	if cmd == nil {
		return m
	}
	for _, msg := range runCmd(cmd) {
		if hm, ok := msg.(taskDetailLoadedMsg); ok {
			m, _ = m.handleTaskDetailLoaded(hm)
		}
	}
	return m
}

// TestTheBoardViewParamIsSpelledOnce keeps the query fragment from drifting
// into a second spelling — the defect the listFetchPath constant already exists
// to prevent for `limit`.
func TestTheBoardViewParamIsSpelledOnce(t *testing.T) {
	if !strings.HasPrefix(boardViewParam, "&view=") {
		t.Fatalf("boardViewParam = %q, want a leading &view= — it is concatenated onto a path that already carries ?limit=", boardViewParam)
	}
	cc := &corpusCache{live: true}
	if got := cc.listView(); got != boardViewParam {
		t.Fatalf("a live cache's listView = %q, want %q", got, boardViewParam)
	}
	var bare *corpusCache
	if got := bare.listView(); got != "" {
		t.Fatalf("a nil cache's listView = %q, want the default shape", got)
	}
	if got := (&corpusCache{}).listView(); got != "" {
		t.Fatalf("a one-shot cache's listView = %q, want the default shape", got)
	}
}
