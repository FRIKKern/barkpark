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
			met:   attrNumeric(r, "met"),
			total: attrNumeric(r, "total"),
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
	// Keep every authored label. The old fixed 24-column ceiling silently
	// changed "Survey every corpus chapter" into "Survey every corpus cha…"
	// even when the surface had ample room. Reserve only the irreducible meter
	// and digit width; genuinely narrow surfaces put an overlong label on its
	// own wrapped line below.
	maxInlineLabelW := w - (2 + 1 + digitW + 1)
	if maxInlineLabelW < 1 {
		maxInlineLabelW = 1
	}
	if labelW > maxInlineLabelW {
		labelW = maxInlineLabelW
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
		if runeWidth(r.label) > labelW {
			out = append(out, wrapLines(ctx.Theme.Body.Render(r.label), w)...)
			meterW := w - digitW - 1
			if meterW < 1 {
				meterW = 1
			}
			out = append(out, statBar(prop, meterW, ctx)+" "+ctx.Theme.Body.Render(digits[i]))
			continue
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
