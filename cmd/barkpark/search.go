package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SEARCH                                                                  ║
// ║                                                                          ║
// ║  `/` on a focused pane opens a query input in the help bar (the n-prompt ║
// ║  mechanics); enter hits the scoped full-text endpoint                    ║
// ║                                                                          ║
// ║    GET /w/<ws>/p/<proj>/v1/data/search/<dataset>?q=…&limit=20            ║
// ║                                                                          ║
// ║  (SearchController.search — response carries the matching document       ║
// ║  envelopes at top-level "documents"). Hits render as a transient         ║
// ║  results modal (title + type + list_preview badge); j/k + enter drills   ║
// ║  into the hit's editor (type resolved from the envelope's _type), esc    ║
// ║  dismisses back to the untouched pane state. Empty results never open    ║
// ║  the modal — the status bar says "no matches". Read-path only.           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

const searchLimit = 20

// startSearch opens the help-bar query input (reuses m.textInput, exactly the
// startCreateDoc mechanics).
func (m *model) startSearch() {
	m.searching = true
	m.textInput = textinput.New()
	m.textInput.Focus()
	m.textInput.CharLimit = 200
	m.textInput.Width = maxInt(m.width-20, 20)
	m.textInput.Prompt = ""
}

// commitSearch runs the typed query. An empty query just closes the prompt;
// zero hits surface "no matches" in the status bar without opening the modal.
func (m model) commitSearch() (tea.Model, tea.Cmd) {
	m.searching = false
	query := strings.TrimSpace(m.textInput.Value())
	if query == "" {
		return m, nil
	}
	hits, err := m.ds.Search(query, searchLimit)
	if err != nil {
		m.setStatus(fmt.Sprintf("search failed: %v", err), true)
		return m, nil
	}
	if len(hits) == 0 {
		m.setStatus("no matches", true)
		return m, nil
	}
	m.searchQuery = query
	m.searchHits = hits
	m.searchCursor = 0
	m.searchOpen = true
	return m, nil
}

// handleSearchResultsKey routes key input while the results modal is open.
// Esc dismisses back to the previous pane state — the panes/focus were never
// mutated, so dropping the overlay restores the exact prior view.
func (m model) handleSearchResultsKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.searchOpen = false
		m.searchHits = nil
		return m, nil
	case "down", "tab", "j":
		if m.searchCursor < len(m.searchHits)-1 {
			m.searchCursor++
		}
		return m, nil
	case "up", "shift+tab", "k":
		if m.searchCursor > 0 {
			m.searchCursor--
		}
		return m, nil
	case "enter":
		return m.drillIntoHit()
	}
	return m, nil
}

// drillIntoHit opens the highlighted hit's editor, resolving the schema from
// the envelope's _type. An unknown type (schema not in this scope) surfaces a
// status error and keeps the modal open rather than opening a broken editor.
func (m model) drillIntoHit() (tea.Model, tea.Cmd) {
	if m.searchCursor >= len(m.searchHits) {
		return m, nil
	}
	hit := &m.searchHits[m.searchCursor]
	schema := findSchema(hit.Type)
	if schema == nil {
		m.setStatus("unknown type "+hit.Type, true)
		return m, nil
	}
	m.searchOpen = false
	m.selectedDoc = hit
	m.editorSchema = schema
	m.showEditor = true
	m.focus.Target = FocusEditor
	m.fieldCursor = 0
	m.syncSelectedPaper()
	m.cacheRefTitlesFor(schema)
	m.resetViewport()
	return m, nil
}

// renderSearchResults draws the results modal centred over the body area
// (selector.go's modal chrome). Rows: status icon + title + dim [type], plus
// the schema's list_preview badge when declared.
func (m model) renderSearchResults(width, height int) string {
	var lines []string
	lines = append(lines, headerStyle.Render(fmt.Sprintf(" Search: %s", truncate(m.searchQuery, 24))))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", 34)))
	lines = append(lines, "")

	for i := range m.searchHits {
		hit := &m.searchHits[i]
		sub := "[" + hit.Type + "]"
		if badge := previewValue(*hit, schemaListPreview(hit.Type).Badge); badge != "" {
			sub += " " + badge
		}
		lines = append(lines, renderRefRow(statusIcon(hit.Status), truncate(hit.Title, 40), sub, i == m.searchCursor))
	}

	lines = append(lines, "")
	lines = append(lines, dimStyle.Render("  ↑↓/jk move  enter open  esc dismiss"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}
