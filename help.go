package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  HELP OVERLAY                                                            ║
// ║                                                                          ║
// ║  `?` opens the full key reference as a centred modal — the help BAR is   ║
// ║  one line and truncates at narrow widths, so it can only ever advertise  ║
// ║  a slice of the surface. The overlay is the complete, grouped map        ║
// ║  (navigate / documents / editor / papers / scope), the canonical TUI     ║
// ║  discoverability pattern. j/k scroll, ?/esc/q dismiss; panes and focus   ║
// ║  are untouched, so closing restores the exact prior view.                ║
// ╚══════════════════════════════════════════════════════════════════════════╝

type helpSection struct {
	title string
	rows  [][2]string
}

// helpSections is the curated key reference. Curated ON PURPOSE: it documents
// intent ("R R discard draft (twice to confirm)"), not just bindings — keep it
// in sync when adding keys (help_test.go spot-pins the load-bearing rows).
var helpSections = []helpSection{
	{"Navigate", [][2]string{
		{"j / k", "move down / up"},
		{"h / l", "pane left / right (l also drills in)"},
		{"enter", "drill in · open document"},
		{"g / G", "first / last row"},
		{"/", "search this scope"},
		{"s", "workspace / project / dataset selector"},
		{"q", "quit"},
	}},
	{"Documents (list pane)", [][2]string{
		{"n", "new document (title prompt)"},
		{"y", "duplicate (content verbatim)"},
		{"space", "mark / unmark row for bulk"},
		{"ctrl+p / U", "publish / unpublish every marked doc"},
		{"R R", "discard draft (twice to confirm)"},
		{"D D", "delete (twice to confirm)"},
		{"c / x", "claim / close task (task lists)"},
		{"esc", "clear marks · go back"},
	}},
	{"Editor", [][2]string{
		{"enter", "edit field (reference: picker; image: URL)"},
		{"space", "toggle boolean / cycle select"},
		{"ctrl+s", "save"},
		{"ctrl+p", "publish draft"},
		{"U", "unpublish"},
		{"d", "diff draft ↔ published"},
		{"H", "revision history (enter: diff vs current)"},
		{"R R / D D", "discard draft / delete"},
		{"esc", "back to the list"},
	}},
	{"Papers (read-only)", [][2]string{
		{"j / k · ctrl+d / u", "scroll · half page"},
		{"g / G", "top / bottom"},
		{"", "editing happens in Studio"},
	}},
	{"Scope selector", [][2]string{
		{"n", "create workspace / project (server slugs the name)"},
		{"m", "manual three-field entry"},
	}},
}

// helpLines pre-renders the overlay rows once per open.
func helpLines() []string {
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(highlight)
	var lines []string
	for i, sec := range helpSections {
		if i > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, editorLabelStyle.Render(strings.ToUpper(sec.title)))
		for _, row := range sec.rows {
			key := fmt.Sprintf("%-14s", row[0])
			lines = append(lines, "  "+keyStyle.Render(key)+dimStyle.Render(row[1]))
		}
	}
	return lines
}

// handleHelpKey routes key input while the help overlay is open.
func (m model) handleHelpKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q", "?":
		m.helpOpen = false
		return m, nil
	case "down", "j":
		if m.helpScroll < len(helpLines())-1 {
			m.helpScroll++
		}
		return m, nil
	case "up", "k":
		if m.helpScroll > 0 {
			m.helpScroll--
		}
		return m, nil
	case "g", "home":
		m.helpScroll = 0
		return m, nil
	}
	return m, nil
}

// renderHelpOverlay draws the key reference centred over the body area.
func (m model) renderHelpOverlay(width, height int) string {
	all := helpLines()
	maxRows := maxInt(height-8, 4)

	var lines []string
	lines = append(lines, headerStyle.Render(" Keys"))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", 34)))
	lines = append(lines, "")

	start := minInt(m.helpScroll, maxInt(len(all)-1, 0))
	end := minInt(start+maxRows, len(all))
	lines = append(lines, all[start:end]...)
	if end < len(all) {
		lines = append(lines, dimStyle.Render(fmt.Sprintf("  … %d more (j/k)", len(all)-end)))
	}

	lines = append(lines, "")
	lines = append(lines, dimStyle.Render("  jk scroll  esc close"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}
