package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/FRIKKern/barkpark/internal/apiclient"
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
	cursor    int    // 0 == the "(clear)" row; filtered items occupy 1..n
	err       string // inline notice (e.g. empty list)
	// Type-to-filter (Sanity's search-driven reference field): `/` enters
	// filter typing, printables narrow the list live (case-insensitive
	// substring over title + bare id), esc steps out of typing first and
	// clears the filter second — the third esc closes the picker.
	filter    string
	filtering bool
}

// filteredRefItems returns the items the picker currently shows — the fetch
// list narrowed by the live filter. An empty filter shows everything.
func (p refPickerState) filteredRefItems() []Doc {
	if p.filter == "" {
		return p.items
	}
	q := strings.ToLower(p.filter)
	var out []Doc
	for _, d := range p.items {
		if strings.Contains(strings.ToLower(d.Title), q) ||
			strings.Contains(strings.ToLower(publishedID(d.ID)), q) {
			out = append(out, d)
		}
	}
	return out
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
	// QueryResult, not Query: a refused/unreachable read also yields zero
	// docs, and the empty-list arm below reported that as "no <type>
	// documents" — asserting the type is empty when we never got to look.
	docs, outcome := m.ds.QueryResult(field.RefType, "")
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
		m.refPicker.err = refPickerEmptyError(field.RefType, outcome)
	}
}

// refPickerEmptyError names WHY the picker has no rows. An empty list is only
// "no <type> documents" when the read actually succeeded; a refusal or an
// unreachable server gets its own message, because the two suggest opposite
// next actions (create one vs. fix the connection).
func refPickerEmptyError(refType string, outcome apiclient.DocReadOutcome) string {
	if outcome.Failed() {
		return "couldn't load " + refType + " — " + outcome.Describe()
	}
	return "no " + refType + " documents"
}

// openOptionPicker reuses the reference-picker modal for a LONG select
// field's options: each option becomes a synthetic row (ID == Title == the
// option string, so commitRefPick writes the option verbatim), the (clear)
// row clears, and `/` filtering works unchanged. Short selects keep the
// in-place cycle (startFieldEdit's threshold).
func (m *model) openOptionPicker(field Field) {
	docs := make([]Doc, 0, len(field.Options))
	for _, opt := range field.Options {
		docs = append(docs, Doc{ID: opt, Title: opt, Status: ""})
	}

	cursor := 1
	if cur := m.getFieldValue(field.Name); cur != "" {
		for i, opt := range field.Options {
			if opt == cur {
				cursor = i + 1
				break
			}
		}
	}

	m.refPicker = refPickerState{
		active:    true,
		fieldName: field.Name,
		refType:   field.Title, // the modal header reads "Select <Title>"
		items:     docs,
		cursor:    cursor,
	}
}

// handleRefPickerKey routes key input while the reference picker is open.
// `/` enters filter typing; in that mode printables narrow the list and the
// navigation keys still move over the FILTERED rows, so type-then-arrow-then-
// enter flows without mode juggling.
func (m model) handleRefPickerKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()
	shown := m.refPicker.filteredRefItems()

	if m.refPicker.filtering {
		switch key {
		case "esc":
			// Step out of typing; the filter (and narrowed list) stays.
			m.refPicker.filtering = false
			return m, nil
		case "enter":
			return m.commitRefPick()
		case "backspace":
			if f := m.refPicker.filter; f != "" {
				m.refPicker.filter = f[:len(f)-1]
				m.clampRefCursor()
			}
			return m, nil
		case "down", "tab":
			if m.refPicker.cursor < len(shown) {
				m.refPicker.cursor++
			}
			return m, nil
		case "up", "shift+tab":
			if m.refPicker.cursor > 0 {
				m.refPicker.cursor--
			}
			return m, nil
		default:
			if msg.Type == tea.KeyRunes {
				m.refPicker.filter += string(msg.Runes)
				m.clampRefCursor()
			}
			return m, nil
		}
	}

	switch key {
	case "esc":
		if m.refPicker.filter != "" {
			// Layered esc: clear the filter first, close on the next.
			m.refPicker.filter = ""
			m.clampRefCursor()
			return m, nil
		}
		m.refPicker = refPickerState{}
		return m, nil
	case "/":
		m.refPicker.filtering = true
		return m, nil
	case "down", "tab", "j":
		if m.refPicker.cursor < len(shown) {
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

// clampRefCursor keeps the cursor inside the filtered row span after the
// filter narrows (row 0 is always the "(clear)" pin).
func (m *model) clampRefCursor() {
	if n := len(m.refPicker.filteredRefItems()); m.refPicker.cursor > n {
		m.refPicker.cursor = n
	}
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
	shown := p.filteredRefItems()
	if p.cursor == 0 {
		m.dirtyValues[p.fieldName] = ""
	} else if p.cursor-1 < len(shown) {
		doc := shown[p.cursor-1]
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
		docs, outcome := m.ds.QueryResult(f.RefType, "")
		if m.refTitles == nil {
			m.refTitles = make(map[string]string)
		}
		for i := range docs {
			m.refTitles[publishedID(docs[i].ID)] = docs[i].Title
		}
		// The whole refType list was just fetched; a value still missing
		// from it points at a deleted doc. The "" sentinel means "checked,
		// not found" — renderField shows the broken-reference warning. A
		// FAILED fetch returns zero docs and would mark every ref broken,
		// so only mark when the READ SUCCEEDED. This replaces a len(docs)>0
		// proxy that was wrong in BOTH directions: it stayed silent about a
		// genuinely broken ref whenever the type happened to be empty, and it
		// could not see a successful read that returned nothing.
		if _, ok := m.refTitles[val]; !ok && outcome == apiclient.DocReadOK {
			m.refTitles[val] = ""
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

	if m.refPicker.filtering || m.refPicker.filter != "" {
		cursor := ""
		if m.refPicker.filtering {
			cursor = "▌"
		}
		lines = append(lines, "  "+dimStyle.Render("/ ")+m.refPicker.filter+cursor)
	}

	// Window the logical row list (the "(clear)" pin at index 0, then the
	// filtered items at 1..n) around the cursor so long ref types stay
	// reachable — mirrors renderHistoryView's cursor windowing.
	shown := m.refPicker.filteredRefItems()
	maxRows := maxInt(height-9, 3)
	total := len(shown) + 1
	start := 0
	if m.refPicker.cursor >= maxRows {
		start = m.refPicker.cursor - maxRows + 1
	}
	end := minInt(start+maxRows, total)
	if start == 0 {
		lines = append(lines, renderRefRow("∅", "(clear)", "", m.refPicker.cursor == 0))
	}
	for i, d := range shown {
		if logical := i + 1; logical >= start && logical < end {
			lines = append(lines, renderRefRow(statusIcon(d.Status), d.Title, timeAgo(d.UpdatedAt), logical == m.refPicker.cursor))
		}
	}
	if end < total {
		lines = append(lines, dimStyle.Render(fmt.Sprintf("  … %d more", total-end)))
	}
	if len(shown) == 0 && m.refPicker.filter != "" {
		lines = append(lines, dimStyle.Render("    no matches"))
	}

	lines = append(lines, "")
	lines = appendErr(lines, m.refPicker.err)
	if m.refPicker.filtering {
		lines = append(lines, dimStyle.Render("  type to filter  ↑↓ move  enter select  esc done"))
	} else {
		lines = append(lines, dimStyle.Render("  ↑↓/jk move  / filter  enter select  esc cancel"))
	}

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
