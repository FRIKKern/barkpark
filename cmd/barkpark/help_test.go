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
		"cycle pane focus / editor", // tab / S-tab pane cycling (tui-update.go)
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
	m := model{helpOpen: true, helpScroll: 3, height: 20}

	// G jumps to the max scroll the render window can actually reach
	// (len-maxRows, a full trailing page) — NOT len-1, or the last page of k
	// presses is dead against the render clamp.
	after, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
	am := after.(model)
	if want := helpMaxScroll(m.paneHeight()); am.helpScroll != want {
		t.Errorf("G should jump to max scroll (%d), got %d", want, am.helpScroll)
	}

	// g jumps back to the top.
	back, _ := am.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'g'}})
	bm := back.(model)
	if bm.helpScroll != 0 {
		t.Errorf("g should jump to top (0), got %d", bm.helpScroll)
	}
}

// TestHelpScrollNeverOverclamps is the drift guard for the over-clamp bug:
// down/j and G must never push helpScroll past the render window's max, and one
// k from the bottom must immediately move the rendered window (no dead presses).
func TestHelpScrollNeverOverclamps(t *testing.T) {
	for _, height := range []int{10, 18, 24, 40} {
		m := model{helpOpen: true, height: height}
		max := helpMaxScroll(m.paneHeight())

		// Mash j well past the end.
		for i := 0; i < len(helpLines())+5; i++ {
			next, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
			m = next.(model)
		}
		if m.helpScroll != max {
			t.Errorf("height %d: j to the end should land on max (%d), got %d", height, max, m.helpScroll)
		}

		// G lands on the same bound, never past it.
		gm, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
		m = gm.(model)
		if m.helpScroll != max {
			t.Errorf("height %d: G should land on max (%d), got %d", height, max, m.helpScroll)
		}

		// Render at paneHeight — the height the production render path receives —
		// so the handler bound and the render clamp agree. One k must move it.
		ph := m.paneHeight()
		before := m.renderHelpOverlay(120, ph)
		km, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
		m = km.(model)
		after := m.renderHelpOverlay(120, ph)
		if max > 0 && before == after {
			t.Errorf("height %d: one k from the bottom should change the window", height)
		}
	}
}
