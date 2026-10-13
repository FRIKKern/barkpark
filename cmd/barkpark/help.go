package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  HELP OVERLAY                                                            ║
// ║                                                                          ║
// ║  `?` opens the full key reference as a centred modal — the help BAR is   ║
// ║  one line and truncates at narrow widths, so it can only ever advertise  ║
// ║  a slice of the surface. The overlay is the complete, grouped map        ║
// ║  (navigate / documents / editor / papers / scope), the canonical TUI     ║
// ║  discoverability pattern. j/k scroll, ?/esc/q dismiss; panes and focus   ║
// ║  are untouched, so closing restores the exact prior view. g/G jump to    ║
// ║  the top/bottom, matching the g/G first-last convention used everywhere. ║
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
		{"tab / S-tab", "cycle pane focus / editor"},
		{"s", "workspace / project / dataset selector"},
		{"q", "quit"},
	}},
	{"Documents (list pane)", [][2]string{
		{"n", "new document (title prompt)"},
		{"+", "load more (a list whose count shows N+)"},
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

// helpChrome is the horizontal space the modal spends outside the rows: the
// rounded border (2) plus Padding(1, 2) (4).
const helpChrome = 6

// helpKeyWidth is the key column width: the longest key plus a two-space gap,
// so a long key such as "j / k · ctrl+d / u" never runs into its description.
func helpKeyWidth() int {
	w := 0
	for _, sec := range helpSections {
		for _, row := range sec.rows {
			w = maxInt(w, lipgloss.Width(row[0]))
		}
	}
	return w + 2
}

// helpLines pre-renders the overlay rows once per open. width is the space
// the modal is centred in. A description that would not fit wraps onto
// continuation rows under the description column, so the frame's width clamp
// never cuts it mid-sentence. width <= 0 disables wrapping.
func helpLines(width int) []string {
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(highlight)
	keyW := helpKeyWidth()
	descW := width - helpChrome - 2 - keyW
	if width > 0 && descW < 12 {
		descW = 12 // very narrow terminal: keep a readable column, the frame clamp backstops
	}
	indent := "  " + strings.Repeat(" ", keyW)
	var lines []string
	for i, sec := range helpSections {
		if i > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, editorLabelStyle.Render(strings.ToUpper(sec.title)))
		for _, row := range sec.rows {
			desc := []string{row[1]}
			if width > 0 && lipgloss.Width(row[1]) > descW {
				desc = strings.Split(ansi.Wrap(row[1], descW, ""), "\n")
			}
			key := row[0] + strings.Repeat(" ", keyW-lipgloss.Width(row[0]))
			lines = append(lines, "  "+keyStyle.Render(key)+dimStyle.Render(desc[0]))
			for _, d := range desc[1:] {
				lines = append(lines, indent+dimStyle.Render(d))
			}
		}
	}
	return lines
}

// helpMaxScroll is the largest helpScroll that still moves the window. The
// render path clamps its top row to len-maxRows (a full trailing page), so the
// handler must stop at the same bound — otherwise down/j and G run helpScroll
// past it and the next maxRows-1 `k` presses look dead. width and height are
// what the render path receives, so callers pass m.width and m.paneHeight().
func helpMaxScroll(width, height int) int {
	maxRows := maxInt(height-8, 4)
	return maxInt(len(helpLines(width))-maxRows, 0)
}

// handleHelpKey routes key input while the help overlay is open.
func (m model) handleHelpKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q", "?":
		m.helpOpen = false
		return m, nil
	case "down", "j":
		if m.helpScroll < helpMaxScroll(m.width, m.paneHeight()) {
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
	case "G", "end":
		m.helpScroll = helpMaxScroll(m.width, m.paneHeight())
		return m, nil
	}
	return m, nil
}

// renderHelpOverlay draws the key reference centred over the body area.
func (m model) renderHelpOverlay(width, height int) string {
	all := helpLines(width)
	maxRows := maxInt(height-8, 4)

	var lines []string
	lines = append(lines, headerStyle.Render(" Keys"))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", 34)))
	lines = append(lines, "")

	start := minInt(m.helpScroll, helpMaxScroll(width, height))
	end := minInt(start+maxRows, len(all))
	lines = append(lines, all[start:end]...)
	if end < len(all) {
		lines = append(lines, dimStyle.Render(fmt.Sprintf("  … %d more (j/k)", len(all)-end)))
	}

	lines = append(lines, "")
	lines = append(lines, dimStyle.Render("  jk scroll  g/G ends  esc close"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}
