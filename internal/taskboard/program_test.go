package taskboard

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// --- fixtures & helpers ------------------------------------------------------

func t(id string) Task { return Task{DocID: id, Title: id} }

// focusOf builds a FocusSet map from doc ids. The hand-built fixtures set it so a
// section renders in modeFocus showing exactly these rows (charter D51 / wave-11)
// — the successor to the old "an Active section shows its children" default. A
// section with no FocusSet renders header-only (modeHeader), the inactive shape.
func focusOf(ids ...string) map[string]bool {
	m := map[string]bool{}
	for _, id := range ids {
		m[id] = true
	}
	return m
}

// sampleBoard is a fixture exercising every row kind: three epics, one loose
// task under a focused "(no epic)" header, plus two Now entries (model state
// only — the pinned band is retired, so they own no rows). Each section
// carries a FocusSet over ALL its children (charter D51 / wave-11), so every
// child renders — the fixture proves the row structure, while bigEpicBoard (no
// focus → header-only) proves the fold/expand cycle.
//
// Fresh (nothing collapsed) it flattens to 9 navigable rows:
//
//	0 header e1   3 header e2    6 child c3
//	1 child c1    4 child cx     7 orphan header
//	2 child c2    5 header e3    8 orphan o1
func sampleBoard() Board {
	return Board{
		Now: []Task{t("n1"), t("n2")},
		Epics: []Epic{
			{Root: t("e1"), Children: []Task{t("c1"), t("c2")}, Active: true, FocusSet: focusOf("c1", "c2")},
			{Root: t("e2"), Children: []Task{t("cx")}, FocusSet: focusOf("cx")},
			{Root: t("e3"), Children: []Task{t("c3")}, Active: true, FocusSet: focusOf("c3")},
		},
		Orphans:         []Task{t("o1")},
		OrphansActive:   true,
		OrphansFocusSet: focusOf("o1"),
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

// This is the bp-tasks boundary proof, not a unit test of portableDocLines:
// API-shaped JSON is decoded into DetailIndex, installed in the TUI model, and
// rendered through FrameTask — the exact path `bp tasks` / `bp task tui` uses.
func TestTaskTUIFrameShowsPortableDocBriefFromWire(t2 *testing.T) {
	body := []byte(`{"docs":[{"doc_id":"drafts.rich-task","title":"Rich task","content":{
      "kind":"task","lifecycle_status":"open",
      "description":"LEGACY WALL MUST NOT RENDER",
      "brief":{"version":1,"blocks":[
        {"id":"h","type":"heading","level":2,"text":"Human brief"},
        {"id":"p","type":"paragraph","content":[{"type":"text","value":"PortableDoc reaches the task TUI."}]}
      ]}
    }}]}`)
	tasks, details, err := decodeTaskListFull(body)
	if err != nil {
		t2.Fatalf("decodeTaskListFull: %v", err)
	}
	m := testModel(Board{})
	m.tasks, m.details = tasks, details
	lines, _ := m.frameContent(Frame{Kind: FrameTask, Ref: "drafts.rich-task"}, 80, detailNow)
	plain := ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(plain, "Human brief") || !strings.Contains(plain, "PortableDoc reaches the task TUI.") {
		t2.Fatalf("bp task TUI frame lost PortableDoc:\n%s", plain)
	}
	if strings.Contains(plain, "LEGACY WALL") {
		t2.Fatalf("bp task TUI rendered legacy fallback over PortableDoc:\n%s", plain)
	}
}

// --- flattening --------------------------------------------------------------

func TestVisibleRowsOrderAndKinds(t2 *testing.T) {
	m := testModel(sampleBoard())
	rows := m.visibleRows()
	// The spine is the whole cursor space (Amendment 7 — the pinned NOW/NEXT band
	// is retired): sampleBoard's Now entries own no cursor rows.
	want := []struct {
		kind  rowKind
		docID string
	}{
		{rowEpicHeader, "e1"},
		{rowChild, "c1"},
		{rowChild, "c2"},
		{rowEpicHeader, "e2"}, // not Active, but carries a FocusSet (modeFocus)…
		{rowChild, "cx"},      // …so its neighborhood child shows (charter D51 / wave-11)
		{rowEpicHeader, "e3"},
		{rowChild, "c3"},
		{rowOrphanHeader, orphansFoldKey}, // the loose bucket is a navigable header now
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

// TestCursorParityShellRender is the shell↔render selection tripwire: for
// EVERY cursor index, the ▶ marker in the rendered frame must sit on the row
// visibleRows says the cursor is on — the row the act verbs (c/x/o) fire on.
// Wave 1 shipped with the renderer counting only spine tasks while the shell
// counted NOW cards + epic headers too, so the highlight was offset from the
// acted-on row; this pins the repaired parity forever.
func TestCursorParityShellRender(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40

	rows := m.visibleRows()
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
			t2.Fatalf("cursor %d (%v %q): %d ▎-marked lines, want exactly 1\n%s",
				i, r.kind, r.docID, len(marked), frame)
		}
		// The board's titles equal the doc ids (see t()), and an epic header
		// row carries its root's title — either way the marked line must name
		// the row the shell would act on. The orphan header paints "(no epic)",
		// not its internal fold key, so match that token instead.
		want := r.docID
		if r.kind == rowOrphanHeader {
			want = "(no epic)"
		}
		if !strings.Contains(marked[0], want) {
			t2.Errorf("cursor %d: marked line %q does not carry %q (kind %v)",
				i, marked[0], want, r.kind)
		}
	}
}

// Under wave-11 the loose bucket no longer dumps every survivor: with live claims
// it renders a FOCUS WINDOW (charter D51) — the neighborhood around the active
// work, bounded by focusWindowMax — instead of the ~41-row flat wall. Folded
// orphans are absent from Board.Orphans by construction, and the focus filter
// narrows the rest, so the navigable list is short: 3 NOW claims + the "(no epic)"
// header + the focus neighborhood. It must never touch a folded "dn*" ghost, and
// G must land on a real row.
func TestVisibleRowsExcludeFoldedOrphans(t2 *testing.T) {
	b := BuildBoard(loadFlatSnapshot(t2), RepoContext{}, refNow)
	m := testModel(b)
	rows := m.visibleRows()
	// The window is far shorter than the full survivor pile but still shows the
	// pinned claims + the header + a real neighborhood.
	if len(rows) <= len(b.Now)+1 {
		t2.Fatalf("flat board visible rows = %d, want more than NOW+header (a focus window)", len(rows))
	}
	// +1 for the "+N more/done" fold line, itself a cursor stop since D57
	// (enter on it expands the section). +len(b.Next) for the pinned NEXT
	// intent strip, cursor stops above the spine (charter wave-12 D63).
	if len(rows) > len(b.Now)+len(b.Next)+1+focusWindowMax+1 {
		t2.Fatalf("flat board visible rows = %d, want <= NOW + NEXT + header + focusWindowMax + fold line (%d) — the wall must not return",
			len(rows), len(b.Now)+len(b.Next)+1+focusWindowMax+1)
	}
	for _, r := range rows {
		if len(r.docID) >= 2 && r.docID[:2] == "dn" {
			t2.Fatalf("folded stale-done orphan %q became a navigable row", r.docID)
		}
	}
	m, _ = step(t2, m, runes("G"))
	if m.ui.Cursor != len(rows)-1 {
		t2.Fatalf("G on the flat board left cursor at %d, want %d (last row)", m.ui.Cursor, len(rows)-1)
	}
}

// clusterBoard extends sampleBoard with two derived clusters (freshest-first,
// AFTER the authored epics, BEFORE the orphan) — the fixture the wave-3 cursor
// contract must survive. The first cluster's first member is a twin (⧉), so the
// parity walk also proves the twin glyph never shifts the acted-on row.
//
// Fresh (nothing collapsed) it flattens to 16 navigable rows. Every section is
// under the head cap, so all children show — including e2's lone child cx. After
// Amendment 6 (charter D84/D86) the scrolling list is the TOP region: its spine
// rows own [0, S), then the pinned band (NEXT then NOW) is the TAIL. clusterBoard
// carries no NEXT, so the two NOW cards land last (14, 15):
//
//	0 header e1     6 child c3             12 orphan header
//	1 child c1      7 clusterHeader alpha  13 orphan o1
//	2 child c2      8 clusterMember a1
//	3 header e2     9 clusterMember a2
//	4 child cx     10 clusterHeader beta
//	5 header e3    11 clusterMember b1
func clusterBoard() Board {
	b := sampleBoard()
	a1 := t("a1")
	a1.TwinOf = "a2"
	b.Clusters = []Cluster{
		{Key: "proj:alpha", Tasks: []Task{a1, t("a2")}, Active: true, FocusSet: focusOf("a1", "a2")},
		{Key: "proj:beta", Tasks: []Task{t("b1")}, Active: true, FocusSet: focusOf("b1")},
	}
	return b
}

// clusterHeaderKey mirrors the shell's fold-key namespacing for the tests.
func clusterHeaderKey(key string) string { return "cluster:" + key }

func TestVisibleRowsWithClusters(t2 *testing.T) {
	m := testModel(clusterBoard())
	rows := m.visibleRows()
	want := []struct {
		kind  rowKind
		docID string
	}{
		{rowEpicHeader, "e1"},
		{rowChild, "c1"},
		{rowChild, "c2"},
		{rowEpicHeader, "e2"}, // inactive, but its lone child is under the head cap…
		{rowChild, "cx"},      // …so it shows by default now
		{rowEpicHeader, "e3"},
		{rowChild, "c3"},
		{rowClusterHeader, "cluster:proj:alpha"}, // clusters after epics
		{rowClusterMember, "a1"},
		{rowClusterMember, "a2"},
		{rowClusterHeader, "cluster:proj:beta"},
		{rowClusterMember, "b1"},
		{rowOrphanHeader, orphansFoldKey}, // loose bucket header, then its rows
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

// TestCursorParityWithClusters is the wave-3 extension of the shell↔render
// tripwire: for EVERY cursor index on a board carrying NOW cards + epics +
// clusters + a folded cluster + orphans, the ▶ marker in the rendered frame must
// sit on exactly the row visibleRows says the cursor is on. A cluster header
// paints its SHORT name (prefix stripped), so its expected token is derived from
// the fold key; every other row's title equals its doc id (see t()).
func TestCursorParityWithClusters(t2 *testing.T) {
	for _, folded := range []bool{false, true} {
		m := testModel(clusterBoard())
		m.ui.Conn = ConnLive
		m.ui.LastSync = time.Unix(1, 0)
		m.now = func() time.Time { return time.Unix(2, 0) }
		m.width, m.height = 80, 60
		if folded {
			m.ui.CollapsedEpics[clusterHeaderKey("proj:alpha")] = true
		}

		rows := m.visibleRows()
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
				t2.Fatalf("folded=%v cursor %d (%v %q): %d ▎-marked lines, want 1\n%s",
					folded, i, r.kind, r.docID, len(marked), frame)
			}
			want := r.docID
			if r.kind == rowClusterHeader {
				want = clusterDisplayName(strings.TrimPrefix(r.docID, "cluster:")) // "cluster:proj:alpha" → "alpha"
			}
			if r.kind == rowOrphanHeader {
				want = "(no epic)"
			}
			if !strings.Contains(marked[0], want) {
				t2.Errorf("folded=%v cursor %d: marked line %q does not carry %q (kind %v)",
					folded, i, marked[0], want, r.kind)
			}
		}
	}
}

// phaseBoard is the nesting-parity fixture: ONE epic whose children form a real
// nested tree, so the spine exercises arbitrary-depth branch rails — the one non-flat
// structure on the board (the clusterBoard/sampleBoard fixtures are entirely
// FLAT). Titles stay == docID so the ▎-marker check still names the acted-on row.
// The phase: labels survive from the wave-9 fixture but no longer open sub-bands:
// wave-9b (D-B) removed within-epic phase sub-bands — they rendered as bare
// orphan "W#" lines on the live corpus and doubled the code the rows already
// carry. nestTasks walks the children into tree order w1a → w1a1 → w1a2 (depth 2):
//
//	pe (header)
//	  w1a  (d0)  w1a1 (d1)  w1a2 (d2)
//	  w2a  (d0)  w2a1 (d1)
func phaseBoard() Board {
	tp := func(id, phase string) Task { x := t(id); x.Labels = []string{labelPhasePrefix + phase}; return x }
	tn := func(id, parent string) Task { x := t(id); x.ParentID = parent; return x }
	return Board{
		Epics: []Epic{{
			Root:   t("pe"),
			Active: true,
			Children: []Task{
				tp("w1a", "W1"),
				tn("w1a1", "w1a"),
				tn("w1a2", "w1a1"),
				tp("w2a", "W2"),
				tn("w2a1", "w2a"),
			},
			FocusSet: focusOf("w1a", "w1a1", "w1a2", "w2a", "w2a1"), // focus over the whole tree
		}},
	}
}

// TestVisibleRowsWithPhaseAndNesting pins the spine producer for the redesign's
// new structure: the phase-band lines and the tree outline add NO selectable rows
// (they are Selectable:false), so the navigable list is exactly the header + the
// five tasks in tree order — never a band or a fold line.
func TestVisibleRowsWithPhaseAndNesting(t2 *testing.T) {
	m := testModel(phaseBoard())
	rows := m.visibleRows()
	want := []struct {
		kind  rowKind
		docID string
	}{
		{rowEpicHeader, "pe"},
		{rowChild, "w1a"},
		{rowChild, "w1a1"},
		{rowChild, "w1a2"},
		{rowChild, "w2a"},
		{rowChild, "w2a1"},
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

// bandedBoard exercises the wave-10 NAMED PHASE BANDS (W10-A): an epic whose
// children carry phase:<n>-<slug> labels — a 7-child "1-spine" band, a 2-child
// "3-web-cli" band whose members span W3/W4 titles (merged "W3–4" code), and one
// unphased child that renders FIRST. FocusSet covers ALL members (charter D51 /
// wave-11), so the epic is in modeFocus and every band renders in full (wave-11
// deleted the per-band head cap — expand/focus reveal the whole band).
func bandedBoard() Board {
	tp := func(id, title, phase string) Task {
		return Task{DocID: id, Title: title, Lifecycle: lifeOpen, Labels: []string{labelPhasePrefix + phase}}
	}
	children := []Task{
		{DocID: "un", Title: "un unphased scaffold", Lifecycle: lifeReady}, // unphased → first
		tp("sp1", "sp1 W1.1 spine slice", "1-spine"),
		tp("sp2", "sp2 W1.2 spine slice", "1-spine"),
		tp("sp3", "sp3 W1.3 spine slice", "1-spine"),
		tp("sp4", "sp4 W1.4 spine slice", "1-spine"),
		tp("sp5", "sp5 W1.5 spine slice", "1-spine"),
		tp("sp6", "sp6 W1.6 spine slice", "1-spine"),
		tp("sp7", "sp7 W1.7 spine slice", "1-spine"),
		tp("wc1", "wc1 W3.1 web bridge", "3-web-cli"),
		tp("wc2", "wc2 W4.1 cli thread", "3-web-cli"),
	}
	ids := make([]string, len(children))
	for i, c := range children {
		ids[i] = c.DocID
	}
	return Board{Epics: []Epic{{Root: t("pe"), Children: children, Active: true, FocusSet: focusOf(ids...)}}}
}

// TestBandedVisibleRows pins the selectable index space of a banded epic: the
// band HEADERS are display-only (Selectable:false), so the navigable list is
// exactly the epic header + the unphased child + all 7 spine children + the 2
// web-cli children — never a band line.
func TestBandedVisibleRows(t2 *testing.T) {
	m := testModel(bandedBoard())
	rows := m.visibleRows()
	want := []struct {
		kind  rowKind
		docID string
	}{
		{rowEpicHeader, "pe"},
		{rowChild, "un"},
		{rowChild, "sp1"}, {rowChild, "sp2"}, {rowChild, "sp3"}, {rowChild, "sp4"}, {rowChild, "sp5"}, {rowChild, "sp6"}, {rowChild, "sp7"},
		{rowChild, "wc1"}, {rowChild, "wc2"},
	}
	if len(rows) != len(want) {
		t2.Fatalf("got %d selectable rows, want %d: %+v", len(rows), len(want), rows)
	}
	for i, w := range want {
		if rows[i].kind != w.kind || rows[i].docID != w.docID {
			t2.Errorf("row %d = {%v %q}, want {%v %q}", i, rows[i].kind, rows[i].docID, w.kind, w.docID)
		}
	}
}

// TestBandedRenderStructure eyeballs the painted band frame: named headers with
// whole-band rollups (incl the merged "W3–4"), the unphased child first, every
// band member shown (wave-11 dropped the per-band cap), and no cancelled/blank
// noise.
func TestBandedRenderStructure(t2 *testing.T) {
	m := testModel(bandedBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 60
	frame := ansi.Strip(m.View())
	for _, want := range []string{"Spine ", "W1 · 0/7", "Web CLI ", "W3–4 · 0/2", "unphased scaffold"} {
		if !strings.Contains(frame, want) {
			t2.Errorf("banded frame missing %q\n%s", want, frame)
		}
	}
	// Every spine slice now renders (no per-band cap) — W1.7 is a visible row.
	if !strings.Contains(frame, "W1.7 spine slice") {
		t2.Errorf("focus/expanded band should show every member incl W1.7\n%s", frame)
	}
}

// TestCursorParityBandedEpic is the shell↔render tripwire on the NEW named bands:
// for every cursor index the ▎ marker sits on exactly the row visibleRows says —
// proving the display-only band headers + fold lines never shift the selection
// index space (charter wave-10 W10-A structural parity via the one spineRows).
func TestCursorParityBandedEpic(t2 *testing.T) {
	m := testModel(bandedBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 60

	rows := m.visibleRows()
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
			t2.Fatalf("cursor %d (%v %q): %d ▎-marked lines, want 1\n%s", i, r.kind, r.docID, len(marked), frame)
		}
		if !strings.Contains(marked[0], r.docID) && r.docID != "un" {
			t2.Errorf("cursor %d: marked line %q does not carry %q (kind %v)", i, marked[0], r.docID, r.kind)
		}
	}
}

// TestCursorParityWithPhaseAndNesting is the shell↔render tripwire on a NON-flat
// board: with arbitrary-depth outline rows, the ▎ marker in the painted frame must sit
// on exactly the row visibleRows says the cursor is on — proving the display-only
// tree rails never shift the selection index space (charter D42 structural parity).
// (wave-9b removed within-epic phase sub-bands per D-B, so this no longer asserts
// a band renders — the tree outline is the structure under test.)
func TestCursorParityWithPhaseAndNesting(t2 *testing.T) {
	m := testModel(phaseBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 60

	// Branch and continuation rails must be present, proving real tree structure.
	frame0 := ansi.Strip(m.View())
	if !strings.Contains(frame0, "├─") || !strings.Contains(frame0, "└─") || !strings.Contains(frame0, "│ ") {
		t2.Fatalf("tree outline incomplete — want branch, final branch, and continuation rail:\n%s", frame0)
	}

	rows := m.visibleRows()
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
			t2.Fatalf("cursor %d (%v %q): %d ▎-marked lines, want 1\n%s",
				i, r.kind, r.docID, len(marked), frame)
		}
		if !strings.Contains(marked[0], r.docID) {
			t2.Errorf("cursor %d: marked line %q does not carry %q (kind %v)",
				i, marked[0], r.docID, r.kind)
		}
	}
}

// TestClusterFoldHidesMembersAndMovesCursorAcross proves a cluster folds/unfolds
// exactly like an epic and that j/k step cleanly across the fold — the members
// leave the navigable list entirely, so the cursor never lands on a hidden row.
func TestClusterFoldHidesMembersAndMovesCursorAcross(t2 *testing.T) {
	m := testModel(clusterBoard())
	if got := len(m.visibleRows()); got != 14 {
		t2.Fatalf("unfolded cluster board = %d rows, want 14", got)
	}

	// Put the cursor on the alpha cluster header (index 7 — the spine leads now,
	// charter D84/D86) and fold with h.
	m.ui.Cursor = 7
	m, _ = step(t2, m, runes("h"))
	if !m.ui.CollapsedEpics[clusterHeaderKey("proj:alpha")] {
		t2.Fatalf("h on a cluster header did not record the fold")
	}
	rows := m.visibleRows()
	if len(rows) != 12 { // a1 + a2 (2 members) gone
		t2.Fatalf("after folding alpha: %d rows, want 12", len(rows))
	}
	for _, r := range rows {
		if r.docID == "a1" || r.docID == "a2" {
			t2.Fatalf("folded cluster member %q is still navigable", r.docID)
		}
	}
	// j from the alpha header steps straight to the beta header (index 8 now).
	m, _ = step(t2, m, runes("j"))
	if r, _ := m.currentRow(); r.kind != rowClusterHeader || r.docID != clusterHeaderKey("proj:beta") {
		t2.Fatalf("j across the folded cluster landed on {%v %q}, want the beta header", r.kind, r.docID)
	}

	// enter on the alpha header (back up one row) unfolds it again.
	m.ui.Cursor = 7
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.visibleRows()) != 14 {
		t2.Fatalf("enter did not unfold alpha: %d rows, want 14", len(m.visibleRows()))
	}
}

// TestActVerbsReachClusterMembers proves taskByID finds a cluster member so the
// act verbs (c/x/o) operate on it — a member is claimable/closable/openable
// exactly like an epic child, never a dead row.
func TestActVerbsReachClusterMembers(t2 *testing.T) {
	b := clusterBoard()
	b.Clusters[1].Tasks[0].Lifecycle = lifeReady // b1 is claimable
	m := testModel(b)

	if got, ok := m.taskByID("a2"); !ok || got.DocID != "a2" {
		t2.Fatalf("taskByID did not find cluster member a2: %v %+v", ok, got)
	}
	// Cursor on b1 (index 11 — the spine leads the index space now, charter
	// D84/D86), c fires a claim command (ready row).
	m.ui.Cursor = 11
	if r, _ := m.currentRow(); r.docID != "b1" {
		t2.Fatalf("cursor 11 is on %q, want b1", r.docID)
	}
	m2, cmd := step(t2, m, runes("c"))
	if cmd == nil {
		t2.Fatalf("c on a ready cluster member produced no claim command")
	}
	if strings.Contains(m2.ui.Strip.Message, "no task") {
		t2.Fatalf("c treated a cluster member as no-task: %q", m2.ui.Strip.Message)
	}
}

// --- cursor movement ---------------------------------------------------------

func TestCursorMovesAndClampsAtEnds(t2 *testing.T) {
	m := testModel(sampleBoard()) // 9 rows (head cap shows every small section whole)

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
	m.ui.Cursor = 0 // header e1 (the spine leads the index space now, charter D84/D86)

	// e1 is a FOCUS section (its neighborhood happens to be both children). enter
	// on a focus/header section writes an explicit EXPAND (entry=false) — charter
	// D51/D54; since focus already shows both children the row count is unchanged
	// (still 11), but the state is now modeExpanded.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.ui.CollapsedEpics["e1"] {
		t2.Fatal("enter on a focus header should record an explicit expand (false), not collapse")
	}
	if len(m.visibleRows()) != 9 {
		t2.Fatalf("after expand: %d rows, want 9", len(m.visibleRows()))
	}

	// enter again collapses the now-expanded section to just its header, dropping
	// c1 + c2 → 9 rows.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.ui.CollapsedEpics["e1"] {
		t2.Fatal("second enter did not collapse the expanded epic")
	}
	rows := m.visibleRows()
	if len(rows) != 7 {
		t2.Fatalf("after collapsing e1: %d rows, want 7", len(rows))
	}
	if rows[1].docID != "e2" { // e1 header now immediately followed by e2 header
		t2.Fatalf("row 1 after collapse = %q, want e2 header", rows[1].docID)
	}
}

func TestHFoldsAndLUnfoldsDeterministically(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 5 // header e3 (the spine leads the index space now, charter D84/D86)

	// h folds; a second h is idempotent (NOT a toggle — the help text promises
	// "h / l  fold / unfold", so each key always means the same thing).
	m, _ = step(t2, m, runes("h"))
	if !m.ui.CollapsedEpics["e3"] {
		t2.Fatal("h on epic header did not fold it")
	}
	m, _ = step(t2, m, runes("h"))
	if !m.ui.CollapsedEpics["e3"] {
		t2.Fatal("second h un-folded the epic; h must be idempotent fold")
	}

	// l unfolds; a second l is idempotent.
	m, _ = step(t2, m, runes("l"))
	if m.ui.CollapsedEpics["e3"] {
		t2.Fatal("l on epic header did not unfold it")
	}
	m, _ = step(t2, m, runes("l"))
	if m.ui.CollapsedEpics["e3"] {
		t2.Fatal("second l re-folded the epic; l must be idempotent unfold")
	}
}

// bigEpicBoard has a single INACTIVE epic (no FocusSet) carrying 7 children, so
// under wave-11 it renders header-ONLY by default (modeHeader — the dotted-leader
// rollup is the big-picture line). It is the fixture the fold/expand-cycle tests
// need — sampleBoard's sections all carry a focus set so they always show rows.
func bigEpicBoard() Board {
	return Board{
		Epics: []Epic{{
			Root:     t("big"),
			Children: []Task{t("k1"), t("k2"), t("k3"), t("k4"), t("k5"), t("k6"), t("k7")},
		}}, // inactive, no focus → header only
	}
}

// An inactive epic renders header-ONLY by default (charter D51 / wave-11); the
// user's explicit enter expands it to the full child list, and enter again
// collapses it back to the header. (Repurposed from the wave-8 head-cap test; the
// head-of-5 default it exercised is gone — an inactive section is now a single
// big-picture line until the user opens it.)
func TestEnterExpandsInactiveEpic(t2 *testing.T) {
	m := testModel(bigEpicBoard()) // header only = 1 row
	if got := len(m.visibleRows()); got != 1 {
		t2.Fatalf("inactive epic shows %d rows, want 1 (header only)", got)
	}
	m.ui.Cursor = 0 // the epic header

	// enter expands the header to the full child list (7 children) → 8 rows.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	rows := m.visibleRows()
	if len(rows) != 8 {
		t2.Fatalf("enter did not expand the inactive epic: %d rows, want 8", len(rows))
	}
	if rows[7].kind != rowChild || rows[7].docID != "k7" {
		t2.Fatalf("row 7 after expand = %+v, want child k7", rows[7])
	}

	// enter again collapses the whole section to just its header → 1 row.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if got := len(m.visibleRows()); got != 1 {
		t2.Fatalf("second enter did not collapse the epic to its header: %d rows, want 1", got)
	}
}

// Regression: expanding an inactive epic with enter must write an explicit
// EXPAND (CollapsedEpics entry=false), never a collapse. If that press wrote
// entry=true (the old toggle-the-map bug), the flag would stick and keep the
// epic folded to its header even after it goes Active (new claim → focus set).
// (Repurposed from TestWakingDormantEpicLeavesNoPhantomCollapse.)
func TestExpandedInactiveEpicHasNoPhantomCollapse(t2 *testing.T) {
	m := testModel(bigEpicBoard())
	m.ui.Cursor = 0                                    // the inactive epic header
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter}) // user expands it to all 7 children

	// The epic goes Active on the next refetch (same board, big now focused).
	b := bigEpicBoard()
	b.Epics[0].Active = true
	b.Epics[0].FocusSet = focusOf("k1")
	m.board = b

	// It still shows every child — the explicit expand (entry=false, modeExpanded)
	// wins over the focus default, so it never becomes a phantom collapse
	// (header + 7 children = 8 rows).
	if got := len(m.visibleRows()); got != 8 {
		t2.Fatalf("expanded epic renders folded (phantom collapse): %d rows, want 8", got)
	}
}

func TestHAndLOnTaskAreNoOps(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 1 // child c1 (a task, not a header)
	m, _ = step(t2, m, runes("l"))
	m, _ = step(t2, m, runes("h"))
	// h/l are the section-fold controls; on a task row they must do NOTHING — no
	// fold, and (charter D11) they must never descend into a frame either.
	if len(m.stack) != 1 {
		t2.Fatalf("h/l on a task row changed the stack depth to %d, want 1", len(m.stack))
	}
	if len(m.ui.CollapsedEpics) != 0 {
		t2.Fatalf("h/l on a task row touched CollapsedEpics: %+v", m.ui.CollapsedEpics)
	}
}

// enter on a task row PUSHES a FrameTask (charter D11/D29) — the navigation-shell
// descent that replaced the retired inline-expand toggle. It never changes the
// board's own row count, and esc pops back to the board.
func TestEnterOnTaskPushesFrameTask(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 8 // orphan o1

	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.stack) != 2 {
		t2.Fatalf("enter on a task row did not push a frame: stack depth %d, want 2", len(m.stack))
	}
	top := m.topFrame()
	if top.Kind != FrameTask || top.Ref != "o1" {
		t2.Fatalf("pushed frame = {%v %q}, want {FrameTask o1}", top.Kind, top.Ref)
	}
	// The board's own visible-row list is unchanged under the pushed frame.
	if len(m.visibleRows()) != 9 {
		t2.Fatalf("pushing a detail frame changed board row count to %d, want 9", len(m.visibleRows()))
	}
	// esc ascends back to the board (stack root).
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEsc})
	if len(m.stack) != 1 || m.topFrame().Kind != FrameBoard {
		t2.Fatalf("esc did not return to the board: depth %d top %v", len(m.stack), m.topFrame().Kind)
	}

	// enter on a child row pushes that child's FrameTask.
	m.ui.Cursor = 1 // child c1 (the spine leads the index space now, charter D84/D86)
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if top := m.topFrame(); top.Kind != FrameTask || top.Ref != "c1" {
		t2.Fatalf("enter on a child pushed {%v %q}, want {FrameTask c1}", top.Kind, top.Ref)
	}
}

// clampCursor keeps the selection valid when a refetch shrinks the board under it.
func TestApplySnapshotClampsCursor(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 8 // on child c3, deep in the 11-row board
	// A refetch that yields a much smaller board: one loose task under its
	// navigable "(no epic)" header → 2 rows total.
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Orphans: []Task{t("only")}, OrphansActive: true, OrphansFocusSet: focusOf("only")}
	}
	m.now = func() time.Time { return time.Unix(1000, 0) }
	m, _ = step(t2, m, snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(1000, 0)}})
	if got := len(m.visibleRows()); got != 2 {
		t2.Fatalf("post-refetch rows = %d, want 2 (loose header + one task)", got)
	}
	// c3 is gone from the new board, so the selection can't follow it; the cursor
	// clamps down to the last valid row instead of dangling off the end.
	if m.ui.Cursor != 1 {
		t2.Fatalf("cursor not clamped after shrink: %d, want 1", m.ui.Cursor)
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

// --- act verbs: claim / close / open ----------------------------------------

// activeOrphans wraps loose tasks in a FOCUSED loose bucket (OrphansFocusSet over
// every task, charter D51 / wave-11), so an act-verb test can navigate onto a
// task row. Its header is a navigable row — so the loose tasks live at cursor
// 1, 2, … (row 0 is the header). These fixtures want the rows reachable.
func activeOrphans(tasks ...Task) Board {
	ids := make([]string, len(tasks))
	for i, tk := range tasks {
		ids[i] = tk.DocID
	}
	return Board{Orphans: tasks, OrphansActive: true, OrphansFocusSet: focusOf(ids...)}
}

// readyTask is a claimable row (the board overlays "ready" onto queue-ready
// tasks). claimedTask holds a live claim, so it is closable.
func readyTask(id string) Task { return Task{DocID: id, Title: id, Lifecycle: lifeReady} }

func claimedTask(id string, epoch int) Task {
	return Task{DocID: id, Title: id, Lifecycle: lifeInProgress,
		Claim: &Claim{Worker: "w", Epoch: epoch, ClaimedAt: time.Unix(1000, 0)}}
}

// c on a ready row fires DoClaim with the resolved worker, then on the OK
// result flashes an ok strip and fires a reconciling refetch.
func TestClaimKeyOnReadyRowFiresClaimAndReconciles(t2 *testing.T) {
	t2.Setenv("BARKPARK_WORKER_ID", "opus-9")
	m := testModel(activeOrphans(readyTask("r1")))
	m.ui.Cursor = 1 // r1 (row 0 is the loose-bucket header)

	var gotDoc, gotWorker string
	m.doClaim = func(_ *apiclient.Client, docID, worker string) ActionResult {
		gotDoc, gotWorker = docID, worker
		return ActionResult{OK: true, Message: "claimed as opus-9 · epoch 1"}
	}

	m, cmd := step(t2, m, runes("c"))
	if cmd == nil {
		t2.Fatal("c on a ready row did not fire a claim command")
	}
	msg := cmd()
	res, ok := msg.(actionResultMsg)
	if !ok {
		t2.Fatalf("claim command produced %T, want actionResultMsg", msg)
	}
	if gotDoc != "r1" || gotWorker != "opus-9" {
		t2.Fatalf("DoClaim got (%q,%q), want (r1,opus-9)", gotDoc, gotWorker)
	}

	// Feeding the OK result back sets an ok strip AND fires a reconcile refetch.
	m, cmd = step(t2, m, res)
	if m.ui.Strip.Message != "claimed as opus-9 · epoch 1" || m.ui.Strip.Role != RoleOK {
		t2.Fatalf("strip after claim = %+v, want the ok confirmation", m.ui.Strip)
	}
	if cmd == nil {
		t2.Fatal("a successful claim did not trigger a reconciling refetch")
	}
}

// TestClaimForwardOnSpineReadyRow — claim-forward without a READY TO CLAIM band
// (charter D52 / wave-11 — ONE list): the cursor lands on a ready row in the
// spine and c claims exactly THAT task. Here a focused loose bucket surfaces two
// ready rows; c on the second claims it.
func TestClaimForwardOnSpineReadyRow(t2 *testing.T) {
	t2.Setenv("BARKPARK_WORKER_ID", "opus-9")
	m := testModel(activeOrphans(readyTask("h1"), readyTask("h2")))
	rows := m.visibleRows()
	// row 0 is the loose-bucket header; the two ready rows follow.
	if len(rows) != 3 || rows[1].docID != "h1" || rows[2].docID != "h2" {
		t2.Fatalf("rows = %+v, want [header h1 h2]", rows)
	}

	m.ui.Cursor = 2 // the SECOND ready row (h2) — not the default top
	var gotDoc, gotWorker string
	m.doClaim = func(_ *apiclient.Client, docID, worker string) ActionResult {
		gotDoc, gotWorker = docID, worker
		return ActionResult{OK: true, Message: "claimed as opus-9 · epoch 1"}
	}

	m, cmd := step(t2, m, runes("c"))
	if cmd == nil {
		t2.Fatal("c on a ready spine row did not fire a claim command")
	}
	if _, ok := cmd().(actionResultMsg); !ok {
		t2.Fatal("claim command did not produce an actionResultMsg")
	}
	if gotDoc != "h2" || gotWorker != "opus-9" {
		t2.Fatalf("DoClaim got (%q,%q), want (h2,opus-9) — c must claim the HIGHLIGHTED ready row", gotDoc, gotWorker)
	}
}

// A claim that the server refuses (e.g. a race that returns not_ready) shows the
// server's honest message verbatim in danger, and fires NO refetch.
func TestClaimResultFailureRendersHonestMessage(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{readyTask("r1")}})
	res := actionResultMsg{res: ActionResult{OK: false, Message: "claim failed: task is not ready"}}
	m, cmd := step(t2, m, res)
	if m.ui.Strip.Message != "claim failed: task is not ready" || m.ui.Strip.Role != RoleDanger {
		t2.Fatalf("strip = %+v, want the honest failure in danger", m.ui.Strip)
	}
	if cmd != nil {
		t2.Fatal("a failed claim must not trigger a refetch")
	}
}

// A landed claim/close whose result carries a rail-awareness role override paints
// that role (warn for a blocker on the task you just claimed), not the plain
// green — the notice is the reason for the color. Still fires the reconcile
// refetch, exactly like an un-noticed success.
func TestActionResultRoleOverrideLandsOnStrip(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{readyTask("r1")}})
	res := actionResultMsg{res: ActionResult{OK: true, Message: "claimed as w · epoch 4 · blocked while claimed: t9", Role: RoleWarn}}
	m, cmd := step(t2, m, res)
	if m.ui.Strip.Role != RoleWarn {
		t2.Fatalf("strip role = %v, want RoleWarn (the notice override)", m.ui.Strip.Role)
	}
	if m.ui.Strip.Message != "claimed as w · epoch 4 · blocked while claimed: t9" {
		t2.Fatalf("strip message = %q, want the notice folded in", m.ui.Strip.Message)
	}
	if cmd == nil {
		t2.Fatal("a noticed success must still reconcile (refetch)")
	}
}

// c on a NON-ready row never hits the network — it explains why on the strip.
func TestClaimKeyOnNonReadyRowExplainsInstead(t2 *testing.T) {
	fired := false
	m := testModel(activeOrphans(Task{DocID: "o1", Title: "o1", Lifecycle: lifeOpen}))
	m.ui.Cursor = 1 // o1 (row 0 is the loose-bucket header)
	m.doClaim = func(*apiclient.Client, string, string) ActionResult {
		fired = true
		return ActionResult{}
	}
	m, cmd := step(t2, m, runes("c"))
	if cmd != nil || fired {
		t2.Fatal("c on a non-ready row must not fire a claim")
	}
	if m.ui.Strip.Role != RoleWarn || m.ui.Strip.Message == "" {
		t2.Fatalf("strip = %+v, want a warn explanation", m.ui.Strip)
	}
}

// An action result in flight disarms the close guard — the arm-prompt is the
// guard's only visible face, so once any action result replaces it the guard
// must not stay silently armed. (The calm-board subtraction retired the `t` tag
// verb; this pins the same behavior on a claim result.)
func TestActionResultDisarmsCloseGuard(t2 *testing.T) {
	m := testModel(activeOrphans(claimedTask("c1", 7)))
	m.now = func() time.Time { return time.Unix(10, 0) }
	m.fetch = func(*apiclient.Client) (Snapshot, DetailIndex, error) {
		return Snapshot{FetchedAt: time.Unix(10, 0)}, nil, nil
	}
	m.ui.Cursor = 1 // c1 (row 0 is the loose-bucket header)

	m, _ = step(t2, m, runes("x")) // arm the close guard
	if m.pendingClose != "c1" {
		t2.Fatalf("pendingClose = %q after arming, want c1", m.pendingClose)
	}
	m, _ = step(t2, m, actionResultMsg{res: ActionResult{OK: true, Message: "claimed"}})
	if m.pendingClose != "" {
		t2.Fatal("an action result left the close guard armed")
	}
}

// x is a double-press guard: the first arms (prompt + pendingClose), the second
// consecutive x fires DoClose with the OBSERVED epoch.
func TestCloseKeyDoublePressFiresWithObservedEpoch(t2 *testing.T) {
	t2.Setenv("BARKPARK_WORKER_ID", "opus-9")
	m := testModel(activeOrphans(claimedTask("c1", 7)))
	m.ui.Cursor = 1 // c1 (row 0 is the loose-bucket header)

	var gotDoc, gotWorker string
	var gotEpoch int
	m.doClose = func(_ *apiclient.Client, docID, worker string, epoch int, _ string) ActionResult {
		gotDoc, gotWorker, gotEpoch = docID, worker, epoch
		return ActionResult{OK: true, Message: "closed · epoch 7"}
	}

	// First x arms — no command, an armed prompt, pendingClose recorded.
	m, cmd := step(t2, m, runes("x"))
	if cmd != nil {
		t2.Fatal("the first x fired a close (should only arm)")
	}
	if m.pendingClose != "c1" {
		t2.Fatalf("pendingClose = %q after first x, want c1", m.pendingClose)
	}
	if !strings.Contains(m.ui.Strip.Message, "press x again") {
		t2.Fatalf("first-x strip = %q, want the confirm prompt", m.ui.Strip.Message)
	}

	// Second consecutive x fires the close with the observed epoch.
	m, cmd = step(t2, m, runes("x"))
	if cmd == nil {
		t2.Fatal("the second x did not fire the close")
	}
	if _, ok := cmd().(actionResultMsg); !ok {
		t2.Fatal("close command did not produce an actionResultMsg")
	}
	if gotDoc != "c1" || gotWorker != "opus-9" || gotEpoch != 7 {
		t2.Fatalf("DoClose got (%q,%q,%d), want (c1,opus-9,7)", gotDoc, gotWorker, gotEpoch)
	}
	if m.pendingClose != "" {
		t2.Fatal("pendingClose not cleared after firing")
	}
}

// Any key other than a repeated x disarms the close guard (and clears the strip).
func TestCloseGuardDisarmsOnOtherKey(t2 *testing.T) {
	fired := false
	m := testModel(activeOrphans(claimedTask("c1", 7)))
	m.ui.Cursor = 1 // c1 (row 0 is the loose-bucket header)
	m.doClose = func(*apiclient.Client, string, string, int, string) ActionResult {
		fired = true
		return ActionResult{}
	}

	m, _ = step(t2, m, runes("x")) // arm
	if m.pendingClose != "c1" {
		t2.Fatalf("pendingClose = %q, want c1", m.pendingClose)
	}
	m, _ = step(t2, m, runes("j")) // any other key disarms + clears the strip
	if m.pendingClose != "" {
		t2.Fatal("j did not disarm the close guard")
	}
	if m.ui.Strip.Message != "" {
		t2.Fatalf("keypress did not clear the strip: %q", m.ui.Strip.Message)
	}

	// A subsequent lone x must RE-ARM (cursor returned to c1), never fire.
	m.ui.Cursor = 1
	_, cmd := step(t2, m, runes("x"))
	if cmd != nil || fired {
		t2.Fatal("x after a disarm fired a close instead of re-arming")
	}
}

// x on a row with no live claim explains instead of arming.
func TestCloseKeyOnUnclaimedRowExplains(t2 *testing.T) {
	m := testModel(activeOrphans(readyTask("r1")))
	m.ui.Cursor = 1 // r1 (row 0 is the loose-bucket header)
	m, cmd := step(t2, m, runes("x"))
	if cmd != nil {
		t2.Fatal("x on an unclaimed row fired a command")
	}
	if m.pendingClose != "" {
		t2.Fatal("x on an unclaimed row armed the guard")
	}
	if m.ui.Strip.Role != RoleWarn || m.ui.Strip.Message == "" {
		t2.Fatalf("strip = %+v, want a warn explanation", m.ui.Strip)
	}
}

// o surfaces the Studio deep link on the strip AND launches it via openURL.
func TestOpenKeySurfacesURLAndLaunches(t2 *testing.T) {
	m := testModel(activeOrphans(Task{DocID: "t1", Title: "t1"}))
	m.cfg.BaseURL = "https://guerrilla.test"
	m.ui.Cursor = 1 // t1 (row 0 is the loose-bucket header)

	old := openURL
	t2.Cleanup(func() { openURL = old })
	var opened string
	openURL = func(u string) error { opened = u; return nil }

	m, _ = step(t2, m, runes("o"))
	want := "https://guerrilla.test/studio/production/task/t1"
	if opened != want {
		t2.Fatalf("openURL launched %q, want %q", opened, want)
	}
	if !strings.Contains(m.ui.Strip.Message, want) || m.ui.Strip.Role != RoleOK {
		t2.Fatalf("strip = %+v, want the URL in ok", m.ui.Strip)
	}
}

// Even when the browser launch fails, the URL stays on the strip (SSH-friendly).
func TestOpenKeyShowsURLWhenLaunchFails(t2 *testing.T) {
	m := testModel(activeOrphans(Task{DocID: "t1", Title: "t1"}))
	m.cfg.BaseURL = "https://guerrilla.test"
	m.ui.Cursor = 1 // t1 (row 0 is the loose-bucket header)

	old := openURL
	t2.Cleanup(func() { openURL = old })
	openURL = func(string) error { return errFakeLaunch }

	m, _ = step(t2, m, runes("o"))
	want := "https://guerrilla.test/studio/production/task/t1"
	if !strings.Contains(m.ui.Strip.Message, want) {
		t2.Fatalf("strip = %q, want it to still show %q", m.ui.Strip.Message, want)
	}
}

var errFakeLaunch = fakeErr("no browser")

type fakeErr string

func (e fakeErr) Error() string { return string(e) }

// A successful action's OWN reconciling refetch must not wipe the confirmation
// off the strip — otherwise every success flashes for one network round-trip
// and is unreadable. A later, unrelated snapshot does clear it.
func TestActionReconcileKeepsConfirmationStrip(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{readyTask("r1")}})
	m.now = func() time.Time { return time.Unix(10, 0) }
	m.fetch = func(*apiclient.Client) (Snapshot, DetailIndex, error) {
		return Snapshot{FetchedAt: time.Unix(10, 0)}, nil, nil
	}

	m, cmd := step(t2, m, actionResultMsg{res: ActionResult{OK: true, Message: "claimed as w · epoch 1"}})
	if cmd == nil {
		t2.Fatal("successful action fired no reconcile")
	}
	m, _ = step(t2, m, cmd()) // the reconciling snapshot lands
	if m.ui.Strip.Message != "claimed as w · epoch 1" {
		t2.Fatalf("reconcile wiped the confirmation: %+v", m.ui.Strip)
	}

	// An unrelated snapshot (SSE/backstop-driven) clears the stale strip.
	m, _ = step(t2, m, snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(11, 0)}})
	if m.ui.Strip.Message != "" {
		t2.Fatalf("unrelated snapshot kept a stale strip: %+v", m.ui.Strip)
	}
}

// A landed snapshot disarms the close guard along with clearing the strip: the
// arm-prompt is the guard's only visible face, so an x pressed after the prompt
// was wiped must RE-ARM (with a fresh prompt), never fire invisibly.
func TestSnapshotDisarmsCloseGuard(t2 *testing.T) {
	fired := false
	m := testModel(activeOrphans(claimedTask("c1", 7)))
	m.now = func() time.Time { return time.Unix(10, 0) }
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return activeOrphans(claimedTask("c1", 7))
	}
	m.doClose = func(*apiclient.Client, string, string, int, string) ActionResult {
		fired = true
		return ActionResult{}
	}
	m.ui.Cursor = 1 // c1 (row 0 is the loose-bucket header)

	m, _ = step(t2, m, runes("x")) // arm
	m, _ = step(t2, m, snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(10, 0)}})
	if m.pendingClose != "" {
		t2.Fatal("snapshot cleared the prompt but left the guard armed")
	}
	m, cmd := step(t2, m, runes("x"))
	if cmd != nil || fired {
		t2.Fatal("x after a snapshot-disarm fired the close instead of re-arming")
	}
	if !strings.Contains(m.ui.Strip.Message, "press x again") {
		t2.Fatalf("re-arm did not prompt: %q", m.ui.Strip.Message)
	}
}

// Init fires the initial fetch as a command (async first paint, amendment E):
// the batch it returns includes the refetch that produces a snapshotMsg.
func TestInitFiresInitialFetch(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.backstopEvery = time.Millisecond // so the batched backstop tick returns fast
	m.fetch = func(*apiclient.Client) (Snapshot, DetailIndex, error) {
		return Snapshot{FetchedAt: time.Unix(1, 0)}, nil, nil
	}
	cmd := m.Init()
	if cmd == nil {
		t2.Fatal("Init returned no command")
	}
	batch, ok := cmd().(tea.BatchMsg)
	if !ok {
		t2.Fatalf("Init did not return a batch: %T", cmd())
	}
	sawSnapshot := false
	for _, c := range batch {
		if c == nil {
			continue
		}
		if _, ok := c().(snapshotMsg); ok {
			sawSnapshot = true
		}
	}
	if !sawSnapshot {
		t2.Fatal("Init's batch does not include the initial fetch")
	}
}

// applySnapshot recomputes repo correlation from the gathered git subjects
// BEFORE building, so "↳ git" badges track the fresh task set.
func TestApplySnapshotRecomputesRepoBeforeBuild(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return time.Unix(1, 0) }
	m.subjects = []string{"fix (dwb-18) the thing"}
	m.repoName = "barkpark"

	var gotRepo RepoContext
	m.build = func(_ Snapshot, repo RepoContext, _ time.Time) Board {
		gotRepo = repo
		return Board{}
	}
	snap := Snapshot{Tasks: []Task{{DocID: "dwb-18", Title: "x"}}, FetchedAt: time.Unix(1, 0)}
	step(t2, m, snapshotMsg{snap: snap})

	if gotRepo.RepoName != "barkpark" {
		t2.Fatalf("build saw repo %q, want barkpark", gotRepo.RepoName)
	}
	if gotRepo.Mentioned["dwb-18"] == 0 {
		t2.Fatalf("applySnapshot did not correlate dwb-18 before build: %+v", gotRepo.Mentioned)
	}
}

// serverHost reduces the resolved base URL to the host[:port] the header shows.
func TestServerHost(t2 *testing.T) {
	cases := []struct{ in, want string }{
		{"https://guerrilla.barkpark.cloud", "guerrilla.barkpark.cloud"},
		{"http://localhost:4000", "localhost:4000"},
		{"http://localhost:4000/", "localhost:4000"},
		{"guerrilla.test", "guerrilla.test"}, // scheme-less
		{"", "—"},
	}
	for _, tc := range cases {
		if got := serverHost(tc.in); got != tc.want {
			t2.Errorf("serverHost(%q) = %q, want %q", tc.in, got, tc.want)
		}
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

// ── Heartbeat (charter decisions 16/17) ──────────────────────────────────────
//
// The frame cmd is a real 1s tea.Tick, so these tests assert the SCHEDULING
// decision (a cmd was/was not armed, plus the frameOn/frameGen/Frame state) and
// never CALL the tick — calling it would block a full second per test.

// A snapshot carrying a live NOW claim arms the heartbeat: applySnapshot returns
// a frame command and marks exactly one live generation.
func TestHeartbeatArmsOnClaimSnapshot(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return time.Unix(2000, 0) }
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Now: []Task{claimedTask("c1", 1)}}
	}
	m, cmd := m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(2000, 0)}})
	if cmd == nil {
		t2.Fatal("a NOW claim did not arm the heartbeat")
	}
	if !m.frameOn {
		t2.Fatal("frameOn stayed false after arming")
	}
	if m.frameGen != 1 {
		t2.Fatalf("frameGen = %d after one arm, want 1", m.frameGen)
	}
}

// An at-rest snapshot (no claims, no flashes, already synced) schedules NO frame
// and leaves the animation deterministically at rest.
func TestAtRestSnapshotSchedulesNoFrame(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return time.Unix(3000, 0) }
	m.build = func(Snapshot, RepoContext, time.Time) Board { return Board{} }
	m, cmd := m.applySnapshot(snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(3000, 0)}})
	if cmd != nil {
		t2.Fatal("an at-rest board armed a frame cmd — the aliveness budget leaked")
	}
	if m.frameOn {
		t2.Fatal("frameOn is true on an at-rest board")
	}
	if m.ui.Frame != 0 {
		t2.Fatalf("Frame = %d at rest, want 0", m.ui.Frame)
	}
}

// Two arm calls leave exactly ONE live generation: the frameOn guard makes the
// second a no-op (charter decision 16, the debounceGen double-schedule guard).
func TestHeartbeatDoubleScheduleGuard(t2 *testing.T) {
	m := testModel(Board{Now: []Task{claimedTask("c1", 1)}})
	m.now = func() time.Time { return time.Unix(4000, 0) }

	cmd1 := m.maybeStartHeartbeat()
	cmd2 := m.maybeStartHeartbeat()
	if cmd1 == nil {
		t2.Fatal("first arm returned no frame cmd")
	}
	if cmd2 != nil {
		t2.Fatal("second arm double-scheduled a frame cmd")
	}
	if m.frameGen != 1 {
		t2.Fatalf("frameGen = %d after two arms, want 1 (one live gen)", m.frameGen)
	}
	if !m.frameOn {
		t2.Fatal("frameOn is false after arming")
	}
}

// A frame tick on a still-alive board advances Frame by one and reschedules.
func TestHeartbeatTickAdvancesAndReschedulesWhileAlive(t2 *testing.T) {
	m := testModel(Board{Now: []Task{claimedTask("c1", 1)}})
	m.now = func() time.Time { return time.Unix(5000, 0) }
	m.frameOn, m.frameGen = true, 1

	m, cmd := m.handleFrame(frameMsg{gen: 1})
	if m.ui.Frame != 1 {
		t2.Fatalf("Frame = %d after one tick, want 1", m.ui.Frame)
	}
	if cmd == nil {
		t2.Fatal("a live board did not reschedule the next frame")
	}
	if !m.frameOn {
		t2.Fatal("frameOn dropped while the board is still alive")
	}
}

// When the last flash decays the ticker stops DEAD: no reschedule, frameOn
// clears, and Frame resets to 0 so the rest state is deterministic.
func TestHeartbeatStopsAfterLastFlashDecays(t2 *testing.T) {
	base := time.Unix(6000, 0)
	m := testModel(Board{}) // no NOW claim
	m.now = func() time.Time { return base }
	m.ui.Conn, m.ui.LastSync = ConnLive, base.Add(-time.Minute)           // synced, not syncing
	m.ui.Flashes = map[string]time.Time{"x": base.Add(-10 * time.Second)} // level 0
	m.frameOn, m.frameGen = true, 1

	m, cmd := m.handleFrame(frameMsg{gen: 1})
	if cmd != nil {
		t2.Fatal("the ticker rescheduled after the last flash decayed")
	}
	if m.frameOn {
		t2.Fatal("frameOn stayed true after going still")
	}
	if m.ui.Frame != 0 {
		t2.Fatalf("Frame = %d after stopping, want 0 (deterministic rest)", m.ui.Frame)
	}
	if _, ok := m.ui.Flashes["x"]; ok {
		t2.Fatal("the decayed flash was not pruned")
	}
}

// A tick whose generation no longer matches the live chain (a straggler from a
// stopped or superseded chain) is dropped without touching the animation.
func TestStaleFrameTickIsDropped(t2 *testing.T) {
	m := testModel(Board{Now: []Task{claimedTask("c1", 1)}})
	m.now = func() time.Time { return time.Unix(7000, 0) }
	m.frameOn, m.frameGen, m.ui.Frame = true, 5, 3

	m, cmd := m.handleFrame(frameMsg{gen: 1}) // stale
	if cmd != nil {
		t2.Fatal("a stale-gen tick was not dropped")
	}
	if m.ui.Frame != 3 {
		t2.Fatalf("a stale tick advanced Frame to %d, want it untouched at 3", m.ui.Frame)
	}
}

// Init never arms the heartbeat: its batch is the backstop + the initial fetch,
// with no frame tick — a board you just opened is still until work lands.
func TestInitSchedulesNoFrame(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.backstopEvery = time.Millisecond // so calling the backstop tick returns fast
	m.fetch = func(*apiclient.Client) (Snapshot, DetailIndex, error) {
		return Snapshot{FetchedAt: time.Unix(1, 0)}, nil, nil
	}
	batch, ok := m.Init()().(tea.BatchMsg)
	if !ok {
		t2.Fatal("Init did not return a batch")
	}
	for _, c := range batch {
		if c == nil {
			continue
		}
		if _, isFrame := c().(frameMsg); isFrame {
			t2.Fatal("Init armed a frame tick — the aliveness budget leaked at startup")
		}
	}
	if m.frameOn {
		t2.Fatal("Init marked the heartbeat running")
	}
}

// TestEnterOnMoreLineExpandsSection — charter D57: the "+N more" fold line is a
// cursor stop, and enter on it expands its section to the full list ("open and
// see the rest"); enter again (on the surviving done-tail line) toggles back.
func TestEnterOnMoreLineExpandsSection(t *testing.T) {
	b := BuildBoard(loadFlatSnapshot(t), RepoContext{}, refNow)
	m := testModel(b)
	rows := m.visibleRows()
	moreAt := -1
	for i, r := range rows {
		if r.kind == rowMore {
			moreAt = i
			break
		}
	}
	if moreAt < 0 {
		t.Fatalf("flat focus board has no rowMore stop, want the fold line selectable")
	}
	before := len(rows)
	m.ui.Cursor = moreAt
	m = m.activateBoard()
	expanded := m.visibleRows()
	if len(expanded) <= before {
		t.Fatalf("enter on the fold line: rows %d -> %d, want the section expanded (more rows)", before, len(expanded))
	}
	// toggle back from the same section's surviving fold line (if any) or header:
	key := rows[moreAt].docID
	if !m.sectionExpandedByKey(key) {
		t.Fatalf("section %q not in modeExpanded after enter on its fold line", key)
	}
}

// TestBoardScrollsOneLineAtATime is the Amendment 8 interaction guard: driving
// j through a tall flat board, the viewport holds STILL while the cursor walks
// the visible window, then slides exactly ONE line per press once the cursor
// rides the bottom edge — never the old re-centering jump. k back up mirrors
// it: still first, then one line per press at the top edge.
func TestBoardScrollsOneLineAtATime(t2 *testing.T) {
	tasks := make([]Task, 40)
	for i := range tasks {
		tasks[i] = readyTask(fmt.Sprintf("row-%02d", i))
	}
	m := testModel(activeOrphans(tasks...))
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 24

	above := func() int {
		frame := ansi.Strip(m.View())
		mm := regexp.MustCompile(`↑ (\d+) more above`).FindStringSubmatch(frame)
		if mm == nil {
			return 0
		}
		n, _ := strconv.Atoi(mm[1])
		return n
	}

	if got := above(); got != 0 {
		t2.Fatalf("fresh board should start at the top, got %d hidden above", got)
	}
	// Walk down 30 rows (adjacent single-line stops): each press may scroll the
	// window by AT MOST one line, and it must not scroll at all until the
	// cursor reaches the bottom edge.
	prev, scrolled := 0, false
	for i := 0; i < 30; i++ {
		m, _ = step(t2, m, runes("j"))
		got := above()
		if got < prev || got > prev+1 {
			t2.Fatalf("press %d: hidden-above went %d -> %d, want a slide of at most one line", i, prev, got)
		}
		if got > prev {
			scrolled = true
		}
		prev = got
	}
	if !scrolled {
		t2.Fatalf("30 presses on a 40-row board at height 24 never scrolled — the window is stuck")
	}
	// Walking back up: the window holds still (cursor descends through the
	// visible rows) before sliding one line per press at the top edge.
	for i := 0; i < 30; i++ {
		m, _ = step(t2, m, runes("k"))
		got := above()
		if got > prev || got < prev-1 {
			t2.Fatalf("k press %d: hidden-above went %d -> %d, want a slide of at most one line", i, prev, got)
		}
		prev = got
	}
	if got := above(); got != 0 {
		t2.Fatalf("after walking back to the top %d lines stayed hidden above", got)
	}
}
