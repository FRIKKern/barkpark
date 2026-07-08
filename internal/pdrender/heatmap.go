package pdrender

import (
	"fmt"
	"math"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── heatmap ──────────────────────────────────────────────────────────────────
//
// The terminal counterpart of a contribution/intensity heatmap (the TUI creative
// slate, W1). It draws a row-major 2D numeric grid where each cell's colour/shade
// encodes value/max ∈ [0,1] — the "GitHub contribution grid" read, in the
// reader/CLI. This is the first block of the slate; W2/W3 build on the CELL
// PRIMITIVE below (heatCell + heatShadeGlyph + heatTrueColor + heatUseTrueColor).
//
// CONTRACT (ratified, pbp-tui-creative-slate):
//
//		heatmap: {cells: [[n…]], max?, ramp?: "shade"|"truecolor", rowLabels?, colLabels?}
//
//	  - cells   row-major 2D numeric array. Non-numeric entries are tolerated and
//	            read as 0 (a gap) so the grid never shifts columns.
//	  - max     normalisation ceiling; default = the max value across cells. All-zero
//	            or empty data is guarded (maxVal falls back to 1 → every cell blank),
//	            so intensity math never divides by zero.
//	  - ramp    "shade" (default) or "truecolor".
//	  - row/colLabels  optional string arrays; rows down the left gutter, cols as a
//	            compact dim header. Omitted gracefully when absent.
//
// AUTO-DEGRADE (load-bearing): the truecolor ramp emits lipgloss 24-bit colour
// ONLY when ctx.Profile == TrueColor. Under NoColor / ANSI16 / ANSI256 the block
// falls back to the SHADE ramp even when ramp:"truecolor" is set — it NEVER emits a
// raw \x1b[38;2;r;g;b sequence into a terminal that can't render it. This mirrors
// code.go's formatterName gate (terminal16m only on an explicit TrueColor profile).
//
// DEGRADE: absent / empty / malformed cells → a dim placeholder line (mirrors the
// taskListRenderer resolvedKeyPresent honesty). Import discipline holds: only
// lipgloss + the stdlib; every document-controlled label passes through
// sanitizeText; every index is clamped so the renderer never panics.
type heatmapRenderer struct{}

func (heatmapRenderer) Render(b Block, ctx RenderCtx) []string {
	grid, ok := parseHeatCells(b.Attrs)
	if !ok {
		return []string{unresolvedPlaceholder(ctx, "heatmap")}
	}

	// Normalisation ceiling: explicit `max` when positive, else the data max;
	// guard all-zero/empty so intensity = value/maxVal never divides by zero.
	maxVal := attrFloat(b.Attrs, "max")
	if maxVal <= 0 {
		maxVal = heatDataMax(grid)
	}
	if maxVal <= 0 {
		maxVal = 1 // all-zero data → every cell reads as the lowest intensity
	}

	ramp := strings.TrimSpace(attrStr(b.Attrs, "ramp"))
	trueColor := heatUseTrueColor(ramp, ctx)

	rowLabels := heatStrings(b.Attrs, "rowLabels")
	colLabels := heatStrings(b.Attrs, "colLabels")

	// Left gutter width = widest row label, capped to a third of the surface.
	labelW := 0
	for _, l := range rowLabels {
		if n := runeWidth(l); n > labelW {
			labelW = n
		}
	}
	cap := clampWidth(ctx.Width) / 3
	if cap < 3 {
		cap = 3
	}
	if labelW > cap {
		labelW = cap
	}

	// Cells that fit: surface − label gutter (label + two spaces).
	gutter := 0
	if labelW > 0 {
		gutter = labelW + 2
	}
	maxCols := clampWidth(ctx.Width) - gutter
	if maxCols < 1 {
		maxCols = 1
	}

	var out []string

	// Compact col-label header (dim), indented past the row-label gutter.
	if len(colLabels) > 0 {
		head := strings.Repeat(" ", gutter) + strings.Join(colLabels, " ")
		out = append(out, firstLine(wrapLines(ctx.Theme.Dim.Render(head), clampWidth(ctx.Width))))
	}

	// The grid: one line per row, `rowLabel  cell cell cell…`.
	for i, row := range grid {
		var sb strings.Builder
		cols := len(row)
		if cols > maxCols {
			cols = maxCols
		}
		for j := 0; j < cols; j++ {
			intensity := row[j] / maxVal
			sb.WriteString(heatCell(intensity, trueColor, ctx))
		}
		line := sb.String()
		if labelW > 0 {
			label := ""
			if i < len(rowLabels) {
				label = rowLabels[i]
			}
			line = ctx.Theme.Dim.Render(padOrTruncate(label, labelW)) + "  " + line
		}
		out = append(out, line)
	}

	// Legend: a low→high intensity-ramp key, itself auto-degrading through heatCell.
	out = append(out, heatLegend(trueColor, ctx))
	return out
}

// ── the cell primitive (reused by W2/W3) ─────────────────────────────────────

// heatShadeLadder is the deterministic, ANSI-plain intensity ramp: blank → faint
// dot → the three quarter-shade blocks → the full block. A byte-stable glyph
// gradient that reads without any colour, so it is also the auto-degrade target.
var heatShadeLadder = []string{" ", "·", "░", "▒", "▓", "█"}

// heatShadeGlyph maps an intensity ∈ [0,1] onto the shade ladder. Exactly 0 is the
// blank floor; any positive intensity lands on at least the faint dot, and 1.0 on
// the full block — so a non-zero cell is always visible.
func heatShadeGlyph(intensity float64) string {
	if intensity <= 0 {
		return heatShadeLadder[0]
	}
	if intensity > 1 {
		intensity = 1
	}
	idx := int(math.Ceil(intensity * float64(len(heatShadeLadder)-1)))
	if idx < 1 {
		idx = 1
	}
	if idx > len(heatShadeLadder)-1 {
		idx = len(heatShadeLadder) - 1
	}
	return heatShadeLadder[idx]
}

// heatTrueColor maps an intensity ∈ [0,1] onto a dark→bright RGB ramp (a GitHub-
// contribution-style green: near-black base → vivid green peak), as a lipgloss
// hex colour. Only reached under a TrueColor profile (see heatUseTrueColor).
func heatTrueColor(intensity float64) lipgloss.Color {
	if intensity < 0 {
		intensity = 0
	}
	if intensity > 1 {
		intensity = 1
	}
	lr, lg, lb := 13.0, 17.0, 23.0  // #0d1117 near-black base
	hr, hg, hb := 57.0, 211.0, 83.0 // #39d353 vivid green peak
	r := int(math.Round(lr + intensity*(hr-lr)))
	g := int(math.Round(lg + intensity*(hg-lg)))
	bl := int(math.Round(lb + intensity*(hb-lb)))
	return lipgloss.Color(fmt.Sprintf("#%02x%02x%02x", r, g, bl))
}

// heatUseTrueColor is the AUTO-DEGRADE gate: truecolor cells are emitted ONLY when
// the author asked for ramp:"truecolor" AND the terminal profile is TrueColor.
// Every lower profile (NoColor / ANSI16 / ANSI256) falls back to the shade ramp,
// so a raw 24-bit escape never reaches a terminal that can't render it. Mirrors
// code.go's formatterName gate (terminal16m only on an explicit TrueColor profile).
func heatUseTrueColor(ramp string, ctx RenderCtx) bool {
	return ramp == "truecolor" && ctx.Profile == TrueColor
}

// heatCell renders one intensity cell. The truecolor path emits a lipgloss-styled
// full block in the interpolated ramp colour; the shade path (also the auto-degrade
// fallback) emits a ladder glyph in the body tone. This is the single primitive the
// grid, the legend, and the later slate blocks all draw through.
func heatCell(intensity float64, trueColor bool, ctx RenderCtx) string {
	if trueColor {
		return lipgloss.NewStyle().Foreground(heatTrueColor(intensity)).Render("█")
	}
	return ctx.Theme.Body.Render(heatShadeGlyph(intensity))
}

// ── small helpers ────────────────────────────────────────────────────────────

// heatLegend draws the low→high intensity key beneath the grid, through the same
// heatCell primitive so it auto-degrades in lockstep with the grid.
func heatLegend(trueColor bool, ctx RenderCtx) string {
	var sb strings.Builder
	for _, in := range []float64{0.15, 0.35, 0.55, 0.75, 1.0} {
		sb.WriteString(heatCell(in, trueColor, ctx))
	}
	return ctx.Theme.Dim.Render("less ") + sb.String() + ctx.Theme.Dim.Render(" more")
}

// parseHeatCells reads the row-major `cells` array into [][]float64. A missing key,
// a non-array value, zero rows, or zero total cells → ok=false (the placeholder
// degrade). Non-numeric cell entries are tolerated as 0 so the grid keeps its shape.
func parseHeatCells(m map[string]any) (grid [][]float64, ok bool) {
	rows := attrSlice(m, "cells")
	if rows == nil {
		return nil, false
	}
	total := 0
	for _, r := range rows {
		cells, isRow := r.([]any)
		if !isRow {
			// A non-array row is skipped (keeps a malformed row from crashing the
			// grid); it simply contributes no line.
			grid = append(grid, nil)
			continue
		}
		row := make([]float64, len(cells))
		for j, c := range cells {
			if f, okf := toFloat(c); okf {
				row[j] = f
			}
			total++
		}
		grid = append(grid, row)
	}
	if len(grid) == 0 || total == 0 {
		return nil, false
	}
	return grid, true
}

// heatDataMax returns the largest cell value across the grid (0 when empty/all
// non-positive), the default normalisation ceiling.
func heatDataMax(grid [][]float64) float64 {
	max := 0.0
	for _, row := range grid {
		for _, v := range row {
			if v > max {
				max = v
			}
		}
	}
	return max
}

// heatStrings reads a string array field (row/col labels), trimming and sanitizing
// each entry. Missing/empty → nil.
func heatStrings(m map[string]any, key string) []string {
	raw := attrSlice(m, key)
	if raw == nil {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, el := range raw {
		out = append(out, sanitizeText(strings.TrimSpace(toStr(el))))
	}
	return out
}
