package taskboard

import (
	"context"
	"testing"
	"time"
)

// corpus_membership_test.go pins the CHEAP periodic resync of
// task-1ca34359dc0805df: a live board whose base is merely DUE re-verifies it
// through `?view=ids` instead of re-downloading the corpus, and still retires a
// row that vanished without a write — the one job fullResyncEvery exists for.

// vanish removes a row WITHOUT an event and without re-stamping any survivor:
// the hard-delete / twin-collapse shape the incremental head walk cannot see.
func (l *fakeLedger) vanish(docID string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for i := range l.rows {
		if l.rows[i].DocID == docID {
			l.rows = append(l.rows[:i], l.rows[i+1:]...)
			return
		}
	}
	l.t.Fatalf("vanish: no such row %q", docID)
}

// restamp moves a row's updated_at to an OLDER instant without an event — a
// different version of the row at or below the watermark, which neither the
// head walk nor a prune can explain.
func (l *fakeLedger) restamp(docID string, at time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for i := range l.rows {
		if l.rows[i].DocID == docID {
			l.rows[i].UpdatedAt = at
			return
		}
	}
	l.t.Fatalf("restamp: no such row %q", docID)
}

// fullWalkPages counts corpus GETs that were pages of a FULL board walk
// (`view=board`, limit 1000), as opposed to head pages (limit 50) or the ids
// membership walk.
func (l *fakeLedger) fullWalkPages() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for i, v := range l.viewsSeen {
		if v == "board" && l.limitsSeen[i] == 1000 {
			n++
		}
	}
	return n
}

func hasRow(tasks []Task, id string) bool {
	for _, t := range tasks {
		if t.DocID == id {
			return true
		}
	}
	return false
}

// primeDueBase runs the launch walk and returns the cache plus the instant at
// which its base is DUE for the periodic resync.
func primeDueBase(t *testing.T, l *fakeLedger) (*corpusCache, time.Time) {
	t.Helper()
	cc := &corpusCache{live: true}
	t0 := time.Now()
	if _, _, exh, err := fetchTaskCorpus(context.Background(), l.client(), cc, t0); err != nil || !exh {
		t.Fatalf("launch walk: exhaustive=%v err=%v", exh, err)
	}
	if got := l.fullWalkPages(); got == 0 {
		t.Fatal("precondition failed: the launch walk made no full-walk page, so the fixture does not tell a full walk apart")
	}
	return cc, t0.Add(fullResyncEvery + time.Second)
}

func TestDueResyncVerifiesByMembershipNotByRedownload(t *testing.T) {
	l := newFakeLedger(t, 2500, 2000)
	cc, due := primeDueBase(t, l)
	fullBefore := l.fullWalkPages()
	boardBefore, _ := l.tally("tasks")

	l.vanish("t-1200")                                       // gone without a write
	l.mutate("t-2000", "Changed after the base", time.Now()) // a normal write

	tasks, _, exh, err := fetchTaskCorpus(context.Background(), l.client(), cc, due)
	if err != nil || !exh {
		t.Fatalf("due resync: exhaustive=%v err=%v", exh, err)
	}
	if got := l.fullWalkPages() - fullBefore; got != 0 {
		t.Fatalf("the due resync re-downloaded the corpus (%d full-walk pages) — the membership path did not answer", got)
	}
	if _, calls := l.tally("tasks_ids"); calls == 0 {
		t.Fatal("the due resync never asked ?view=ids")
	}
	if hasRow(tasks, "t-1200") {
		t.Fatal("a row that vanished without a write survived the resync — the one job fullResyncEvery exists for")
	}
	found := false
	for _, tk := range tasks {
		if tk.DocID == "t-2000" {
			found = tk.Title == "Changed after the base"
		}
	}
	if !found {
		t.Fatal("the write made after the base is not on the resynced corpus: the head walk did not run over the pruned base")
	}
	if len(tasks) != 2499 {
		t.Fatalf("resynced corpus has %d rows, want 2499", len(tasks))
	}
	if b := cc.snapshot(); !b.lastFull.Equal(due) || !b.exhaustive {
		t.Fatalf("the verified base must restart the resync clock: lastFull=%v exhaustive=%v, want %v true", b.lastFull, b.exhaustive, due)
	}
	// The point of the path, as bytes: the resync's board-view spend is the head
	// walk only, far below one full re-download of the same corpus.
	boardAfter, _ := l.tally("tasks")
	if spent := boardAfter - boardBefore; spent*10 > boardBefore {
		t.Fatalf("the resync spent %d board-view bytes against a %d-byte launch walk — not a cheap resync", spent, boardBefore)
	}
}

func TestMembershipDisagreementFallsBackToTheFullWalk(t *testing.T) {
	l := newFakeLedger(t, 1500, 200)
	cc, due := primeDueBase(t, l)
	fullBefore := l.fullWalkPages()

	// A different version of a row BELOW the watermark: nothing the prune or
	// the head walk can explain.
	l.restamp("t-0700", time.Date(2025, 6, 1, 0, 0, 0, 0, time.UTC))

	if _, _, exh, err := fetchTaskCorpus(context.Background(), l.client(), cc, due); err != nil || !exh {
		t.Fatalf("due resync: exhaustive=%v err=%v", exh, err)
	}
	if l.fullWalkPages() == fullBefore {
		t.Fatal("an unexplainable membership disagreement did NOT fall back to the full walk — the cheap path vouched for a corpus it could not explain")
	}
}

func TestServerWithoutTheIDsViewFallsBackToTheFullWalk(t *testing.T) {
	l := newFakeLedger(t, 1500, 200)
	cc, due := primeDueBase(t, l)
	fullBefore := l.fullWalkPages()
	l.mu.Lock()
	l.refuseIDs = true
	l.mu.Unlock()
	l.vanish("t-0300")

	tasks, _, exh, err := fetchTaskCorpus(context.Background(), l.client(), cc, due)
	if err != nil || !exh {
		t.Fatalf("due resync against an older server: exhaustive=%v err=%v — a refused ?view=ids must fall back, never fail the board", exh, err)
	}
	if l.fullWalkPages() == fullBefore {
		t.Fatal("a server that refuses ?view=ids did not get the full walk")
	}
	if hasRow(tasks, "t-0300") {
		t.Fatal("the fallback full walk kept a vanished row")
	}
}

func TestPruneByMembership(t *testing.T) {
	wm := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	older := wm.Add(-time.Hour)
	base := corpusBase{
		tasks: []Task{
			{DocID: "a", UpdatedAt: wm},
			{DocID: "b", UpdatedAt: older},
			{DocID: "c", UpdatedAt: older},
		},
		details:    DetailIndex{"a": {}, "b": {}, "c": {}},
		watermark:  wm,
		exhaustive: true,
		lastFull:   older,
	}
	cases := []struct {
		name    string
		members map[string]time.Time
		wantOK  bool
		wantIDs []string
	}{
		{"all listed, unchanged", map[string]time.Time{"a": wm, "b": older, "c": older}, true, []string{"a", "b", "c"}},
		{"one vanished", map[string]time.Time{"a": wm, "c": older}, true, []string{"a", "c"}},
		{"a row newer than the watermark is the head walk's", map[string]time.Time{"a": wm.Add(time.Minute), "b": older, "c": older}, true, []string{"a", "b", "c"}},
		{"a new row newer than the watermark is the head walk's", map[string]time.Time{"a": wm, "b": older, "c": older, "d": wm.Add(time.Minute)}, true, []string{"a", "b", "c"}},
		{"an unknown row at or below the watermark", map[string]time.Time{"a": wm, "b": older, "c": older, "d": older}, false, nil},
		{"a listed row with a different old version", map[string]time.Time{"a": wm, "b": older.Add(-time.Minute), "c": older}, false, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, _, ok := pruneByMembership(base, tc.members)
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tc.wantOK)
			}
			if !ok {
				return
			}
			if len(got.tasks) != len(tc.wantIDs) {
				t.Fatalf("kept %d rows, want %v", len(got.tasks), tc.wantIDs)
			}
			for i, id := range tc.wantIDs {
				if got.tasks[i].DocID != id {
					t.Fatalf("row %d = %s, want %s (order must be kept)", i, got.tasks[i].DocID, id)
				}
				if _, ok := got.details[id]; !ok {
					t.Fatalf("details for kept row %s were dropped", id)
				}
			}
			if len(got.details) != len(tc.wantIDs) {
				t.Fatalf("details carry %d rows, want %d (a vanished row's detail must go with it)", len(got.details), len(tc.wantIDs))
			}
		})
	}
}
