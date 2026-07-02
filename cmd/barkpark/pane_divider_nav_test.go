package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// Dividers are user-authorable via S.divider(), so a structure can lead or
// trail with one. The list-pane cursor must never rest on a divider: it isn't
// selectable (Enter/l are dead on it), so j/k, pgup/pgdn, g/G and the initial
// build all have to skip past leading/trailing dividers to a real item.

// dividerNode returns a list whose items are [divider, a, b, divider], the
// shape that strands the old forward-skip-then-clamp handlers on both ends.
func dividerNode() *StructureNode {
	return &StructureNode{
		Type: NodeList,
		ID:   "root",
		Items: []*StructureNode{
			{Type: NodeDivider, ID: "d0"},
			{Type: NodeList, ID: "a", Title: "A"},
			{Type: NodeList, ID: "b", Title: "B"},
			{Type: NodeDivider, ID: "d1"},
		},
	}
}

func dividerPaneModel() model {
	m := model{width: 100, height: 40}
	pane := m.buildListPane(dividerNode())
	m.panes = []Pane{pane}
	m.focus = focusState{Target: FocusPane, PaneIndex: 0}
	return m
}

func TestClampToItem(t *testing.T) {
	items := []PaneItem{
		{IsDivider: true}, // 0
		{ID: "a"},         // 1
		{ID: "b"},         // 2
		{IsDivider: true}, // 3
	}
	cases := []struct {
		name     string
		idx, dir int
		want     int
	}{
		{"leading divider walks forward", 0, +1, 1},
		{"leading divider reverses when asked to go back", 0, -1, 1},
		{"trailing divider walks back", 3, -1, 2},
		{"trailing divider reverses when asked to go forward", 3, +1, 2},
		{"over-the-end clamps then walks inward", 9, +1, 2},
		{"under-the-start clamps then walks inward", -9, -1, 1},
		{"real item is returned as-is", 1, +1, 1},
	}
	for _, c := range cases {
		if got := clampToItem(items, c.idx, c.dir); got != c.want {
			t.Errorf("%s: clampToItem(%d,%+d) = %d, want %d", c.name, c.idx, c.dir, got, c.want)
		}
	}

	// All-dividers must terminate (no infinite walk) and return the clamped idx.
	all := []PaneItem{{IsDivider: true}, {IsDivider: true}}
	if got := clampToItem(all, 0, +1); got != 0 {
		t.Errorf("all-dividers clampToItem(0,+1) = %d, want 0 (no real item)", got)
	}
	if got := clampToItem(all, 5, -1); got != 1 {
		t.Errorf("all-dividers clampToItem(5,-1) = %d, want 1 (clamped)", got)
	}

	// Empty is safe.
	if got := clampToItem(nil, 3, +1); got != 0 {
		t.Errorf("empty clampToItem = %d, want 0", got)
	}
}

func TestBuildListPaneSkipsLeadingDivider(t *testing.T) {
	m := model{width: 100, height: 40}
	pane := m.buildListPane(dividerNode())
	if pane.Cursor != 1 {
		t.Fatalf("initial cursor = %d, want 1 (item A — a leading divider must not boot selected)", pane.Cursor)
	}
	if pane.Items[pane.Cursor].IsDivider {
		t.Fatalf("initial cursor landed on a divider (%+v)", pane.Items[pane.Cursor])
	}
}

func TestJDoesNotStrandOnTrailingDivider(t *testing.T) {
	m := dividerPaneModel()
	m.panes[0].Cursor = 2 // on B, the last real item

	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	nm := next.(model)
	if got := nm.panes[0].Cursor; got != 2 {
		t.Fatalf("j from last real item = %d, want 2 (must not jump onto the trailing divider)", got)
	}
}

func TestKDoesNotStrandOnLeadingDivider(t *testing.T) {
	m := dividerPaneModel()
	m.panes[0].Cursor = 1 // on A, the first real item

	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("k")})
	nm := next.(model)
	if got := nm.panes[0].Cursor; got != 1 {
		t.Fatalf("k from first real item = %d, want 1 (must not jump onto the leading divider)", got)
	}
}

func TestMovePaneCursorClampsToRealItem(t *testing.T) {
	m := dividerPaneModel()
	m.panes[0].Cursor = 1 // on A
	// A large forward delta overshoots the trailing divider; it must land on B,
	// not clamp back onto the divider (the old forward-skip-then-clamp bug).
	m.movePaneCursor(&m.panes[0], 100)
	if got := m.panes[0].Cursor; got != 2 {
		t.Fatalf("movePaneCursor(+100) = %d, want 2 (item B, not the trailing divider)", got)
	}

	// A large backward delta must land on A, not the leading divider.
	m.movePaneCursor(&m.panes[0], -100)
	if got := m.panes[0].Cursor; got != 1 {
		t.Fatalf("movePaneCursor(-100) = %d, want 1 (item A, not the leading divider)", got)
	}
}

// An all-divider pane has nothing selectable; navigation must not hang or panic,
// and the cursor stays put (Enter-targeting code is guarded elsewhere and is
// deliberately not exercised here).
func TestAllDividerPaneDoesNotHang(t *testing.T) {
	node := &StructureNode{
		Type:  NodeList,
		ID:    "root",
		Items: []*StructureNode{{Type: NodeDivider, ID: "d0"}, {Type: NodeDivider, ID: "d1"}},
	}
	m := model{width: 100, height: 40}
	pane := m.buildListPane(node)
	m.panes = []Pane{pane}
	m.focus = focusState{Target: FocusPane, PaneIndex: 0}

	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	nm := next.(model)
	next2, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("k")})
	nm2 := next2.(model)
	nm2.movePaneCursor(&nm2.panes[0], 100)
	nm2.jumpPaneCursor(&nm2.panes[0], len(nm2.panes[0].Items)-1)
	// Reaching here without hanging is the assertion.
}
