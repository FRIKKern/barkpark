package pdrender

import "strings"

// ── lineage (dated nodes on a line, jarl figure family) ──────────────────────
//
// The terminal counterpart of the web's lineage strip (dataviz.ts `lineage` /
// data_viz.ex):
//
//	lineage: {sourceDefault?, nodes:[{overline?, title?, body?, value?,
//	         unit?, source?}]}
//
// Nodes render in AUTHORED order as a vertical stack with a blank line of
// rhythm between them: a dim overline (the date/period — "jan–sep 2025",
// "i dag"), a bold title, the value with its dim unit (the optional datum, a
// DISPLAY string never reformatted), and the body prose wrapped to ctx.Width.
// A node with none of overline/title/body/value contributes nothing; an empty
// list → the honest dim `[lineage — no data]` line (the family's degrade
// idiom). Kilde law (kilde.go): datum-bearing nodes (those with a `value`)
// carry the provenance obligation — own `source`, else `sourceDefault` — into
// one dim provenance line. Import discipline holds: every document-controlled
// string passes through sanitizeText; widths are ANSI-aware.
type lineageRenderer struct{}

func (lineageRenderer) Render(b Block, ctx RenderCtx) []string {
	m := b.Attrs
	nodes := lineageNodes(m)
	if len(nodes) == 0 {
		return []string{ctx.Theme.Dim.Render("[lineage — no data]")}
	}
	w := clampWidth(ctx.Width)

	var out []string
	for i, n := range nodes {
		if i > 0 {
			out = append(out, "") // rhythm between nodes
		}
		if overline := sanitizeText(strings.TrimSpace(attrStr(n, "overline"))); overline != "" {
			out = append(out, wrapLines(ctx.Theme.Dim.Render(overline), w)...)
		}
		if title := sanitizeText(strings.TrimSpace(attrStr(n, "title"))); title != "" {
			out = append(out, wrapLines(ctx.Theme.Body.Bold(true).Render(title), w)...)
		}
		if value := sanitizeText(strings.TrimSpace(attrStr(n, "value"))); value != "" {
			line := ctx.Theme.Body.Bold(true).Render(value)
			if unit := sanitizeText(strings.TrimSpace(attrStr(n, "unit"))); unit != "" {
				line += ctx.Theme.Dim.Render(" " + unit)
			}
			out = append(out, line)
		}
		if body := sanitizeText(strings.TrimSpace(attrStr(n, "body"))); body != "" {
			out = append(out, wrapLines(ctx.Theme.Body.Render(body), w)...)
		}
	}

	labels := figureSourceLabels(nodes, strings.TrimSpace(attrStr(m, "sourceDefault")), func(n map[string]any) bool {
		return strings.TrimSpace(attrStr(n, "value")) != ""
	})
	if kl := kildeLines(labels, ctx, w); len(kl) > 0 {
		out = append(out, "")
		out = append(out, kl...)
	}
	return out
}

// lineageNodes keeps the nodes that say anything: overline, title, body or
// value non-empty (dataviz.ts's node filter, verbatim).
func lineageNodes(m map[string]any) []map[string]any {
	var out []map[string]any
	for _, n := range itemMaps(m, "nodes") {
		if strings.TrimSpace(attrStr(n, "overline")) != "" ||
			strings.TrimSpace(attrStr(n, "title")) != "" ||
			strings.TrimSpace(attrStr(n, "body")) != "" ||
			strings.TrimSpace(attrStr(n, "value")) != "" {
			out = append(out, n)
		}
	}
	return out
}
