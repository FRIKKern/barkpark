package pdrender

import (
	"math"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── chart block (TUI creative slate, W3 — the capstone) ──────────────────────
//
// The terminal counterpart of a line/bar chart: a braille step-line plot of one
// or more numeric series, the "sparkline grown up into a real axis" read in the
// reader/CLI. This is the third and final block of the slate; it builds on W1's
// truecolor auto-degrade (heatUseTrueColor) and W2's sparkline normaliser
// (sparkNorm), rasterising through the braille.go dot-canvas.
//
// CONTRACT (ratified, pbp-tui-creative-slate §4):
//
//	chart: {series:[{label, points:[n…]}], kind?:"line"|"bars", axes?:{min?, max?, xLabels?:[string]}}
//
//	- series   one or more {label, points} rows. A series with no usable points
//	           is dropped; NO usable series → the dim placeholder (mirrors stat /
//	           heatmap honesty).
//	- kind     "line" (default) Bresenham-connects successive points into a
//	           continuous stroke; "bars" fills a floor-anchored column per point.
//	- axes.min/max  the y-scale span. Default is the global min/max across ALL
//	           series points. BOTH partial pins work: min-only (max auto) and
//	           max-only (min auto). Out-of-span values CLAMP to a plot edge (the
//	           scale never expands). Malformed axes — a non-numeric min/max, or
//	           both pinned with min >= max — are ignored and the plot auto-scales.
//	- axes.xLabels  aligned to point indices; v1 draws the FIRST and LAST label
//	           under the x-rule. A length mismatch vs the point count is tolerated
//	           (index 0 and the array's last, regardless). Absent → a bare rule.
//
// LAYOUT: optional title (the block caption) → H rows of
// `[tick value gutter][┤][braille row]` (ticks auto-computed down the effective
// min/max) → `└────…` x-rule → the first/last x-labels → a legend row (per-series
// braille swatch + label, spaced through the shared joinColumns — zero new width
// math). TRUECOLOR DEGRADE: per-series colour is emitted ONLY under a TrueColor
// profile (chartUseTrueColor, mirroring heatUseTrueColor); every lower profile
// (and the mono union) draws the ANSI-plain braille in the body tone, so the
// mono render is byte-stable. Import discipline holds: lipgloss + stdlib only.
type chartRenderer struct{}

// chartCellHeight is the fixed plot height in terminal cells (×4 = the dot-row
// resolution). Four cells give a legible curve and four y-ticks.
const chartCellHeight = 4

// maxChartSeries is the ratified series ceiling (pbp-slate2-chart-units): a chart
// plots at most the first two series, legend included. See the cap in Render.
const maxChartSeries = 2

type chartSeries struct {
	label  string
	points []float64
}

func (chartRenderer) Render(b Block, ctx RenderCtx) []string {
	series := parseChartSeries(b.Attrs)
	if len(series) == 0 {
		return []string{unresolvedPlaceholder(ctx, "chart")}
	}

	// Max-2-series law: a chart renders at most the FIRST two series. Braille
	// step-lines beyond two overlap into an unreadable union (there is no colour
	// to lean on at the NoColor floor), so the cap is a hard readability contract,
	// not a style choice. It fences the whole downstream pipeline — scale, plot,
	// legend all read `series` below — so no surface can leak a third curve.
	if len(series) > maxChartSeries {
		series = series[:maxChartSeries]
	}

	kind := strings.TrimSpace(attrStr(b.Attrs, "kind"))
	if kind != "bars" {
		kind = "line"
	}

	effMin, effMax := chartScale(series)
	effMin, effMax = applyAxes(b.Attrs, series, effMin, effMax)
	xLabels := chartXLabels(b.Attrs)

	W := clampWidth(ctx.Width)
	H := chartCellHeight

	// y-ticks down the plot: row 0 = top = effMax, row H-1 = bottom = effMin.
	ticks := make([]string, H)
	gutterW := 0
	for row := 0; row < H; row++ {
		frac := 0.0
		if H > 1 {
			frac = float64(row) / float64(H-1)
		}
		ticks[row] = formatTickCompact(effMax - frac*(effMax-effMin))
		if n := runeWidth(ticks[row]); n > gutterW {
			gutterW = n
		}
	}

	// Plot cell width = surface − gutter − 1 (the ┤ axis column). When that would
	// drop below MinWidth the plot DEGRADES to a gutterless, bare-rule render.
	plotW := W - gutterW - 1
	gutterOn := true
	if plotW < MinWidth {
		gutterOn = false
		plotW = W
	}
	if plotW < 1 {
		plotW = 1
	}

	// Rasterise every series into ONE canvas (mono union; per-series colour only
	// under a TrueColor profile).
	trueColor := chartUseTrueColor(ctx)
	canvas := newBrailleCanvas(plotW, H)
	colors := make([]lipgloss.Color, len(series))
	for i, s := range series {
		colors[i] = chartSeriesColor(i)
		plotSeries(canvas, s.points, effMin, effMax, i, kind)
	}
	body := canvas.rows(ctx, colors, trueColor)

	var out []string

	// Title: the block caption, if present.
	if cap := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "caption"))); cap != "" {
		out = append(out, firstLine(wrapLines(ctx.Theme.Caption.Render(cap), W)))
	}

	// Plot rows.
	for row := 0; row < H; row++ {
		line := body[row]
		if gutterOn {
			line = ctx.Theme.Dim.Render(leftPad(ticks[row], gutterW)) + ctx.Theme.Rule.Render("┤") + line
		}
		out = append(out, line)
	}

	// x-rule: └ under the ┤ corner, ─ under the plot.
	if gutterOn {
		out = append(out, ctx.Theme.Rule.Render(strings.Repeat(" ", gutterW)+"└"+strings.Repeat("─", plotW)))
	} else {
		out = append(out, ctx.Theme.Rule.Render("└"+strings.Repeat("─", plotW)))
	}

	// x-labels: first + last, aligned under the plot columns.
	out = append(out, chartXAxisLabels(xLabels, gutterW, plotW, gutterOn, ctx)...)

	// Legend: per-series swatch + label through the shared joinColumns.
	out = append(out, chartLegend(series, colors, trueColor, ctx)...)

	return out
}

// chartUseTrueColor is the W3 auto-degrade gate — the exact twin of
// heatUseTrueColor: per-series colour is emitted only on a TrueColor profile.
func chartUseTrueColor(ctx RenderCtx) bool { return ctx.Profile == TrueColor }

// ── parsing ──────────────────────────────────────────────────────────────────

// parseChartSeries reads the `series` array into []chartSeries, dropping
// non-object entries and any series left with no usable numeric points. Missing
// / wrong-typed → nil (the placeholder degrade).
func parseChartSeries(m map[string]any) []chartSeries {
	raw := attrSlice(m, "series")
	if raw == nil {
		return nil
	}
	var out []chartSeries
	for _, el := range raw {
		obj, ok := el.(map[string]any)
		if !ok {
			continue
		}
		points := parseChartPoints(obj["points"])
		if len(points) == 0 {
			continue
		}
		out = append(out, chartSeries{
			label:  sanitizeText(strings.TrimSpace(attrStr(obj, "label"))),
			points: points,
		})
	}
	return out
}

// parseChartPoints coerces a points array to []float64, tolerating non-numeric
// entries (dropped, exactly like parseSpark / the heatmap cell parse).
func parseChartPoints(v any) []float64 {
	raw, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]float64, 0, len(raw))
	for _, el := range raw {
		if f, ok := toFloat(el); ok {
			out = append(out, f)
		}
	}
	return out
}

// chartXLabels reads axes.xLabels (sanitized), or nil when axes/xLabels absent.
func chartXLabels(m map[string]any) []string {
	axes, ok := m["axes"].(map[string]any)
	if !ok {
		return nil
	}
	return heatStrings(axes, "xLabels")
}

// ── scaling ──────────────────────────────────────────────────────────────────

// chartScale is the AUTO y-span: the global min/max across every series point.
// Empty data opens a unit span so the plot always has a floor and a ceiling.
func chartScale(series []chartSeries) (min, max float64) {
	have := false
	for _, s := range series {
		for _, v := range s.points {
			if !have {
				min, max, have = v, v, true
				continue
			}
			if v < min {
				min = v
			}
			if v > max {
				max = v
			}
		}
	}
	if !have {
		return 0, 1
	}
	return min, max
}

// applyAxes folds the ratified axes.min/max pins onto the auto span. BOTH
// partial pins work (min-only keeps the auto max; max-only keeps the auto min).
// Malformed axes — a non-numeric min/max (read as absent) or both pinned with
// min >= max — are ignored and the auto span (dataMin,dataMax) is used. A
// partial pin (or flat data) that still leaves min >= max falls back to the auto
// span, opening a unit span if that too is degenerate — so the render never
// crashes and never divides by zero (sparkNorm also guards span<=0).
func applyAxes(m map[string]any, series []chartSeries, dataMin, dataMax float64) (min, max float64) {
	min, max = dataMin, dataMax
	pinMin, hasMin, pinMax, hasMax := chartAxesPins(m)
	if hasMin && hasMax && pinMin >= pinMax {
		hasMin, hasMax = false, false // malformed inverted pins → auto-scale
	}
	if hasMin {
		min = pinMin
	}
	if hasMax {
		max = pinMax
	}
	if min >= max {
		min, max = dataMin, dataMax
		if min >= max {
			max = min + 1
		}
	}
	return min, max
}

// chartAxesPins reads axes.min/max. A non-numeric (or absent) value reports its
// has-flag false, so a malformed pin is simply ignored (the auto span stands).
func chartAxesPins(m map[string]any) (min float64, hasMin bool, max float64, hasMax bool) {
	axes, ok := m["axes"].(map[string]any)
	if !ok {
		return 0, false, 0, false
	}
	if v, ok := toFloat(axes["min"]); ok {
		min, hasMin = v, true
	}
	if v, ok := toFloat(axes["max"]); ok {
		max, hasMax = v, true
	}
	return
}

// ── rasterising ──────────────────────────────────────────────────────────────

// plotSeries maps points to dot coordinates through the reused W2 normaliser
// (sparkNorm) and draws them into the canvas as series s. `line` mode
// Bresenham-connects successive points; `bars` mode fills a floor-anchored
// column per point.
func plotSeries(c *brailleCanvas, points []float64, min, max float64, s int, kind string) {
	n := len(points)
	if n == 0 {
		return
	}
	xs := make([]int, n)
	ys := make([]int, n)
	for i, v := range points {
		xs[i] = pointDotX(i, n, c.dotW)
		ys[i] = pointDotY(v, min, max, c.dotH)
	}
	if kind == "bars" {
		for i := range points {
			c.column(xs[i], ys[i], s)
		}
		return
	}
	if n == 1 {
		c.set(xs[0], ys[0], s)
		return
	}
	for i := 0; i < n-1; i++ {
		c.line(xs[i], ys[i], xs[i+1], ys[i+1], s)
	}
}

// pointDotX spreads point index i across the dot-width: index 0 at the left
// edge, index n-1 at the right edge.
func pointDotX(i, n, dotW int) int {
	if n <= 1 {
		return 0
	}
	x := int(math.Round(float64(i) * float64(dotW-1) / float64(n-1)))
	if x < 0 {
		x = 0
	}
	if x > dotW-1 {
		x = dotW - 1
	}
	return x
}

// pointDotY maps a value to a dot-row through sparkNorm (the W2 normaliser),
// inverted so a high value lands on the TOP row (y=0). Out-of-span values clamp
// to an edge (sparkNorm clamps the normalised value to [0,1]).
func pointDotY(v, min, max float64, dotH int) int {
	y := int(math.Round((1 - sparkNorm(v, min, max)) * float64(dotH-1)))
	if y < 0 {
		y = 0
	}
	if y > dotH-1 {
		y = dotH - 1
	}
	return y
}

// ── labels / legend / colour ─────────────────────────────────────────────────

// chartXAxisLabels draws the first + last x-labels aligned under the plot's
// first and last columns (past the tick gutter + ┤). Absent labels → no line.
func chartXAxisLabels(labels []string, gutterW, plotW int, gutterOn bool, ctx RenderCtx) []string {
	if len(labels) == 0 {
		return nil
	}
	lead := 0
	if gutterOn {
		lead = gutterW + 1
	}
	first := labels[0]
	last := labels[len(labels)-1]
	var content string
	if len(labels) == 1 || first == last {
		content = padOrTruncate(first, plotW)
	} else {
		content = placeFirstLast(first, last, plotW)
	}
	return []string{strings.Repeat(" ", lead) + ctx.Theme.Dim.Render(content)}
}

// placeFirstLast lays `first` at the left of a width-w field and `last` at the
// right; if they would collide it keeps first (truncated to fit).
func placeFirstLast(first, last string, w int) string {
	fw := runeWidth(first)
	lw := runeWidth(last)
	if fw+1+lw > w {
		return padOrTruncate(first, w)
	}
	return first + strings.Repeat(" ", w-fw-lw) + last
}

// chartLegend builds the per-series swatch + label row, spaced through the
// shared joinColumns (the Flex Arrange body — even swatch spacing, zero new
// width math). Falls back to a one-per-line stack when the row would overrun the
// surface.
func chartLegend(series []chartSeries, colors []lipgloss.Color, trueColor bool, ctx RenderCtx) []string {
	if len(series) == 0 {
		return nil
	}
	entries := make([]string, len(series))
	widths := make([]int, len(series))
	groups := make([][]string, len(series))
	for i, s := range series {
		label := s.label
		if label == "" {
			label = "series " + itoa(i+1)
		}
		e := chartSwatch(i, colors, trueColor, ctx) + " " + ctx.Theme.Dim.Render(label)
		entries[i] = e
		widths[i] = runeWidth(e)
		groups[i] = []string{e}
	}
	row := joinColumns(groups, widths, 2)
	if len(row) == 1 && runeWidth(row[0]) <= clampWidth(ctx.Width) {
		return row
	}
	return entries // too wide (or oddly shaped) → stack one per line
}

// chartSwatch is a two-cell braille line sample for the legend, coloured under a
// TrueColor profile and body-toned otherwise.
func chartSwatch(i int, colors []lipgloss.Color, trueColor bool, ctx RenderCtx) string {
	const sample = "⠒⠒"
	if trueColor && i < len(colors) {
		return lipgloss.NewStyle().Foreground(colors[i]).Render(sample)
	}
	return ctx.Theme.Body.Render(sample)
}

// chartSeriesColor is the per-series colour cycle (used only under TrueColor):
// blue, pink, green, amber, violet, cyan — a legible categorical set sourced from
// the generated GenChartSeries palette (design/tokens.json color.pdrenderChart),
// cycled by series index.
func chartSeriesColor(i int) lipgloss.Color { return GenChartSeries[i%len(GenChartSeries)] }

// ── small helpers ────────────────────────────────────────────────────────────

// formatTick renders a y-tick value compactly: an integer when it rounds to one
// (within a small epsilon), else one decimal place — so interior ticks read
// cleanly rather than as long float tails.
func formatTick(v float64) string {
	if r := math.Round(v); math.Abs(v-r) < 0.05 {
		return toStr(r)
	}
	return strconv.FormatFloat(v, 'f', 1, 64)
}

// formatTickCompact renders a y-tick with compact SI-style units once the
// magnitude reaches 10000: 12500→"12.5k", 45500000→"45.5M", 2000000000→"2B" — one
// decimal place with a trailing ".0" trimmed, so a large-value axis keeps a narrow
// gutter instead of splaying eight-digit ticks that crowd out the plot. BELOW the
// 10000 threshold it is byte-identical to formatTick, so every existing
// small-value chart golden (m13, m15) stays byte-stable. Sign is preserved
// (-45500000→"-45.5M") because the division carries it through.
func formatTickCompact(v float64) string {
	if math.Abs(v) < 10000 {
		return formatTick(v)
	}
	var div float64
	var suffix string
	switch abs := math.Abs(v); {
	case abs >= 1e9:
		div, suffix = 1e9, "B"
	case abs >= 1e6:
		div, suffix = 1e6, "M"
	default:
		div, suffix = 1e3, "k"
	}
	s := strconv.FormatFloat(v/div, 'f', 1, 64)
	s = strings.TrimSuffix(s, ".0")
	return s + suffix
}

// leftPad right-aligns s within w display columns (spaces on the left). An
// already-wide string is returned unchanged.
func leftPad(s string, w int) string {
	if d := runeWidth(s); d < w {
		return strings.Repeat(" ", w-d) + s
	}
	return s
}
