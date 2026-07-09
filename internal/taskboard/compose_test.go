package taskboard

// compose_test.go — the navigation-shell compositor (charter D11/D12/D18/D26).
// Full-frame goldens exercise BOTH modes (charter "BOTH compositor modes" gate):
// narrow PUSH at 60/80/100 (a pushed FrameTask + a pushed FramePaper) and a WIDE
// two-pane at 120 with the depth-0 detail preview. Behavioral tests pin the
// stack (push/pop + D11 cycle guard), the breadcrumb, the ±4 hysteresis, the
// reading cursor grammar, and the act-verbs-follow-the-reader rule. Deterministic
// fixed clock; reuses render_test.go's -update flag.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// composeSubjectID is the fixture's drilled-into task.
const composeSubjectID = "wire-sse-bridge"

// composeFixture builds a self-contained Model: one rich subject task with three
// parent-linked children and a cached paper, an orphan board holding them all,
// the DetailIndex, and a deterministic clock. Callers set stack/width/wide.
func composeFixture() Model {
	subj := Task{
		DocID:     composeSubjectID,
		Title:     "Wire the SSE live bridge to the task board pane",
		Lifecycle: "in_progress",
		Kind:      "task",
		Priority:  "1",
		Labels:    []string{"proj:task-tui", "area:live"},
		Claim:     &Claim{Worker: "fable-3", Epoch: 4, ClaimedAt: at("2026-07-04T17:26:00Z")},
		Criteria:  &Criteria{Met: 2, Total: 3},
		CriteriaItems: []CriterionItem{
			{Criterion: "SSE dirty-bit triggers a debounced refetch", Met: true},
			{Criterion: "Connection dot renders honestly", Met: true},
			{Criterion: "A stuck reconnect never reads ConnLive", Met: false},
		},
		InsertedAt: at("2026-07-02T09:12:00Z"),
		UpdatedAt:  at("2026-07-04T17:22:00Z"),
	}
	d := TaskDetail{
		Task: subj,
		Description: "The board must repaint the moment the queue moves.\n\n" +
			"- one dirty bit signals the refetch\n" +
			"- one snapshot is the single source of truth",
		DesignDoc: "task-tui-wave5-charter",
		Papers:    []string{"doey-ui-lessons"},
		Evidence:  []string{"internal/taskboard/live.go:42", "", ""},
	}
	children := []Task{
		{DocID: "sse-decode", ParentID: composeSubjectID, Title: "Decode the change feed envelope",
			Lifecycle: "done", UpdatedAt: at("2026-07-03T10:00:00Z")},
		{DocID: "sse-debounce", ParentID: composeSubjectID, Title: "Debounce the refetch at 750ms",
			Lifecycle: "in_progress", Claim: &Claim{Worker: "fable-3", ClaimedAt: at("2026-07-04T17:26:00Z")},
			UpdatedAt: at("2026-07-04T17:00:00Z")},
		{DocID: "sse-conn-dot", ParentID: composeSubjectID, Title: "Honest connection dot states",
			Lifecycle: "ready", UpdatedAt: at("2026-07-04T12:00:00Z")},
	}
	tasks := append([]Task{subj}, children...)
	details := DetailIndex{subj.DocID: d}
	for _, c := range children {
		details[c.DocID] = TaskDetail{Task: c}
	}
	return Model{
		board: Board{
			// The loose bucket holds active work, so it is a focus section (charter
			// D51 / wave-11) — its FocusSet keeps the subject + its children visible
			// for the reading-frame and wide-preview tests. Its navigable header is
			// row 0; the subject task sits at cursor 1.
			Orphans:         tasks,
			OrphansActive:   true,
			OrphansFocusSet: focusOf(composeSubjectID, "sse-decode", "sse-debounce", "sse-conn-dot"),
			Counts:          map[string]int{"in_progress": 2, "done": 1},
		},
		ui:      UIState{Conn: ConnLive, LastSync: at("2026-07-04T17:28:00Z"), CollapsedEpics: map[string]bool{}},
		details: details,
		tasks:   tasks,
		papers: map[string]PaperState{
			"task-tui-wave5-charter": {
				Slug:      "task-tui-wave5-charter",
				Title:     "Task-TUI wave 5 charter",
				Rev:       "rev-7",
				BlocksRaw: []byte(fixtureBlocks),
			},
		},
		now:   func() time.Time { return detailNow },
		stack: []Frame{{Kind: FrameBoard, Title: "tasks"}},
	}
}

func withChrome(t *testing.T) {
	t.Helper()
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "lead/session-stable", Server: "guerrilla"}
	t.Cleanup(func() { Chrome = old })
}

func composeGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden (run with -update): %v", err)
	}
	if got != string(want) {
		t.Errorf("compose frame diverged from %s\n--- got ---\n%s\n--- want ---\n%s", path, got, want)
	}
}

// A pushed FrameTask, full-frame push at 60/80/100: breadcrumb top line, the
// windowed detail body, the reading footer. Every line width-safe.
func TestComposeTaskGoldens(t *testing.T) {
	withChrome(t)
	for _, w := range []int{60, 80, 100} {
		m := composeFixture()
		m.width, m.height, m.wide = w, 44, false
		(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "Wire the SSE live bridge"})
		got := ansi.Strip(Compose(m))
		assertWidthSafe(t, got, w)
		composeGolden(t, composeName("compose_task", w), got)
	}
}

// A pushed FramePaper (task → paper), full-frame push at 80: the breadcrumb now
// carries three segments, the pdrender body renders, and the driven rail shows.
func TestComposePaperGolden(t *testing.T) {
	withChrome(t)
	resetPaperCache()
	m := composeFixture()
	m.width, m.height, m.wide = 80, 44, false
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "Wire the SSE live bridge"})
	(&m).pushFrame(Frame{Kind: FramePaper, Ref: "task-tui-wave5-charter", Title: "Task-TUI wave 5 charter"})
	got := ansi.Strip(Compose(m))
	assertWidthSafe(t, got, 80)
	composeGolden(t, "compose_paper_80.txt", got)
}

// WIDE two-pane at 120: board pinned left (46 cols), the depth-0 detail PREVIEW
// of the board cursor-target on the right, the breadcrumb spanning the top.
func TestComposeWideGolden(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 1 // the subject task (row 0 is the loose-bucket header) — its detail previews right
	got := ansi.Strip(Compose(m))
	assertWidthSafe(t, got, 120)
	composeGolden(t, "compose_wide_120.txt", got)
}

func composeName(prefix string, w int) string {
	switch w {
	case 60:
		return prefix + "_60.txt"
	case 80:
		return prefix + "_80.txt"
	default:
		return prefix + "_100.txt"
	}
}

func assertWidthSafe(t *testing.T, frame string, width int) {
	t.Helper()
	for i, ln := range strings.Split(frame, "\n") {
		if w := disp(ln); w > width {
			t.Errorf("line %d is %d cols (over budget %d): %q", i, w, width, ln)
		}
	}
}

// Narrow depth-0 composites to the pure board frame (no redundant breadcrumb) —
// the board's own header orients you, so View() at rest is byte-identical to
// Render (protects the board goldens from a compositor regression).
func TestComposeNarrowDepth0IsBoard(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 80, 40, false
	// Compose = the board frame inside the pane gutter (1 col left + 3 right
	// at >=56 wide, one blank top row): the inner render is byte-identical,
	// just inset.
	inner := Render(m.board, m.ui, 76, 39, m.now())
	var want strings.Builder
	want.WriteByte('\n')
	for i, l := range strings.Split(inner, "\n") {
		if i > 0 {
			want.WriteByte('\n')
		}
		if l != "" {
			want.WriteString(" ")
			want.WriteString(l)
		}
	}
	if got := Compose(m); got != want.String() {
		t.Errorf("narrow depth-0 Compose != gutter(Render(board))\n--- compose ---\n%s\n--- render ---\n%s",
			ansi.Strip(got), ansi.Strip(want.String()))
	}
}

// ── Stack + cycle guard (charter D11) ────────────────────────────────────────

// Pushing a (Kind,Ref) already on the stack POPS BACK to it instead of
// duplicating (a task→paper→same-task loop lands on the first copy).
func TestPushFrameCycleGuardPopsBack(t *testing.T) {
	m := composeFixture()
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: "a", Title: "A"})
	(&m).pushFrame(Frame{Kind: FramePaper, Ref: "p", Title: "P"})
	if len(m.stack) != 3 {
		t.Fatalf("depth after two pushes = %d, want 3", len(m.stack))
	}
	// Push A again — the guard truncates back to it rather than growing to 4.
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: "a", Title: "A"})
	if len(m.stack) != 2 {
		t.Fatalf("cycle guard did not pop back: depth %d, want 2", len(m.stack))
	}
	if top := m.topFrame(); top.Kind != FrameTask || top.Ref != "a" {
		t.Fatalf("top after cycle-guard = {%v %q}, want {FrameTask a}", top.Kind, top.Ref)
	}
}

// popFrame is a no-op at the root board frame.
func TestPopAtRootIsNoOp(t *testing.T) {
	m := composeFixture()
	(&m).popFrame()
	if len(m.stack) != 1 || m.topFrame().Kind != FrameBoard {
		t.Fatalf("pop at root changed the stack: depth %d", len(m.stack))
	}
}

// ── Breadcrumb (charter D18) ─────────────────────────────────────────────────

// The first (root) and last (where you are) segments always survive the
// middle-truncation, even on a deep stack in a narrow pane.
func TestBreadcrumbKeepsFirstAndLast(t *testing.T) {
	stack := []Frame{
		{Kind: FrameBoard, Title: "tasks"},
		{Kind: FrameTask, Ref: "a", Title: "Wire the SSE live bridge to the pane"},
		{Kind: FramePaper, Ref: "p", Title: "Task-TUI wave 5 charter document"},
		{Kind: FrameTask, Ref: "c", Title: "Debounce the refetch at 750ms exactly"},
	}
	crumb := ansi.Strip(Breadcrumb(stack, 40))
	if disp(crumb) > 40 {
		t.Fatalf("breadcrumb over width: %d cols %q", disp(crumb), crumb)
	}
	if !strings.HasPrefix(crumb, "tasks") {
		t.Errorf("lost the root segment: %q", crumb)
	}
	if !strings.Contains(crumb, "Debounce") {
		t.Errorf("lost the current (last) segment: %q", crumb)
	}
	if !strings.Contains(crumb, "…") && !strings.Contains(crumb, "›") {
		t.Errorf("no elision/separator in a truncated trail: %q", crumb)
	}
}

// ── Hysteresis (charter D12/D27) ─────────────────────────────────────────────

// Two-pane engages at >=110 and reverts below 106; the deadband [106,110) holds
// the previous mode so a resize across the boundary never flaps.
func TestWideHysteresis(t *testing.T) {
	m := composeFixture()
	step := func(w int) bool {
		nm, _ := m.Update(tea.WindowSizeMsg{Width: w, Height: 40})
		m = nm.(Model)
		return m.wide
	}
	if step(120) != true {
		t.Fatal("w=120 must be wide")
	}
	if step(108) != true {
		t.Fatal("w=108 in the deadband must HOLD wide")
	}
	if step(105) != false {
		t.Fatal("w=105 must revert to narrow")
	}
	if step(108) != false {
		t.Fatal("w=108 in the deadband must HOLD narrow")
	}
	if step(110) != true {
		t.Fatal("w=110 must re-engage wide")
	}
}

// ── Reading viewport (charter D18: Scroll semantics) ─────────────────────────

// A freshly opened frame in a pane too SHORT to hold its whole body shows the
// frame from its TOP (title first), NOT centered on the first selectable stop
// (which sits far down the body). The wish is "open a task and SEE it"; the
// zero-value Scroll=0 is a real absolute offset (top), never the follow sentinel.
func TestFreshFrameOpensAtTop(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 80, 16, false // short pane → body > avail → windows
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	body, stops := m.frameContent(m.topFrame(), m.readingWidth(), m.now())
	if len(body) <= m.readingViewportHeight() {
		t.Fatalf("fixture must overflow the short pane (body %d <= avail %d)", len(body), m.readingViewportHeight())
	}
	if len(stops) == 0 || stops[0].Line < m.readingViewportHeight() {
		t.Fatalf("fixture's first stop must sit below the fold to exercise the bug (stop0.Line=%v avail=%d)",
			stops, m.readingViewportHeight())
	}
	frame := ansi.Strip(Compose(m))
	if !strings.Contains(frame, "Wire the SSE live bridge to the task board pane") {
		t.Errorf("fresh frame did not open on its title (centered on stop 0 instead):\n%s", frame)
	}
	if strings.Contains(frame, "↑ more above") {
		t.Errorf("fresh frame opened mid-body (has '↑ more above'):\n%s", frame)
	}
}

// Free-scrolling up settles at the top (Scroll=0) instead of oscillating back to
// cursor-follow — the old bug had Scroll==0 mean BOTH "top" and "follow", so a
// third 'u' snapped the viewport back down (9→2→0→9…). Now it holds at 0.
func TestFreeScrollUpSettlesAtTop(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 80, 16, false
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	// Move the cursor down so follow-mode's top is well below 0, making an
	// oscillation back to follow visibly different from a settled top.
	(&m).moveStopCursor(2)
	last := -999
	for i := 0; i < 6; i++ {
		(&m).freeScroll(-m.readingViewportHeight() / 2)
		s := m.topFrame().Scroll
		if i > 0 && s > last {
			t.Fatalf("scroll-up oscillated: press %d moved Scroll %d -> %d (must be monotone toward 0)", i, last, s)
		}
		last = s
	}
	if m.topFrame().Scroll != 0 {
		t.Fatalf("scroll-up did not settle at the top: Scroll=%d, want 0", m.topFrame().Scroll)
	}
	if strings.Contains(ansi.Strip(Compose(m)), "↑ more above") {
		t.Error("settled viewport still reports content above the top")
	}
}

// ── Reading cursor grammar (charter D18/D29) ─────────────────────────────────

// j/k move the frame's stop cursor (not the board's) and snap the viewport back;
// esc ascends.
func TestReadingJKMovesStopCursor(t *testing.T) {
	m := composeFixture()
	m.width, m.height = 80, 40
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	if n := m.frameStopCount(); n < 2 {
		t.Fatalf("fixture detail should expose >=2 stops (children+papers), got %d", n)
	}
	m2, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	m = m2.(Model)
	if m.topFrame().Cursor != 1 {
		t.Fatalf("j did not advance the stop cursor: %d, want 1", m.topFrame().Cursor)
	}
	// The board cursor is untouched — the two navigation domains are separate.
	if m.ui.Cursor != 0 {
		t.Fatalf("reading j moved the BOARD cursor to %d", m.ui.Cursor)
	}
	m2, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	m = m2.(Model)
	if len(m.stack) != 1 {
		t.Fatalf("esc did not ascend: depth %d", len(m.stack))
	}
}

// enter on a child stop descends into that child's FrameTask.
func TestReadingEnterDescendsOnChild(t *testing.T) {
	m := composeFixture()
	m.width, m.height = 80, 40
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	// stop 0 is the first child rail row (children emit before papers).
	_, stops := m.frameContent(m.topFrame(), m.readingWidth(), m.now())
	if len(stops) == 0 || stops[0].Kind != FrameTask {
		t.Fatalf("first stop should be a child FrameTask, got %+v", stops)
	}
	want := stops[0].Ref
	m2, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = m2.(Model)
	if top := m.topFrame(); top.Kind != FrameTask || top.Ref != want {
		t.Fatalf("enter descended to {%v %q}, want {FrameTask %q}", top.Kind, top.Ref, want)
	}
}

// ── Act verbs follow the reader (charter D30) ────────────────────────────────

// In a FrameTask, c/x/o target the frame's OWN subject task — not a board cursor.
func TestReadingActTargetsSubject(t *testing.T) {
	m := composeFixture()
	m.width, m.height = 80, 40
	// Make the subject claimable so c fires a claim command on IT.
	subj := m.tasks[0]
	subj.Lifecycle = lifeReady
	subj.Claim = nil
	m.details[composeSubjectID] = TaskDetail{Task: subj}
	m.tasks[0] = subj
	m.board.Orphans[0] = subj
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})

	// c on the reading frame resolves the frame's subject (not a board cursor)
	// and fires a claim command for IT.
	got, ok := m.readingSubjectTask()
	if !ok || got.DocID != composeSubjectID {
		t.Fatalf("readingSubjectTask = (%+v,%v), want the subject", got, ok)
	}
	m2, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("c")})
	m = m2.(Model)
	if cmd == nil {
		t.Fatal("c on a ready reading-frame subject fired no claim command")
	}
	if strings.Contains(m.ui.Strip.Message, "nothing to act on") {
		t.Fatalf("c treated the reading subject as un-actionable: %q", m.ui.Strip.Message)
	}
}

// ── Wide two-pane mouse routing (charter D12) ────────────────────────────────

// lineContaining returns the 0-based index of the first line whose stripped text
// contains sub, or -1. Used to locate a painted row by its visible text so the
// mouse tests never hand-compute the layout.
func lineContaining(frame, sub string) int {
	for i, ln := range strings.Split(frame, "\n") {
		if strings.Contains(ansi.Strip(ln), sub) {
			return i
		}
	}
	return -1
}

// visibleRowIndex is the cursor index of the board row with the given doc id.
func visibleRowIndex(m Model, docID string) int {
	for i, r := range m.visibleRows() {
		if r.docID == docID {
			return i
		}
	}
	return -1
}

// wideClick builds a left-press mouse event at a composeAt-local (x,y): the
// router strips the Compose gutter (gl=1 pad + one blank top row), so screen
// X = x+1 and screen Y = y+1.
func wideClick(x, y int) tea.MouseMsg {
	return tea.MouseMsg{X: x + 1, Y: y + 1, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress}
}

func wideWheel(x, y int, up bool) tea.MouseMsg {
	b := tea.MouseButtonWheelDown
	if up {
		b = tea.MouseButtonWheelUp
	}
	return tea.MouseMsg{X: x + 1, Y: y + 1, Button: b, Action: tea.MouseActionPress}
}

// A left click on a board row selects it — the SAME cursor arrowing to it would
// land on (charter/wish: "click a task row to select it, same effect as arrowing
// to it"), and the FULL row is the target (the X is deep in the row, not on the
// glyph).
func TestWideMouseBoardRowClickSelects(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 0 // header selected → the short board never scrolls
	_, _, inner := m.wideGeom()
	board := Render(m.board, m.ui, boardPaneWidth, inner, m.now())
	pl := lineContaining(board, "Wire the SSE")
	if pl < 0 {
		t.Fatalf("subject row not painted in the board pane:\n%s", ansi.Strip(board))
	}
	want := visibleRowIndex(m, composeSubjectID)
	if want < 0 {
		t.Fatal("subject is not a visible board row")
	}
	// composeAt Y = pl+1 (row 0 is the breadcrumb); X=20 is deep in the 46-col row.
	m2, cmd := m.handleWideMouse(wideClick(20, pl+1))
	nm := m2
	if cmd != nil {
		t.Errorf("a board select fired a command: %v", cmd)
	}
	if nm.ui.Cursor != want {
		t.Fatalf("board click selected cursor %d, want %d (the subject)", nm.ui.Cursor, want)
	}
}

// A click on the identity strip / status chrome / the dead inter-pane gutter is a
// no-op — honest degradation, never a mis-select.
func TestWideMouseInertRegionsNoOp(t *testing.T) {
	withChrome(t)
	base := func() Model {
		m := composeFixture()
		m.width, m.height, m.wide = 120, 40, true
		m.ui.Cursor = 1
		return m
	}
	_, _, inner := base().wideGeom()
	cases := []struct {
		name string
		ev   tea.MouseMsg
	}{
		{"identity-strip", wideClick(20, 1)},          // composeAt Y=1 → board pane line 0 (identity top)
		{"dead-gutter", wideClick(boardPaneWidth, 3)}, // x=46 → the 2-col gutter
		{"crumb-row", wideClick(20, 0)},               // composeAt Y=0 → the breadcrumb
		{"below-frame", wideClick(20, inner+5)},       // past the last pane row
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := base()
			m2, cmd := m.handleWideMouse(c.ev)
			if m2.ui.Cursor != 1 || cmd != nil {
				t.Fatalf("%s moved the cursor to %d / fired %v, want no-op", c.name, m2.ui.Cursor, cmd)
			}
		})
	}
}

// The wheel over the board pane steps the cursor one row (#1878: one line at a
// time, never a recenter jump) — up and down, clamped.
func TestWideMouseBoardWheelStepsCursor(t *testing.T) {
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 1
	down, _ := m.handleWideMouse(wideWheel(20, 2, false))
	if down.ui.Cursor != 2 {
		t.Fatalf("wheel-down stepped cursor to %d, want 2", down.ui.Cursor)
	}
	up, _ := down.handleWideMouse(wideWheel(20, 2, true))
	if up.ui.Cursor != 1 {
		t.Fatalf("wheel-up stepped cursor to %d, want 1", up.ui.Cursor)
	}
}

// At depth 0 the right pane is a non-interactive preview — clicks AND wheel
// no-op honestly (cursor unmoved, stack unchanged, no command).
func TestWideMouseDepth0PreviewInert(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 1
	rightX := boardPaneWidth + paneGutter2 + 4 // deep in the right preview pane
	for _, ev := range []tea.MouseMsg{
		wideClick(rightX, 3),
		wideWheel(rightX, 3, false),
		wideWheel(rightX, 3, true),
	} {
		m2, cmd := m.handleWideMouse(ev)
		if m2.ui.Cursor != 1 || len(m2.stack) != 1 || cmd != nil {
			t.Fatalf("preview event %v was not inert: cursor=%d depth=%d cmd=%v",
				ev, m2.ui.Cursor, len(m2.stack), cmd)
		}
	}
}

// Depth>0: a click on a rail stop in the right pane selects that stop (the frame
// cursor moves, viewport follows) — resolved via Stop.Line + the painted window
// offset, the FULL row a target.
func TestWideMouseRightRailClickSelectsStop(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 60, true // tall enough that the detail body fits
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	_, _, inner := m.wideGeom()
	rightW := 120 - 1 - 3 - boardPaneWidth - paneGutter2
	body, stops := m.frameContent(m.topFrame(), rightW, m.now())
	if len(body) > inner {
		t.Fatalf("fixture body (%d) must fit the pane (%d) so stops are on-screen", len(body), inner)
	}
	if len(stops) < 2 {
		t.Fatalf("need >=2 rail stops to prove selection moves, got %d", len(stops))
	}
	// Click stop index 1 (a fresh frame opens on cursor 0, so 1 proves movement).
	target := stops[1]
	// composeAt Y = pane line + 1; the body fits so pane line == body line.
	m2, cmd := m.handleWideMouse(wideClick(boardPaneWidth+paneGutter2+3, target.Line+1))
	if cmd != nil {
		t.Errorf("a rail select fired a command: %v", cmd)
	}
	if got := m2.topFrame().Cursor; got != 1 {
		t.Fatalf("rail click selected stop %d, want 1", got)
	}
}

// Depth>0: the wheel over the right reading pane free-scrolls one line, exactly
// like the keyboard's space/u/d — so mouse and keyboard never disagree about the
// viewport (#1878).
func TestWideMouseRightWheelFreeScrolls(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 16, true // short pane so the body overflows
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	body, _ := m.frameContent(m.topFrame(), m.readingWidth(), m.now())
	if len(body) <= m.readingViewportHeight() {
		t.Fatalf("fixture must overflow the short pane (body %d <= avail %d)", len(body), m.readingViewportHeight())
	}
	rightX := boardPaneWidth + paneGutter2 + 3
	m2, _ := m.handleWideMouse(wideWheel(rightX, 3, false))
	if got := m2.topFrame().Scroll; got != 1 {
		t.Fatalf("one wheel-down scrolled to %d, want 1 (one line, like space)", got)
	}
	m3, _ := m2.handleWideMouse(wideWheel(rightX, 3, true))
	if got := m3.topFrame().Scroll; got != 0 {
		t.Fatalf("wheel-up back to %d, want 0", got)
	}
}

// The Y hit-map addresses EXACTLY the painted composeAt rows — the crumb plus one
// per pane line, no more — so a click can never resolve to a row that was never
// drawn (length parity, including the crumb row).
func TestWideMouseHitMapParity(t *testing.T) {
	withChrome(t)
	for _, wh := range [][2]int{{120, 40}, {160, 24}, {110, 50}} {
		m := composeFixture()
		m.width, m.height, m.wide = wh[0], wh[1], true
		rowmap := m.wideRowMap()
		_, innerW, _ := m.wideGeom()
		lines := strings.Split(composeAt(m, innerW, m.height-1), "\n")
		if len(rowmap) != len(lines) {
			t.Fatalf("%dx%d: hit-map length %d != painted composeAt rows %d",
				wh[0], wh[1], len(rowmap), len(lines))
		}
		if rowmap[0] != rowCrumb {
			t.Fatalf("%dx%d: row 0 is not the breadcrumb", wh[0], wh[1])
		}
	}
}

// On a FramePaper the act verbs operate on the cursor stop iff it is a task, else
// there is nothing to act on.
func TestPaperActResolvesCursorStop(t *testing.T) {
	withChrome(t)
	resetPaperCache()
	m := composeFixture()
	m.width, m.height = 80, 40
	// Drive the paper from the subject so the driven rail has a task stop.
	(&m).pushFrame(Frame{Kind: FramePaper, Ref: "task-tui-wave5-charter", Title: "charter"})
	_, stops := m.frameContent(m.topFrame(), m.readingWidth(), m.now())
	if len(stops) == 0 {
		// The fixture's subject names this paper via design_doc, so it drives it.
		t.Fatalf("paper should drive >=1 task (the subject names it), got 0 stops")
	}
	got, ok := m.readingSubjectTask()
	if !ok || got.DocID != stops[0].Ref {
		t.Fatalf("paper act resolved %+v (ok=%v), want the cursor stop %q", got, ok, stops[0].Ref)
	}
}
