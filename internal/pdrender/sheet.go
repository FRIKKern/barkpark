package pdrender

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	ltable "github.com/charmbracelet/lipgloss/table"
	"github.com/charmbracelet/x/ansi"
)

// ── sheet ──────────────────────────────────────────────────────────────────
// PdSheet is a spreadsheet-flavoured grid. JSON shape:
//
//	{
//	  "kind":       "PdSheet",
//	  "head":       ["Col A", "Col B"],   // optional header row
//	  "rows":       [["a1","b1"], ...],
//	  "col_widths": [10, 20]              // optional per-column char widths
//	}
//
// When col_widths is present each cell is padded/truncated to exactly that
// many visible characters BEFORE the table sees it, so lipgloss/table's
// auto-sizer honours the intent. When absent the table auto-sizes by content
// exactly like PdTable does.
//
// Head row treatment mirrors PdTable: UPPERCASE + muted-bold (opt-in; renders
// only when `head` is non-empty). Border and layout use the same NormalBorder
// + BorderStyle(ctx.Theme.Rule) pattern as PdTable for visual consistency.
type sheetRenderer struct{ ir InlineRenderer }

// ── raw "sheet" embed blocks ────────────────────────────────────────────────
// A paper embeds a sheet document as {"type":"sheet","ref":…,"snapshot":{…}} —
// the raw authored shape the API serves. The snapshot carries the same dense
// grid PdSheet consumes (head/rows), nested one level down, so this adapter
// lifts snapshot.head/snapshot.rows onto a PdSheet-shaped block and delegates.
//
// Documented losses (values-first fidelity):
//   - snapshot "merges" are ignored — a merged range renders as its
//     anchor-cell value (covered cells are "" in the dense grid); there is
//     no colspan in a character grid.
//   - snapshot "styles" (bold/italic/background/align) do not travel.
//   - snapshot "col_widths" are PIXEL hints from the Studio grid; PdSheet
//     widths are character counts, so px values are dropped and columns
//     auto-size by content.
//
// A clipped snapshot (`"truncated": true`, stamped by Core when the sheet
// exceeds the position cap) appends a muted partial-data note after the grid
// so a TUI reader is never silently missing rows — the same guarantee walk.ex
// (`sheet_truncation_note/3`) and web (`truncationNotice`) already give. The
// note string is byte-matched to those surfaces so the note itself stays parity-consistent.
//
// supportedSheetSnapshotSV pins the snapshot schema version this adapter was
// written against — the Elixir source-of-truth is Core's @snapshot_schema_version
// (api/lib/barkpark/plugins/sheets/core.ex; policy: bump on ANY snapshot shape or
// value-string change). This adapter lifts snapshot.head/snapshot.rows with NO
// version awareness, so a Core sv bump could silently change the grid the TUI
// draws. The golden-parity fixture stamps its own "sv"; sheet_golden_test.go
// asserts fixture.sv == this const, so a bump reds the Go gate here and forces a
// human to re-examine this lift before the version drifts.
const supportedSheetSnapshotSV = 2

type sheetBlockRenderer struct{ sr sheetRenderer }

func (sb sheetBlockRenderer) Render(b Block, ctx RenderCtx) []string {
	attrs := map[string]any{}
	truncated := false
	if snap, ok := b.Attrs["snapshot"].(map[string]any); ok {
		attrs["head"] = snap["head"]
		attrs["rows"] = snap["rows"]
		truncated, _ = snap["truncated"].(bool)
	}
	lines := sb.sr.Render(Block{Type: "PdSheet", Attrs: attrs}, ctx)
	if truncated {
		shown := len(attrSlice(attrs, "rows"))
		note := ctx.Theme.Dim.Render(fmt.Sprintf("Sheet truncated — showing the first %d rows", shown))
		lines = append(lines, note)
	}
	return lines
}

func (sr sheetRenderer) Render(b Block, ctx RenderCtx) []string {
	head := attrSlice(b.Attrs, "head")
	rows := attrSlice(b.Attrs, "rows")
	colWidths := sr.readColWidths(b.Attrs)

	t := ltable.New().
		Width(clampWidth(ctx.Width)).
		Wrap(false). // sheet cells are fixed-width — no re-wrap
		Border(lipgloss.NormalBorder()).
		BorderStyle(ctx.Theme.Rule)

	hasHead := len(head) > 0
	if hasHead {
		cells := make([]string, 0, len(head))
		for i, c := range head {
			txt := ansi.Strip(sr.ir.Inline([]any{c}, ctx))
			txt = strings.ToUpper(txt)
			if w := sr.colWidth(colWidths, i); w > 0 {
				txt = padOrTruncate(txt, w)
			}
			cells = append(cells, txt)
		}
		t.Headers(cells...)
	}

	addedRows := 0
	for _, r := range rows {
		cells := sr.rowCells(r, colWidths, ctx)
		if len(cells) == 0 {
			continue // skip empty rows — ltable panics on zero-column rows
		}
		t.Row(cells...)
		addedRows++
	}

	// Guard: no columns at all (no head and no non-empty rows) → empty output.
	if !hasHead && addedRows == 0 {
		return []string{""}
	}

	headerStyle := ctx.Theme.Dim.Bold(true)
	bodyStyle := ctx.Theme.Body
	t.StyleFunc(func(row, col int) lipgloss.Style {
		if row == ltable.HeaderRow {
			return headerStyle.Padding(0, 1)
		}
		return bodyStyle.Padding(0, 1)
	})

	return strings.Split(t.Render(), "\n")
}

// rowCells converts a row ([]any or scalar) to []string, applying col_widths.
func (sr sheetRenderer) rowCells(row any, colWidths []int, ctx RenderCtx) []string {
	cells, ok := row.([]any)
	if !ok {
		return []string{sr.cellString(row, 0, colWidths, ctx)}
	}
	out := make([]string, 0, len(cells))
	for i, c := range cells {
		out = append(out, sr.cellString(c, i, colWidths, ctx))
	}
	return out
}

// cellString renders one cell and applies the column width hint if present.
func (sr sheetRenderer) cellString(cell any, col int, colWidths []int, ctx RenderCtx) string {
	var txt string
	switch v := cell.(type) {
	case []any:
		txt = sr.ir.Inline(v, ctx)
	case nil:
		txt = ""
	default:
		txt = sr.ir.Inline([]any{v}, ctx)
	}
	if w := sr.colWidth(colWidths, col); w > 0 {
		txt = padOrTruncate(ansi.Strip(txt), w)
	}
	return txt
}

// colWidth returns the declared width for column col, or 0 (auto) when absent.
func (sr sheetRenderer) colWidth(widths []int, col int) int {
	if col < len(widths) {
		return widths[col]
	}
	return 0
}

// maxColWidth caps an author-declared column width. Widths flow into
// padOrTruncate → strings.Repeat(" ", w-vis), so an unbounded value (e.g.
// col_widths:["1000000000000000000"]) would attempt a ~1e18-byte allocation
// and OOM/panic on render. No real terminal column is this wide, so clamp.
const maxColWidth = 1000

// readColWidths extracts the optional "col_widths" array as []int.
func (sr sheetRenderer) readColWidths(m map[string]any) []int {
	raw := attrSlice(m, "col_widths")
	if len(raw) == 0 {
		return nil
	}
	out := make([]int, 0, len(raw))
	for _, v := range raw {
		w := attrInt(map[string]any{"w": v}, "w", 0)
		if w > maxColWidth {
			w = maxColWidth
		}
		out = append(out, w)
	}
	return out
}

// padOrTruncate pads s with spaces to exactly w visible characters, or
// truncates with a "…" ellipsis if s is wider than w. Operates on plain
// (non-ANSI) strings — callers must strip ANSI before calling when widths
// matter for alignment.
func padOrTruncate(s string, w int) string {
	if w <= 0 {
		return s
	}
	vis := lipgloss.Width(s)
	switch {
	case vis < w:
		return s + strings.Repeat(" ", w-vis)
	case vis > w:
		if w <= 1 {
			return "…"
		}
		// Truncate to w-1 visible display columns + ellipsis. Accumulate by
		// display width (lipgloss.Width), not rune count, so full-width CJK /
		// emoji runes (width 2) don't overflow the column.
		runes := []rune(s)
		cut := 0
		width := 0
		for _, r := range runes {
			rw := lipgloss.Width(string(r))
			if width+rw > w-1 {
				break
			}
			cut++
			width += rw
		}
		return string(runes[:cut]) + "…"
	default:
		return s
	}
}
