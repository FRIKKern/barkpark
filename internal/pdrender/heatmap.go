package pdrender

import (
	"fmt"
	"math"
	"sort"
	"strconv"
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
// CONTRACT (ratified, pbp-tui-creative-slate; amended pbp-slate2-heat-family —
// calendar + matrix marginals/values are MODES of THIS one renderer, never siblings):
//
//		heatmap: {cells: [[n…]], max?, ramp?, mode?: "calendar",
//		          marginals?: bool, values?: bool, rowLabels?, colLabels?}
//
//	  - cells   row-major 2D numeric array. Non-numeric entries are tolerated and
//	            read as 0 (a gap) so the grid never shifts columns.
//	  - max     normalisation ceiling (LEGACY grid only); default = the max value
//	            across cells. All-zero or empty data is guarded (maxVal falls back to
//	            1 → every cell blank), so intensity math never divides by zero. The
//	            new modes bin by QUANTILE (HeatQuantileBins), not value/max, so months
//	            of activity don't flatten off one spike — `max` is ignored there.
//	  - ramp    "shade" (default) or "truecolor" — the LEGACY grid's 2-endpoint
//	            base→peak interpolation. The new modes always dual-encode (shade glyph
//	            UNDER GenHeatRamp colour) and ignore `ramp`.
//	  - mode    "calendar" ⇒ a GitHub-style contribution calendar: cells are
//	            day-rows × week-cols (≤7 rows). 38 weeks is the 80-col BUDGET POINT
//	            (a 4-char day gutter + 38×2-char cells = 80); it is not a ceiling —
//	            the calendar renders as many weeks as the snapshot carries and the
//	            surface can hold (a full 53-week year fits at ≥110 cols). colLabels
//	            are per-week month labels stamped along the top; rowLabels are day
//	            letters in the gutter. Narrower widths drop the OLDEST (leftmost)
//	            whole weeks, never squash.
//	  - marginals  (matrix, opt-in) ⇒ append a Σ row of column sums and a Σ column of
//	            row sums, with the grand total in the corner.
//	  - values  (matrix, opt-in) ⇒ print the exact right-aligned cell value instead of
//	            a pure shade glyph (colour still reinforces the quantile bin). Both
//	            marginals and values engage the quantile dual-encode cell path; with
//	            NEITHER set the legacy grid renders byte-identically.
//	  - row/colLabels  optional string arrays; rows down the left gutter, cols as a
//	            compact dim header when short. Long labels wrap or move to a numbered
//	            legend; authored label text is never discarded. Omitted gracefully
//	            when absent.
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

	// MODES (pbp-slate2-heat-family): calendar and matrix marginals/values are
	// rendered by dedicated helpers on THIS renderer (never registered siblings).
	// They dual-encode through the quantile bins; the legacy grid below is reached
	// ONLY when no mode and no matrix extras are set, so its goldens stay byte-stable.
	if strings.TrimSpace(attrStr(b.Attrs, "mode")) == "calendar" {
		return heatRenderCalendar(grid, b.Attrs, ctx)
	}
	if attrBool(b.Attrs, "marginals") || attrBool(b.Attrs, "values") {
		return heatRenderMatrixExtras(grid, b.Attrs, ctx)
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

	// Per-column cell width. Without colLabels every cell is the classic 1-glyph
	// contribution square (byte-stable with the pre-label render). WITH colLabels
	// each column widens to its label (glyph repeated, columns space-separated)
	// so the header actually sits over its cells — 1-glyph cells under multi-char
	// labels drifted apart after the first column.
	colW := func(j int) int {
		if j < len(colLabels) {
			if w := runeWidth(colLabels[j]); w > 1 {
				return w
			}
		}
		return 1
	}
	colSep := ""
	if len(colLabels) > 0 {
		colSep = " "
	}

	// Columns that fit: accumulate per-column width + separator against the
	// space left of the row-label gutter.
	fitCols := func(n int) int {
		used, fit := 0, 0
		for j := 0; j < n; j++ {
			w := colW(j)
			if j > 0 {
				w += len(colSep)
			}
			if used+w > maxCols {
				break
			}
			used += w
			fit++
		}
		if fit < 1 {
			fit = 1
		}
		return fit
	}

	// Compact col-label header (dim), each label padded to its column.
	if len(colLabels) > 0 {
		cols := fitCols(len(colLabels))
		padded := make([]string, 0, cols)
		for j := 0; j < cols; j++ {
			padded = append(padded, padOrTruncate(colLabels[j], colW(j)))
		}
		head := strings.Repeat(" ", gutter) + strings.Join(padded, colSep)
		out = append(out, firstLine(wrapLines(ctx.Theme.Dim.Render(head), clampWidth(ctx.Width))))
	}

	// The grid: one line per row, `rowLabel  cell cell cell…`.
	for i, row := range grid {
		var sb strings.Builder
		cols := fitCols(len(row))
		for j := 0; j < cols; j++ {
			intensity := row[j] / maxVal
			if j > 0 {
				sb.WriteString(colSep)
			}
			sb.WriteString(heatCellN(intensity, colW(j), trueColor, ctx))
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
	r := int(math.Round(heatRampLoR + intensity*(heatRampHiR-heatRampLoR)))
	g := int(math.Round(heatRampLoG + intensity*(heatRampHiG-heatRampLoG)))
	bl := int(math.Round(heatRampLoB + intensity*(heatRampHiB-heatRampLoB)))
	return lipgloss.Color(fmt.Sprintf("#%02x%02x%02x", r, g, bl))
}

// heatRamp{Lo,Hi}{R,G,B} are the parsed RGB channels of the generated gradient
// endpoints (GenHeatmapBase #0d1117 near-black base → GenHeatmapPeak #39d353 vivid
// green peak, design/tokens.json color.pdrenderHeatmap). Parsed once at init so
// heatTrueColor interpolates without re-parsing per cell; byte-identical to the
// former inline 13,17,23 / 57,211,83 literals.
var (
	heatRampLoR, heatRampLoG, heatRampLoB = heatHexRGB(GenHeatmapBase)
	heatRampHiR, heatRampHiG, heatRampHiB = heatHexRGB(GenHeatmapPeak)
)

// heatHexRGB parses a "#rrggbb" string into float RGB channels (0–255).
func heatHexRGB(hex string) (r, g, b float64) {
	n, _ := strconv.ParseUint(strings.TrimPrefix(hex, "#"), 16, 32)
	return float64(n >> 16 & 0xff), float64(n >> 8 & 0xff), float64(n & 0xff)
}

// heatUseTrueColor is the AUTO-DEGRADE gate: truecolor cells are emitted ONLY when
// the author asked for ramp:"truecolor" AND the terminal profile is TrueColor.
// Every lower profile (NoColor / ANSI16 / ANSI256) falls back to the shade ramp,
// so a raw 24-bit escape never reaches a terminal that can't render it. Mirrors
// code.go's formatterName gate (terminal16m only on an explicit TrueColor profile).
func heatUseTrueColor(ramp string, ctx RenderCtx) bool {
	return ramp == "truecolor" && ctx.Profile == TrueColor
}

// heatCell renders one intensity cell. Both paths paint the SAME shade-ladder glyph
// (heatShadeGlyph) so the datum lives in geometry, not colour — the truecolor path
// just layers the interpolated ramp colour on top of that glyph as REINFORCEMENT
// (dual-encode), while the shade path (also the auto-degrade fallback) tones it with
// the body colour. Because the glyph is identical, ansi.Strip(truecolor) equals the
// NoColor render, so the truecolor grid satisfies the detail-ceiling strip law. This
// is the single primitive the grid, the legend, and the later slate blocks draw through.
func heatCell(intensity float64, trueColor bool, ctx RenderCtx) string {
	if trueColor {
		return lipgloss.NewStyle().Foreground(heatTrueColor(intensity)).Render(heatShadeGlyph(intensity))
	}
	return ctx.Theme.Body.Render(heatShadeGlyph(intensity))
}

// heatCellN is heatCell widened to a labeled column: the cell glyph repeated w
// times under one style run. w<=1 is exactly heatCell.
func heatCellN(intensity float64, w int, trueColor bool, ctx RenderCtx) string {
	if w <= 1 {
		return heatCell(intensity, trueColor, ctx)
	}
	if trueColor {
		return lipgloss.NewStyle().Foreground(heatTrueColor(intensity)).Render(strings.Repeat(heatShadeGlyph(intensity), w))
	}
	return ctx.Theme.Body.Render(strings.Repeat(heatShadeGlyph(intensity), w))
}

// ── quantile dual-encode (calendar + matrix extras) ──────────────────────────

// heatDualLadder is the 4-step shade ramp the new modes paint, matched 1:1 to
// GenHeatRamp — the top four glyphs of heatShadeLadder (light→full). Bin k∈0..3
// selects both the glyph and its colour, so the datum survives an ANSI strip.
var heatDualLadder = []string{"░", "▒", "▓", "█"}

// heatZeroGlyph is the empty-cell mark: a dim middle dot (U+00B7). Never the
// lower-one-eighth block ▁ (reads as data), never blank (loses the grid), never
// lipgloss.Faint (the wasm applySGR drops SGR 2, so a faint cell would vanish).
const heatZeroGlyph = "·"

// HeatQuantileBins bins every cell into 0..3 by QUANTILE over the NONZERO values
// (zero cells get -1, the special "dim dot" bin). Quantile binning is load-bearing:
// a linear value/max ramp flattens months of ordinary activity into the floor when
// one spike owns the max — quartiles spread the mass so the whole grid reads. It
// owns the binning for BOTH the glyph ladder and the GenHeatRamp colour, so shade
// and hue can never disagree about a cell's intensity.
//
// @canonical capability:heat-quantile-bin aka:quantile,binning,heat-ramp doc:docs/contracts/tui-render-doctrine.md
func HeatQuantileBins(cells [][]float64) [][]int {
	var nz []float64
	for _, row := range cells {
		for _, v := range row {
			if v > 0 {
				nz = append(nz, v)
			}
		}
	}
	sort.Float64s(nz)
	// Nearest-rank quartile thresholds over the sorted nonzero values. With a
	// single distinct value all thresholds coincide → every nonzero cell is bin 0
	// (a uniform grid is genuinely uniform; there is no distribution to spread).
	q := func(p float64) float64 {
		if len(nz) == 0 {
			return 0
		}
		idx := int(math.Ceil(p*float64(len(nz)))) - 1
		if idx < 0 {
			idx = 0
		}
		if idx >= len(nz) {
			idx = len(nz) - 1
		}
		return nz[idx]
	}
	q1, q2, q3 := q(0.25), q(0.50), q(0.75)
	out := make([][]int, len(cells))
	for i, row := range cells {
		out[i] = make([]int, len(row))
		for j, v := range row {
			switch {
			case v <= 0:
				out[i][j] = -1
			case v <= q1:
				out[i][j] = 0
			case v <= q2:
				out[i][j] = 1
			case v <= q3:
				out[i][j] = 2
			default:
				out[i][j] = 3
			}
		}
	}
	return out
}

// heatDualCell renders one quantile-binned cell w columns wide. Bin -1 (zero) is
// the dim middle dot; bins 0..3 repeat the ladder glyph with GenHeatRamp[k] as
// Foreground REINFORCEMENT — but only at Profile ≥ ANSI256 (lipgloss auto-degrades
// the truecolor hex to the 256-palette; NoColor / ANSI16 emit the glyph alone, and
// the ANSI-stripped render is still a complete artifact). The colour never carries
// the datum by itself — that is the detail-ceiling readability line.
func heatDualCell(bin, w int, ctx RenderCtx) string {
	if w < 1 {
		w = 1
	}
	if bin < 0 {
		return ctx.Theme.Dim.Render(padOrTruncate(heatZeroGlyph, w))
	}
	if bin > len(heatDualLadder)-1 {
		bin = len(heatDualLadder) - 1
	}
	glyph := strings.Repeat(heatDualLadder[bin], w)
	if ctx.Profile >= ANSI256 {
		return lipgloss.NewStyle().Foreground(GenHeatRamp[bin]).Render(glyph)
	}
	return ctx.Theme.Body.Render(glyph)
}

// ── calendar mode ────────────────────────────────────────────────────────────

// heatCalGutter is the fixed day-letter gutter for the calendar. 4 + 38×2 = 80,
// so 38 weeks is the 80-col BUDGET POINT with 2-col cells — not a ceiling: wider
// terminals render up to what the snapshot carries (a full 53-week year at ≥110
// cols), narrower ones drop the oldest whole weeks (see heatRenderCalendar).
const heatCalGutter = 4

// heatCalCellW is the per-week cell width (a 2-col contribution square).
const heatCalCellW = 2

// heatRenderCalendar draws a GitHub-style contribution calendar: day-rows ×
// week-cols, quantile dual-encoded. Weeks run old→new left→right; when the surface
// can't hold every week the OLDEST (leftmost) whole weeks are dropped, never
// squashed. colLabels are per-week month labels stamped along the top; rowLabels
// are day letters down the gutter.
func heatRenderCalendar(grid [][]float64, attrs map[string]any, ctx RenderCtx) []string {
	bins := HeatQuantileBins(grid)
	rowLabels := heatStrings(attrs, "rowLabels")
	colLabels := heatStrings(attrs, "colLabels")

	// Widest week count across day-rows (rows may be ragged; treat missing as gap).
	weeks := 0
	for _, row := range grid {
		if len(row) > weeks {
			weeks = len(row)
		}
	}
	if weeks == 0 {
		return []string{unresolvedPlaceholder(ctx, "heatmap")}
	}

	// Weeks that fit right of the gutter; drop the OLDEST (leftmost) whole weeks.
	avail := clampWidth(ctx.Width) - heatCalGutter
	if avail < heatCalCellW {
		avail = heatCalCellW
	}
	fit := avail / heatCalCellW
	if fit < 1 {
		fit = 1
	}
	start := 0
	if weeks > fit {
		start = weeks - fit // keep the newest `fit` weeks
	}

	var out []string

	// Month header: a full-width rune buffer, each non-empty per-week label stamped
	// at its column, skipped if it would collide with an already-stamped label.
	if len(colLabels) > 0 {
		width := heatCalGutter + (weeks-start)*heatCalCellW
		buf := []rune(strings.Repeat(" ", width))
		lastEnd := -1
		for w := start; w < weeks; w++ {
			if w >= len(colLabels) {
				break
			}
			lbl := strings.TrimSpace(colLabels[w])
			if lbl == "" {
				continue
			}
			pos := heatCalGutter + (w-start)*heatCalCellW
			if pos <= lastEnd {
				continue // would overwrite the previous month's letters
			}
			for k, r := range []rune(lbl) {
				if pos+k < len(buf) {
					buf[pos+k] = r
				}
			}
			lastEnd = pos + len([]rune(lbl))
		}
		out = append(out, firstLine(wrapLines(ctx.Theme.Dim.Render(strings.TrimRight(string(buf), " ")), clampWidth(ctx.Width))))
	}

	// One line per day-row: gutter day letter + a 2-col cell per surviving week.
	for i := range grid {
		var sb strings.Builder
		label := ""
		if i < len(rowLabels) {
			label = rowLabels[i]
		}
		sb.WriteString(ctx.Theme.Dim.Render(padOrTruncate(label, heatCalGutter)))
		for w := start; w < weeks; w++ {
			bin := -1
			if w < len(bins[i]) {
				bin = bins[i][w]
			}
			sb.WriteString(heatDualCell(bin, heatCalCellW, ctx))
		}
		out = append(out, sb.String())
	}

	out = append(out, heatDualLegend(ctx))
	return out
}

// ── matrix marginals / values ────────────────────────────────────────────────

// heatRenderMatrixExtras draws the small rows×cols heat matrix with the opt-in
// marginals (Σ row + Σ column of sums, grand total in the corner) and/or exact
// values. Cells dual-encode through the quantile bins; with values:true each cell
// shows its right-aligned number (colour still reinforcing the bin). Long column
// labels move into a numbered, wrapped legend; long row labels wrap in their
// gutter. No authored label is replaced with an ellipsis. Reached only when
// marginals||values is set, so the legacy grid stays byte-identical.
func heatRenderMatrixExtras(grid [][]float64, attrs map[string]any, ctx RenderCtx) []string {
	bins := HeatQuantileBins(grid)
	showVals := attrBool(attrs, "values")
	showMarg := attrBool(attrs, "marginals")

	rowLabels := heatStrings(attrs, "rowLabels")
	colLabels := heatStrings(attrs, "colLabels")

	// Column count = widest row.
	nCols := 0
	for _, row := range grid {
		if len(row) > nCols {
			nCols = len(row)
		}
	}
	if nCols == 0 {
		return []string{unresolvedPlaceholder(ctx, "heatmap")}
	}

	// Row / column sums for the marginals.
	rowSum := make([]float64, len(grid))
	colSum := make([]float64, nCols)
	grand := 0.0
	for i, row := range grid {
		for j := 0; j < nCols; j++ {
			if j < len(row) {
				rowSum[i] += row[j]
				colSum[j] += row[j]
				grand += row[j]
			}
		}
	}

	// Left gutter = widest row label, capped to a third of the surface. A label
	// beyond the cap wraps onto continuation rows rather than being truncated.
	labelW := 0
	for _, l := range rowLabels {
		if n := runeWidth(l); n > labelW {
			labelW = n
		}
	}
	if showMarg && labelW < 1 {
		labelW = 1
	}
	labelCap := clampWidth(ctx.Width) / 3
	if labelCap < 4 {
		labelCap = 4
	}
	if labelCap > 24 {
		labelCap = 24
	}
	if labelW > labelCap {
		labelW = labelCap
	}

	// Labels wider than the historical four-cell header move into a complete
	// numbered legend. The matrix header then uses those compact indices, keeping
	// the data grid narrow without sacrificing the authored vocabulary.
	numberedCols := false
	for j := 0; j < nCols && j < len(colLabels); j++ {
		if runeWidth(colLabels[j]) > 4 {
			numberedCols = true
			break
		}
	}

	// Per-column width: enough for the compact header (label or numbered index)
	// and for the widest value in the column (incl. its Σ sum) when values are
	// shown; else 1 for a pure shade cell.
	colW := make([]int, nCols)
	for j := 0; j < nCols; j++ {
		w := 1
		if j < len(colLabels) {
			header := colLabels[j]
			if numberedCols {
				header = strconv.Itoa(j + 1)
			} else {
				// Preserve the established four-cell compact header geometry for
				// already-short labels.
				w = 4
			}
			if n := runeWidth(header); n > w {
				w = n
			}
		}
		if showVals {
			for i := range grid {
				if j < len(grid[i]) {
					if n := len(heatNum(grid[i][j])); n > w {
						w = n
					}
				}
			}
			if showMarg {
				if n := len(heatNum(colSum[j])); n > w {
					w = n
				}
			}
		}
		colW[j] = w
	}
	// Σ marginal column width (row sums + grand total), values only.
	margW := 1
	if showVals {
		margW = runeWidth("Σ")
		for _, s := range rowSum {
			if n := len(heatNum(s)); n > margW {
				margW = n
			}
		}
		if n := len(heatNum(grand)); n > margW {
			margW = n
		}
	}

	gutter := 0
	if labelW > 0 {
		gutter = labelW + 2
	}
	matrixW := gutter
	for _, width := range colW {
		matrixW += width
	}
	if nCols > 1 {
		matrixW += nCols - 1
	}
	if showMarg {
		matrixW += 2 + margW
	}
	if matrixW > clampWidth(ctx.Width) {
		return heatMatrixLedger(
			grid, rowLabels, colLabels, rowSum, colSum, grand, showVals, showMarg, ctx,
		)
	}

	var out []string

	if numberedCols {
		legend := make([]string, 0, nCols)
		for j := 0; j < nCols && j < len(colLabels); j++ {
			legend = append(legend, strconv.Itoa(j+1)+" "+colLabels[j])
		}
		out = append(
			out,
			hardBoundDisplayLines(
				[]string{ctx.Theme.Dim.Render("Columns: " + strings.Join(legend, " · "))},
				clampWidth(ctx.Width),
			)...,
		)
	}

	// Header row: col labels (dim), plus a Σ header over the marginal column.
	if len(colLabels) > 0 || showMarg {
		var sb strings.Builder
		sb.WriteString(strings.Repeat(" ", gutter))
		for j := 0; j < nCols; j++ {
			lbl := ""
			if j < len(colLabels) {
				if numberedCols {
					lbl = strconv.Itoa(j + 1)
				} else {
					lbl = padOrTruncate(colLabels[j], 4)
				}
			}
			if j > 0 {
				sb.WriteString(" ")
			}
			sb.WriteString(heatPadLeft(lbl, colW[j]))
		}
		if showMarg {
			sb.WriteString("  ")
			sb.WriteString(heatPadLeft("Σ", margW))
		}
		out = append(out, ctx.Theme.Dim.Render(sb.String()))
	}

	// Body rows: wrapped label gutter + a cell per column + optional Σ row-sum.
	// Data sits on the label's final continuation row so the full label reads
	// uninterrupted before its values.
	for i, row := range grid {
		var data strings.Builder
		for j := 0; j < nCols; j++ {
			if j > 0 {
				data.WriteString(" ")
			}
			bin := -1
			var v float64
			if j < len(row) {
				bin = bins[i][j]
				v = row[j]
			}
			data.WriteString(heatMatrixCell(bin, v, colW[j], showVals, ctx))
		}
		if showMarg {
			data.WriteString("  ")
			data.WriteString(ctx.Theme.Body.Render(heatPadLeft(heatSumField(rowSum[i], margW, showVals), margW)))
		}

		if labelW == 0 {
			out = append(out, data.String())
			continue
		}
		label := ""
		if i < len(rowLabels) {
			label = rowLabels[i]
		}
		labelLines := hardBoundDisplayLines([]string{label}, labelW)
		for j, line := range labelLines {
			rendered := ctx.Theme.Dim.Render(padRight(line, labelW))
			if j == len(labelLines)-1 {
				rendered += "  " + data.String()
			}
			out = append(out, rendered)
		}
	}

	// Σ footer: column sums + grand total.
	if showMarg {
		var sb strings.Builder
		if labelW > 0 {
			sb.WriteString(ctx.Theme.Dim.Render(padRight("Σ", labelW)) + "  ")
		}
		for j := 0; j < nCols; j++ {
			if j > 0 {
				sb.WriteString(" ")
			}
			sb.WriteString(ctx.Theme.Body.Render(heatPadLeft(heatSumField(colSum[j], colW[j], showVals), colW[j])))
		}
		sb.WriteString("  ")
		sb.WriteString(ctx.Theme.Body.Render(heatPadLeft(heatSumField(grand, margW, showVals), margW)))
		out = append(out, sb.String())
	}

	out = append(out, heatDualLegend(ctx))
	return out
}

// heatMatrixLedger is the complete narrow-surface representation for a matrix
// whose row-label gutter plus aligned columns cannot fit. It preserves every
// actual column and authored label in a numbered vertical ledger; values:true
// carries exact numbers, while values:false keeps the quantile shade contract.
// This avoids letting the generic document boundary wrap a matrix row and sever
// its header mapping.
func heatMatrixLedger(
	grid [][]float64,
	rowLabels, colLabels []string,
	rowSum, colSum []float64,
	grand float64,
	showVals bool,
	showMarg bool,
	ctx RenderCtx,
) []string {
	w := clampWidth(ctx.Width)
	bins := HeatQuantileBins(grid)
	out := hardBoundDisplayLines(
		[]string{ctx.Theme.Dim.Render("Matrix ledger · complete narrow fallback")},
		w,
	)
	if len(colLabels) > 0 {
		legend := make([]string, 0, len(colSum))
		for j := 0; j < len(colSum) && j < len(colLabels); j++ {
			legend = append(legend, strconv.Itoa(j+1)+" "+colLabels[j])
		}
		out = append(out, hardBoundDisplayLines(
			[]string{ctx.Theme.Dim.Render("Columns: " + strings.Join(legend, " · "))},
			w,
		)...)
	}
	for i, row := range grid {
		label := "Row " + strconv.Itoa(i+1)
		if i < len(rowLabels) && rowLabels[i] != "" {
			label += ": " + rowLabels[i]
		}
		out = append(out, hardBoundDisplayLines(
			[]string{ctx.Theme.Body.Render(label)},
			w,
		)...)

		values := make([]string, 0, len(colSum)+1)
		for j := 0; j < len(colSum); j++ {
			value := 0.0
			bin := -1
			if j < len(row) {
				value = row[j]
				bin = bins[i][j]
			}
			display := heatNum(value)
			if !showVals {
				display = heatDualCell(bin, 1, ctx)
			}
			values = append(values, strconv.Itoa(j+1)+"="+display)
		}
		if showMarg {
			values = append(
				values,
				"Σ="+heatSumField(rowSum[i], 1, showVals),
			)
		}
		out = append(out, hardBoundDisplayLines(
			[]string{ctx.Theme.Dim.Render(strings.Join(values, " · "))},
			w,
		)...)
	}
	if showMarg {
		totals := make([]string, 0, len(colSum)+1)
		for j, value := range colSum {
			totals = append(
				totals,
				strconv.Itoa(j+1)+"="+heatSumField(value, 1, showVals),
			)
		}
		totals = append(totals, "total="+heatSumField(grand, 1, showVals))
		out = append(out, hardBoundDisplayLines(
			[]string{ctx.Theme.Body.Render("Σ columns: " + strings.Join(totals, " · "))},
			w,
		)...)
	}
	out = append(out, heatDualLegend(ctx))
	return out
}

// heatMatrixCell renders one matrix cell: the exact right-aligned value (bin colour
// as reinforcement) when values are shown, else a quantile dual-encode shade cell.
func heatMatrixCell(bin int, v float64, w int, showVals bool, ctx RenderCtx) string {
	if !showVals {
		return heatDualCell(bin, w, ctx)
	}
	txt := heatPadLeft(heatNum(v), w)
	if bin < 0 {
		return ctx.Theme.Dim.Render(txt)
	}
	if bin > len(heatDualLadder)-1 {
		bin = len(heatDualLadder) - 1
	}
	if ctx.Profile >= ANSI256 {
		return lipgloss.NewStyle().Foreground(GenHeatRamp[bin]).Render(txt)
	}
	return ctx.Theme.Body.Render(txt)
}

// heatSumField formats a marginal sum: the number when values are shown, else a
// bar of the full block sized to the column (a pure-shade Σ marker).
func heatSumField(v float64, w int, showVals bool) string {
	if showVals {
		return heatNum(v)
	}
	if w < 1 {
		w = 1
	}
	return strings.Repeat("█", w)
}

// heatNum formats a cell value as a compact integer when it is whole, else a
// trimmed 1-dp decimal — so the aligned digit columns stay narrow.
func heatNum(v float64) string {
	if v == math.Trunc(v) {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'f', 1, 64)
}

// heatPadLeft right-aligns s in a field of w display columns (left-padded with
// spaces); a value wider than the field is returned as-is.
func heatPadLeft(s string, w int) string {
	vis := lipgloss.Width(s)
	if vis >= w {
		return s
	}
	return strings.Repeat(" ", w-vis) + s
}

// heatDualLegend is the low→high key for the dual-encode modes: the four ramp
// glyphs in their GenHeatRamp colours, auto-degrading in lockstep with the cells.
func heatDualLegend(ctx RenderCtx) string {
	var sb strings.Builder
	for k := 0; k < len(heatDualLadder); k++ {
		sb.WriteString(heatDualCell(k, 1, ctx))
	}
	return ctx.Theme.Dim.Render("less ") + sb.String() + ctx.Theme.Dim.Render(" more")
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
