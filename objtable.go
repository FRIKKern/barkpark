package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  OBJECT-ARRAY TABLE                                                      ║
// ║                                                                          ║
// ║  A read-only array of FLAT objects (every value a scalar) renders as a   ║
// ║  compact aligned table — Sanity shows structured rows, a raw JSON clamp  ║
// ║  buried them. Columns are the union of keys (first-seen order from the   ║
// ║  first row, extras sorted after), widths fit the data within the box,    ║
// ║  rows clamp at 6 with a "+N more" line. Anything non-conforming (mixed   ║
// ║  shapes, nested values, non-objects) reports ok=false and the caller     ║
// ║  keeps today's pretty-JSON fallback — the table never guesses.           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

const objTableMaxRows = 6

// objectTable renders raw JSON as table lines when it is an array of flat
// objects. ok=false means "not table-shaped — use the JSON fallback".
func objectTable(raw json.RawMessage, width int) ([]string, bool) {
	var rows []map[string]any
	if json.Unmarshal(raw, &rows) != nil || len(rows) == 0 {
		return nil, false
	}

	// Columns: first row's keys (sorted for determinism), then any extras
	// from later rows, sorted. Every value must be a scalar.
	colSet := map[string]bool{}
	var cols []string
	addCols := func(r map[string]any) {
		var ks []string
		for k := range r {
			if !colSet[k] {
				ks = append(ks, k)
				colSet[k] = true
			}
		}
		sort.Strings(ks)
		cols = append(cols, ks...)
	}
	for _, r := range rows {
		if r == nil {
			return nil, false
		}
		for _, v := range r {
			switch v.(type) {
			case string, float64, bool, nil:
			default:
				return nil, false // nested array/object — not table-shaped
			}
		}
		addCols(r)
	}
	if len(cols) == 0 {
		return nil, false
	}

	cell := func(r map[string]any, k string) string {
		v, ok := r[k]
		if !ok || v == nil {
			return ""
		}
		switch t := v.(type) {
		case string:
			return t
		case bool:
			return fmt.Sprint(t)
		case float64:
			if t == float64(int64(t)) {
				return fmt.Sprint(int64(t))
			}
			return fmt.Sprint(t)
		}
		return ""
	}

	// Column widths fit header + data, then shrink to the box if needed.
	w := make([]int, len(cols))
	for i, c := range cols {
		w[i] = lipgloss.Width(c)
	}
	shown := rows
	if len(shown) > objTableMaxRows {
		shown = shown[:objTableMaxRows]
	}
	for _, r := range shown {
		for i, c := range cols {
			if l := lipgloss.Width(cell(r, c)); l > w[i] {
				w[i] = l
			}
		}
	}
	// Total width budget: per-column cap so wide values don't blow the box.
	budget := width - 2*(len(cols)-1) // "  " separators
	if budget < len(cols)*3 {
		return nil, false // box too narrow to be a table
	}
	for total := sum(w); total > budget; total = sum(w) {
		// Trim the widest column until it fits (floor 3).
		widest := 0
		for i := range w {
			if w[i] > w[widest] {
				widest = i
			}
		}
		if w[widest] <= 3 {
			return nil, false
		}
		w[widest]--
	}

	pad := func(s string, n int) string {
		if lipgloss.Width(s) > n {
			if n <= 1 {
				return ansi.Truncate(s, n, "")
			}
			return ansi.Truncate(s, n, "…")
		}
		return s + strings.Repeat(" ", n-lipgloss.Width(s))
	}

	var lines []string
	var hdr []string
	for i, c := range cols {
		hdr = append(hdr, pad(strings.ToUpper(c), w[i]))
	}
	lines = append(lines, strings.Join(hdr, "  "))
	for _, r := range shown {
		var cells []string
		for i, c := range cols {
			cells = append(cells, pad(cell(r, c), w[i]))
		}
		lines = append(lines, strings.Join(cells, "  "))
	}
	if len(rows) > objTableMaxRows {
		lines = append(lines, fmt.Sprintf("… +%d more rows", len(rows)-objTableMaxRows))
	}
	return lines, true
}

func sum(xs []int) int {
	t := 0
	for _, x := range xs {
		t += x
	}
	return t
}
