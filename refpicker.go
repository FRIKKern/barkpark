package main

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  REFERENCE-FIELD PICKER                                                  ║
// ║                                                                          ║
// ║  Enter on a focused reference field opens this modal (selector.go's      ║
// ║  modal conventions): it lists the documents of the field's RefType       ║
// ║  (client Query, drafts perspective — the TUI default), with a "(clear)"  ║
// ║  row pinned at the top. Enter stores the picked doc's BARE published id  ║
// ║  (drafts. prefix stripped) as the field's dirty value — the exact wire   ║
// ║  format the Studio's select-ref handler writes (Content.published_id);   ║
// ║  "(clear)" stores "" (the Studio's clear-ref). Esc cancels untouched.    ║
// ║  Every fetched doc's title lands in the model's refTitles cache so the   ║
// ║  field renders the referenced TITLE with the id dim beside it.           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// refPickerState holds the transient UI state for the reference picker modal.
type refPickerState struct {
	active    bool
	fieldName string // schema field the pick writes to
	refType   string // the field's RefType (the listed document type)
	items     []Doc  // fetched candidates of refType
	cursor    int    // 0 == the "(clear)" row; items occupy 1..len(items)
	err       string // inline notice (e.g. empty list)
}

// publishedID strips the drafts. prefix — the Studio stores reference values
// as Content.published_id(doc_id), so the TUI must write the same bare id.
func publishedID(id string) string {
	return strings.TrimPrefix(id, "drafts.")
}

// openRefPicker fetches the field's RefType documents and opens the modal.
// The cursor starts on the row of the field's current value when it is in the
// list, else on the first document (the "(clear)" row is never the default
// landing unless the list is empty). All fetched titles are cached.
func (m *model) openRefPicker(field Field) {
	docs := m.ds.Query(field.RefType, "")
	if m.refTitles == nil {
		m.refTitles = make(map[string]string)
	}
	for i := range docs {
		m.refTitles[publishedID(docs[i].ID)] = docs[i].Title
	}

	cursor := 0
	if len(docs) > 0 {
		cursor = 1
		if cur := m.getFieldValue(field.Name); cur != "" {
			for i := range docs {
				if publishedID(docs[i].ID) == cur {
					cursor = i + 1
					break
				}
			}
		}
	}

	m.refPicker = refPickerState{
		active:    true,
		fieldName: field.Name,
		refType:   field.RefType,
		items:     docs,
		cursor:    cursor,
	}
	if len(docs) == 0 {
		m.refPicker.err = "no " + field.RefType + " documents"
	}
}

// handleRefPickerKey routes key input while the reference picker is open.
func (m model) handleRefPickerKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.refPicker = refPickerState{}
		return m, nil
	case "down", "tab", "j":
		if m.refPicker.cursor < len(m.refPicker.items) {
			m.refPicker.cursor++
		}
		return m, nil
	case "up", "shift+tab", "k":
		if m.refPicker.cursor > 0 {
			m.refPicker.cursor--
		}
		return m, nil
	case "enter":
		return m.commitRefPick()
	}
	return m, nil
}

// commitRefPick writes the picked value into dirtyValues — the bare published
// id for a document row, "" for the "(clear)" row — exactly the content value
// the server expects for a reference field (matches Studio's select-ref /
// clear-ref). The save itself stays on ctrl+s like every other field edit.
func (m model) commitRefPick() (tea.Model, tea.Cmd) {
	p := m.refPicker
	m.refPicker = refPickerState{}

	if m.dirtyValues == nil {
		m.dirtyValues = make(map[string]string)
	}
	if p.cursor == 0 {
		m.dirtyValues[p.fieldName] = ""
	} else if p.cursor-1 < len(p.items) {
		doc := p.items[p.cursor-1]
		id := publishedID(doc.ID)
		m.dirtyValues[p.fieldName] = id
		if m.refTitles == nil {
			m.refTitles = make(map[string]string)
		}
		m.refTitles[id] = doc.Title
	} else {
		return m, nil
	}
	m.dirty = true
	m.applyDirtyToDoc()
	m.refreshViewport()
	return m, nil
}

// cacheRefTitlesFor resolves the titles of reference values already set on the
// opened document — one Query per reference field whose value is not yet in
// the cache — so the field renders "Title  id" instead of a bare id. Called on
// editor open (drill-in / search drill); fields with no value are skipped.
func (m *model) cacheRefTitlesFor(schema *Schema) {
	if schema == nil {
		return
	}
	for _, f := range schema.Fields {
		if f.Type != FieldReference {
			continue
		}
		val := m.getFieldValue(f.Name)
		if val == "" {
			continue
		}
		if _, ok := m.refTitles[val]; ok {
			continue
		}
		docs := m.ds.Query(f.RefType, "")
		if m.refTitles == nil {
			m.refTitles = make(map[string]string)
		}
		for i := range docs {
			m.refTitles[publishedID(docs[i].ID)] = docs[i].Title
		}
	}
}

// renderRefPicker draws the modal centred over the body area, mirroring
// renderSelector's chrome: header, divider, rows, inline error, key hints.
func (m model) renderRefPicker(width, height int) string {
	var lines []string
	lines = append(lines, headerStyle.Render(" Select "+m.refPicker.refType))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", 34)))
	lines = append(lines, "")

	lines = append(lines, renderRefRow("∅", "(clear)", "", m.refPicker.cursor == 0))
	for i, d := range m.refPicker.items {
		lines = append(lines, renderRefRow(statusIcon(d.Status), d.Title, timeAgo(d.UpdatedAt), i+1 == m.refPicker.cursor))
	}

	lines = append(lines, "")
	lines = appendErr(lines, m.refPicker.err)
	lines = append(lines, dimStyle.Render("  ↑↓/jk move  enter select  esc cancel"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}

// renderRefRow draws one selectable picker row: status icon + title, with a
// dim timeAgo suffix. Selected rows get the ▸ highlight (selector convention).
func renderRefRow(icon, title, sub string, selected bool) string {
	suffix := ""
	if sub != "" {
		suffix = "  " + dimStyle.Render(sub)
	}
	if selected {
		return lipgloss.NewStyle().Bold(true).Foreground(highlight).Render("  ▸ "+icon+" "+title) + suffix
	}
	return editorLabelStyle.Render("    "+icon+" "+title) + suffix
}
