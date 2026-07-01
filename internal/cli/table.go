package cli

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/mattn/go-runewidth"
)

// renderTable prints a human-readable table for the common API payload shapes:
//
//   - {"documents":[…]} — a list query: one row per doc, columns from the union
//     of keys (id/title first), volatile/underscore keys deprioritised.
//   - a single object — key/value pairs, one per line.
//   - an array of objects — same column logic as documents.
//   - anything else — falls back to pretty JSON.
//
// Table output is for eyeballs only; piped consumers get json/yaml/minimal.
func renderTable(out *writer, payload []byte) {
	var v any
	if json.Unmarshal(payload, &v) != nil {
		out.outf("%s", string(payload))
		return
	}

	switch t := v.(type) {
	case map[string]any:
		if rows, ok := envelopeRows(t); ok {
			renderRows(out, rows, t)
			return
		}
		// Single-object GET envelopes ({webhook: {...}}, {schema: {...}}): render
		// the inner object's fields, not "webhook  {…json…}" crammed into one cell.
		if obj, ok := singleObjectEnvelope(t); ok {
			renderKV(out, obj)
			return
		}
		renderKV(out, t)
	case []any:
		renderRows(out, t, nil)
	default:
		out.renderRaw(payload)
	}
}

// listEnvelopeKeys are the keys the API's list envelopes carry their rows
// under: query/search use "documents", the tasks endpoints "docs", media
// "assets". The admin/tenancy list commands each carry their own key —
// workspace.ls "workspaces", workspace.project-ls "projects", schema.ls
// "schemas", webhook.ls "webhooks", plugin.ls "plugins", share.ls "shares",
// secret.ls "secrets".
// media.collections uses "collections"; media.collection-assets (and media
// search) carry their hits under "hits"; doc.backlinks uses "backlinks". A key
// missing here is not cosmetic: renderTable falls through to renderKV and crams
// the whole array into ONE key/value cell (and minimal prints a bare "ok") —
// valid output, zero information. Add a list command's envelope key here
// whenever its default_output is "table".
var listEnvelopeKeys = []string{
	"documents", "docs", "assets", "collections", "hits", "backlinks", "revisions",
	"workspaces", "projects", "schemas", "webhooks", "plugins", "shares", "secrets",
}

// envelopeRows finds the row list of a list-envelope payload, trying the known
// envelope keys in order. ok=false when none holds a JSON array.
func envelopeRows(m map[string]any) ([]any, bool) {
	for _, k := range listEnvelopeKeys {
		if rows, ok := m[k].([]any); ok {
			return rows, true
		}
	}
	return nil, false
}

// singleObjectEnvelopeKeys are the keys a single-object GET nests its object
// under — webhook.get → {webhook: {...}}, schema.get → {_schemaVersion, schema:
// {...}}, doc.revision → {revision: {...}}. Unlike doc.get / media.get (which use
// the {result: …} wrapper that unwrapResult already strips), these carry their
// own key, so renderTable otherwise falls to renderKV and crams the whole object
// into one cell. A known list, NOT a heuristic: "first object-valued key" would
// wrongly unwrap a doc whose only non-system field is an object (e.g. a
// portableText body).
var singleObjectEnvelopeKeys = []string{"webhook", "schema", "revision"}

// singleObjectEnvelope returns the inner object of a single-object envelope, if
// the payload carries one of the known keys with a JSON-object value.
func singleObjectEnvelope(m map[string]any) (map[string]any, bool) {
	for _, k := range singleObjectEnvelopeKeys {
		if obj, ok := m[k].(map[string]any); ok {
			return obj, true
		}
	}
	return nil, false
}

// renderKV prints a single object as aligned key: value lines.
func renderKV(out *writer, obj map[string]any) {
	keys := sortedKeys(obj)
	// Width is measured in terminal display cells, not bytes or runes: a CJK
	// ideograph is one rune but occupies two columns, so a rune width would
	// under-pad it and shear the alignment. runewidth.StringWidth accounts for
	// wide (east-asian) and zero-width (combining) runes; FillRight pads to that
	// same cell width. Matches renderRows below.
	width := 0
	for _, k := range keys {
		if n := runewidth.StringWidth(k); n > width {
			width = n
		}
	}
	for _, k := range keys {
		out.outf("%s  %s", runewidth.FillRight(k, width), cellString(obj[k]))
	}
}

// renderRows prints a list of objects as a column table. meta (the enclosing
// envelope) supplies an optional count line.
func renderRows(out *writer, rows []any, meta map[string]any) {
	if len(rows) == 0 {
		out.outf("(no rows)")
		return
	}

	cols := pickColumns(rows)
	// Header. Widths are measured in terminal display cells (runewidth), not
	// bytes or runes: a CJK ideograph is one rune but two columns, and a
	// combining mark is one rune but zero columns — a rune width would shear the
	// alignment for either. The separator repeats "-" (one cell each) to the same
	// cell width, and joinCols pads with FillRight to match.
	widths := make([]int, len(cols))
	for i, c := range cols {
		widths[i] = runewidth.StringWidth(c)
	}
	cells := make([][]string, 0, len(rows))
	for _, r := range rows {
		obj, _ := r.(map[string]any)
		row := make([]string, len(cols))
		for i, c := range cols {
			// Cap each cell in the TABLE so a single long string value (title, url,
			// slug) can't stretch its column past the terminal. renderKV (the
			// single-object key:value view) intentionally shows full values.
			s := truncateCell(cellString(obj[c]), cellMaxRunes)
			row[i] = s
			if n := runewidth.StringWidth(s); n > widths[i] {
				widths[i] = n
			}
		}
		cells = append(cells, row)
	}

	out.outf("%s", joinCols(cols, widths))
	sep := make([]string, len(cols))
	for i := range cols {
		sep[i] = strings.Repeat("-", widths[i])
	}
	out.outf("%s", joinCols(sep, widths))
	for _, row := range cells {
		out.outf("%s", joinCols(row, widths))
	}

	if meta != nil {
		if c, ok := meta["count"]; ok {
			out.outf("")
			out.outf("count: %s", cellString(c))
			// `?count=true` adds the full match count (paginator total).
			if t, ok := meta["total"]; ok {
				out.outf("total: %s", cellString(t))
			}
		}
	}
}

func joinCols(cells []string, widths []int) string {
	parts := make([]string, len(cells))
	for i, c := range cells {
		// FillRight pads to display-cell width (see renderRows) rather than fmt's
		// rune-counting %-*s, so wide/zero-width runes don't shear the columns.
		parts[i] = runewidth.FillRight(c, widths[i])
	}
	return strings.TrimRight(strings.Join(parts, "  "), " ")
}

// pickColumns builds a stable column list from the union of row keys. Identity
// columns (_id/id/title/name) lead; the rest follow alphabetically; underscore
// "system" keys are dropped from the table view to keep it readable (full data
// is one -o json away).
func pickColumns(rows []any) []string {
	seen := map[string]bool{}
	for _, r := range rows {
		if obj, ok := r.(map[string]any); ok {
			for k := range obj {
				seen[k] = true
			}
		}
	}

	lead := []string{}
	for _, k := range []string{"_id", "id", "title", "name", "slug", "status"} {
		if seen[k] {
			lead = append(lead, k)
			delete(seen, k)
		}
	}

	rest := make([]string, 0, len(seen))
	for k := range seen {
		if strings.HasPrefix(k, "_") {
			continue // hide system columns from the table
		}
		rest = append(rest, k)
	}
	sort.Strings(rest)

	cols := append(lead, rest...)
	if len(cols) == 0 {
		// All keys were system keys; show them rather than an empty table.
		for k := range seen {
			cols = append(cols, k)
		}
		sort.Strings(cols)
	}
	return cols
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// cellString renders a scalar/compound value compactly for a table cell.
func cellString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return sanitizeCell(t)
	case float64:
		if t == math.Trunc(t) && t >= math.MinInt64 && t < math.MaxInt64 {
			return fmt.Sprintf("%d", int64(t))
		}
		return fmt.Sprintf("%g", t)
	case bool:
		if t {
			return "true"
		}
		return "false"
	case map[string]any, []any:
		b, _ := json.Marshal(t)
		return truncateCell(string(b), cellMaxRunes)
	default:
		return sanitizeCell(fmt.Sprintf("%v", t))
	}
}

// sanitizeCell keeps a table cell single-line and escape-free. Author-controlled
// data (a title like "Line1\nLine2") would otherwise break row alignment, a tab
// would desync columns, and an ESC sequence would inject raw terminal escapes.
// Whitespace controls collapse to a space; other C0/DEL bytes are dropped.
func sanitizeCell(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || r == '\r' {
			return ' '
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}

// cellMaxRunes caps a table cell's display width so one long value (a title,
// url, or nested blob) can't blow the whole table past the terminal width. Full
// data is always one `-o json` away.
const cellMaxRunes = 60

// truncateCell caps s at max DISPLAY RUNES, appending "..." when it overflows.
// Rune-safe: slicing on a byte boundary (s[:max-3]) would split a multibyte rune
// (æøå, emoji) and emit invalid UTF-8 that renders as a stray �.
func truncateCell(s string, max int) string {
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	// No room for the 3-char ellipsis: return the first max runes bare. Guards
	// max-3 from going negative (a negative slice bound panics); still rune-safe.
	if max < 4 {
		if max < 0 {
			max = 0
		}
		r := []rune(s)
		if len(r) > max {
			r = r[:max]
		}
		return string(r)
	}
	return string([]rune(s)[:max-3]) + "..."
}
