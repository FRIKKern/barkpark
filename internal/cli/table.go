package cli

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
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
// "schemas", webhook.ls "webhooks", plugin.ls "plugins", share.ls "shares".
// A key missing here is not cosmetic: renderTable falls through to renderKV and
// crams the whole array into ONE key/value cell (and minimal prints a bare
// "ok") — valid output, zero information. Add a list command's envelope key
// here whenever its default_output is "table".
var listEnvelopeKeys = []string{
	"documents", "docs", "assets",
	"workspaces", "projects", "schemas", "webhooks", "plugins", "shares",
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

// renderKV prints a single object as aligned key: value lines.
func renderKV(out *writer, obj map[string]any) {
	keys := sortedKeys(obj)
	width := 0
	for _, k := range keys {
		if len(k) > width {
			width = len(k)
		}
	}
	for _, k := range keys {
		out.outf("%-*s  %s", width, k, cellString(obj[k]))
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
	// Header.
	widths := make([]int, len(cols))
	for i, c := range cols {
		widths[i] = len(c)
	}
	cells := make([][]string, 0, len(rows))
	for _, r := range rows {
		obj, _ := r.(map[string]any)
		row := make([]string, len(cols))
		for i, c := range cols {
			s := cellString(obj[c])
			row[i] = s
			if len(s) > widths[i] {
				widths[i] = len(s)
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
		parts[i] = fmt.Sprintf("%-*s", widths[i], c)
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
		return t
	case float64:
		if t == float64(int64(t)) {
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
		s := string(b)
		if len(s) > 60 {
			s = s[:57] + "..."
		}
		return s
	default:
		return fmt.Sprintf("%v", t)
	}
}
