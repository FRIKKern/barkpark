package taskboard

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// Esc at depth 0 must hand j/k back to the board cursor (charter D117).
//
// enterTask (and any depth-0 preview focus) sets wideFocus=reader, but before
// this fix popFrame never touched it — so Enter→Esc, or a wheel over the preview
// pane, stranded j/k in the preview scroll with only a mouse board-pane click to
// recover. The invariant lazygit and k9s share is that esc ALWAYS returns you to
// list navigation; these tests pin both strand paths the live W19 tmux drive
// found (ttw17-bl-live-tmux-drive): the descend→pop path and the
// mouse-preview-focus-at-depth-0 path.

// TestEscAtDepth0RestoresBoardFocusAfterEnter drives the Enter→Esc strand: Enter
// descends into the subject (wideFocus=reader, depth 2), Esc pops back to the
// root board, and j must then move the board CURSOR — not scroll the preview.
func TestEscAtDepth0RestoresBoardFocusAfterEnter(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = visibleRowIndex(m, composeSubjectID)
	if m.ui.Cursor < 0 {
		t.Fatal("subject is not a visible board row")
	}

	// Enter descends into the task — single-open focus goes to the reader pane.
	entered, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	me := entered.(Model)
	if len(me.stack) != 2 || me.topFrame().Kind != FrameTask {
		t.Fatalf("Enter did not descend: depth=%d kind=%v", len(me.stack), me.topFrame().Kind)
	}
	if me.wideFocus != wideFocusReader {
		t.Fatalf("Enter did not focus the reader: focus=%v", me.wideFocus)
	}

	// Esc pops back to the depth-0 board AND returns focus to the board.
	popped, _ := me.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	mp := popped.(Model)
	if len(mp.stack) != 1 {
		t.Fatalf("Esc did not pop to the root board: depth=%d", len(mp.stack))
	}
	if mp.wideFocus != wideFocusBoard {
		t.Fatalf("Esc at depth 0 did not restore board focus: focus=%v", mp.wideFocus)
	}

	// j now moves the board cursor, not the preview scroll.
	cursorBefore := mp.ui.Cursor
	moved, _ := mp.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	mm := moved.(Model)
	if mm.ui.Cursor != cursorBefore+1 {
		t.Fatalf("j after esc did not move the board cursor: got %d, want %d", mm.ui.Cursor, cursorBefore+1)
	}
	if mm.previewScroll != 0 {
		t.Fatalf("j after esc scrolled the preview (%d) instead of the board", mm.previewScroll)
	}
}

// TestEscAtDepth0RestoresBoardFocusAfterPreviewWheel drives the strand popFrame
// alone can never fix: a wheel over the depth-0 preview focuses the reader WHILE
// staying at depth 1, so Esc's popFrame is a no-op — only the depth-0 focus
// restore hands j/k back to the board.
func TestEscAtDepth0RestoresBoardFocusAfterPreviewWheel(t *testing.T) {
	withChrome(t)
	m := composeFixture()
	m.width, m.height, m.wide = 120, 40, true
	m.ui.Cursor = visibleRowIndex(m, composeSubjectID)
	if m.ui.Cursor < 0 {
		t.Fatal("subject is not a visible board row")
	}

	// A wheel over the right preview pane focuses the reader but stays at depth 0.
	rightX := boardPaneWidth + paneGutter2 + 4
	wheeled, _ := m.handleWideMouse(wideWheel(rightX, 3, false))
	if len(wheeled.stack) != 1 {
		t.Fatalf("preview wheel changed depth: got %d, want 1", len(wheeled.stack))
	}
	if wheeled.wideFocus != wideFocusReader {
		t.Fatalf("preview wheel did not focus the reader: focus=%v", wheeled.wideFocus)
	}

	// Esc is a popFrame no-op at the root, so ONLY the depth-0 restore acts.
	popped, _ := wheeled.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	mp := popped.(Model)
	if len(mp.stack) != 1 {
		t.Fatalf("Esc at root unexpectedly changed depth: %d", len(mp.stack))
	}
	if mp.wideFocus != wideFocusBoard {
		t.Fatalf("Esc at depth 0 did not restore board focus after a preview wheel: focus=%v", mp.wideFocus)
	}

	// j moves the board cursor; the preview offset the wheel set is left alone.
	cursorBefore := mp.ui.Cursor
	moved, _ := mp.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	mm := moved.(Model)
	if mm.ui.Cursor != cursorBefore+1 {
		t.Fatalf("j after esc did not move the board cursor: got %d, want %d", mm.ui.Cursor, cursorBefore+1)
	}
}
