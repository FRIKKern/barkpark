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
			// The loose bucket holds active in_progress work, so it is OrphansActive
			// (auto-expanded under wave-7's fold-by-default) — its rows stay visible
			// for the reading-frame and wide-preview tests. Its navigable header is
			// row 0; the subject task sits at cursor 1.
			Orphans:       tasks,
			OrphansActive: true,
			Counts:        map[string]int{"in_progress": 2, "done": 1},
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
