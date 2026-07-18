package pdrender

import (
	"strings"
)

// ── criteria-progress ─────────────────────────────────────────────────────
//
// Acceptance-criteria met/total rolled up per row, or aggregated to one
// total row (B034) — the terminal port of the React DataViz criteria-progress
// emitter. Renders from its OWN attrs — no live task-resolver query at
// render time:
//
//	criteria-progress: {rows: [{label, met, total}], detail?: "rows"|"total"}
//
//	- rows    [{label, met, total}], author order preserved (default mode).
//	          Empty/absent -> renders nothing (silent empty state).
//	- detail  "total" collapses all rows into one aggregate bar (summed
//	          met/total, label "Total"); default "rows" keeps them separate.
//
// Same statBar meter vocabulary as bar-chart, but the denominator is each
// row's own `total` (a fraction, not a shared max) and the digit (met/total)
// is always shown — it IS the datum, not optional embellishment.
type criteriaProgressRenderer struct{}

func (criteriaProgressRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	rows := itemMaps(b.Attrs, "rows")
	if len(rows) == 0 {
		return nil
	}

	type row struct {
		label string
		met   float64
		total float64
	}

	resolved := make([]row, 0, len(rows))
	for _, r := range rows {
		resolved = append(resolved, row{
			label: sanitizeText(strings.TrimSpace(attrStr(r, "label"))),
			met:   attrFloat(r, "met"),
			total: attrFloat(r, "total"),
		})
	}

	if attrStr(b.Attrs, "detail") == "total" {
		var met, total float64
		for _, r := range resolved {
			met += r.met
			total += r.total
		}
		resolved = []row{{label: "Total", met: met, total: total}}
	}

	labelW, digitW := 0, 0
	digits := make([]string, len(resolved))
	for i, r := range resolved {
		if n := runeWidth(r.label); n > labelW {
			labelW = n
		}
		digits[i] = formatBarValue(r.met) + "/" + formatBarValue(r.total)
		if n := runeWidth(digits[i]); n > digitW {
			digitW = n
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

	reserved := labelW + 2 + digitW + 1
	barW := w - reserved
	if barW < 1 {
		barW = 1
	}

	out := make([]string, 0, len(resolved))
	for i, r := range resolved {
		prop := 0.0
		if r.total > 0 {
			prop = r.met / r.total
		}
		if prop < 0 {
			prop = 0
		}
		if prop > 1 {
			prop = 1
		}
		label := ctx.Theme.Body.Render(padOrTruncate(r.label, labelW))
		bar := statBar(prop, barW, ctx)
		pad := digitW - runeWidth(digits[i])
		if pad < 0 {
			pad = 0
		}
		line := label + "  " + bar + " " + strings.Repeat(" ", pad) + ctx.Theme.Body.Render(digits[i])
		out = append(out, line)
	}
	return out
}
