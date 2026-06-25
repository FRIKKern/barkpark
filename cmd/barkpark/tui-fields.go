package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// startFieldEdit begins editing the field at fieldCursor. It returns the
// cursor-blink cmd of whichever widget took focus (textarea.Focus()'s cmd for
// multi-line fields, textinput.Blink for single-line; nil for toggle/picker
// fields and for a refused richText blocks doc).
func (m *model) startFieldEdit() tea.Cmd {
	if m.fieldCursor >= len(m.editorSchema.Fields) {
		return nil
	}
	field := m.editorSchema.Fields[m.fieldCursor]

	switch field.Type {
	// Multi-line: text + legacy-string richText edit in a textarea. Enter
	// inserts a newline; ctrl+s commits (see handleKey's editing branch).
	case FieldText, FieldRichText:
		if field.Type == FieldRichText {
			// A blocks-doc projection ({"blocks":…,"html":…} — the current
			// wire shape for block-editor docs) must NEVER be edited as text:
			// patching a string over the map is the data-corruption hazard.
			// renderField shows its read-only preview; here we refuse loudly.
			if _, blocks := m.richTextBlocksDoc(field.Name); blocks {
				m.setStatus("blocks doc — read-only here, edit in Studio/Beta", true)
				return nil
			}
		}
		val := m.getFieldValue(field.Name)
		// Editing height == the static render's row count (field.Rows,
		// min 3), grown to fit a taller existing value (capped) so the
		// scroll accounting in scrollToField never drifts mid-edit: the
		// textarea View() is FIXED at this height (internal scrolling),
		// so the rendered field keeps one stable line span per session.
		return m.openMultilineEditor(val, field.Rows)

	// Array of strings: edits one element per line in the same textarea
	// (enter adds an element, ctrl+s commits — commitFieldEdit marshals the
	// lines back to a JSON array string). Anything else inside the array —
	// objects, numbers, booleans, nulls, or a non-array value — keeps
	// today's read-only render: a line-based edit would silently stringify
	// the typed elements, so we refuse loudly instead.
	case FieldArray:
		items, ok := m.arrayStringItems(field.Name)
		if !ok {
			m.setStatus("array has non-string items — read-only here, edit in Studio", true)
			return nil
		}
		return m.openMultilineEditor(strings.Join(items, "\n"), field.Rows)

	// Single-line: string, slug, datetime, color, image edit in a textinput.
	case FieldString, FieldSlug, FieldDatetime, FieldColor, FieldImage, FieldNumber:
		m.editing = true
		m.textInput = textinput.New()
		m.textInput.Focus()
		m.textInput.CharLimit = 500
		m.textInput.Width = m.calcEditorWidth() - 12
		m.textInput.Prompt = ""

		// Pre-fill with current value. Image values may be a JSON envelope
		// ({"url","assetId"}) — edit the URL part, not the raw JSON.
		val := m.getFieldValue(field.Name)
		if field.Type == FieldImage {
			val, _ = parseImageValue(val)
		}
		// Empty slug pre-fills the title-derived slug — the same value the
		// static render ghosts — so enter→enter ACCEPTS the generation
		// (Sanity's Generate button, two keypresses here). The [gen] label
		// annotation finally describes a real behavior.
		if field.Type == FieldSlug && val == "" && m.selectedDoc != nil {
			val = toSlug(m.selectedDoc.Title)
		}
		m.textInput.SetValue(val)
		return textinput.Blink
	case FieldSelect:
		// Short option lists cycle in place (space muscle-memory); long ones
		// open the filterable picker — cycling through a dozen options blind
		// is the anti-Sanity experience.
		if len(field.Options) > 4 {
			m.openOptionPicker(field)
		} else {
			m.toggleField()
		}
	case FieldBoolean:
		m.toggleField()
	case FieldReference:
		// Enter on a reference field opens the picker modal (refpicker.go)
		// instead of a text input — the value is a document id, never typed.
		m.openRefPicker(field)
	}
	return nil
}

// openMultilineEditor focuses a fresh textarea seeded with val. Editing
// height == the static render's row count (schemaRows, min 3), grown to fit a
// taller existing value (capped at 12) so the scroll accounting in
// scrollToField never drifts mid-edit: the textarea View() is FIXED at this
// height (internal scrolling), so the rendered field keeps one stable line
// span per session. Returns the textarea's cursor-blink cmd.
func (m *model) openMultilineEditor(val string, schemaRows int) tea.Cmd {
	rows := schemaRows
	if rows < 2 {
		rows = 3
	}
	if n := strings.Count(val, "\n") + 1; n > rows {
		rows = n
		if rows > 12 {
			rows = 12
		}
	}
	m.editing = true
	m.editingMultiline = true
	m.textArea = textarea.New()
	m.textArea.Prompt = ""
	m.textArea.ShowLineNumbers = false
	m.textArea.CharLimit = 0
	// The outer activeFieldStyle box carries the border; strip the
	// textarea's own cursor-line wash so the surface reads like the
	// single-line input and nothing double-decorates.
	m.textArea.FocusedStyle.CursorLine = lipgloss.NewStyle()
	// Interior width mirrors renderField's box math exactly: editor
	// width − 4 (field indent) − 6 (border+padding+indent) − 2 (the
	// box style's own padding) = calcEditorWidth() − 12 — the same
	// budget the single-line textinput gets.
	taWidth := m.calcEditorWidth() - 12
	if taWidth < 8 {
		taWidth = 8
	}
	m.textArea.SetWidth(taWidth)
	m.textArea.SetHeight(rows)
	m.textArea.SetValue(val)
	return m.textArea.Focus()
}

// arrayStringItems returns a FieldArray field's current items when its value
// is a JSON array of strings — or empty/absent/null, which edits from scratch
// — plus editable=true. A committed-but-unsaved edit lives in dirtyValues as
// the marshalled JSON array string and wins over the wire value in Doc.Extra
// (Doc.Values carries only scalars — arrays never land there, see
// normalizeEnvelope). Any non-array value or any non-string element returns
// (nil, false): read-only, exactly the pre-edit behaviour.
func (m model) arrayStringItems(name string) ([]string, bool) {
	raw := ""
	if v, ok := m.dirtyValues[name]; ok {
		raw = v
	} else if m.selectedDoc != nil && m.selectedDoc.Extra != nil {
		raw = string(m.selectedDoc.Extra[name])
	}
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "null" {
		return nil, true // no items yet — editable from scratch
	}
	var elems []any
	if json.Unmarshal([]byte(raw), &elems) != nil {
		return nil, false // not a JSON array (object / scalar / garbage)
	}
	items := make([]string, 0, len(elems))
	for _, e := range elems {
		s, ok := e.(string)
		if !ok {
			return nil, false // a number/object/bool/null element — refuse
		}
		items = append(items, s)
	}
	return items, true
}

// marshalArrayLines converts the textarea's one-element-per-line text into a
// compact JSON array-of-strings string — elements trimmed, empty lines
// dropped, "[]" when nothing remains. The string form keeps dirtyValues a
// map[string]string; saveDocument re-types it on the wire.
func marshalArrayLines(text string) string {
	items := []string{}
	for _, line := range strings.Split(text, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			items = append(items, t)
		}
	}
	b, _ := json.Marshal(items) // []string never fails to marshal
	return string(b)
}

// editorField finds a field by name in the open editor's schema; nil when no
// schema is open or the name is unknown (e.g. "title"/"status" pseudo-keys).
func (m model) editorField(name string) *Field {
	if m.editorSchema == nil {
		return nil
	}
	for i := range m.editorSchema.Fields {
		if m.editorSchema.Fields[i].Name == name {
			return &m.editorSchema.Fields[i]
		}
	}
	return nil
}

// commitFieldEdit saves the text input value to dirtyValues.
func (m *model) commitFieldEdit() bool {
	if m.fieldCursor >= len(m.editorSchema.Fields) {
		return true
	}
	field := m.editorSchema.Fields[m.fieldCursor]
	val := m.textInput.Value()

	// Validating field types refuse a bad commit and KEEP the editor open
	// (the caller leaves editing mode only on true) — Studio surfaces the
	// same constraint via input affordances; here the status line carries it.
	switch field.Type {
	case FieldNumber:
		t := strings.TrimSpace(val)
		if t != "" {
			if _, err := strconv.ParseFloat(t, 64); err != nil {
				m.setStatus("not a number — digits only (esc cancels)", true)
				return false
			}
		}
		val = t
	case FieldDatetime:
		norm, ok := normalizeDatetime(val)
		if !ok {
			m.setStatus("bad datetime — YYYY-MM-DD [HH:MM], RFC3339, or 'now'", true)
			return false
		}
		val = norm
	case FieldColor:
		norm, ok := normalizeHexColor(val)
		if !ok {
			m.setStatus("bad color — use #rrggbb", true)
			return false
		}
		val = norm
	}

	// Schema pattern (validation.pattern): refuse a violating non-empty value
	// at commit so it never reaches the server's warning pass. An invalid
	// regex in the schema fails open — enforcement is the server's job.
	if field.Pattern != "" && val != "" {
		if re, err := regexp.Compile(field.Pattern); err == nil && !re.MatchString(val) {
			m.setStatus("doesn't match the field's pattern: "+field.Pattern, true)
			return false
		}
	}
	if m.editingMultiline {
		// Multi-line widget owns the edit — embedded newlines survive
		// verbatim into dirtyValues (and the eventual patch mutation).
		val = m.textArea.Value()
		if field.Type == FieldArray {
			// One element per line → JSON array string (trimmed, empties
			// dropped). saveDocument sends the real array on the wire.
			val = marshalArrayLines(val)
		}
	}

	// Image fields edit the URL part of the value. An unchanged URL keeps
	// the original stored value verbatim (preserving the assetId linkage a
	// library pick carries); a new or cleared URL stores the bare string —
	// the asset linkage no longer matches a hand-entered URL. Image fields
	// never take the multiline path — the guard makes that explicit.
	if !m.editingMultiline && field.Type == FieldImage {
		orig := m.getFieldValue(field.Name)
		if u, assetID := parseImageValue(orig); strings.TrimSpace(val) == u {
			val = orig
		} else {
			val = strings.TrimSpace(val)
			if assetID != "" {
				// The hand-entered URL no longer matches the library pick —
				// say so instead of silently orphaning the asset reference
				// (media back-references and renditions key off assetId).
				m.setStatus("asset link removed — saved as bare URL", true)
			}
		}
	}

	if m.dirtyValues == nil {
		m.dirtyValues = make(map[string]string)
	}
	m.dirtyValues[field.Name] = val
	m.dirty = true

	// Also update the in-memory doc for immediate display
	m.applyDirtyToDoc()
	return true
}

// normalizeDatetime accepts the friendly terminal spellings and returns the
// canonical stored form. Empty clears; "now" stamps the current UTC moment;
// a bare date or "date HH:MM" normalizes to the datetime-local shape Studio's
// picker writes; full RFC3339 passes through.
func normalizeDatetime(v string) (string, bool) {
	t := strings.TrimSpace(v)
	switch {
	case t == "":
		return "", true
	case strings.EqualFold(t, "now"):
		return time.Now().UTC().Format(time.RFC3339), true
	}
	for _, layout := range []string{"2006-01-02", "2006-01-02 15:04", "2006-01-02T15:04", time.RFC3339} {
		if _, err := time.Parse(layout, t); err == nil {
			if layout == "2006-01-02 15:04" {
				return strings.Replace(t, " ", "T", 1), true
			}
			return t, true
		}
	}
	return "", false
}

// relTimeHint renders a stored datetime's distance from now ("2h ago",
// "in 3d") — empty for unparseable/empty values, so the hint never lies.
func relTimeHint(v string) string {
	t := strings.TrimSpace(v)
	if t == "" {
		return ""
	}
	var parsed time.Time
	var err error
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04", "2006-01-02"} {
		if parsed, err = time.Parse(layout, t); err == nil {
			break
		}
	}
	if err != nil {
		return ""
	}
	d := time.Until(parsed)
	past := d < 0
	if past {
		d = -d
	}
	var span string
	switch {
	case d < time.Hour:
		span = fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		span = fmt.Sprintf("%dh", int(d.Hours()))
	default:
		span = fmt.Sprintf("%dd", int(d.Hours()/24))
	}
	if past {
		return span + " ago"
	}
	return "in " + span
}

// normalizeHexColor validates + canonicalizes a hex color: 6 hex digits with
// or without the leading #, lowercased, # restored. Empty clears.
func normalizeHexColor(v string) (string, bool) {
	t := strings.TrimSpace(strings.ToLower(v))
	if t == "" {
		return "", true
	}
	t = strings.TrimPrefix(t, "#")
	if len(t) != 6 {
		return "", false
	}
	for _, r := range t {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return "", false
		}
	}
	return "#" + t, true
}

// toggleField cycles select options or toggles boolean.
func (m *model) toggleField() {
	if m.fieldCursor >= len(m.editorSchema.Fields) {
		return
	}
	field := m.editorSchema.Fields[m.fieldCursor]

	if m.dirtyValues == nil {
		m.dirtyValues = make(map[string]string)
	}

	current := m.getFieldValue(field.Name)

	switch field.Type {
	case FieldBoolean:
		if current == "true" {
			m.dirtyValues[field.Name] = "false"
		} else {
			m.dirtyValues[field.Name] = "true"
		}
	case FieldSelect:
		if len(field.Options) > 0 {
			idx := 0
			for i, opt := range field.Options {
				if opt == current {
					idx = (i + 1) % len(field.Options)
					break
				}
			}
			m.dirtyValues[field.Name] = field.Options[idx]
		}
	}
	m.dirty = true
	m.applyDirtyToDoc()
}

// parseImageValue splits an image field's stored value into (url, assetId).
// Two accepted shapes, mirroring the Studio picker's bpParseMediaValue:
// a JSON object `{"url":…,"assetId":…}` (library/upload selections) or a
// bare URL string (legacy + hand-entered). Unparseable JSON degrades to
// treating the whole string as a URL, never an error.
func parseImageValue(v string) (string, string) {
	trimmed := strings.TrimSpace(v)
	if trimmed == "" {
		return "", ""
	}
	if strings.HasPrefix(trimmed, "{") {
		var o struct {
			URL     string `json:"url"`
			AssetID string `json:"assetId"`
			ID      string `json:"id"`
		}
		if err := json.Unmarshal([]byte(trimmed), &o); err == nil {
			if o.AssetID == "" {
				o.AssetID = o.ID
			}
			return o.URL, o.AssetID
		}
	}
	return trimmed, ""
}

// getFieldValue gets the current value for a field, checking dirty values first.
func (m model) getFieldValue(fieldName string) string {
	if m.dirtyValues != nil {
		if v, ok := m.dirtyValues[fieldName]; ok {
			return v
		}
	}
	if m.selectedDoc == nil {
		return ""
	}
	switch fieldName {
	case "title", "name":
		return m.selectedDoc.Title
	case "status":
		return m.selectedDoc.Status
	default:
		if m.selectedDoc.Values != nil {
			return m.selectedDoc.Values[fieldName]
		}
	}
	return ""
}

// applyDirtyToDoc updates the in-memory doc with dirty values for display.
func (m *model) applyDirtyToDoc() {
	if m.selectedDoc == nil || m.dirtyValues == nil {
		return
	}
	for k, v := range m.dirtyValues {
		switch k {
		case "title", "name":
			m.selectedDoc.Title = v
		case "status":
			m.selectedDoc.Status = v
		default:
			if m.selectedDoc.Values == nil {
				m.selectedDoc.Values = make(map[string]string)
			}
			m.selectedDoc.Values[k] = v
			// A FieldArray dirty value is a JSON array string, but the read
			// path (arrayStringItems, rawFieldJSON via renderField) reads the
			// raw wire value in Doc.Extra, not Values — mirror the bytes there
			// so the form shows the committed array, before AND after save.
			if f := m.editorField(k); f != nil && f.Type == FieldArray && json.Valid([]byte(v)) {
				if m.selectedDoc.Extra == nil {
					m.selectedDoc.Extra = make(map[string]json.RawMessage)
				}
				m.selectedDoc.Extra[k] = json.RawMessage(v)
			}
		}
	}
}
