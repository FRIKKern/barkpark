package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  HISTORY VIEW                                                            ║
// ║                                                                          ║
// ║  `H` on a focused editor lists the doc's revision history                ║
// ║  (GET /v1/data/history/<ds>/<type>/<bare-id> — newest first; the server  ║
// ║  tracks the draft+published family under the bare id). Rows: time ago,   ║
// ║  action, [status], title. `enter` fetches the highlighted revision       ║
// ║  (GET /v1/data/revision/<ds>/<uuid>) and opens the diff modal OVER the   ║
// ║  list — `- revision  + current` — so "what changed since then?" is one   ║
// ║  keypress; esc steps back to the list, esc again to the editor.          ║
// ║                                                                          ║
// ║  Read-only by design: restore stays in Studio (History pane) and the     ║
// ║  API (POST /v1/data/revision/:dataset/:id/restore) — a destructive       ║
// ║  overwrite earns more ceremony than a terminal modal in v1.              ║
// ╚══════════════════════════════════════════════════════════════════════════╝

const historyLimit = 50

// openHistoryView fetches the revision list for the doc in the editor.
// Zero revisions surface a status line, never an empty modal.
func (m *model) openHistoryView() {
	doc := m.selectedDoc
	if doc == nil || m.editorSchema == nil {
		return
	}
	bare := strings.TrimPrefix(doc.ID, "drafts.")
	revs, err := m.ds.History(m.editorSchema.Name, bare, historyLimit)
	if err != nil {
		m.setStatus(fmt.Sprintf("history failed: %v", err), true)
		return
	}
	if len(revs) == 0 {
		m.setStatusInfo("no revisions recorded")
		return
	}
	m.historyRevs = revs
	m.historyCursor = 0
	m.historyOpen = true
}

// handleHistoryKey routes key input while the history modal is open. The
// diff-over-history case never reaches here — the key router checks
// diffOpen first.
func (m model) handleHistoryKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q", "H":
		m.historyOpen = false
		m.historyRevs = nil
		return m, nil
	case "down", "j":
		if m.historyCursor < len(m.historyRevs)-1 {
			m.historyCursor++
		}
		return m, nil
	case "up", "k":
		if m.historyCursor > 0 {
			m.historyCursor--
		}
		return m, nil
	case "g", "home":
		m.historyCursor = 0
		return m, nil
	case "G", "end":
		if len(m.historyRevs) > 0 {
			m.historyCursor = len(m.historyRevs) - 1
		}
		return m, nil
	case "enter":
		return m.diffAgainstRevision()
	}
	return m, nil
}

// diffAgainstRevision fetches the highlighted revision and opens the diff
// modal over the history list: the revision is the `-` side, the editor's
// effective values (unsaved edits included) the `+` side.
func (m model) diffAgainstRevision() (tea.Model, tea.Cmd) {
	if m.historyCursor >= len(m.historyRevs) {
		return m, nil
	}
	rev := m.historyRevs[m.historyCursor]
	revDoc, err := m.ds.RevisionDoc(rev.ID)
	if err != nil {
		m.setStatus(fmt.Sprintf("revision fetch failed: %v", err), true)
		return m, nil
	}
	m.diffLines = m.buildDiffLines(&revDoc)
	m.diffLegend = "- revision (" + timeAgo(rev.Timestamp) + ")   + current"
	m.diffScroll = 0
	m.diffOpen = true
	return m, nil
}

// renderHistoryView draws the revision list centred over the body area (the
// search-results modal chrome). Cursor row highlights like a ref-picker row.
func (m model) renderHistoryView(width, height int) string {
	title := ""
	if m.selectedDoc != nil {
		title = m.selectedDoc.Title
	}

	maxRows := maxInt(height-9, 3)

	var lines []string
	lines = append(lines, headerStyle.Render(fmt.Sprintf(" History: %s", truncate(title, 40))))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", 34)))
	lines = append(lines, "")

	// Window the rows around the cursor so long histories stay reachable.
	start := 0
	if m.historyCursor >= maxRows {
		start = m.historyCursor - maxRows + 1
	}
	end := minInt(start+maxRows, len(m.historyRevs))
	for i := start; i < end; i++ {
		rev := m.historyRevs[i]
		label := fmt.Sprintf("%-8s %-9s", timeAgo(rev.Timestamp), rev.Action)
		sub := "[" + rev.Status + "] " + truncate(rev.Title, 30)
		lines = append(lines, renderRefRow("·", label, sub, i == m.historyCursor))
	}
	if end < len(m.historyRevs) {
		lines = append(lines, dimStyle.Render(fmt.Sprintf("  … %d more", len(m.historyRevs)-end)))
	}

	lines = append(lines, "")
	lines = append(lines, dimStyle.Render("  ↑↓/jk move  enter diff vs current  esc close"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}
