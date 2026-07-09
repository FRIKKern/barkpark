package taskboard

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// activityband_test.go — the NEXT intent MODEL guards (charter D60/D61/D65/D66)
// plus the Amendment 7 retirement guard. The pinned NOW/NEXT display band is
// RETIRED — claims render in place as spinner rows (D56) and the ready rows ARE
// the intent — but the board still resolves Next/IndependentReady as model
// state (the same curation `bp task next`/`bp task frontier` lean on), so the
// resolution rules keep their teeth here.

// TestNextResumableFirst — a lease dropped mid-work surfaces FIRST in Next, as a
// nextResume carrying its lease-expiry time (charter D60/D61).
func TestNextResumableFirst(t *testing.T) {
	b := BuildBoard(corpusSnapshot(), RepoContext{}, corpusFixedNow)
	if len(b.Next) == 0 {
		t.Fatalf("Next is empty — the resumable + ready head did not resolve")
	}
	first := b.Next[0]
	if first.Kind != nextResume || first.Task.DocID != "studio-user-login" {
		t.Fatalf("Next[0] = {%v %q}, want the studio-user-login resumable first", first.Kind, first.Task.DocID)
	}
	if first.LeaseExpiredAt.IsZero() {
		t.Errorf("resumable carries no lease-expiry time")
	}
}

// TestNextReadyHeadP0First — behind the resumables, the ready head is CURATED
// (charter D65): continuity with live/dropped work + leverage + well-formedness
// outrank the raw priority label, so the fixture's P1 inside the ACTIVE auth
// epic beats the cold orphan P0. Resumables still always precede ready rows.
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
			t.Fatalf("a resumable followed a ready row in Next — resumables must lead: %+v", nextKinds(b.Next))
		}
	}
	if firstReady == nil {
		t.Fatalf("no ready row in Next — the P0 head did not resolve: %+v", nextKinds(b.Next))
	}
	// D65: the continuity pick leads (auth is the active epic) and explains
	// itself; the cold orphan P0 no longer wins on its label alone.
	if firstReady.Task.DocID != "auth-w1-s1" {
		t.Errorf("first Next ready row = %q, want auth-w1-s1 (continuity with the active epic, D65)", firstReady.Task.DocID)
	}
	if !strings.Contains(firstReady.Reason, "continues") {
		t.Errorf("curated pick carries reason %q, want a 'continues …' justification", firstReady.Reason)
	}
	// The cap holds and there is an honest remainder tail.
	if len(b.Next) > nextMax {
		t.Errorf("Next has %d rows, over the cap %d", len(b.Next), nextMax)
	}
	if b.NextReadyMore <= 0 {
		t.Errorf("expected a '+N ready' remainder (many ready tasks exceed the cap), got %d", b.NextReadyMore)
	}
}

func nextKinds(ns []NextItem) []NextKind {
	out := make([]NextKind, len(ns))
	for i, n := range ns {
		out[i] = n.Kind
	}
	return out
}

// TestBandRetired — Amendment 7: a board that HAS live claims and Next intent
// paints NO pinned band (no "NOW"/"NEXT" labels) and gives band entries no
// cursor stops — the spine is the whole index space, and every cursor index
// still wears exactly one ▎ marker (parity stays structural).
func TestBandRetired(t *testing.T) {
	m := testModel(nextBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 60

	if len(m.board.Now) == 0 || len(m.board.Next) == 0 {
		t.Fatalf("fixture must carry Now and Next entries, got now=%d next=%d", len(m.board.Now), len(m.board.Next))
	}
	rows := m.visibleRows()
	spineSelectable := 0
	for _, sr := range spineRows(m.board, m.ui) {
		if sr.Selectable {
			spineSelectable++
		}
	}
	if len(rows) != spineSelectable {
		t.Fatalf("visibleRows = %d rows, want the %d selectable spine rows only (no band stops)", len(rows), spineSelectable)
	}
	for i, r := range rows {
		m.ui.Cursor = i
		frame := ansi.Strip(m.View())
		for _, banned := range []string{"NOW", "NEXT"} {
			if strings.Contains(frame, banned) {
				t.Fatalf("frame leaked the retired %q band label:\n%s", banned, frame)
			}
		}
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

// nextBoard is a small fixture: sampleBoard's two NOW claims + a two-row Next
// resolution (a resumable then a ready row) with a "+N ready" tail. Titles ==
// doc ids so the ▎-marker check names the acted-on row.
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
// superseded is no longer a follow-up: it drops from Next (charter D61).
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

var _ tea.Model = Model{}

// TestNextCurationSignals — charter D65/D66 unit truths: leverage beats a plain
// peer, zombies sink, and the strip picks at most one task per root
// neighborhood (independent moves, not one epic's queue).
func TestNextCurationSignals(t *testing.T) {
	old := refNow.Add(-8 * 24 * time.Hour)
	s := Snapshot{Tasks: []Task{
		{DocID: "g1", Title: "Epic one", Kind: kindGoal, Lifecycle: lifeOpen, UpdatedAt: refNow},
		{DocID: "a", Title: "unblocker", ParentID: "g1", Lifecycle: lifeReady, Priority: "2", DependentCount: 3, UpdatedAt: refNow},
		{DocID: "b", Title: "plain peer", ParentID: "g1", Lifecycle: lifeReady, Priority: "2", UpdatedAt: refNow},
		{DocID: "g2", Title: "Epic two", Kind: kindGoal, Lifecycle: lifeOpen, UpdatedAt: refNow},
		{DocID: "c", Title: "zombie p0", ParentID: "g2", Lifecycle: lifeReady, Priority: "0", UpdatedAt: old},
		{DocID: "d", Title: "fresh p1", ParentID: "g2", Lifecycle: lifeReady, Priority: "1", UpdatedAt: refNow},
	}}
	b := BuildBoard(s, RepoContext{}, refNow)
	if len(b.Next) < 2 {
		t.Fatalf("Next = %d rows, want >=2 (two independent neighborhoods)", len(b.Next))
	}
	// One pick per root (D66): never two rows from the same epic.
	roots := map[string]bool{}
	for _, ni := range b.Next {
		root := ni.Task.ParentID
		if roots[root] {
			t.Fatalf("two Next rows from root %q — the strip must pick independent moves", root)
		}
		roots[root] = true
	}
	// Leverage (D65): the unblocker beats its plain same-priority peer.
	for _, ni := range b.Next {
		if ni.Task.ParentID == "g1" && ni.Task.DocID != "a" {
			t.Errorf("g1 pick = %q, want the unblocker 'a' (DependentCount=3)", ni.Task.DocID)
		}
		// Zombie (D65): the week-old P0 loses to the fresh P1 in the same epic.
		if ni.Task.ParentID == "g2" && ni.Task.DocID != "d" {
			t.Errorf("g2 pick = %q, want the fresh 'd' (zombie P0 sinks)", ni.Task.DocID)
		}
	}
	if b.IndependentReady != 2 {
		t.Errorf("IndependentReady = %d, want 2 (two neighborhoods hold ready work)", b.IndependentReady)
	}
}
