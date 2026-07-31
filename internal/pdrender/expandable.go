package pdrender

// ── expandable ───────────────────────────────────────────────────────────────
// Mirrors compose_block(expandable): a generic collapsible container — the
// same native-<details> pattern `callout` ships (walk.ex:1415-1434), minus the
// callout chrome. `summary` is a bold header line; the block's children
// (`children`, falling back to `blocks`, auto-decoded into `Block.Children`)
// recurse through the registry, indented two columns.
// The terminal has no collapse affordance, so this ALWAYS renders
// expanded — "TUI: expanded-by-default" (the `open`/`false` attr only matters
// on surfaces that can actually fold). Empty (no summary, no children) renders
// nothing (honest empty state).
type expandableRenderer struct{ reg *Registry }

func (er expandableRenderer) Render(b Block, ctx RenderCtx) []string {
	summary := sanitizeText(attrStr(b.Attrs, "summary"))
	if summary == "" && len(b.Children) == 0 {
		return nil
	}

	w := clampWidth(ctx.Width)
	bold := ctx.Theme.Body.Bold(true)
	const indent = "  "
	childCtx := ctx.Deeper().WithWidth(clampWidth(w - len(indent)))

	var out []string
	if summary != "" {
		out = append(out, truncateANSI(bold.Render(summary), w))
	}
	for _, child := range b.Children {
		for _, line := range er.reg.Render(child, childCtx) {
			out = append(out, indent+line)
		}
	}
	return out
}
