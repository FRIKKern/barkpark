package pdrender

import (
	"strconv"
)

// ── steps ────────────────────────────────────────────────────────────────────
// Mirrors compose_block(steps) (compose.ex): a numbered procedure. `steps` is
// a list of `{title, blocks}` — each step's title renders as a bold numbered
// header ("1. Title"), then its nested blocks recurse through the registry
// (the columns/terminal precedent), indented two columns under the header.
// A step with neither a title nor any blocks is dropped; empty/missing
// `steps` renders nothing (honest empty state).
type stepsRenderer struct{ reg *Registry }

func (sr stepsRenderer) Render(b Block, ctx RenderCtx) []string {
	steps, _ := b.Attrs["steps"].([]any)
	if len(steps) == 0 {
		return nil
	}

	w := clampWidth(ctx.Width)
	const indent = "  "
	childCtx := ctx.Deeper().WithWidth(clampWidth(w - len(indent)))
	bold := ctx.Theme.Body.Bold(true)

	var out []string
	n := 0
	for _, s := range steps {
		m, ok := s.(map[string]any)
		if !ok {
			continue
		}
		title := sanitizeText(attrStr(m, "title"))
		blocks := slotBlocks(m["blocks"])
		if title == "" && len(blocks) == 0 {
			continue
		}
		n++
		if len(out) > 0 {
			out = append(out, "")
		}
		header := strconv.Itoa(n) + ". " + title
		out = append(out, truncateANSI(bold.Render(header), w))
		for _, child := range blocks {
			for _, line := range sr.reg.Render(child, childCtx) {
				out = append(out, indent+line)
			}
		}
	}
	return out
}
