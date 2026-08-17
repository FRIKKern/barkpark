package taskboard

// overflow_click_test.go — the wide panes' ↑/↓ overflow markers answer clicks
// (charter D119/D121, ttw20-wide-overflow-marker-clicks). Wave 20 left ONE mouse
// asymmetry: the narrow board's markers scroll on click, but the wide panes'
// were dead — a press on the board pane's marker did nothing, and a press on the
// depth-0 preview's marker ENTERED the previewed task (the booby-trap). These
// tests compose REAL overflowing wide frames and drive three router paths:
//
//   - the wide LEFT board pane's counted "↑ N more above" / "↓ N more below"
//     markers step the cursor ∓1 (wideBoardMarkerAt → moveCursor);
//   - the depth-0 RIGHT preview's countless "↑ more above" / "↓ more below"
//     markers scroll the preview instead of entering (rightPaneMarkerAt →
//     scrollPreview) — the booby-trap is defused; and
//   - the depth>0 RIGHT reading frame's markers free-scroll ±1 (→ freeScroll).
//
// The board markers are COUNTED (a finite spine windowed to N rows) and the
// reading/preview markers are COUNTLESS (an unbounded document) — distinct glyph
// strings, asserted distinctly so a paint that swapped one for the other reds.

import (
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// countedMarker matches the board spine's "↑ 3 more above" affordance (render.go
// windowSpine); countlessMarker matches the reading/preview "↑ more above"
// affordance (windowFrame) — which carries NO number. Kept separate so a test can
// prove the two panes wear different glyphs (the counted-vs-countless split).
var (
	countedAbove   = regexp.MustCompile(`↑ \d+ more above`)
	countedBelow   = regexp.MustCompile(`↓ \d+ more below`)
	countlessAbove = regexp.MustCompile(`↑ more above`)
	countlessBelow = regexp.MustCompile(`↓ more below`)
)

// The wide LEFT board pane's overflow markers step the cursor one row toward the
// hidden spine — the last board-pane mouse asymmetry with the narrow board's
// LineScrollUp/Down affordances, now closed (D119). The fixture windows a 7-row
// spine into a 5-row pane scrolled to the middle, so BOTH markers paint.
func TestWideBoardOverflowMarkerClickStepsCursor(t *testing.T) {
	withChrome(t)
	base := func() Model {
		m := composeFixture()
		m.width, m.height, m.wide = 120, 10, true // short pane ⇒ the 7-row spine overflows
		m.ui.Cursor = 2                           // a mid-spine row so slideTop holds top=1
		m.ui.SpineScroll = 1                      // window top 1 ⇒ ↑ above AND ↓ below both show
		return m
	}
	m := base()
	now := m.now()
	_, _, inner := m.wideGeom()
	idTop, avail := m.wideBoardPaneAvail(inner, now)

	upRow, downRow := -1, -1
	for pl := 0; pl < inner; pl++ {
		switch m.wideBoardMarkerAt(pl, idTop, avail, now) {
		case -1:
			upRow = pl
		case 1:
			downRow = pl
		}
	}
	if upRow < 0 || downRow < 0 {
		t.Fatalf("fixture must window both markers: up=%d down=%d (avail=%d)", upRow, downRow, avail)
	}

	// The eye must see what the router routes: the counted glyph is actually
	// painted on those exact pane rows (the board pane composeAt splits into).
	boardW := m.boardPaneCols(m.wideInnerWidth())
	ui := m.ui
	ui.OpenTasks = openTaskRefs(m.stack)
	board := ansi.Strip(Render(m.board, ui, boardW, inner, now))
	lines := splitLines(board)
	if upRow >= len(lines) || !countedAbove.MatchString(lines[upRow]) {
		t.Fatalf("board pane row %d is not the counted ↑ marker: %q", upRow, lineAt(lines, upRow))
	}
	if downRow >= len(lines) || !countedBelow.MatchString(lines[downRow]) {
		t.Fatalf("board pane row %d is not the counted ↓ marker: %q", downRow, lineAt(lines, downRow))
	}

	// Clicking the ↑ marker steps the cursor UP one row; the ↓ marker steps DOWN.
	up, cmd := base().handleWideMouse(wideClick(20, upRow))
	if cmd != nil {
		t.Errorf("board ↑ marker click fired a command: %v", cmd)
	}
	if up.ui.Cursor != 1 {
		t.Fatalf("↑ marker click stepped cursor to %d, want 1 (2−1)", up.ui.Cursor)
	}
	if len(up.stack) != 1 {
		t.Fatalf("↑ marker click changed nav depth to %d, want 1 (scroll, never descend)", len(up.stack))
	}
	down, cmd := base().handleWideMouse(wideClick(20, downRow))
	if cmd != nil {
		t.Errorf("board ↓ marker click fired a command: %v", cmd)
	}
	if down.ui.Cursor != 3 {
		t.Fatalf("↓ marker click stepped cursor to %d, want 3 (2+1)", down.ui.Cursor)
	}
}

// The wide RIGHT depth-0 preview's overflow markers scroll the preview — and,
// critically, NEVER enter the previewed task (the defused booby-trap, D121). A
// press on any non-marker preview row still enters, so the special-case is narrow.
func TestWideDepth0PreviewMarkerClickScrollsNotEnters(t *testing.T) {
	withChrome(t)
	base := func() Model {
		m := composeFixture()
		m.width, m.height, m.wide = 120, 16, true // short pane ⇒ the preview overflows
		m.ui.Cursor = visibleRowIndex(m, composeSubjectID)
		return m
	}
	m := base()
	now := m.now()
	_, innerW, inner := m.wideGeom()
	rightX := m.boardPaneCols(innerW) + paneGutter2 + 4

	// At the top of the preview only the ↓ marker shows. Clicking it scrolls the
	// preview one notch and does NOT descend into the task.
	downRow := -1
	for pl := 0; pl < inner; pl++ {
		if m.rightPaneMarkerAt(pl, innerW, inner, now) == 1 {
			downRow = pl
		}
	}
	if downRow < 0 {
		t.Fatal("fixture preview must show a ↓ more-below marker")
	}
	d, cmd := base().handleWideMouse(wideClick(rightX, downRow))
	if cmd != nil {
		t.Errorf("preview ↓ marker click fired a command: %v", cmd)
	}
	if len(d.stack) != 1 {
		t.Fatalf("preview ↓ marker click ENTERED the task (depth %d) — the booby-trap is not defused", len(d.stack))
	}
	if d.previewScroll != 1 || d.previewRef != composeSubjectID {
		t.Fatalf("preview ↓ marker click scrolled to (%q,%d), want (%q,1)", d.previewRef, d.previewScroll, composeSubjectID)
	}

	// Scrolled to the bottom, the ↑ marker shows; clicking it scrolls back up one,
	// still without entering.
	bottom := base()
	subj, _ := bottom.taskByID(composeSubjectID)
	(&bottom).scrollPreview(subj, 1<<20, innerW, inner, now)
	maxScroll := bottom.previewScroll
	upRow := -1
	for pl := 0; pl < inner; pl++ {
		if bottom.rightPaneMarkerAt(pl, innerW, inner, now) == -1 {
			upRow = pl
		}
	}
	if upRow < 0 {
		t.Fatal("scrolled-to-bottom preview must show a ↑ more-above marker")
	}
	u, _ := bottom.handleWideMouse(wideClick(rightX, upRow))
	if len(u.stack) != 1 {
		t.Fatalf("preview ↑ marker click ENTERED the task (depth %d)", len(u.stack))
	}
	if u.previewScroll != maxScroll-1 {
		t.Fatalf("preview ↑ marker click scrolled to %d, want %d (max−1)", u.previewScroll, maxScroll-1)
	}

	// A press on a genuine preview BODY row still enters — the special-case is
	// limited to the two marker rows (no over-reach into normal preview clicks).
	bodyRow := -1
	for pl := 1; pl < inner; pl++ {
		if m.rightPaneMarkerAt(pl, innerW, inner, now) == 0 { // pl>=1 skips the ─ top edge
			bodyRow = pl
			break
		}
	}
	if bodyRow < 0 {
		t.Fatal("preview must have at least one non-marker body row")
	}
	e, _ := base().handleWideMouse(wideClick(rightX, bodyRow))
	if len(e.stack) != 2 || e.topFrame().Kind != FrameTask || e.topFrame().Ref != composeSubjectID {
		t.Fatalf("a non-marker preview click did not enter: depth=%d kind=%v ref=%q",
			len(e.stack), e.topFrame().Kind, e.topFrame().Ref)
	}

	// The preview's markers are the COUNTLESS glyph (no number) — distinct from the
	// board pane's counted glyph proven above.
	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	preview := ansi.Strip(joinLines(m.previewLines(subj, rightW, inner, now)))
	if !countlessBelow.MatchString(preview) || countedBelow.MatchString(preview) {
		t.Fatalf("preview ↓ marker must be countless, got: %q", preview)
	}
}

// The wide RIGHT depth>0 reading frame's overflow markers free-scroll the prose
// ±1 — mouse == space/u/d — without moving the stop cursor or the nav depth
// (D119). The reading body is free-scrolled to the middle so both markers paint.
func TestWideReadingOverflowMarkerClickFreeScrolls(t *testing.T) {
	withChrome(t)
	base := func() Model {
		m := composeFixture()
		m.width, m.height, m.wide = 120, 16, true
		(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "Wire the SSE live bridge"})
		m.stack[len(m.stack)-1].Scroll = 2 // absolute mid-scroll ⇒ ↑ AND ↓ both show
		return m
	}
	m := base()
	now := m.now()
	_, innerW, inner := m.wideGeom()
	rightX := m.boardPaneCols(innerW) + paneGutter2 + 4

	upRow, downRow := -1, -1
	for pl := 0; pl < inner; pl++ {
		switch m.rightPaneMarkerAt(pl, innerW, inner, now) {
		case -1:
			upRow = pl
		case 1:
			downRow = pl
		}
	}
	if upRow < 0 || downRow < 0 {
		t.Fatalf("reading fixture must window both markers: up=%d down=%d", upRow, downRow)
	}
	wantCursor := m.topFrame().Cursor

	up, cmd := base().handleWideMouse(wideClick(rightX, upRow))
	if cmd != nil {
		t.Errorf("reading ↑ marker click fired a command: %v", cmd)
	}
	if up.topFrame().Scroll != 1 {
		t.Fatalf("reading ↑ marker click scrolled to %d, want 1 (2−1)", up.topFrame().Scroll)
	}
	if len(up.stack) != 2 || up.topFrame().Cursor != wantCursor {
		t.Fatalf("reading ↑ marker click moved the stop/depth: depth=%d cursor=%d (want depth 2, cursor %d)",
			len(up.stack), up.topFrame().Cursor, wantCursor)
	}
	down, _ := base().handleWideMouse(wideClick(rightX, downRow))
	if down.topFrame().Scroll != 3 {
		t.Fatalf("reading ↓ marker click scrolled to %d, want 3 (2+1)", down.topFrame().Scroll)
	}
	if len(down.stack) != 2 || down.topFrame().Cursor != wantCursor {
		t.Fatalf("reading ↓ marker click moved the stop/depth: depth=%d cursor=%d", len(down.stack), down.topFrame().Cursor)
	}

	// Reading markers are the COUNTLESS glyph — distinct from the board's counted one.
	top := m.topFrame()
	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	docW, _ := docLayout(rightW)
	body, stops := m.frameContent(top, docW, now)
	pane := ansi.Strip(joinLines(renderDocPane(body, stops, top.Cursor, top.Scroll, m.ui.HoverStop, rightW, inner)))
	if !countlessAbove.MatchString(pane) || countedAbove.MatchString(pane) {
		t.Fatalf("reading ↑ marker must be countless, got: %q", pane)
	}
}

// splitLines / joinLines / lineAt keep the marker-row assertions terse.
func splitLines(s string) []string { return strings.Split(s, "\n") }
func joinLines(ls []string) string { return strings.Join(ls, "\n") }
func lineAt(lines []string, i int) string {
	if i < 0 || i >= len(lines) {
		return "<out of range>"
	}
	return lines[i]
}
