package taskboard

// compose_test.go — the navigation-shell compositor (charter D11/D12/D18/D26).
// Full-frame goldens exercise BOTH modes (charter "BOTH compositor modes" gate):
// narrow PUSH at 60/80/100 (a pushed FrameTask + a pushed FramePaper) and a WIDE
// two-pane at 120 with the depth-0 detail preview. Behavioral tests pin the
// stack (push/pop + D11 cycle guard), the breadcrumb, the ±4 hysteresis, the
// reading cursor grammar, and the act-verbs-follow-the-reader rule. Deterministic
// fixed clock; reuses render_test.go's -update flag.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
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
		ui:      UIState{Conn: ConnLive, LastSync: at("2026-07-04T17:28:00Z"), CollapsedEpics: map[string]bool{}, HoverStop: -1},
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
		now:           func() time.Time { return detailNow },
		stack:         []Frame{{Kind: FrameBoard, Title: "tasks"}},
		wideBoardCols: boardPaneWidth,
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

// WIDE two-pane at 120 with a DRAGGED divider: a persisted non-default
// DetailsPaneRatio (0.4444, as if the user had dragged the split wider), driving
// the layout through boardPaneCols' ratio path instead of the fixture's fixed
// 46-col wideBoardCols. The board pane widens past its default third, so the
// resize handle lands well right of compose_wide_120's. TestComposeWideGolden
// pins ONLY the default split; without this the drag's ratio→column geometry had
// no frame baseline, so a regression there would ship silently.
func TestComposeWideDraggedGolden(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 1     // the subject task — same target as the default-split golden
	m.wideBoardCols = 0 // drop the fixture's fixed split so the ratio drives the layout
	m.wideDetailsRatio = 0.4444
	got := ansi.Strip(Compose(m))
	assertWidthSafe(t, got, 120)
	composeGolden(t, "compose_wide_dragged_120.txt", got)

	// The point of a dragged baseline: its divider sits at a DIFFERENT column than
	// the default-third split, proving the ratio actually moved the panes (and that
	// this golden is not a stale copy of compose_wide_120).
	def := composeFixture()
	def.width, def.height, def.wide = 120, 40, true
	def.ui.Cursor = 1
	defCol := dividerCol(t, ansi.Strip(Compose(def)))
	dragCol := dividerCol(t, got)
	if dragCol <= defCol {
		t.Fatalf("a wider board pane must push the divider RIGHT of the default split: dragged col %d, default col %d",
			dragCol, defCol)
	}
}

// dividerCol returns the rune column of the wide resize handle (↔) — painted once,
// on the identity row at the pane boundary — so a test can compare where the split
// fell across two frames without re-deriving the pane geometry.
func dividerCol(t *testing.T, frame string) int {
	t.Helper()
	for _, ln := range strings.Split(frame, "\n") {
		if i := strings.IndexRune(ln, '↔'); i >= 0 {
			return len([]rune(ln[:i]))
		}
	}
	t.Fatalf("no ↔ resize handle in the wide frame:\n%s", frame)
	return -1
}

// TestEnterChecksOpenTaskRow — the picker vocabulary: entering a task CHECKS
// its reader marker. While a FrameTask is on the navigation stack its board row
// wears ◆ (in place of the lifecycle glyph, same color), and
// popping the frame (esc) reverts it. Exercised in WIDE mode, where the board
// stays pinned beside the reading frame so the check is actually visible.
func TestEnterChecksOpenTaskRow(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 1 // the subject task

	// subjectRow finds the subject task's BOARD-PANE row: the match must sit in
	// the left 46 columns (the pinned board); only the Compose blank row is
	// skipped (the breadcrumb row was retired).
	subjectRow := func(frame string) string {
		t.Helper()
		for i, ln := range strings.Split(frame, "\n") {
			if i < 1 {
				continue
			}
			r := []rune(ln)
			if len(r) > boardPaneWidth {
				r = r[:boardPaneWidth]
			}
			if strings.Contains(string(r), "Wire the SSE") {
				return ln[:len(string(r))]
			}
		}
		t.Fatalf("subject row not found in the board pane:\n%s", frame)
		return ""
	}

	before := subjectRow(ansi.Strip(Compose(m)))
	if strings.Contains(before, "◆") {
		t.Fatalf("subject row is checked before enter: %q", before)
	}

	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "Wire the SSE live bridge"})
	during := subjectRow(ansi.Strip(Compose(m)))
	if !strings.Contains(during, "◆") {
		t.Fatalf("entered task's board row is not checked: %q", during)
	}

	(&m).popFrame()
	after := subjectRow(ansi.Strip(Compose(m)))
	if strings.Contains(after, "◆") {
		t.Fatalf("escaped task's board row is still checked: %q", after)
	}
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

// ── Reading viewport clamp matches the paint (off-by-one guard) ──────────────

// longBodyFixture is the compose fixture with the subject task's detail padded to
// a body far taller than any tested pane, so the reading window is always full
// and the free-scroll clamp is genuinely exercised.
func longBodyFixture() Model {
	m := composeFixture()
	d := m.details[composeSubjectID]
	var b strings.Builder
	b.WriteString(d.Description)
	b.WriteString("\n\n")
	for i := 0; i < 60; i++ {
		fmt.Fprintf(&b, "- body line %02d marks a distinct paragraph in the reading frame\n", i)
	}
	d.Description = b.String()
	m.details[composeSubjectID] = d
	return m
}

// paintedBodyWindow counts the reading-window lines Compose ACTUALLY painted for a
// pushed frame — the ground truth readingViewportHeight() must equal. Compose
// prepends one blank row and composeAt reserves only the footer in narrow, so
// the window is total lines minus that chrome. Measuring
// the real paint (not re-deriving the formula) is what makes this a regression
// guard: change composeAt's reserved chrome and this count moves with it.
func paintedBodyWindow(t *testing.T, m Model) int {
	t.Helper()
	lines := strings.Split(ansi.Strip(Compose(m)), "\n")
	if len(lines) < 3 {
		t.Fatalf("compose produced too few lines to hold a window: %d", len(lines))
	}
	if m.wide {
		return len(lines) - 1 // leading blank
	}
	return len(lines) - 2 // leading blank + footer
}

// readingViewportHeight() must equal the body-window Compose paints, at EVERY
// height in both modes — the helper fed Compose height while the paint runs at
// composeAt's height-1 (the leading blank row), so a naive split under-clamped
// free-scroll by one and hid the last body line under a stuck ↓-more marker.
func TestReadingViewportHeightMatchesPaint(t *testing.T) {
	withChrome(t)
	for _, wide := range []bool{false, true} {
		for h := 8; h <= 30; h++ {
			m := longBodyFixture()
			m.wide = wide
			if wide {
				m.width = 120 // above the two-pane threshold
			} else {
				m.width = 80
			}
			m.height = h
			(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
			want := paintedBodyWindow(t, m)
			if got := m.readingViewportHeight(); got != want {
				t.Errorf("wide=%v h=%d: readingViewportHeight()=%d but Compose painted %d body-window lines",
					wide, h, got, want)
			}
		}
	}
}

// Free-scrolling to the clamp on a long body must land on the LAST body line with
// NO ↓-more marker — proving the clamp reaches bottom (the off-by-one under-scroll
// left the final line hidden). Both modes.
func TestFreeScrollReachesLastBodyLine(t *testing.T) {
	withChrome(t)
	for _, wide := range []bool{false, true} {
		m := longBodyFixture()
		m.wide = wide
		if wide {
			m.width = 120
		} else {
			m.width = 80
		}
		m.height = 20
		(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})

		body, _ := m.frameContent(m.topFrame(), m.readingWidth(), m.now())
		avail := m.readingViewportHeight()
		if len(body) <= avail {
			t.Fatalf("wide=%v: fixture must overflow the pane (body %d <= avail %d)", wide, len(body), avail)
		}
		// Scroll down past the end; the clamp must settle exactly at the bottom
		// window (top = len(body)-avail), not one short of it.
		for i := 0; i < len(body); i++ {
			(&m).freeScroll(1)
		}
		if got, wantTop := m.topFrame().Scroll, len(body)-avail; got != wantTop {
			t.Errorf("wide=%v: scroll clamp settled at %d, want the bottom window %d", wide, got, wantTop)
		}
		frame := ansi.Strip(Compose(m))
		if strings.Contains(frame, "more below") {
			t.Errorf("wide=%v: ↓-more marker still shown after scrolling to the bottom:\n%s", wide, frame)
		}
		// The last non-blank body line is on screen.
		lastIdx := len(body) - 1
		for lastIdx >= 0 && strings.TrimSpace(ansi.Strip(body[lastIdx])) == "" {
			lastIdx--
		}
		if lastIdx >= 0 {
			last := strings.TrimSpace(ansi.Strip(body[lastIdx]))
			if last != "" && !strings.Contains(frame, last) {
				t.Errorf("wide=%v: last body line %q not painted at the bottom:\n%s", wide, last, frame)
			}
		}
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

// A left click on a board task moves the cursor there and activates it in one
// gesture — exactly the state reached by moving there and pressing Enter.
func TestWideMouseBoardRowClickMatchesEnter(t *testing.T) {
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
	// composeAt Y == pane line (the crumb row was retired); X=20 is deep in the 46-col row.
	m2, cmd := m.handleWideMouse(wideClick(20, pl))
	nm := m2
	if cmd != nil {
		t.Errorf("a board click fired a command: %v", cmd)
	}
	if nm.ui.Cursor != want {
		t.Fatalf("board click selected cursor %d, want %d (the subject)", nm.ui.Cursor, want)
	}
	if len(nm.stack) != 2 || nm.topFrame().Kind != FrameTask || nm.topFrame().Ref != composeSubjectID {
		t.Fatalf("single click did not match Enter: depth=%d kind=%v ref=%q",
			len(nm.stack), nm.topFrame().Kind, nm.topFrame().Ref)
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
		{"identity-strip", wideClick(20, 0)},    // composeAt Y=0 → board pane line 0 (identity top)
		{"below-frame", wideClick(20, inner+5)}, // past the last pane row
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

// At depth 0 the wheel over the right pane scrolls INSIDE the preview — the
// viewport offset moves (clamped at the top), while the board cursor and the
// stack stay untouched, so scrolling the info pane never re-selects a row.
func TestWideMouseDepth0PreviewWheelScrolls(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 16, true // short pane so the preview overflows
	m.ui.Cursor = visibleRowIndex(m, composeSubjectID)
	if m.ui.Cursor < 0 {
		t.Fatal("subject is not a visible board row")
	}
	rightX := boardPaneWidth + paneGutter2 + 4
	m2, cmd := m.handleWideMouse(wideWheel(rightX, 3, false))
	if cmd != nil {
		t.Errorf("a preview scroll fired a command: %v", cmd)
	}
	if m2.previewScroll != 1 || m2.previewRef != composeSubjectID {
		t.Fatalf("wheel-down scrolled preview to (%q, %d), want (%q, 1)",
			m2.previewRef, m2.previewScroll, composeSubjectID)
	}
	if m2.wideFocus != wideFocusReader {
		t.Fatal("wheel inside preview did not focus the right pane")
	}
	keyed, _ := m2.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if got := keyed.(Model).previewScroll; got != 2 {
		t.Fatalf("focused preview did not own keyboard scroll: got %d, want 2", got)
	}
	if m2.ui.Cursor != m.ui.Cursor || len(m2.stack) != 1 {
		t.Fatalf("preview scroll moved the board: cursor=%d depth=%d", m2.ui.Cursor, len(m2.stack))
	}
	// Wheel-up returns to the top and clamps there — never negative.
	m3, _ := m2.handleWideMouse(wideWheel(rightX, 3, true))
	m4, _ := m3.handleWideMouse(wideWheel(rightX, 3, true))
	if m4.previewScroll != 0 {
		t.Fatalf("wheel-up clamped preview to %d, want 0", m4.previewScroll)
	}
	// The painted pane follows the offset: a scrolled preview shows the ↑ marker.
	frame := ansi.Strip(composeAt(m2, 116, 15))
	if !strings.Contains(frame, "more above") {
		t.Errorf("scrolled preview shows no ↑ more-above marker:\n%s", frame)
	}
}

// At depth 0 a click on the right preview pane ENTERS the previewed task — the
// same single-open descent as activating its board row.
func TestWideMouseDepth0PreviewClickEnters(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = visibleRowIndex(m, composeSubjectID)
	if m.ui.Cursor < 0 {
		t.Fatal("subject is not a visible board row")
	}
	rightX := boardPaneWidth + paneGutter2 + 4
	// The activation click also transfers focus to the right column.
	m2, cmd := m.handleWideMouse(wideClick(rightX, 3))
	if cmd != nil {
		t.Errorf("a preview click fired a command: %v", cmd)
	}
	if m2.wideFocus != wideFocusReader {
		t.Fatalf("preview click did not focus the reader: focus=%v", m2.wideFocus)
	}
	if len(m2.stack) != 2 || m2.topFrame().Kind != FrameTask || m2.topFrame().Ref != composeSubjectID {
		t.Fatalf("preview click did not enter the previewed task: depth=%d kind=%v ref=%q",
			len(m2.stack), m2.topFrame().Kind, m2.topFrame().Ref)
	}
}

// rightPaneOf extracts the wide right pane's text from a composeAt frame: each
// row's columns past the board pane + gutter, ansi-stripped and joined — so an
// assertion on the preview can never be satisfied by the LEFT board pane's own
// row text.
func rightPaneOf(frame string) string {
	var sb strings.Builder
	for _, ln := range strings.Split(ansi.Strip(frame), "\n") {
		r := []rune(ln)
		if len(r) > boardPaneWidth+paneGutter2 {
			sb.WriteString(string(r[boardPaneWidth+paneGutter2:]))
		}
		sb.WriteByte('\n')
	}
	return sb.String()
}

// Hovering a board row previews THAT task in the wide right pane, exactly as
// entering it would — and the pane reverts when the hover clears (pointer left
// the board pane). The cursor is parked on the section HEADER (no preview
// target of its own), so the hovered task's detail is attributable to the
// hover alone.
func TestWideHoverPreviewsHoveredRow(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 0 // the orphan-section header — previews nothing itself
	_, innerW, _ := m.wideGeom()

	m.ui.HoverTarget = "sse-conn-dot"
	right := rightPaneOf(composeAt(m, innerW, m.height-1))
	if !strings.Contains(right, "Honest connection dot states") {
		t.Fatalf("hover did not preview the hovered task in the right pane:\n%s", right)
	}

	m.ui.HoverTarget = ""
	right = rightPaneOf(composeAt(m, innerW, m.height-1))
	if strings.Contains(right, "Honest connection dot states") {
		t.Fatalf("clearing the hover did not revert the preview:\n%s", right)
	}
	if !strings.Contains(right, "no task selected") {
		t.Fatalf("header cursor + no hover should preview nothing:\n%s", right)
	}
}

// Entering a task from the board while ANOTHER task frame is open REPLACES it
// (single-open): the stack never accumulates board-entered FrameTasks, and the
// reader-open ◆ marks exactly one row — the deepest open task.
func TestSingleOpenTaskEntry(t *testing.T) {
	m := composeFixture()
	m = m.enterTask("a")
	m = m.enterTask("b")
	if len(m.stack) != 2 || m.topFrame().Ref != "b" {
		t.Fatalf("second entry did not replace the first: depth=%d top=%q", len(m.stack), m.topFrame().Ref)
	}
	if refs := openTaskRefs(m.stack); len(refs) != 1 || !refs["b"] {
		t.Fatalf("openTaskRefs after replace = %v, want exactly {b}", refs)
	}
	// A deep trail (task → paper → child task) still checks ONLY the deepest task.
	(&m).pushFrame(Frame{Kind: FramePaper, Ref: "p", Title: "p"})
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: "c", Title: "c"})
	if refs := openTaskRefs(m.stack); len(refs) != 1 || !refs["c"] {
		t.Fatalf("openTaskRefs on a deep trail = %v, want exactly {c}", refs)
	}
	// Re-entering a task already on the trail takes the cycle-guard path: pop
	// back to its existing frame, never a fresh duplicate.
	m = m.enterTask("b")
	if len(m.stack) != 2 || m.topFrame().Ref != "b" {
		t.Fatalf("re-entry did not pop back to the open frame: depth=%d top=%q", len(m.stack), m.topFrame().Ref)
	}
}

// Depth>0: a click on a rail stop selects and descends in one gesture, matching
// moving the stop cursor there and pressing Enter.
func TestWideMouseRightRailClickMatchesEnter(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 60, true // tall enough that the detail body fits
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	m.wideFocus = wideFocusReader
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
	// Borderless composeAt Y equals the body line when the body fits the pane.
	m2, cmd := m.handleWideMouse(wideClick(boardPaneWidth+paneGutter2+3, target.Line))
	if cmd != nil {
		t.Errorf("a rail select fired a command: %v", cmd)
	}
	if len(m2.stack) != 3 || m2.topFrame().Ref != target.Ref {
		t.Fatalf("single rail click did not match Enter: depth=%d ref=%q want ref=%q",
			len(m2.stack), m2.topFrame().Ref, target.Ref)
	}
}

func TestWideDividerIsVisibleAndDraggable(t *testing.T) {
	withChrome(t)
	oldProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldProfile) })
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	restStyled := Compose(m)
	frame := ansi.Strip(restStyled)
	if !strings.Contains(frame, "↔") || !strings.Contains(frame, "│") {
		t.Fatalf("wide frame has no visible resize rail:\n%s", frame)
	}
	if !strings.Contains(restStyled, dividerRestStyle.Render("↔ ")) {
		t.Fatal("divider at rest did not use the low-emphasis style")
	}
	hover := tea.MouseMsg{X: boardPaneWidth + 1, Y: 4, Action: tea.MouseActionMotion}
	mHover, _ := m.handleWideMouse(hover)
	if !mHover.wideDividerHover || mHover.wideDragging {
		t.Fatalf("divider hover state = hover %v, dragging %v; want true, false", mHover.wideDividerHover, mHover.wideDragging)
	}
	if styled := Compose(mHover); !strings.Contains(styled, dividerHoverStyle.Render("↔ ")) {
		t.Fatal("hovered divider did not use the brighter hover style")
	}
	press := tea.MouseMsg{X: boardPaneWidth + 1, Y: 4, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress}
	m2, _ := mHover.handleWideMouse(press)
	if !m2.wideDragging {
		t.Fatal("divider press did not begin a drag")
	}
	if styled := Compose(m2); !strings.Contains(styled, dividerGrabbedStyle.Render("↔↔")) {
		t.Fatal("grabbed divider did not use the strongest accent style")
	}
	motion := tea.MouseMsg{X: 61, Y: 4, Action: tea.MouseActionMotion}
	m3, _ := m2.handleWideMouse(motion)
	if got := m3.boardPaneCols(m3.wideInnerWidth()); got != 60 {
		t.Fatalf("divider drag resized board pane to %d, want 60", got)
	}
	release := tea.MouseMsg{X: 61, Y: 4, Button: tea.MouseButtonLeft, Action: tea.MouseActionRelease}
	m4, _ := m3.handleWideMouse(release)
	if m4.wideDragging {
		t.Fatal("divider release left drag armed")
	}
	if !m4.wideDividerHover {
		t.Fatal("divider release over the rail did not return to hover state")
	}
	away := tea.MouseMsg{X: 10, Y: 4, Action: tea.MouseActionMotion}
	m5, _ := m4.handleWideMouse(away)
	if m5.wideDividerHover {
		t.Fatal("divider hover remained active after the pointer left the rail")
	}
	if dividerRestStyle.GetForeground() == dividerHoverStyle.GetForeground() || dividerHoverStyle.GetForeground() == dividerGrabbedStyle.GetForeground() {
		t.Fatal("divider rest, hover, and grabbed states must use distinct brightness roles")
	}
	if !dividerGrabbedStyle.GetBold() {
		t.Fatal("grabbed divider must add bold emphasis")
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

// The Y hit-map addresses EXACTLY the painted composeAt rows — one per pane
// line, no more (the breadcrumb row was retired) — so a click can never resolve
// to a row that was never drawn (length parity).
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
		if rowmap[0] != rowPanes {
			t.Fatalf("%dx%d: row 0 is not a pane row", wh[0], wh[1])
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

// ── Reading-frame rail-stop hover (charter D99) ──────────────────────────────

// probeHoverOpen returns the live SGR open sequence hoverStyle emits under the
// active color profile, so a test can assert a line wears the accent hover
// restyle without hard-coding escape bytes.
func probeHoverOpen(t *testing.T) string {
	t.Helper()
	rendered := hoverStyle.Render("\x00\x00")
	i := strings.Index(rendered, "\x00\x00")
	if i <= 0 {
		t.Fatalf("hoverStyle rendered no open sequence under this profile: %q", rendered)
	}
	return rendered[:i]
}

// Depth>0: a Motion over a right-pane rail stop PAINTS that stop's body line in
// the accent foreground (hoverStyle) — the SAME grammar as the board hover,
// distinct from the cursor stop's ▎ bar. Mirrors TestWideMouseRightRailClickSelectsStop
// (the click twin). withChrome + a truecolor profile are mandatory: the default
// profile emits no SGR, so the paint would be the identity and prove nothing.
func TestWideRailHoverPaintsStop(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })
	withChrome(t)

	m := composeFixture()
	m.width, m.height, m.wide = 120, 60, true // tall enough that the detail body fits
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	_, innerW, inner := m.wideGeom()
	rightW := innerW - boardPaneWidth - paneGutter2
	body, stops := m.frameContent(m.topFrame(), rightW, m.now())
	if len(body) > inner {
		t.Fatalf("fixture body (%d) must fit the pane (%d) so stops are on-screen", len(body), inner)
	}
	if len(stops) < 2 {
		t.Fatalf("need >=2 rail stops to prove the paint tracks the pointer, got %d", len(stops))
	}

	// Baseline: no pointer (HoverStop -1) paints nothing.
	m.ui.HoverStop = -1
	before := composeAt(m, innerW, m.height-1)

	// Drive a hover Motion over stop 1's body line (body fits ⇒ composeAt row ==
	// body line in the borderless pane).
	target := stops[1]
	m2, _ := m.wideMouseMotion(boardPaneWidth+paneGutter2, target.Line, innerW, inner, m.now())
	if m2.ui.HoverStop != 1 {
		t.Fatalf("motion over stop 1 set HoverStop %d, want 1", m2.ui.HoverStop)
	}
	after := composeAt(m2, innerW, m.height-1)

	if after == before {
		t.Fatal("a hovered rail stop produced NO visible change in the styled frame")
	}
	hoverOpen := probeHoverOpen(t)
	bl, al := strings.Split(before, "\n"), strings.Split(after, "\n")
	if len(bl) != len(al) {
		t.Fatalf("hover changed the line count: %d vs %d", len(bl), len(al))
	}
	changed, changedIdx := 0, -1
	for i := range al {
		if ansi.Strip(al[i]) != ansi.Strip(bl[i]) {
			t.Errorf("line %d: hover changed the VISIBLE text (styling only expected)\n got: %q\nwant: %q",
				i, ansi.Strip(al[i]), ansi.Strip(bl[i]))
		}
		if al[i] == bl[i] {
			continue
		}
		changed, changedIdx = changed+1, i
		if !strings.Contains(al[i], hoverOpen) {
			t.Errorf("line %d changed without the accent hover restyle:\n%q", i, al[i])
		}
	}
	if changed != 1 {
		t.Fatalf("hover restyled %d lines, want exactly 1 (only the hovered stop)", changed)
	}
	if changedIdx != target.Line {
		t.Fatalf("hover painted composeAt row %d, want %d (the stop's pane row)", changedIdx, target.Line)
	}
	// The painted change lands in the RIGHT pane, never the left board pane.
	r := []rune(ansi.Strip(al[changedIdx]))
	if len(r) <= boardPaneWidth+paneGutter2 || strings.TrimSpace(string(r[:boardPaneWidth])) != strings.TrimSpace(string([]rune(ansi.Strip(bl[changedIdx]))[:boardPaneWidth])) {
		t.Fatalf("hover altered the LEFT board pane, want the right reading pane only:\n%q", al[changedIdx])
	}
}

// The change guard IS the debounce (charter D95): a second Motion onto the SAME
// stop returns an unchanged model — no re-render, no flicker.
func TestWideRailHoverFlickerGuard(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 60, true
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	_, innerW, inner := m.wideGeom()
	rightW := innerW - boardPaneWidth - paneGutter2
	_, stops := m.frameContent(m.topFrame(), rightW, m.now())
	if len(stops) < 1 {
		t.Fatalf("need >=1 rail stop, got %d", len(stops))
	}
	x, y := boardPaneWidth+paneGutter2, stops[0].Line

	m2, _ := m.wideMouseMotion(x, y, innerW, inner, m.now())
	if m2.ui.HoverStop != 0 {
		t.Fatalf("first motion set HoverStop %d, want 0", m2.ui.HoverStop)
	}
	// setHoverStop reports change=false on the repeat — the direct debounce proof.
	if _, changed := setHoverStop(m2.ui, 0); changed {
		t.Fatal("setHoverStop reported a change for the SAME stop (debounce broken)")
	}
	before := composeAt(m2, innerW, m2.height-1)
	m3, _ := m2.wideMouseMotion(x, y, innerW, inner, m2.now())
	if m3.ui.HoverStop != 0 {
		t.Fatalf("second motion onto the same stop moved HoverStop to %d, want 0", m3.ui.HoverStop)
	}
	if got := composeAt(m3, innerW, m3.height-1); got != before {
		t.Fatal("a re-hover of the same stop changed the frame (flicker)")
	}
}

// A Motion off the rail stops — the dead inter-pane gutter, or a prose body line
// with no stop — CLEARS HoverStop back to -1 (the tint yields the moment the
// pointer leaves a stop, exactly as leaving a board row clears HoverTarget).
func TestWideRailHoverClearsOffStop(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 60, true
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	_, innerW, inner := m.wideGeom()
	rightW := innerW - boardPaneWidth - paneGutter2
	body, stops := m.frameContent(m.topFrame(), rightW, m.now())
	if len(body) > inner || len(stops) < 1 {
		t.Fatalf("fixture must fit the pane with >=1 stop (body %d/pane %d, stops %d)", len(body), inner, len(stops))
	}
	x := boardPaneWidth + paneGutter2

	// Hover a stop, then slide into the dead gutter → cleared.
	hov, _ := m.wideMouseMotion(x, stops[0].Line, innerW, inner, m.now())
	if hov.ui.HoverStop != 0 {
		t.Fatalf("hover a stop set HoverStop %d, want 0", hov.ui.HoverStop)
	}
	gutter, _ := hov.wideMouseMotion(boardPaneWidth, stops[0].Line, innerW, inner, hov.now())
	if gutter.ui.HoverStop != -1 {
		t.Fatalf("motion into the dead gutter kept HoverStop %d, want -1", gutter.ui.HoverStop)
	}

	// Slide onto a prose body line (no stop sits there) → cleared.
	stopLine := map[int]bool{}
	for _, s := range stops {
		stopLine[s.Line] = true
	}
	prose := -1
	for ln := 0; ln < len(body); ln++ {
		if !stopLine[ln] && strings.TrimSpace(ansi.Strip(body[ln])) != "" {
			prose = ln
			break
		}
	}
	if prose < 0 {
		t.Fatal("fixture body has no non-stop prose line to prove the clear")
	}
	onProse, _ := hov.wideMouseMotion(x, prose, innerW, inner, hov.now())
	if onProse.ui.HoverStop != -1 {
		t.Fatalf("motion onto a prose line kept HoverStop %d, want -1", onProse.ui.HoverStop)
	}
}

// NEGATIVE (the scoping law, #4240): a wide DEPTH-0 preview has no stops, so a
// right-pane Motion resolves to -1 for every pane row and a stale HoverStop never
// paints there — depth-0 hover is #4240's, not this slice's.
func TestWideRailHoverDepth0HasNoStop(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 60, true
	m.ui.Cursor = 1 // preview the subject; the stack is still just the board (depth 0)
	_, innerW, inner := m.wideGeom()

	for pl := 0; pl < inner; pl++ {
		if idx := m.rightPaneStopAt(pl, innerW, inner, m.now()); idx != -1 {
			t.Fatalf("depth-0 rightPaneStopAt(%d) = %d, want -1 (the preview has no stops)", pl, idx)
		}
	}
	// A right-pane Motion at depth 0 clears any stale HoverStop to -1.
	m.ui.HoverStop = 5
	m2, _ := m.wideMouseMotion(boardPaneWidth+paneGutter2, 3, innerW, inner, m.now())
	if m2.ui.HoverStop != -1 {
		t.Fatalf("depth-0 right-pane hover set HoverStop %d, want -1", m2.ui.HoverStop)
	}
	// The paint is byte-identical whether HoverStop is a stale 5 or a clean -1 —
	// previewLines hard-wires stops=nil/hoverStop=-1, so nothing can paint.
	clean, stale := m, m
	clean.ui.HoverStop, stale.ui.HoverStop = -1, 5
	if composeAt(clean, innerW, m.height-1) != composeAt(stale, innerW, m.height-1) {
		t.Fatal("depth-0 preview painted a hover stop (it has none — #4240 owns depth-0 hover)")
	}
}

// ── Narrow-mode reading-frame rail-stop hover paint (charter D99 close-out / D105) ──

// TestNarrowRailHoverPaintsStop: a Motion over a NARROW reading-frame rail stop
// PAINTS that stop's body line in the accent foreground (hoverStyle) via the
// compose.go:148 HoverStop wiring — the mirror of TestWideRailHoverPaintsStop.
// The truecolor profile is mandatory (D105d): the default profile emits no SGR,
// so the paint would be the identity and prove nothing (vacuous green). withChrome
// alone only swaps the branding fixture. Compose lines index 1:1 with
// ComposeHitMap, so the painted line must land on the stop's hit-map row.
func TestNarrowRailHoverPaintsStop(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })
	withChrome(t)

	m := narrowReadingFixture(3)
	m.width, m.height = 44, 40 // tall enough that the whole body fits ⇒ stops on-screen
	width, height := m.composeInner()
	body, stops := m.frameContent(m.topFrame(), width, m.now())
	if len(body) > height-2 {
		t.Fatalf("fixture body (%d) must fit the pane (%d) so stops are on-screen", len(body), height-2)
	}
	if len(stops) < 2 {
		t.Fatalf("need >=2 rail stops to prove the paint tracks the pointer, got %d", len(stops))
	}

	const stop = 1
	y := firstStopY(m.ComposeHitMap(), stop)
	if y < 0 {
		t.Fatalf("no hit-map line for rail stop %d", stop)
	}
	before := strings.Split(Compose(m), "\n")

	tm, _ := m.mouseMotion(5, y)
	m2 := tm.(Model)
	if m2.ui.HoverStop != stop {
		t.Fatalf("motion over stop %d set HoverStop %d, want %d", stop, m2.ui.HoverStop, stop)
	}
	after := strings.Split(Compose(m2), "\n")

	if len(after) != len(before) {
		t.Fatalf("hover changed the line count: %d vs %d", len(before), len(after))
	}
	hoverOpen := probeHoverOpen(t)
	changed, changedIdx := 0, -1
	for i := range after {
		if ansi.Strip(after[i]) != ansi.Strip(before[i]) {
			t.Errorf("line %d: hover changed the VISIBLE text (styling only expected)\n got: %q\nwant: %q",
				i, ansi.Strip(after[i]), ansi.Strip(before[i]))
		}
		if after[i] == before[i] {
			continue
		}
		changed, changedIdx = changed+1, i
		if !strings.Contains(after[i], hoverOpen) {
			t.Errorf("line %d changed without the accent hover restyle:\n%q", i, after[i])
		}
	}
	if changed != 1 {
		t.Fatalf("hover restyled %d lines, want exactly 1 (only the hovered stop)", changed)
	}
	if changedIdx != y {
		t.Fatalf("hover painted Compose row %d, want %d (the stop's hit-map row)", changedIdx, y)
	}
}

// TestNarrowRailHoverAtCursorCollapsesColorOnly (charter D105e): when the pointer
// hovers the SAME stop the cursor sits on, the ▎ (U+258E) selection bar SURVIVES
// — the stripped text is byte-identical — and only the color collapses to the
// hover accent. Proves the hover restyle composes over the cursor bar rather than
// erasing the row's structure.
func TestNarrowRailHoverAtCursorCollapsesColorOnly(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })
	withChrome(t)

	m := narrowReadingFixture(3)
	m.width, m.height = 44, 40
	const cur = 1
	m.stack[len(m.stack)-1].Cursor = cur // the cursor bar sits on stop `cur`

	y := firstStopY(m.ComposeHitMap(), cur)
	if y < 0 {
		t.Fatalf("no hit-map line for cursor stop %d", cur)
	}
	before := strings.Split(Compose(m), "\n")
	if !strings.Contains(ansi.Strip(before[y]), "▎") {
		t.Fatalf("cursor row %d carries no ▎ bar before hover: %q", y, ansi.Strip(before[y]))
	}

	m.ui.HoverStop = cur // hover the cursor's own stop
	after := strings.Split(Compose(m), "\n")

	if after[y] == before[y] {
		t.Fatal("hovering the cursor stop produced no styling change (color should collapse to hover accent)")
	}
	if ansi.Strip(after[y]) != ansi.Strip(before[y]) {
		t.Fatalf("hover changed the visible text on the cursor row (▎ must survive)\n got: %q\nwant: %q",
			ansi.Strip(after[y]), ansi.Strip(before[y]))
	}
	if !strings.Contains(ansi.Strip(after[y]), "▎") {
		t.Fatalf("the ▎ bar did not survive the hover restyle: %q", ansi.Strip(after[y]))
	}
	if !strings.Contains(after[y], probeHoverOpen(t)) {
		t.Fatalf("cursor-row hover did not apply the accent hover restyle:\n%q", after[y])
	}
}

// ── Centered document column (paper 100-col standard) ────────────────────────

// On an ultrawide pane the reading document renders as a centered, borderless
// maxDocWidth column. Mutating docLayout to left-pinned, uncapped, or restoring
// container chrome MUST fail this test.
func TestWideReadingDocumentCenteredAtCap(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 200, 40, true
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "subj"})
	_, innerW, inner := m.wideGeom()
	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	if rightW <= maxDocWidth {
		t.Fatalf("fixture pane too narrow to exercise the cap: rightW=%d", rightW)
	}
	docW, pad := docLayout(rightW)
	if docW != maxDocWidth || pad != (rightW-maxDocWidth)/2 {
		t.Fatalf("docLayout(%d) = (%d, %d), want (%d, %d)",
			rightW, docW, pad, maxDocWidth, (rightW-maxDocWidth)/2)
	}
	lines := strings.Split(ansi.Strip(composeAt(m, innerW, m.height-1)), "\n")
	if len(lines) != inner {
		t.Fatalf("wide composeAt painted %d rows, want inner=%d", len(lines), inner)
	}
	paneStart := m.boardPaneCols(innerW) + paneGutter2
	sawContent := false
	for i, ln := range lines {
		r := []rune(ln)
		if len(r) <= paneStart {
			continue // blank borderless document row
		}
		right := r[paneStart:]
		plainRight := string(right)
		if strings.ContainsAny(plainRight, "─│┌┐└┘") {
			t.Fatalf("row %d restored reading-container border chrome: %q", i, plainRight)
		}
		if strings.TrimSpace(plainRight) != "" && len(right) < pad+1 {
			t.Fatalf("row %d: content is not inset by centered pad %d: %q", i, pad, plainRight)
		}
		if strings.TrimSpace(plainRight) != "" {
			sawContent = true
		}
	}
	if !sawContent {
		t.Fatal("borderless reading column painted no content")
	}
}
