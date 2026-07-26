package taskboard

import (
	"os"
	"path/filepath"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestWidePaneDefaultGivesDetailsOneThird(t *testing.T) {
	m := newModel(nil, "", Config{})
	m.width, m.height = 120, 40

	innerW := m.wideInnerWidth()
	boardW := m.boardPaneCols(innerW)
	detailsW := innerW - boardW - paneGutter2
	if detailsW != 39 {
		t.Fatalf("default details width = %d, want 39 (one third of %d)", detailsW, innerW)
	}
}

func TestWidePaneDragPersistsRatioAcrossLaunchAndResize(t *testing.T) {
	dir := t.TempDir()
	m := composeFixture()
	m.cacheDir = dir
	m.width, m.height, m.wide = 120, 40, true

	press := tea.MouseMsg{
		X:      boardPaneWidth + 1,
		Y:      4,
		Button: tea.MouseButtonLeft,
		Action: tea.MouseActionPress,
	}
	m, _ = m.handleWideMouse(press)
	if !m.wideDragging {
		t.Fatal("divider press did not begin a drag")
	}

	motion := tea.MouseMsg{X: 61, Y: 4, Action: tea.MouseActionMotion}
	m, _ = m.handleWideMouse(motion)
	if got := m.boardPaneCols(m.wideInnerWidth()); got != 60 {
		t.Fatalf("dragged board width = %d, want 60", got)
	}

	release := tea.MouseMsg{
		X:      61,
		Y:      4,
		Button: tea.MouseButtonLeft,
		Action: tea.MouseActionRelease,
	}
	m, _ = m.handleWideMouse(release)

	reopened := newModel(nil, "", Config{CacheDir: dir})
	innerW := m.wideInnerWidth()
	if got := reopened.boardPaneCols(innerW); got != 60 {
		t.Fatalf("reopened board width = %d, want persisted width 60", got)
	}

	// The preference is a ratio, so a wider next terminal scales the split
	// instead of pinning the board to the old 60-column coordinate.
	if got := reopened.boardPaneCols(innerW * 2); got != 122 {
		t.Fatalf("resized board width = %d, want ratio-scaled width 122", got)
	}
}

func TestWidePanePreferenceCorruptionFallsBackToOneThird(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, taskboardPreferencesFile)
	if err := os.WriteFile(path, []byte(`{"details_pane_ratio":"broken"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	m := newModel(nil, "", Config{CacheDir: dir})
	if got := 120 - m.boardPaneCols(120) - paneGutter2; got != 40 {
		t.Fatalf("corrupt preference details width = %d, want one-third fallback 40", got)
	}
}
