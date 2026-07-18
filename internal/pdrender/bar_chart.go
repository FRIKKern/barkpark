package pdrender

import (
	"strconv"
	"strings"
)

// ── bar-chart ──────────────────────────────────────────────────────────────
//
// Horizontal bars for categorical counts (B003) — the terminal port of the
// React DataViz bar-chart emitter. Rides the same statBar/padOrTruncate
// meter vocabulary as gauge-list's share mode (the horizontal-bar prior
// art), but with its own author-supplied contract:
//
//	bar-chart: {bars: [{label, value}], max?, values?}
//
//	- bars    [{label, value}], author order preserved. Empty/absent →
//	          renders nothing (silent empty state; no phantom blank line).
//	- max     denominator for the meter proportion; else the data max
//	          (never the sum — bars are categorical counts, not shares).
//	- values  when true, print the raw value after each bar.
//
// Color is never load-bearing: the datum lives in the bar length + the
// optional trailing digits, both of which survive an ANSI strip.
type barChartRenderer struct{}

func (barChartRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	bars := itemMaps(b.Attrs, "bars")
	if len(bars) == 0 {
		return nil
	}

	rows := make([]struct {
		label string
		value float64
	}, 0, len(bars))
	max := attrFloat(b.Attrs, "max")
	for _, bar := range bars {
		v := attrFloat(bar, "value")
		if v > max {
			max = v
		}
		rows = append(rows, struct {
			label string
			value float64
		}{sanitizeText(strings.TrimSpace(attrStr(bar, "label"))), v})
	}
	if max <= 0 {
		max = 1 // guard: never divide the meter proportion by zero
	}
	showValues := attrBool(b.Attrs, "values")

	labelW, digitW := 0, 0
	digits := make([]string, len(rows))
	for i, r := range rows {
		if n := runeWidth(r.label); n > labelW {
			labelW = n
		}
		if showValues {
			digits[i] = formatBarValue(r.value)
			if n := runeWidth(digits[i]); n > digitW {
				digitW = n
			}
		}
	}
	cap := w / 3
	if cap < 6 {
		cap = 6
	}
	if cap > 24 {
		cap = 24
	}
	if labelW > cap {
		labelW = cap
	}
	if labelW < 1 {
		labelW = 1
	}

	reserved := labelW + 2
	if digitW > 0 {
		reserved += digitW + 1
	}
	barW := w - reserved
	if barW < 1 {
		barW = 1
	}

	out := make([]string, 0, len(rows))
	for i, r := range rows {
		prop := r.value / max
		if prop < 0 {
			prop = 0
		}
		if prop > 1 {
			prop = 1
		}
		label := ctx.Theme.Body.Render(padOrTruncate(r.label, labelW))
		bar := statBar(prop, barW, ctx)
		line := label + "  " + bar
		if showValues {
			pad := digitW - runeWidth(digits[i])
			if pad < 0 {
				pad = 0
			}
			line += " " + strings.Repeat(" ", pad) + ctx.Theme.Body.Render(digits[i])
		}
		out = append(out, line)
	}
	return out
}

// formatBarValue prints a bar's value without a trailing ".0" for whole
// numbers (mirrors toStr's float64 tolerance for JSON-decoded numbers).
func formatBarValue(v float64) string {
	if v == float64(int64(v)) {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}
