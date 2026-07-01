package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// Help-overlay pins (2026-06-12): `?` opens the full grouped key reference
// from pane AND paper focus, the curated rows cover every load-bearing verb
// the one-line help bar can't fit, and the overlay scrolls/windows.

func TestHelpOverlayOpensAndCloses(t *testing.T) {
	m := bulkModel() // pane focus

	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	nm := next.(model)
	if !nm.helpOpen {
		t.Fatal("? should open the help overlay from pane focus")
	}

	// esc closes; panes/focus untouched.
	after, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	am := after.(model)
	if am.helpOpen {
		t.Error("esc should close the overlay")
	}
	if am.focus != m.focus {
		t.Errorf("focus must be untouched, got %+v", am.focus)
	}
}

func TestHelpOverlayCoversLoadBearingVerbs(t *testing.T) {
	m := model{helpOpen: true, width: 110, height: 44}
	out := m.renderHelpOverlay(110, 60)

	// One row per shipped verb family — the drift guard for new keybindings.
	for _, want := range []string{
		"diff draft ↔ published",
		"revision history",
		"mark / unmark row for bulk",
		"publish / unpublish every marked doc",
		"create workspace / project",
		"claim / close task",
		"duplicate",
		"discard draft (twice to confirm)",
		"editing happens in Studio",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("help overlay missing %q", want)
		}
	}
}

func TestHelpOverlayScrollWindows(t *testing.T) {
	m := model{helpOpen: true}
	short := m.renderHelpOverlay(100, 18) // small view → must window
	if !strings.Contains(short, "more") {
		t.Errorf("small view should show the overflow indicator:\n%s", short)
	}

	m.helpScroll = len(helpLines()) - 1
	end := m.renderHelpOverlay(100, 18)
	if strings.Contains(end, "more") {
		t.Error("scrolled-to-end view must not claim more rows")
	}

	// Scrolled to the very bottom the window must stay a full page — it must
	// not shrink one row at a time down to a lone trailing line adrift in the
	// modal. height 18 → maxRows = max(18-8, 4) = 10, so the top clamps to
	// len-maxRows and the last full page of rows renders.
	all := helpLines()
	maxRows := maxInt(18-8, 4)
	pageStart := maxInt(len(all)-maxRows, 0)
	want, shown := 0, 0
	for _, line := range all[pageStart:] {
		if line == "" {
			continue // blank section separators don't count as rows
		}
		want++
		if strings.Contains(end, line) {
			shown++
		}
	}
	if want <= 1 {
		t.Fatalf("test setup: expected a multi-row last page, got %d", want)
	}
	if shown != want {
		t.Errorf("bottom of scroll should render the full last page (%d rows), got %d:\n%s", want, shown, end)
	}
}

func TestHelpOverlayGGJumpsTopBottom(t *testing.T) {
	m := model{helpOpen: true, helpScroll: 3}

	// G jumps to the bottom, matching the g/G convention used elsewhere.
	after, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
	am := after.(model)
	if want := len(helpLines()) - 1; am.helpScroll != want {
		t.Errorf("G should jump to bottom (%d), got %d", want, am.helpScroll)
	}

	// g jumps back to the top.
	back, _ := am.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'g'}})
	bm := back.(model)
	if bm.helpScroll != 0 {
		t.Errorf("g should jump to top (0), got %d", bm.helpScroll)
	}
}
