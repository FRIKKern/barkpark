package taskboard

import (
	"fmt"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// firstLineFor returns the first hit-map line index tagged as the given spine-row
// cursor index, or -1. It is how the mouse tests locate the Y to click a row.
func firstLineFor(hits []LineTarget, cursorIdx int) int {
	for i, h := range hits {
		if h.Kind == LineSpineRow && h.CursorIndex == cursorIdx {
			return i
		}
	}
	return -1
}

// leftClick is a left mouse press at Y (X is irrelevant — the click target is the
// full row).
func leftClick(y int) tea.MouseMsg {
	return tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, Y: y}
}

// syncScroll mirrors what Update does after every message, so a hand-set cursor's
// hit map and painted frame agree on the spine window.
func syncScroll(m *Model) {
	w, h := m.boardGeometry()
	m.ui.SpineScroll = SpineTopFor(m.board, m.ui, w, h, m.now())
}

// TestHitMapBoardParity is the D91 tripwire: at every cursor index the hit map
// mirrors the painted board line-for-line — same length, the LineSpineRow lines
// tagged with the CURRENT cursor index are EXACTLY the U+258E-marked lines, every
// visible row's index appears on >=1 contiguous line, and separators/chrome carry
// non-cursor kinds. It is the mouse-side twin of TestCursorParityShellRender.
func TestHitMapBoardParity(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40

	rows := m.visibleRows()
	for i := range rows {
		m.ui.Cursor = i
		syncScroll(&m)
		frame := strings.Split(ansi.Strip(m.View()), "\n")
		hits := m.ComposeHitMap()

		if len(hits) != len(frame) {
			t2.Fatalf("cursor %d: hit map has %d lines, painted frame has %d", i, len(hits), len(frame))
		}
		// The ▎-marked lines are EXACTLY the lines the hit map tags with cursor i.
		for j, ln := range frame {
			marked := strings.Contains(ln, "▎")
			isCur := hits[j].Kind == LineSpineRow && hits[j].CursorIndex == i
			if marked != isCur {
				t2.Fatalf("cursor %d line %d: marked=%v hit-is-cursor=%v (kind=%v idx=%d)\n%q",
					i, j, marked, isCur, hits[j].Kind, hits[j].CursorIndex, ln)
			}
		}
		// Every visible-row index appears on >=1 contiguous line, and no LineSpineRow
		// index escapes [0,len(rows)).
		seen := map[int][]int{}
		for j, h := range hits {
			if h.Kind != LineSpineRow {
				continue
			}
			if h.CursorIndex < 0 || h.CursorIndex >= len(rows) {
				t2.Fatalf("cursor %d line %d: spine-row index %d out of range [0,%d)", i, j, h.CursorIndex, len(rows))
			}
			seen[h.CursorIndex] = append(seen[h.CursorIndex], j)
		}
		for idx := 0; idx < len(rows); idx++ {
			ls := seen[idx]
			if len(ls) == 0 {
				t2.Fatalf("cursor %d: visible row %d has no hit-map line", i, idx)
			}
			for k := 1; k < len(ls); k++ {
				if ls[k] != ls[k-1]+1 {
					t2.Fatalf("cursor %d: row %d hit lines not contiguous: %v", i, idx, ls)
				}
			}
		}
	}
}

// TestHitMapScrollAffordances proves a scrolled board window stamps its first/last
// overwritten lines as LineScrollUp/LineScrollDown — never a cursor stop — so a
// click there scrolls instead of selecting a phantom row.
func TestHitMapScrollAffordances(t2 *testing.T) {
	m := testModel(manyOrphans(30))
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 60, 14
	m.ui.Cursor = 15 // mid-list: both ↑ and ↓ affordances present
	syncScroll(&m)

	hits := m.ComposeHitMap()
	var up, down int
	for _, h := range hits {
		switch h.Kind {
		case LineScrollUp:
			up++
		case LineScrollDown:
			down++
		}
		if (h.Kind == LineScrollUp || h.Kind == LineScrollDown) && h.CursorIndex != -1 {
			t2.Fatalf("scroll affordance carried a cursor index %d, want -1", h.CursorIndex)
		}
	}
	if up != 1 || down != 1 {
		t2.Fatalf("scrolled window affordances: up=%d down=%d, want 1 and 1", up, down)
	}
}

// TestHitMapWheelParityBoard: a wheel notch on the board reaches the SAME model
// state as the matching j/k keypress (cursor, spine scroll, strip, close guard).
func TestHitMapWheelParityBoard(t2 *testing.T) {
	build := func() Model {
		m := testModel(sampleBoard())
		m.now = func() time.Time { return time.Unix(2, 0) }
		m.width, m.height = 80, 40
		m.ui.Cursor = 3
		syncScroll(&m)
		return m
	}
	cases := []struct {
		wheel  tea.MouseButton
		key    tea.KeyMsg
		reason string
	}{
		{tea.MouseButtonWheelDown, runes("j"), "wheel-down vs j"},
		{tea.MouseButtonWheelUp, runes("k"), "wheel-up vs k"},
	}
	for _, tc := range cases {
		mk, _ := step(t2, build(), tc.key)
		mw, _ := step(t2, build(), tea.MouseMsg{Action: tea.MouseActionPress, Button: tc.wheel})
		if mw.ui.Cursor != mk.ui.Cursor {
			t2.Fatalf("%s: cursor %d != %d", tc.reason, mw.ui.Cursor, mk.ui.Cursor)
		}
		if mw.ui.SpineScroll != mk.ui.SpineScroll {
			t2.Fatalf("%s: SpineScroll %d != %d", tc.reason, mw.ui.SpineScroll, mk.ui.SpineScroll)
		}
		if mw.pendingClose != mk.pendingClose || mw.ui.Strip != mk.ui.Strip {
			t2.Fatalf("%s: strip/close-guard state diverged", tc.reason)
		}
	}
}

// TestHitMapWheelParityReading: a wheel notch in a reading frame free-scrolls the
// prose one line (== freeScroll(±1)) and NEVER moves the stop cursor.
func TestHitMapWheelParityReading(t2 *testing.T) {
	build := func() Model {
		m := testModel(sampleBoard())
		m.now = func() time.Time { return time.Unix(2, 0) }
		m.width, m.height = 40, 24
		p := t("p")
		m.tasks = []Task{p}
		m.details = DetailIndex{"p": {Task: p, Description: strings.Repeat("alpha beta gamma delta ", 80)}}
		m.stack = append(m.stack, Frame{Kind: FrameTask, Ref: "p", Title: "p"})
		return m
	}
	// Direct freeScroll baseline.
	mb := build()
	(&mb).freeScroll(1)
	mw, _ := step(t2, build(), tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})
	if mw.topFrame().Scroll != mb.topFrame().Scroll {
		t2.Fatalf("reading wheel-down Scroll %d != freeScroll(1) %d", mw.topFrame().Scroll, mb.topFrame().Scroll)
	}
	if mw.topFrame().Scroll <= 0 {
		t2.Fatalf("reading wheel-down did not pan the prose (Scroll=%d)", mw.topFrame().Scroll)
	}
	if mw.topFrame().Cursor != 0 {
		t2.Fatalf("reading wheel moved the stop cursor to %d, want 0", mw.topFrame().Cursor)
	}
}

// TestHitMapClickSelectsBoardRow: a left press on a non-selected spine row selects
// it (cursor moves, no descend).
func TestHitMapClickSelectsBoardRow(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40
	m.ui.Cursor = 0
	syncScroll(&m)

	const target = 4 // child cx (a task row)
	y := firstLineFor(m.ComposeHitMap(), target)
	if y < 0 {
		t2.Fatal("no hit-map line for target row 4")
	}
	m2, _ := step(t2, m, leftClick(y))
	if m2.ui.Cursor != target {
		t2.Fatalf("click selected cursor %d, want %d", m2.ui.Cursor, target)
	}
	if len(m2.stack) != 1 {
		t2.Fatalf("selecting a row must not descend: stack depth %d, want 1", len(m2.stack))
	}
}

// TestHitMapClickActivatesSelectedTask: a left press on the ALREADY-selected task
// row activates it (descends into its FrameTask) — the same as a double-click.
func TestHitMapClickActivatesSelectedTask(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40
	m.ui.Cursor = 4 // child cx, already selected
	syncScroll(&m)

	y := firstLineFor(m.ComposeHitMap(), 4)
	if y < 0 {
		t2.Fatal("no hit-map line for the selected row")
	}
	m2, _ := step(t2, m, leftClick(y))
	if len(m2.stack) != 2 || m2.topFrame().Kind != FrameTask || m2.topFrame().Ref != "cx" {
		t2.Fatalf("click-on-selected did not descend: stack=%d top={%v %q}", len(m2.stack), m2.topFrame().Kind, m2.topFrame().Ref)
	}
}

// TestHitMapClickFoldsSelectedHeader: a left press on the already-selected section
// header folds/unfolds it (no descent — headers have no detail frame).
func TestHitMapClickFoldsSelectedHeader(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40
	m.ui.Cursor = 0 // epic header e1, already selected
	syncScroll(&m)

	y := firstLineFor(m.ComposeHitMap(), 0)
	if y < 0 {
		t2.Fatal("no hit-map line for the header row")
	}
	m2, _ := step(t2, m, leftClick(y))
	if len(m2.stack) != 1 {
		t2.Fatalf("activating a header must not push a frame: stack depth %d", len(m2.stack))
	}
	if _, ok := m2.ui.CollapsedEpics["e1"]; !ok {
		t2.Fatalf("click-on-selected-header did not toggle the epic fold state")
	}
}

// TestHitMapClickReadingRail: a click on a reading-frame rail stop selects it;
// a second click on the now-selected stop descends onto it.
func TestHitMapClickReadingRail(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 44, 40
	p := t("p")
	ch1 := Task{DocID: "ch1", Title: "ch1", ParentID: "p"}
	ch2 := Task{DocID: "ch2", Title: "ch2", ParentID: "p"}
	m.tasks = []Task{p, ch1, ch2}
	m.details = DetailIndex{"p": {Task: p}}
	m.stack = append(m.stack, Frame{Kind: FrameTask, Ref: "p", Title: "p"})

	if m.frameStopCount() < 2 {
		t2.Fatalf("reading frame has %d stops, want >=2 (the CHILDREN rail)", m.frameStopCount())
	}
	// Cursor starts at stop 0; click stop 1 → select it (no descend).
	y := firstLineFor(m.ComposeHitMap(), 1)
	if y < 0 {
		t2.Fatal("no hit-map line for rail stop 1")
	}
	m2, _ := step(t2, m, leftClick(y))
	if m2.topFrame().Cursor != 1 {
		t2.Fatalf("rail click selected stop %d, want 1", m2.topFrame().Cursor)
	}
	if len(m2.stack) != 2 {
		t2.Fatalf("rail select must not descend: stack depth %d", len(m2.stack))
	}
	// Click the now-selected stop 1 → descend onto ch2.
	y2 := firstLineFor(m2.ComposeHitMap(), 1)
	if y2 < 0 {
		t2.Fatal("no hit-map line for the selected rail stop")
	}
	m3, _ := step(t2, m2, leftClick(y2))
	if len(m3.stack) != 3 || m3.topFrame().Ref != "ch2" {
		t2.Fatalf("rail click-on-selected did not descend: stack=%d top=%q", len(m3.stack), m3.topFrame().Ref)
	}
}

// TestHitMapClickScrollAffordanceScrolls: a click on the ↓/↑ affordance is one
// wheel step (the cursor moves by one), never a select onto a phantom row.
func TestHitMapClickScrollAffordanceScrolls(t2 *testing.T) {
	m := testModel(manyOrphans(30))
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 60, 14
	m.ui.Cursor = 15
	syncScroll(&m)

	hits := m.ComposeHitMap()
	var upY, downY = -1, -1
	for i, h := range hits {
		if h.Kind == LineScrollUp {
			upY = i
		}
		if h.Kind == LineScrollDown {
			downY = i
		}
	}
	if upY < 0 || downY < 0 {
		t2.Fatalf("expected both scroll affordances present: up=%d down=%d", upY, downY)
	}
	md, _ := step(t2, m, leftClick(downY))
	if md.ui.Cursor != 16 {
		t2.Fatalf("click ↓ affordance moved cursor to %d, want 16", md.ui.Cursor)
	}
	mu, _ := step(t2, m, leftClick(upY))
	if mu.ui.Cursor != 14 {
		t2.Fatalf("click ↑ affordance moved cursor to %d, want 14", mu.ui.Cursor)
	}
}

// TestHitMapClickClearsStripAndDisarm: any handled mouse event is non-x input, so
// it clears the transient action strip and disarms the double-press close guard —
// exactly like a keypress.
func TestHitMapClickClearsStripAndDisarm(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40
	m.ui.Cursor = 1
	m.pendingClose = "c1"
	m.setStrip("press x again to close", RoleWarn)
	syncScroll(&m)

	m2, _ := step(t2, m, leftClick(0)) // click the leading blank / chrome
	if m2.pendingClose != "" {
		t2.Fatalf("mouse click did not disarm the close guard: %q", m2.pendingClose)
	}
	if m2.ui.Strip.Message != "" {
		t2.Fatalf("mouse click did not clear the action strip: %q", m2.ui.Strip.Message)
	}
}

// TestHitMapMotionIgnored: a hover-motion event NEVER moves the cursor — motion
// is hover only (ttm-s3, tested in mouse_fusion_test.go), never navigation.
func TestHitMapMotionIgnored(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.width, m.height = 80, 40
	m.ui.Cursor = 3
	before := m.ui.Cursor
	m2, _ := step(t2, m, tea.MouseMsg{Action: tea.MouseActionMotion, X: 5, Y: 5})
	if m2.ui.Cursor != before {
		t2.Fatalf("motion moved the cursor: %d -> %d", before, m2.ui.Cursor)
	}
}

// TestHitMapWideNoOp: wide two-pane mode routes through ttm-s5's handleWideMouse
// (tested in compose_test.go + mouse_fusion_test.go), never the narrow hit map —
// ComposeHitMap yields no map there, and an event OFF the pane rows (this wheel
// lands on the leading blank row) is an honest no-op.
func TestHitMapWideNoOp(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 120, 40
	m.wide = true
	m.ui.Cursor = 2
	if hits := m.ComposeHitMap(); hits != nil {
		t2.Fatalf("wide-mode ComposeHitMap returned %d lines, want nil", len(hits))
	}
	m2, _ := step(t2, m, tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})
	if m2.ui.Cursor != 2 {
		t2.Fatalf("wide-mode wheel moved the cursor: %d, want 2", m2.ui.Cursor)
	}
}

// manyOrphans is a tall single-section fixture (one loose header + n focused
// orphans) — enough rows to force spine windowing in a short viewport.
func manyOrphans(n int) Board {
	ts := make([]Task, n)
	ids := make([]string, n)
	for i := range ts {
		id := fmt.Sprintf("o%02d", i)
		ts[i] = t(id)
		ids[i] = id
	}
	return Board{Orphans: ts, OrphansActive: true, OrphansFocusSet: focusOf(ids...)}
}

// TestNarrowRailHoverParityUnderScroll is the D42/D105 one-producer tripwire for
// the NARROW reading frame: on a WINDOWED, SCROLLED fixture (a subject with 15
// children at 44×14 forces the body past the viewport; Scroll>0 pushes the window
// down), EVERY rail stop the hit map tags as LineSpineRow must paint on EXACTLY
// its own hit-map screen row when hovered. Because frameHitTargets (the hit map)
// and windowFrame (the paint) now share ONE window-top producer (readingWindowTop)
// this holds structurally — but the test cross-checks it by independent paint, so
// a re-inlined top-math copy that drifts would move the painted row off its hit Y
// and RED this test. Truecolor is mandatory: without SGR hoverPaint is the
// identity and no line would change (vacuous green).
func TestNarrowRailHoverParityUnderScroll(t2 *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t2.Cleanup(func() { lipgloss.SetColorProfile(oldp) })
	withChrome(t2)

	m := narrowReadingFixture(15)
	m.width, m.height = 44, 14
	m.stack[len(m.stack)-1].Scroll = 8 // absolute free-scroll offset > 0 (windowed, scrolled)

	width, height := m.composeInner()
	body, _ := m.frameContent(m.topFrame(), width, m.now())
	if len(body) <= height-2 {
		t2.Fatalf("fixture must WINDOW to prove scroll parity: body %d, avail %d", len(body), height-2)
	}

	hits := m.ComposeHitMap()
	base := m
	base.ui.HoverStop = -1
	baseLines := strings.Split(Compose(base), "\n")
	if len(baseLines) != len(hits) {
		t2.Fatalf("ComposeHitMap (%d) and Compose (%d) lengths diverge", len(hits), len(baseLines))
	}

	seen := 0
	for i, h := range hits {
		if h.Kind != LineSpineRow {
			continue
		}
		seen++
		hm := m
		hm.ui.HoverStop = h.CursorIndex
		afterLines := strings.Split(Compose(hm), "\n")
		if len(afterLines) != len(baseLines) {
			t2.Fatalf("stop %d hover changed the line count: %d vs %d", h.CursorIndex, len(afterLines), len(baseLines))
		}
		nChanged, changedIdx := 0, -1
		for j := range afterLines {
			if afterLines[j] != baseLines[j] {
				nChanged, changedIdx = nChanged+1, j
			}
		}
		if nChanged != 1 {
			t2.Fatalf("stop %d hover restyled %d lines, want exactly 1", h.CursorIndex, nChanged)
		}
		if changedIdx != i {
			t2.Fatalf("stop %d: hit-map row %d ≠ painted row %d — hit-map⇄paint top-math drift",
				h.CursorIndex, i, changedIdx)
		}
		if ansi.Strip(afterLines[changedIdx]) != ansi.Strip(baseLines[changedIdx]) {
			t2.Fatalf("stop %d hover changed the visible text at row %d (styling only expected)", h.CursorIndex, changedIdx)
		}
	}
	if seen < 2 {
		t2.Fatalf("expected >=2 visible rail stops in the scrolled window, got %d", seen)
	}
}
