package pdrender

import "strings"

// ── duel (two-arm comparison, jarl figure family) ────────────────────────────
//
// The terminal counterpart of the web's two-column comparison table
// (dataviz.ts `duel` / data_viz.ex):
//
//	duel: {legendA, legendB, sourceDefault?, rows:[{label, delta?, valueA,
//	       valueB, unit?, source?}]}
//
// A legend header (`legendA  vs  legendB`, arm A bold — the accent arm), then
// one line per row — `label  valueA vs valueB` — with the authored delta
// ("−30 %") as a dim second line under the label and the row's unit riding dim
// after both values. Values are authored DISPLAY strings ("1 478"), never
// reformatted. Both legends are REQUIRED and at least one row must carry
// label/valueA/valueB — an unnamed column is a meaningless comparison — else
// the honest dim `[duel — no data]` line (the family's degrade idiom). Kilde
// law (kilde.go): every row with a value is a datum; per-row `source`
// (fallback `sourceDefault`) aggregates into one dim provenance line. Import
// discipline holds: every document-controlled string passes through
// sanitizeText; widths are ANSI-aware.
type duelRenderer struct{}

func (duelRenderer) Render(b Block, ctx RenderCtx) []string {
	m := b.Attrs
	legendA := sanitizeText(strings.TrimSpace(attrStr(m, "legendA")))
	legendB := sanitizeText(strings.TrimSpace(attrStr(m, "legendB")))
	rows := duelRows(m)
	if legendA == "" || legendB == "" || len(rows) == 0 {
		return []string{ctx.Theme.Dim.Render("[duel — no data]")}
	}
	w := clampWidth(ctx.Width)

	out := wrapLines(
		ctx.Theme.Body.Bold(true).Render(legendA)+ctx.Theme.Dim.Render("  vs  ")+ctx.Theme.Body.Render(legendB),
		w,
	)
	for _, r := range rows {
		label := sanitizeText(strings.TrimSpace(attrStr(r, "label")))
		va := sanitizeText(strings.TrimSpace(attrStr(r, "valueA")))
		vb := sanitizeText(strings.TrimSpace(attrStr(r, "valueB")))
		unit := sanitizeText(strings.TrimSpace(attrStr(r, "unit")))
		delta := sanitizeText(strings.TrimSpace(attrStr(r, "delta")))

		unitSuffix := ""
		if unit != "" {
			unitSuffix = ctx.Theme.Dim.Render(" " + unit)
		}
		// `label  valueA vs valueB` — arm A bold (the accent arm), the joiner dim.
		line := ctx.Theme.Body.Render(label) + "  " +
			ctx.Theme.Body.Bold(true).Render(va) + unitSuffix +
			ctx.Theme.Dim.Render(" vs ") +
			ctx.Theme.Body.Render(vb) + unitSuffix
		out = append(out, line)
		// The authored delta rides small under the row label — display text,
		// never computed.
		if delta != "" {
			out = append(out, "  "+ctx.Theme.Dim.Render(delta))
		}
	}

	labels := figureSourceLabels(rows, strings.TrimSpace(attrStr(m, "sourceDefault")), func(r map[string]any) bool {
		return strings.TrimSpace(attrStr(r, "valueA")) != "" || strings.TrimSpace(attrStr(r, "valueB")) != ""
	})
	return append(out, kildeLines(labels, ctx, w)...)
}

// duelRows keeps the rows that say anything: label, valueA or valueB non-empty
// (dataviz.ts's row filter, verbatim).
func duelRows(m map[string]any) []map[string]any {
	var out []map[string]any
	for _, r := range itemMaps(m, "rows") {
		if strings.TrimSpace(attrStr(r, "label")) != "" ||
			strings.TrimSpace(attrStr(r, "valueA")) != "" ||
			strings.TrimSpace(attrStr(r, "valueB")) != "" {
			out = append(out, r)
		}
	}
	return out
}
