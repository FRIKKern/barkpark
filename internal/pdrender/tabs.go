package pdrender

import "strings"

// ── tabs (B052) ────────────────────────────────────────────────────────────
// Mirrors compose_block(tabs) (compose.ex): tabbed panels of child blocks,
// switched in the browser via I1 (framework-free DOM-scan) hydration. Like
// code-tabs, pdrender is a one-shot static render with no click affordance —
// the honest degrade is every tab's panel stacked, each under a bold label
// heading, separated by a hairline rule (the columns/dashboard stacking
// idiom). Each panel's blocks recurse through the registry, so tabsRenderer
// holds a back-reference like section/columns/card. Empty `tabs` renders
// nothing (honest empty state).
type tabsRenderer struct{ reg *Registry }

func (tr tabsRenderer) Render(b Block, ctx RenderCtx) []string {
	tabs := tabEntries(b.Attrs)
	if len(tabs) == 0 {
		return nil
	}

	w := clampWidth(ctx.Width)
	rule := ctx.Theme.Rule.Render(strings.Repeat("─", w))
	childCtx := ctx.Deeper().WithWidth(w)

	var out []string
	for i, t := range tabs {
		if i > 0 {
			out = append(out, rule)
		}
		out = append(out, ctx.Theme.FieldLabel.Render(t.label))
		out = append(out, tr.renderPanel(t.blocks, childCtx)...)
	}
	return out
}

// renderPanel renders one tab's blocks through the registry, with a blank
// rhythm line between consecutive blocks (the columns.renderColumn cadence).
func (tr tabsRenderer) renderPanel(blocks []Block, ctx RenderCtx) []string {
	var lines []string
	emitted := 0
	for _, blk := range blocks {
		group := tr.reg.Render(blk, ctx)
		if len(group) == 0 {
			continue
		}
		if emitted > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, group...)
		emitted++
	}
	return lines
}

// tabEntry is one authored tab: its display label and its (already-decoded)
// child blocks.
type tabEntry struct {
	label  string
	blocks []Block
}

// tabEntries reads the `tabs` array off a tabs block. Each entry is a
// {label, blocks} object; non-object entries are skipped. A blank label
// becomes a dim "·" placeholder (mirrors dashboardTabs) so the stack never
// carries an unlabeled panel. Child blocks are normalized via slotBlocks
// (the dashboard/card/columns tolerance), reusing blockFromMap so nested
// containers still recurse.
func tabEntries(m map[string]any) []tabEntry {
	raw := attrSlice(m, "tabs")
	if raw == nil {
		return nil
	}
	out := make([]tabEntry, 0, len(raw))
	for _, el := range raw {
		obj, ok := el.(map[string]any)
		if !ok {
			continue
		}
		label := sanitizeText(strings.TrimSpace(attrStr(obj, "label")))
		if label == "" {
			label = "·"
		}
		out = append(out, tabEntry{label: label, blocks: slotBlocks(obj["blocks"])})
	}
	return out
}
