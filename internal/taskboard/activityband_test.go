package taskboard

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// activityband_test.go — the wave-12 guard (charter D58–D63): the pinned TOP band
// gains WHO (agent-attributed NOW rows) + INTENT (the tiny NEXT strip). The
// corpus fixture (livecorpus_test.go) carries a live in_progress claim, a fresh
// task.lease_expired resumable (studio-user-login), a P0 ready head (orph-p0) and
// the empty state, so BuildBoard → Render exercises the whole band. These pin
// what a golden alone would not, with TEETH.

// TestNextResumableFirst — a lease dropped mid-work surfaces FIRST in NEXT, as a
// nextResume carrying its lease-expiry time (charter D60/D61).
func TestNextResumableFirst(t *testing.T) {
	b := BuildBoard(corpusSnapshot(), RepoContext{}, corpusFixedNow)
	if len(b.Next) == 0 {
		t.Fatalf("NEXT strip is empty — the resumable + ready head did not resolve")
	}
	first := b.Next[0]
	if first.Kind != nextResume || first.Task.DocID != "studio-user-login" {
		t.Fatalf("NEXT[0] = {%v %q}, want the studio-user-login resumable first", first.Kind, first.Task.DocID)
	}
	if first.LeaseExpiredAt.IsZero() {
		t.Errorf("resumable carries no lease-expiry time — the row can't say 'lease expired <age>'")
	}
	// It renders with the ↩ marker + a "lease expired" cause.
	frame := ansi.Strip(Render(b, corpusUIState(), 72, 80, corpusFixedNow))
	if !strings.Contains(frame, "↩") || !strings.Contains(frame, "lease expired") {
		t.Errorf("NEXT resumable row missing ↩ / 'lease expired':\n%s", frame)
	}
	if !strings.Contains(frame, "NEXT") {
		t.Errorf("NEXT strip label missing from the frame:\n%s", frame)
	}
}

// TestNextReadyHeadP0First — behind the resumables, the ready head is P0-first
// (the same order bp task next uses), and resumables always precede ready rows.
func TestNextReadyHeadP0First(t *testing.T) {
	b := BuildBoard(corpusSnapshot(), RepoContext{}, corpusFixedNow)
	seenReady := false
	var firstReady *NextItem
	for i := range b.Next {
		it := b.Next[i]
		if it.Kind == nextReady {
			if firstReady == nil {
				firstReady = &b.Next[i]
			}
			seenReady = true
		} else if seenReady {
			t.Fatalf("a resumable followed a ready row in NEXT — resumables must lead: %+v", nextKinds(b.Next))
		}
	}
	if firstReady == nil {
		t.Fatalf("no ready row in NEXT — the P0 head did not resolve: %+v", nextKinds(b.Next))
	}
	if got := priorityRank(firstReady.Task.Priority); got != 0 {
		t.Errorf("first NEXT ready row = %q (priority rank %d), want the P0 head (orph-p0)", firstReady.Task.DocID, got)
	}
	// The cap holds and there is an honest remainder tail.
	if len(b.Next) > nextMax {
		t.Errorf("NEXT strip has %d rows, over the cap %d", len(b.Next), nextMax)
	}
	if b.NextReadyMore <= 0 {
		t.Errorf("expected a '+N ready' remainder (many ready tasks exceed the strip budget), got %d", b.NextReadyMore)
	}
}

func nextKinds(ns []NextItem) []NextKind {
	out := make([]NextKind, len(ns))
	for i, n := range ns {
		out[i] = n.Kind
	}
	return out
}

// TestNextCursorParity — a board WITH next rows: the NEXT rows are cursor stops
// pinned at [len(Now), len(Now)+len(Next)); visibleRows' head count matches
// flattenSpine's pinned offset, so the ▎ marker sits on exactly the acted-on row
// for EVERY cursor index (charter D63 structural parity, extended to NEXT).
func TestNextCursorParity(t *testing.T) {
	m := testModel(nextBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 60

	rows := m.visibleRows()
	// The head is exactly NOW + NEXT before any spine row.
	head := len(m.board.Now) + len(m.board.Next)
	for i := 0; i < head; i++ {
		if i < len(m.board.Now) && rows[i].kind != rowNow {
			t.Fatalf("pinned row %d is %v, want rowNow", i, rows[i].kind)
		}
		if i >= len(m.board.Now) && rows[i].kind != rowNext {
			t.Fatalf("pinned row %d is %v, want rowNext", i, rows[i].kind)
		}
	}
	for i, r := range rows {
		m.ui.Cursor = i
		frame := ansi.Strip(m.View())
		var marked []string
		for _, ln := range strings.Split(frame, "\n") {
			if strings.Contains(ln, "▎") {
				marked = append(marked, ln)
			}
		}
		if len(marked) != 1 {
			t.Fatalf("cursor %d (%v %q): %d ▎-marked lines, want 1\n%s", i, r.kind, r.docID, len(marked), frame)
		}
		want := r.docID
		if r.kind == rowOrphanHeader {
			want = "(no epic)" // the loose header paints its title, not its fold key
		}
		if !strings.Contains(marked[0], want) {
			t.Errorf("cursor %d: marked line %q does not carry %q (kind %v)", i, marked[0], want, r.kind)
		}
	}
}

// nextBoard is a small parity fixture: sampleBoard's two NOW cards + a two-row
// NEXT strip (a resumable then a ready row) with a "+N ready" tail. Titles == doc
// ids so the ▎-marker check names the acted-on row.
func nextBoard() Board {
	b := sampleBoard()
	resume := t("nx-resume")
	ready := t("nx-ready")
	ready.Lifecycle = lifeReady
	b.Next = []NextItem{
		{Task: resume, Kind: nextResume, LeaseExpiredAt: time.Unix(1, 0)},
		{Task: ready, Kind: nextReady},
	}
	b.NextReadyMore = 4
	return b
}

// TestResumableExcludedByLaterClaim — a lease_expired that a LATER task.claimed
// superseded is no longer a follow-up: it drops from NEXT (charter D61).
func TestResumableExcludedByLaterClaim(t *testing.T) {
	base := corpusSnapshot()
	// Before: the resumable is present.
	if b := BuildBoard(base, RepoContext{}, corpusFixedNow); !hasResumable(b, "studio-user-login") {
		t.Fatalf("baseline: studio-user-login should be a resumable")
	}
	// Add a task.claimed AFTER the lease_expired (someone picked it back up).
	snap := corpusSnapshot()
	snap.Events = append(snap.Events, Event{
		Mutation: "task.claimed", DocID: "studio-user-login", At: corpusFixedNow.Add(-2 * time.Minute),
	})
	b := BuildBoard(snap, RepoContext{}, corpusFixedNow)
	if hasResumable(b, "studio-user-login") {
		t.Errorf("a re-claimed drop must not remain a resumable: %+v", nextKinds(b.Next))
	}
}

func hasResumable(b Board, docID string) bool {
	for _, ni := range b.Next {
		if ni.Kind == nextResume && ni.Task.DocID == docID {
			return true
		}
	}
	return false
}

// TestActivityBandCollapsesWhenIdle — empty NOW + empty NEXT collapses the band
// to NOTHING: no "NOW", no "NEXT", no "nothing claimed" line (charter D58/D63).
func TestActivityBandCollapsesWhenIdle(t *testing.T) {
	idle := Snapshot{
		Tasks: []Task{
			{DocID: "d1", Title: "long done", Lifecycle: lifeDone, UpdatedAt: corpusFixedNow.Add(-100 * time.Hour)},
		},
		Counts:    map[string]int{"done": 1},
		FetchedAt: corpusFixedNow.Add(-90 * time.Second),
	}
	b := BuildBoard(idle, RepoContext{}, corpusFixedNow)
	if len(b.Now) != 0 || len(b.Next) != 0 {
		t.Fatalf("idle board should have no NOW and no NEXT, got now=%d next=%d", len(b.Now), len(b.Next))
	}
	frame := ansi.Strip(Render(b, UIState{Conn: ConnLive, LastSync: corpusFixedNow}, 72, 30, corpusFixedNow))
	for _, banned := range []string{"NOW", "NEXT", "nothing claimed"} {
		if strings.Contains(frame, banned) {
			t.Errorf("idle board leaked %q — the activity band must collapse to nothing:\n%s", banned, frame)
		}
	}
}

// TestNextResumeClaimBypassesGate — c on a resumable NEXT row is routed AROUND the
// local ready-gate (charter D62): the open resumable would be refused by
// claimTask's ready-gate, but the c handler issues the claim (server arbitrates).
// The two halves TOGETHER document why the bypass exists.
func TestNextResumeClaimBypassesGate(t *testing.T) {
	b := nextBoard()
	// Make the resumable genuinely non-ready (open), the live shape D62 addresses.
	b.Next[0].Task.Lifecycle = lifeOpen
	m := testModel(b)
	m.now = func() time.Time { return time.Unix(2, 0) }

	// (a) WITHOUT the bypass, claimTask refuses an open row — the ready-gate bites.
	// claimTask is a value receiver, so capture the returned model to read its strip.
	rm, cmd := m.claimTask(b.Next[0].Task)
	if cmd != nil {
		t.Errorf("claimTask on an open resumable should refuse (ready-gate), but issued a command")
	}
	if rm.ui.Strip.Role != RoleWarn {
		t.Errorf("claimTask on an open resumable should set a warn strip, got role %v", rm.ui.Strip.Role)
	}

	// (b) WITH the bypass, c on the resumable NEXT row issues the claim regardless.
	m2 := testModel(b)
	m2.now = func() time.Time { return time.Unix(2, 0) }
	m2.ui.Cursor = len(b.Now) // the first NEXT row (the resumable)
	if r, ok := m2.currentRow(); !ok || r.kind != rowNext {
		t.Fatalf("cursor did not land on the NEXT resumable row, got %+v ok=%v", r, ok)
	}
	nm, cmd := step(t, m2, runes("c"))
	if cmd == nil {
		t.Errorf("c on the resumable NEXT row should issue a claim command (D62 bypass), got nil")
	}
	if nm.ui.Strip.Role == RoleWarn {
		t.Errorf("c on the resumable should not warn-refuse (D62 bypass), strip=%q", nm.ui.Strip.Message)
	}
}

// TestNextRowActionsResolve — x/o on a NEXT row resolve via taskByID (a resumable
// can be a folded orphan absent elsewhere). x on an unclaimed resumable honestly
// refuses (no live claim); o builds a Studio link.
func TestNextRowActionsResolve(t *testing.T) {
	b := nextBoard()
	m := testModel(b)
	m.cfg.BaseURL = "https://guerrilla.barkpark.cloud"
	m.ui.Cursor = len(b.Now) // the resumable NEXT row
	if _, found := m.taskByID("nx-resume"); !found {
		t.Fatalf("taskByID must find a NEXT row's task")
	}
	// x honestly refuses (no live claim on the resumable).
	nm, _ := step(t, m, runes("x"))
	if nm.ui.Strip.Role != RoleWarn {
		t.Errorf("x on an unclaimed resumable should warn-refuse, got role %v", nm.ui.Strip.Role)
	}
	// o builds a Studio deep link on the strip.
	m2 := testModel(b)
	m2.cfg.BaseURL = "https://guerrilla.barkpark.cloud"
	m2.ui.Cursor = len(b.Now)
	nm2, _ := step(t, m2, runes("o"))
	if !strings.Contains(nm2.ui.Strip.Message, "nx-resume") {
		t.Errorf("o on a NEXT row should surface a Studio link carrying the doc id, got %q", nm2.ui.Strip.Message)
	}
}

var _ tea.Model = Model{}
