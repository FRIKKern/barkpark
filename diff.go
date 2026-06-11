package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DIFF VIEW                                                               ║
// ║                                                                          ║
// ║  `d` on a focused DRAFT editor opens a transient draft↔published field   ║
// ║  diff — the missing half of the publish/discard decision: before ctrl+p  ║
// ║  or R×2 you can see exactly WHAT would ship or be thrown away. The       ║
// ║  published twin is fetched live (GET /v1/data/doc/<ds>/<type>/<bare>),   ║
// ║  the draft side reads the editor's effective values (unsaved edits       ║
// ║  included — what you see is what publishes after ctrl+s).                ║
// ║                                                                          ║
// ║  Per changed field: a label row, the published value as `- ` rows, the   ║
// ║  draft value as `+ ` rows (multi-line values diff per line). Unchanged   ║
// ║  fields collapse to one dim count. j/k scroll, esc/q/d dismiss — the     ║
// ║  panes/focus were never mutated, so closing restores the prior view.    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

var (
	diffDelStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#dc2626", Dark: "#f87171"})
	diffAddStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#16a34a", Dark: "#4ade80"})
)

// openDiffView builds the field diff for the doc in the editor. Inert (status
// message, no modal) when the doc is not a draft or has no published twin —
// there is nothing to compare against.
func (m *model) openDiffView() {
	doc := m.selectedDoc
	if doc == nil || m.editorSchema == nil {
		return
	}
	if !strings.HasPrefix(doc.ID, "drafts.") {
		m.setStatus("published doc — diff compares a draft to its published twin", true)
		return
	}
	bare := strings.TrimPrefix(doc.ID, "drafts.")
	pub, ok := m.ds.Get(m.editorSchema.Name, bare)
	if !ok {
		m.setStatus("never published — every field is new", true)
		return
	}
	m.diffLines = m.buildDiffLines(&pub)
	m.diffScroll = 0
	m.diffOpen = true
}

// buildDiffLines renders the per-field diff rows. The draft side reads
// getFieldValue (dirty-aware); the published side reads the fetched twin.
func (m *model) buildDiffLines(pub *Doc) []string {
	pubValue := func(name string) string {
		switch name {
		case "title", "name":
			return pub.Title
		case "status":
			return pub.Status
		default:
			if pub.Values != nil {
				return pub.Values[name]
			}
		}
		return ""
	}

	var lines []string
	unchanged := 0
	for _, field := range m.editorSchema.Fields {
		oldV := pubValue(field.Name)
		newV := m.getFieldValue(field.Name)
		if oldV == newV {
			unchanged++
			continue
		}
		lines = append(lines, editorLabelStyle.Render(strings.ToUpper(field.Title)))
		for _, ln := range strings.Split(oldV, "\n") {
			if ln == "" && oldV == "" {
				ln = "(empty)"
			}
			lines = append(lines, diffDelStyle.Render("- "+ln))
		}
		for _, ln := range strings.Split(newV, "\n") {
			if ln == "" && newV == "" {
				ln = "(empty)"
			}
			lines = append(lines, diffAddStyle.Render("+ "+ln))
		}
		lines = append(lines, "")
	}

	if len(lines) == 0 {
		lines = append(lines, dimStyle.Render("draft and published are identical"))
	} else if unchanged > 0 {
		lines = append(lines, dimStyle.Render(fmt.Sprintf("%d field(s) unchanged", unchanged)))
	}
	return lines
}

// handleDiffKey routes key input while the diff modal is open.
func (m model) handleDiffKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q", "d":
		m.diffOpen = false
		m.diffLines = nil
		return m, nil
	case "down", "j":
		if m.diffScroll < len(m.diffLines)-1 {
			m.diffScroll++
		}
		return m, nil
	case "up", "k":
		if m.diffScroll > 0 {
			m.diffScroll--
		}
		return m, nil
	case "g", "home":
		m.diffScroll = 0
		return m, nil
	case "G", "end":
		if len(m.diffLines) > 0 {
			m.diffScroll = len(m.diffLines) - 1
		}
		return m, nil
	}
	return m, nil
}

// renderDiffView draws the diff modal centred over the body area (the
// search-results modal chrome). The line window scrolls via diffScroll.
func (m model) renderDiffView(width, height int) string {
	title := ""
	if m.selectedDoc != nil {
		title = m.selectedDoc.Title
	}

	contentWidth := minInt(maxInt(width-12, 30), 90)
	maxRows := maxInt(height-9, 3)

	var lines []string
	lines = append(lines, headerStyle.Render(fmt.Sprintf(" Diff: %s", truncate(title, contentWidth-8))))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", minInt(34, contentWidth))))
	lines = append(lines, "")

	end := minInt(m.diffScroll+maxRows, len(m.diffLines))
	for _, ln := range m.diffLines[minInt(m.diffScroll, len(m.diffLines)):end] {
		lines = append(lines, clampLine(ln, contentWidth))
	}
	if end < len(m.diffLines) {
		lines = append(lines, dimStyle.Render(fmt.Sprintf("  … %d more", len(m.diffLines)-end)))
	}

	lines = append(lines, "")
	lines = append(lines, dimStyle.Render("  - published   + draft   ·  jk scroll  esc close"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}
