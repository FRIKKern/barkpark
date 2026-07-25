package taskboard

// Integration-seam tests for the FUSED wave-16 mouse reducer (charter D89–D96).
// Each slice proved its own half in isolation (hitmap_test, mouse_test,
// render_test, compose_test); these pin the wiring the integration added:
// Motion → row hover through the reducer (narrow AND wide), handleMouse →
// handleWideMouse routing, and the MouseReleased guard gating rows and wide —
// not just the footer verbs.

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// motionAt is a hover Motion at screen Y (narrow board: X is irrelevant to row
// resolution, but keep it inside the frame).
func motionAt(x, y int) tea.MouseMsg {
	return tea.MouseMsg{Action: tea.MouseActionMotion, X: x, Y: y}
}

// TestMouseMotionHoversBoardRow drives Motion through the full reducer and pins
// the trailing hover debounce: motion queues a target without repainting it,
// then the single settle message commits the latest target.
func TestMouseMotionHoversBoardRow(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.width, m.height = 80, 40
	m.ui.Cursor = 0
	syncScroll(&m)

	const target = 4 // child cx (a task row)
	y := firstLineFor(m.ComposeHitMap(), target)
	if y < 0 {
		t2.Fatal("no hit-map line for target row 4")
	}
	wantRef := m.visibleRows()[target].docID

	m2, cmd := step(t2, m, motionAt(5, y))
	if m2.ui.HoverTarget != "" || m2.hoverPendingTarget != wantRef || cmd == nil {
		t2.Fatalf("motion did not debounce row %d: visible=%q pending=%q cmd=%v", target, m2.ui.HoverTarget, m2.hoverPendingTarget, cmd)
	}
	m2, _ = step(t2, m2, hoverDebounceMsg{gen: m2.hoverGen})
	if m2.ui.HoverTarget != wantRef {
		t2.Fatalf("settled hover = %q, want %q", m2.ui.HoverTarget, wantRef)
	}
	// The hover must not have moved the cursor or descended.
	if m2.ui.Cursor != 0 || len(m2.stack) != 1 {
		t2.Fatalf("motion mutated navigation: cursor=%d depth=%d", m2.ui.Cursor, len(m2.stack))
	}

	// Off every selectable row (the identity strip, line 0 = chrome) → cleared.
	m3, _ := step(t2, m2, motionAt(5, 0))
	if m3.ui.HoverTarget != "" {
		t2.Fatalf("motion onto chrome kept HoverTarget %q, want cleared", m3.ui.HoverTarget)
	}
}

func TestMouseMotionBurstCoalescesToLatestTarget(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.width, m.height = 80, 40
	syncScroll(&m)

	y4 := firstLineFor(m.ComposeHitMap(), 4)
	y5 := firstLineFor(m.ComposeHitMap(), 5)
	if y4 < 0 || y5 < 0 {
		t2.Fatal("fixture rows are not both visible")
	}
	m2, firstCmd := step(t2, m, motionAt(5, y4))
	m3, secondCmd := step(t2, m2, motionAt(5, y5))
	if firstCmd == nil || secondCmd != nil {
		t2.Fatalf("hover burst scheduled %v then %v, want one bounded timer", firstCmd, secondCmd)
	}
	if m3.ui.HoverTarget != "" {
		t2.Fatalf("burst repainted an intermediate target: %q", m3.ui.HoverTarget)
	}
	want := m3.visibleRows()[5].docID
	m4, _ := step(t2, m3, hoverDebounceMsg{gen: m3.hoverGen})
	if m4.ui.HoverTarget != want {
		t2.Fatalf("debounce committed %q, want latest %q", m4.ui.HoverTarget, want)
	}
}

func TestPendingHoverCannotReappearAfterKeyboardInput(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.width, m.height = 80, 40
	syncScroll(&m)
	y := firstLineFor(m.ComposeHitMap(), 4)
	if y < 0 {
		t2.Fatal("fixture row is not visible")
	}

	m2, _ := step(t2, m, motionAt(5, y))
	staleGen := m2.hoverGen
	m3, _ := step(t2, m2, runes("j"))
	if m3.hoverTimerOn || m3.ui.HoverTarget != "" {
		t2.Fatalf("keyboard input left hover armed: timer=%v target=%q", m3.hoverTimerOn, m3.ui.HoverTarget)
	}
	m4, _ := step(t2, m3, hoverDebounceMsg{gen: staleGen})
	if m4.ui.HoverTarget != "" {
		t2.Fatalf("stale hover timer repainted %q after keyboard input", m4.ui.HoverTarget)
	}
}

// TestHandleMouseRoutesWideToRouter proves the reducer hands wide-mode events to
// ttm-s5's handleWideMouse (the integration replaced s1's wide no-op): a wheel
// over a pane row steps the cursor exactly like the narrow board.
func TestHandleMouseRoutesWideToRouter(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 0

	m2, _ := step(t, m, wideWheel(20, 2, false))
	if m2.ui.Cursor != 1 {
		t.Fatalf("wide wheel-down through the reducer stepped cursor to %d, want 1", m2.ui.Cursor)
	}
	m3, _ := step(t, m2, wideWheel(20, 2, true))
	if m3.ui.Cursor != 0 {
		t.Fatalf("wide wheel-up through the reducer stepped cursor to %d, want 0", m3.ui.Cursor)
	}
}

// TestWideMotionHoversBoardPaneRow: wide-mode hover (the integration's cheap
// extension — the wide left pane shares flattenSpine's hover paint): a Motion
// over a board-pane row stores its Ref; a Motion into the dead gutter clears it.
func TestWideMotionHoversBoardPaneRow(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = 0
	_, _, inner := m.wideGeom()

	board := Render(m.board, m.ui, boardPaneWidth, inner, m.now())
	pl := lineContaining(board, "Wire the SSE")
	if pl < 0 {
		t.Fatal("subject row not painted in the board pane")
	}
	// composeAt (x=20, y=pl+1) → screen (+gl, +1 blank row) = (21, pl+2).
	m2, cmd := step(t, m, motionAt(21, pl+2))
	if m2.ui.HoverTarget != "" || m2.hoverPendingTarget != composeSubjectID || cmd == nil {
		t.Fatalf("wide motion did not debounce subject: visible=%q pending=%q", m2.ui.HoverTarget, m2.hoverPendingTarget)
	}
	m2, _ = step(t, m2, hoverDebounceMsg{gen: m2.hoverGen})
	if m2.ui.HoverTarget != composeSubjectID {
		t.Fatalf("wide settled hover = %q, want %q", m2.ui.HoverTarget, composeSubjectID)
	}
	// The dead inter-pane gutter (composeAt x=46) clears the tint.
	m3, _ := step(t, m2, motionAt(47, pl+2))
	if m3.ui.HoverTarget != "" {
		t.Fatalf("wide motion into the gutter kept HoverTarget %q, want cleared", m3.ui.HoverTarget)
	}
}

// TestMouseReleasedGatesRowsAndWide: the M-released guard sits FIRST in the
// fused reducer, so it gates ROW clicks and hover and the wide router — not
// just the footer verbs ttm-s4 proved.
func TestMouseReleasedGatesRowsAndWide(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.width, m.height = 80, 40
	m.ui.Cursor = 0
	syncScroll(&m)
	y := firstLineFor(m.ComposeHitMap(), 4)
	if y < 0 {
		t2.Fatal("no hit-map line for target row 4")
	}
	m.ui.MouseReleased = true

	if m2, _ := step(t2, m, leftClick(y)); m2.ui.Cursor != 0 {
		t2.Fatalf("released-mode click still selected: cursor %d, want 0", m2.ui.Cursor)
	}
	if m2, _ := step(t2, m, motionAt(5, y)); m2.ui.HoverTarget != "" {
		t2.Fatalf("released-mode motion still hovered: %q", m2.ui.HoverTarget)
	}

	m.wide, m.width = true, 120
	if m2, _ := step(t2, m, wideWheel(20, 2, false)); m2.ui.Cursor != 0 {
		t2.Fatalf("released-mode wide wheel still stepped: cursor %d, want 0", m2.ui.Cursor)
	}
}
