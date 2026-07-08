package pdrender

import (
	"math"
	"strings"
)

// ── stat / KPI block ─────────────────────────────────────────────────────────
//
// The terminal counterpart of a KPI / big-number cell (the TUI creative slate,
// W2). It draws a single headline metric — a prominent value with a caption and
// an optional inline trend — the "/usage dashboard number" read, in the
// reader/CLI. This is the second block of the slate; W3's chart reuses the
// EIGHTH-BLOCK SPARKLINE PRIMITIVE below (sparkline + sparkLadder).
//
// CONTRACT (ratified, pbp-tui-creative-slate §3):
//
//	stat:  {value, max?, label?, spark?:[n…]}
//
//	- value  the headline datum. Rendered as a DISPLAY string (the slate stamps
//	         pre-formatted values like "1.24M", "$42.10", "73%"), so it is read
//	         via attrStr — NOT coerced to a number for display. Absent → the dim
//	         placeholder (mirrors taskListRenderer.resolvedKeyPresent honesty).
//	- max    PRESENT and positive → a BULLET-BAR mode: a value/max proportion bar
//	         drawn above the value (value AND max are coerced numeric for the
//	         proportion). ABSENT → BIG-NUMBER mode: the value stands alone,
//	         prominent.
//	- label  optional caption under the number/bar (dim).
//	- spark  optional numeric array → an eighth-block sparkline row beneath the
//	         stat, through the reusable primitive.
//
// The KPI GRID is the plural `stats` block (below): N stat cells laid out N-up
// through the SHARED Flex solver / joinColumns — zero new width math. Import
// discipline holds: only lipgloss (via the Theme) + the stdlib; every
// document-controlled string passes through sanitizeText; widths are ANSI-aware.

// ── the eighth-block sparkline primitive (reused by W2/W3) ────────────────────

// sparkLadder is the deterministic eighth-block intensity ladder: eight vertical
// sub-levels from the one-eighth bar to the full block. A byte-stable glyph
// gradient that reads without any colour, so the sparkline is ANSI-plain. This is
// the eighth-block counterpart of heatmap.go's heatShadeLadder — the slate ranked
// eighth-blocks the winner for inline sparklines/bars (one row, 8 sub-levels).
var sparkLadder = []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

// sparkline maps a numeric series onto the eighth-block ladder, normalised to the
// series' own min..max, one glyph per value. It is the reusable W2/W3 primitive
// (exactly what heatCell was for W1): deterministic, ANSI-plain, width-bounded.
//
// GUARDS (never a divide-by-zero, never a panic):
//   - empty series          → "" (nothing to draw).
//   - flat series (max==min) → a flat BASELINE row of the lowest glyph (▁), so a
//     constant series reads as a flat floor rather than dividing by a zero span.
//   - width>0 caps the glyph count to `width` (the caller passes the cell width);
//     width<=0 draws one glyph per value.
//
// Normalisation is (v-min)/(max-min) ∈ [0,1] mapped to ladder index
// round(norm*7), clamped to [0,7] — so the series minimum lands on ▁ and the
// maximum on █, the full 8-level swing regardless of the values' absolute scale.
func sparkline(values []float64, width int) string {
	n := len(values)
	if n == 0 {
		return ""
	}
	if width > 0 && n > width {
		n = width // width-bounded: cap the glyph count to the cell width
	}

	min, max := values[0], values[0]
	for _, v := range values[:n] {
		if v < min {
			min = v
		}
		if v > max {
			max = v
		}
	}

	// Flat series (or a single point): a baseline row of the lowest glyph. This is
	// the divide-by-zero guard — span == 0 would otherwise blow up the normaliser.
	span := max - min
	if span <= 0 {
		return strings.Repeat(string(sparkLadder[0]), n)
	}

	top := float64(len(sparkLadder) - 1) // 7
	var sb strings.Builder
	for _, v := range values[:n] {
		norm := (v - min) / span
		idx := int(math.Round(norm * top))
		if idx < 0 {
			idx = 0
		}
		if idx > len(sparkLadder)-1 {
			idx = len(sparkLadder) - 1
		}
		sb.WriteRune(sparkLadder[idx])
	}
	return sb.String()
}

// parseSpark reads the `spark` field into []float64, tolerating non-numeric
// entries (dropped) exactly like the heatmap cell parse. Missing/wrong-typed →
// nil (no sparkline row).
func parseSpark(m map[string]any) []float64 {
	raw := attrSlice(m, "spark")
	if raw == nil {
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

// ── the single stat cell ─────────────────────────────────────────────────────

// statRenderer draws ONE KPI cell. It is the unit the plural `stats` grid lays
// out N-up; on its own it renders a single full-width stat. The mode branch is
// the `max` presence check (see the contract above).
type statRenderer struct{}

func (statRenderer) Render(b Block, ctx RenderCtx) []string {
	return statCell(b.Attrs, ctx)
}

// statCell is the shared body: it renders a stat's attrs into lines at ctx.Width.
// Lifted out so the plural grid re-renders each item at its resolved cell width
// through exactly the same path — the singular and grid renders never diverge.
func statCell(m map[string]any, ctx RenderCtx) []string {
	// Degrade: no `value` key at all → the honest dim placeholder (mirrors the
	// task widgets' resolvedKeyPresent). An explicit empty-string value is still a
	// value (the author's choice) and renders as-is.
	if _, ok := m["value"]; !ok {
		return []string{unresolvedPlaceholder(ctx, "stat")}
	}

	value := sanitizeText(strings.TrimSpace(attrStr(m, "value")))
	label := sanitizeText(strings.TrimSpace(attrStr(m, "label")))
	w := clampWidth(ctx.Width)

	var out []string

	// Mode branch: `max` present and positive → bullet-bar; else big-number.
	if _, hasMax := m["max"]; hasMax {
		maxVal := attrFloat(m, "max")
		if maxVal > 0 {
			proportion := 0.0
			if v, ok := toFloat(m["value"]); ok {
				proportion = v / maxVal
			}
			// Reserve room for the trailing value label; the bar fills the rest of
			// the cell. This is a FILL computation over the cell width the Flex
			// solver already resolved — not an N-up divide.
			valuePart := "  " + value
			barW := w - runeWidth(valuePart)
			if barW < 1 {
				barW = 1
			}
			out = append(out, statBar(proportion, barW, ctx)+ctx.Theme.Body.Render(valuePart))
		} else {
			// max present but non-positive → degrade to a plain prominent value.
			out = append(out, ctx.Theme.Body.Bold(true).Render(value))
		}
	} else {
		// Big-number: the value stands alone, prominent.
		out = append(out, ctx.Theme.Body.Bold(true).Render(value))
	}

	// Caption under the number/bar.
	if label != "" {
		out = append(out, firstLine(wrapLines(ctx.Theme.Dim.Render(label), w)))
	}

	// Inline trend: the eighth-block sparkline, bounded to the cell width.
	if spark := parseSpark(m); len(spark) > 0 {
		if line := sparkline(spark, w); line != "" {
			out = append(out, ctx.Theme.Body.Render(line))
		}
	}

	return out
}

// statBar is the KPI bullet-bar: `fill` cells of ▓ in the body tone, the
// remainder ░ in dim — the same ▓/░ proportion-bar idiom the task widgets use
// (momentumBar / roadmap track), reused rather than reinvented. `proportion` is
// clamped to [0,1]; fill = round(proportion*w), clamped to [0,w]. No new width
// math — `w` is handed in already resolved.
func statBar(proportion float64, w int, ctx RenderCtx) string {
	w = clampWidth(w)
	if proportion < 0 {
		proportion = 0
	}
	if proportion > 1 {
		proportion = 1
	}
	fill := int(math.Round(proportion * float64(w)))
	if fill > w {
		fill = w
	}
	if fill < 0 {
		fill = 0
	}
	return ctx.Theme.Body.Render(strings.Repeat("▓", fill)) +
		ctx.Theme.Dim.Render(strings.Repeat("░", w-fill))
}

// ── the KPI grid (plural stats block) ────────────────────────────────────────

// statsRenderer is the KPI grid: N stat cells laid out N-up. It follows the
// notes/cards/pipeline plural pattern (itemMaps + a synthesized child Block per
// item), but — matching the slate's "four big-number cells laid out 4-up" render
// (pbp-tui-creative-slate §2 ②) — it lays the cells SIDE-BY-SIDE BY DEFAULT (a
// grid IS N-up), degrading to a vertical stack only when the shared Flex solver
// says the surface is too narrow. ALL sizing routes through DefaultFlex.Measure /
// Arrange (the (W-(N-1)*gutter)/N divide + the degrade verdict) and joinColumns —
// zero new width math, exactly like every other side-by-side surface.
type statsRenderer struct{}

func (statsRenderer) Render(b Block, ctx RenderCtx) []string {
	items := itemMaps(b.Attrs, "items")
	if len(items) == 0 {
		return []string{""}
	}

	// Side-by-side path: the shared Flex solver owns the divide + the verdict.
	// Re-render each cell at the resolved cellW so its label/sparkline bound to the
	// cell, then Arrange. Falls through to the stack when Measure says narrow, or a
	// cell's min-content overflows its track (Fits).
	n := len(items)
	if cellW, sideBySide := DefaultFlex.Measure(clampWidth(ctx.Width), n); sideBySide {
		cellCtx := ctx.Deeper().WithWidth(cellW)
		nodes := make([]Node, n)
		for i, item := range items {
			nodes[i] = Node{Lines: statCell(item, cellCtx), Width: cellW, Span: 1}
		}
		if DefaultFlex.Fits(nodes) {
			return DefaultFlex.Arrange(nodes)
		}
	}

	// Vertical stack (narrow surface): each cell full-width, a blank line between.
	out := make([]string, 0, n*3)
	for i, item := range items {
		if i > 0 {
			out = append(out, "") // rhythm between stacked cells
		}
		out = append(out, statCell(item, ctx)...)
	}
	return out
}
