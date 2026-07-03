package taskboard

import (
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// --- fixtures & helpers ------------------------------------------------------

func t(id string) Task { return Task{DocID: id, Title: id} }

// sampleBoard is a fixture exercising every row kind: two NOW cards, three
// epics (one dormant, so its children are hidden; two normal), and one orphan.
//
// Fresh (nothing collapsed) it flattens to 9 navigable rows:
//
//	0 now n1      3 child c1     6 header e3
//	1 now n2      4 child c2     7 child c3
//	2 header e1   5 header e2    8 orphan o1
//	                (e2 dormant)
func sampleBoard() Board {
	return Board{
		Now: []Task{t("n1"), t("n2")},
		Epics: []Epic{
			{Root: t("e1"), Children: []Task{t("c1"), t("c2")}},
			{Root: t("e2"), Children: []Task{t("cx")}, Dormant: true},
			{Root: t("e3"), Children: []Task{t("c3")}},
		},
		Orphans: []Task{t("o1")},
	}
}

func testModel(b Board) Model {
	m := newModel(nil, "", Config{})
	m.board = b
	return m
}

// step feeds one message through Update and type-asserts the concrete Model back.
func step(t2 *testing.T, m Model, msg tea.Msg) (Model, tea.Cmd) {
	t2.Helper()
	nm, cmd := m.Update(msg)
	mm, ok := nm.(Model)
	if !ok {
		t2.Fatalf("Update returned %T, want taskboard.Model", nm)
	}
	return mm, cmd
}

func runes(s string) tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)} }

// --- flattening --------------------------------------------------------------

func TestVisibleRowsOrderAndKinds(t2 *testing.T) {
	m := testModel(sampleBoard())
	rows := m.visibleRows()
	want := []struct {
		kind  rowKind
		docID string
	}{
		{rowNow, "n1"},
		{rowNow, "n2"},
		{rowEpicHeader, "e1"},
		{rowChild, "c1"},
		{rowChild, "c2"},
		{rowEpicHeader, "e2"}, // dormant → no children follow
		{rowEpicHeader, "e3"},
		{rowChild, "c3"},
		{rowOrphan, "o1"},
	}
	if len(rows) != len(want) {
		t2.Fatalf("got %d rows, want %d: %+v", len(rows), len(want), rows)
	}
	for i, w := range want {
		if rows[i].kind != w.kind || rows[i].docID != w.docID {
			t2.Errorf("row %d = {%v %q}, want {%v %q}", i, rows[i].kind, rows[i].docID, w.kind, w.docID)
		}
	}
}

// --- cursor movement ---------------------------------------------------------

func TestCursorMovesAndClampsAtEnds(t2 *testing.T) {
	m := testModel(sampleBoard()) // 9 rows

	// k at the top is a no-op (clamps at 0).
	m, _ = step(t2, m, runes("k"))
	if m.ui.Cursor != 0 {
		t2.Fatalf("k at top moved cursor to %d, want 0", m.ui.Cursor)
	}

	// j walks down and clamps at the last row (index 8).
	for i := 0; i < 20; i++ {
		m, _ = step(t2, m, runes("j"))
	}
	if m.ui.Cursor != 8 {
		t2.Fatalf("j past the bottom left cursor at %d, want 8", m.ui.Cursor)
	}

	// G / g jump to bottom / top.
	m, _ = step(t2, m, runes("g"))
	if m.ui.Cursor != 0 {
		t2.Fatalf("g left cursor at %d, want 0", m.ui.Cursor)
	}
	m, _ = step(t2, m, runes("G"))
	if m.ui.Cursor != 8 {
		t2.Fatalf("G left cursor at %d, want 8", m.ui.Cursor)
	}

	// Arrow keys are equivalent to j/k.
	m.ui.Cursor = 4
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyUp})
	if m.ui.Cursor != 3 {
		t2.Fatalf("↑ left cursor at %d, want 3", m.ui.Cursor)
	}
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyDown})
	if m.ui.Cursor != 4 {
		t2.Fatalf("↓ left cursor at %d, want 4", m.ui.Cursor)
	}
}

// --- collapse / expand -------------------------------------------------------

func TestEnterOnEpicHeaderTogglesCollapse(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 2 // header e1

	// Collapse e1: its two children (c1, c2) drop out → 7 rows.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.ui.CollapsedEpics["e1"] {
		t2.Fatal("enter on epic header did not collapse it")
	}
	rows := m.visibleRows()
	if len(rows) != 7 {
		t2.Fatalf("after collapsing e1: %d rows, want 7", len(rows))
	}
	if rows[3].docID != "e2" { // e1 header now immediately followed by e2 header
		t2.Fatalf("row 3 after collapse = %q, want e2 header", rows[3].docID)
	}

	// enter again un-collapses.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.ui.CollapsedEpics["e1"] {
		t2.Fatal("second enter did not un-collapse the epic")
	}
	if len(m.visibleRows()) != 9 {
		t2.Fatalf("after un-collapse: %d rows, want 9", len(m.visibleRows()))
	}
}

func TestHAndLOnHeaderToggleCollapse(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 6 // header e3
	m, _ = step(t2, m, runes("h"))
	if !m.ui.CollapsedEpics["e3"] {
		t2.Fatal("h on epic header did not toggle collapse")
	}
	m, _ = step(t2, m, runes("l"))
	if m.ui.CollapsedEpics["e3"] {
		t2.Fatal("l on epic header did not toggle collapse back")
	}
}

func TestHAndLOnTaskAreNoOps(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 0 // now card n1 (a task, not a header)
	m, _ = step(t2, m, runes("l"))
	m, _ = step(t2, m, runes("h"))
	if m.ui.Expanded["n1"] {
		t2.Fatal("h/l on a task row toggled expansion; they should only fold epics")
	}
	if len(m.ui.CollapsedEpics) != 0 {
		t2.Fatalf("h/l on a task row touched CollapsedEpics: %+v", m.ui.CollapsedEpics)
	}
}

func TestEnterOnTaskTogglesExpanded(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 0 // now card n1

	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.ui.Expanded["n1"] {
		t2.Fatal("enter on a NOW card did not expand it")
	}
	// Expanding must NOT change the row count (detail is inline render, not a row).
	if len(m.visibleRows()) != 9 {
		t2.Fatalf("expanding a task changed row count to %d, want 9", len(m.visibleRows()))
	}
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.ui.Expanded["n1"] {
		t2.Fatal("second enter did not collapse the inline detail")
	}

	// enter on a child row expands that child.
	m.ui.Cursor = 3 // child c1
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.ui.Expanded["c1"] {
		t2.Fatal("enter on a child task did not expand it")
	}
}

// clampCursor keeps the selection valid when a refetch shrinks the board under it.
func TestApplySnapshotClampsCursor(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 8 // last row
	// A refetch that yields a much smaller board.
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Orphans: []Task{t("only")}}
	}
	m.now = func() time.Time { return time.Unix(1000, 0) }
	m, _ = step(t2, m, snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(1000, 0)}})
	if got := len(m.visibleRows()); got != 1 {
		t2.Fatalf("post-refetch rows = %d, want 1", got)
	}
	if m.ui.Cursor != 0 {
		t2.Fatalf("cursor not clamped after shrink: %d, want 0", m.ui.Cursor)
	}
}

// --- resize ------------------------------------------------------------------

func TestWindowResizeStoresDimensions(t2 *testing.T) {
	m := testModel(sampleBoard())
	m, _ = step(t2, m, tea.WindowSizeMsg{Width: 72, Height: 120})
	if m.width != 72 || m.height != 120 {
		t2.Fatalf("resize stored %dx%d, want 72x120", m.width, m.height)
	}
}

// --- quit --------------------------------------------------------------------

func TestQuitKeys(t2 *testing.T) {
	m := testModel(sampleBoard())
	for _, msg := range []tea.Msg{runes("q"), tea.KeyMsg{Type: tea.KeyCtrlC}} {
		_, cmd := step(t2, m, msg)
		if cmd == nil {
			t2.Fatalf("%v did not return a quit command", msg)
		}
		if got := cmd(); got == nil {
			t2.Fatalf("quit cmd for %v produced a nil msg", msg)
		} else if _, ok := got.(tea.QuitMsg); !ok {
			t2.Fatalf("quit cmd for %v produced %T, want tea.QuitMsg", msg, got)
		}
	}
}
