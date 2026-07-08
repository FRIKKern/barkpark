package pdrender

import (
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// wrapLines word-wraps a single styled string to width and returns it as a
// slice of lines. ansi.Wrap is ANSI-aware: it counts visible cells, not escape
// bytes, so styled text wraps at the right column. " -" are breakpoints (space
// always, hyphen is implicit in ansi.Wrap).
func wrapLines(s string, width int) []string {
	if s == "" {
		return []string{""}
	}
	wrapped := ansi.Wrap(s, clampWidth(width), " ")
	return strings.Split(wrapped, "\n")
}

// ── heading ─────────────────────────────────────────────────────────────────
// Mirrors compose_block(heading) + heading_style/2. Level clamps to 1..3.
// L1: uppercase + the heading style + an underline hairline rule beneath.
// L2: bold accent. L3: bold dim. (Terminal "size" = weight/case/rule.)
type headingRenderer struct{ ir InlineRenderer }

func (h headingRenderer) Render(b Block, ctx RenderCtx) []string {
	level := headingLevel(b.Attrs)
	text := sanitizeText(attrStr(b.Attrs, "text"))
	style := ctx.Theme.Heading[level-1]

	display := text
	if level == 1 {
		display = strings.ToUpper(text)
	}
	line := style.Render(display)
	lines := wrapLines(line, ctx.Width)

	if level == 1 {
		// A hairline rule beneath the L1 heading, as wide as the visible text
		// (capped at ctx.Width) — the terminal stand-in for the underline rule.
		ruleW := lipgloss.Width(display)
		if ruleW > ctx.Width {
			ruleW = ctx.Width
		}
		if ruleW < 1 {
			ruleW = 1
		}
		rule := ctx.Theme.Rule.Render(strings.Repeat("─", ruleW))
		lines = append(lines, rule)
	}
	return lines
}

// headingLevel clamps to 1..3, defaulting to 2 (matches heading_level/1).
func headingLevel(m map[string]any) int {
	l := attrInt(m, "level", 2)
	if l < 1 || l > 3 {
		return 2
	}
	return l
}

// ── paragraph ─────────────────────────────────────────────────────────────────
// Mirrors compose_block(paragraph): compose the inline `content` into one
// styled string, then word-wrap to ctx.Width.
type paragraphRenderer struct{ ir InlineRenderer }

func (p paragraphRenderer) Render(b Block, ctx RenderCtx) []string {
	inline := p.ir.Inline(attrSlice(b.Attrs, "content"), ctx)
	if inline == "" {
		return []string{""}
	}
	return wrapLines(inline, ctx.Width)
}

// ── list ──────────────────────────────────────────────────────────────────────
// Mirrors the email-branch list compose: per item a literal prefix ("N. " when
// ordered, "• " otherwise) + the inline-rendered item, with a HANGING INDENT so
// wrapped continuation lines align under the item text rather than the bullet.
type listRenderer struct{ ir InlineRenderer }

func (lr listRenderer) Render(b Block, ctx RenderCtx) []string {
	ordered := attrBool(b.Attrs, "ordered")
	items := attrSlice(b.Attrs, "items")
	var out []string
	for i, item := range items {
		prefix := "• "
		if ordered {
			prefix = itoa(i+1) + ". "
		}
		indent := lipgloss.Width(prefix)
		// Wrap the item body to the width left after the prefix, then hang.
		bodyWidth := clampWidth(ctx.Width - indent)
		// An item is an array of inline nodes (or a bare scalar — tolerated by
		// the inline node coercion).
		styled := lr.ir.Inline(itemNodes(item), ctx)
		wrapped := wrapLines(styled, bodyWidth)
		for j, line := range wrapped {
			if j == 0 {
				out = append(out, ctx.Theme.Dim.Render(prefix)+line)
			} else {
				out = append(out, strings.Repeat(" ", indent)+line)
			}
		}
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}

// itemNodes normalizes a list item to a []any of inline nodes. The wire shape
// for an item is an array of inline nodes; a bare string/number item is
// tolerated and wrapped (mirrors compose_inline_children's scalar clauses).
func itemNodes(item any) []any {
	switch v := item.(type) {
	case []any:
		return v
	case nil:
		return nil
	default:
		return []any{v}
	}
}

// ── callout ───────────────────────────────────────────────────────────────────
// Mirrors compose_block(callout) + the walk callout/3: a left-bar "▌ " + tinted
// body per tone (info/success/warning/danger/neutral), with an optional bold
// title run-in. Children render at ctx.Width-4 (bar + space + trailing room);
// below MinWidth the chrome is dropped and the body renders flat.
type calloutRenderer struct{ ir InlineRenderer }

func (cr calloutRenderer) Render(b Block, ctx RenderCtx) []string {
	tone := attrStrDefault(b.Attrs, "tone", "info")
	barStyle, bodyStyle := ctx.Theme.Callout(tone)

	// Compose the body: optional bold title run-in + inline content.
	var head strings.Builder
	if title := attrStr(b.Attrs, "title"); title != "" {
		head.WriteString(bodyStyle.Bold(true).Render(sanitizeText(title)))
		head.WriteString(" ")
	}
	head.WriteString(cr.ir.Inline(attrSlice(b.Attrs, "content"), ctx))
	body := head.String()

	const chrome = 4 // "▌ " bar (2) + breathing room (2)
	inner := ctx.Width - chrome
	if inner < MinWidth {
		// Drop the box; render the tinted body flat at full width.
		styled := bodyStyle.Render(ansi.Strip(body)) // re-tint, drop nested styles
		return wrapLines(styled, ctx.Width)
	}

	wrapped := wrapLines(body, inner)
	bar := barStyle.Render("▌")
	out := make([]string, 0, len(wrapped))
	for _, line := range wrapped {
		out = append(out, bar+" "+line)
	}
	return out
}

// ── divider ───────────────────────────────────────────────────────────────────
// Mirrors compose_block(divider, :article): a centered "§" glyph straddling a
// hairline rule across the column.
type dividerRenderer struct{}

func (dividerRenderer) Render(_ Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	glyph := " § "
	gw := lipgloss.Width(glyph)
	if gw >= w {
		return []string{ctx.Theme.Dim.Render(strings.TrimSpace(glyph))}
	}
	side := (w - gw) / 2
	left := strings.Repeat("─", side)
	right := strings.Repeat("─", w-gw-side)
	line := ctx.Theme.Rule.Render(left) + ctx.Theme.Dim.Render(glyph) + ctx.Theme.Rule.Render(right)
	return []string{line}
}

// ── section ───────────────────────────────────────────────────────────────────
// The recursion block. Mirrors compose_block(section): a leading PdHr + optional
// bold title + child blocks + a trailing PdHr. Children render through the
// registry at ctx.Width-indent with ctx.Deeper(); the indent is 2 cols once
// nested (depth>0). Below MinWidth the indent is dropped.
//
// GRID MODE: a section is a grid iff Attrs["layout"] is a map with mode=="grid"
// (mirrors compose.ex grid_layout/1). Then — where every cell clears MinWidth —
// children lay into rows of `tracks` cells SIDE-BY-SIDE (the reader's
// section_grid_html), honoring per-child `span` (slot consumption) and `order`
// (a stable CSS-order reorder). Below the per-cell floor, or tracks<2, it falls
// through to the stack loop UNCHANGED — every legacy/explicit-stack section is
// byte-identical to before (compose.ex's byte-identical guarantee).
type sectionRenderer struct{ reg *Registry }

func (sr sectionRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	rule := ctx.Theme.Rule.Render(strings.Repeat("─", w))

	out := []string{rule}
	if title := attrStr(b.Attrs, "title"); title != "" {
		out = append(out, ctx.Theme.Heading[1].Render(sanitizeText(title)))
		out = append(out, "")
	}

	indent := 0
	if ctx.Depth > 0 {
		indent = 2
	}
	inner := ctx.Width - indent
	if inner < MinWidth {
		indent = 0
		inner = ctx.Width
	}
	childCtx := ctx.Deeper().WithWidth(inner)
	pad := strings.Repeat(" ", indent)

	// Grid branch: only when layout.mode == "grid" AND the grid does not degrade
	// (tracks>1, every cell ≥ MinWidth). A nil return means "degrade" → fall
	// through to the byte-identical stack loop below.
	if layout, ok := b.Attrs["layout"].(map[string]any); ok && attrStr(layout, "mode") == "grid" {
		if grid := sr.gridBody(b, layout, childCtx, inner, pad); grid != nil {
			out = append(out, grid...)
			out = append(out, rule)
			return out
		}
	}

	// Stack path (verbatim — the sub-grid fallback and every non-grid section).
	for i, child := range b.Children {
		if i > 0 {
			out = append(out, "")
		}
		for _, line := range sr.reg.Render(child, childCtx) {
			out = append(out, pad+line)
		}
	}

	out = append(out, rule)
	return out
}

// gridBody lays a grid-mode section's children into rows of `tracks` cells,
// honoring span (a span-S child consumes S slots and is S*cellW+(S-1)*gutter
// wide) and order (a stable sort by CSS order; a child with no order keeps its
// source position, order default 0). cellW is computed off `inner` (post-indent)
// so a nested grid never overflows the section rule. Returns nil to signal the
// caller to degrade to the stack path (tracks<2, or any cell below MinWidth).
func (sr sectionRenderer) gridBody(b Block, layout map[string]any, childCtx RenderCtx, inner int, pad string) []string {
	if len(b.Children) == 0 {
		return nil
	}
	tracks := gridTracks(layout["tracks"])
	// The shared Flex solver owns the divide-formula + degrade verdict: cellW :=
	// (inner-(tracks-1)*gutter)/tracks; side-by-side only when tracks>1 AND
	// cellW>=MinWidth. A false verdict (tracks<2 or any cell too narrow) → nil,
	// signaling the caller to degrade to the byte-identical stack path.
	cellW, sideBySide := DefaultFlex.Measure(inner, tracks)
	if !sideBySide {
		return nil
	}

	// Stable CSS-order reorder: the reader emits `order:`, i.e. it DOES reorder,
	// so a terminal stable-sort by order is parity-correct.
	items := make([]Block, len(b.Children))
	copy(items, b.Children)
	sort.SliceStable(items, func(i, j int) bool { return cellOrder(items[i]) < cellOrder(items[j]) })

	nodes := make([]Node, len(items))
	for i, child := range items {
		s := cellSpan(child, tracks)
		cw := s*cellW + (s-1)*DefaultFlex.Gutter
		nodes[i] = Node{Lines: sr.reg.Render(child, childCtx.WithWidth(cw)), Width: cw, Span: s}
	}

	rows := DefaultFlex.ArrangeGrid(nodes, tracks)
	out := make([]string, 0, len(rows))
	for _, line := range rows {
		out = append(out, pad+line)
	}
	return out
}

// ── fallback ──────────────────────────────────────────────────────────────────
// Unknown block types degrade to a labeled box instead of crashing (render.ex
// raises ArgumentError; a reader must survive a forward-compatible document).
type fallbackRenderer struct{}

func (fallbackRenderer) Render(b Block, ctx RenderCtx) []string {
	label := "unknown block: " + sanitizeText(b.Type)
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ctx.Theme.Accent).
		Foreground(ctx.Theme.Dim.GetForeground()).
		Padding(0, 1).
		Width(clampWidth(ctx.Width - 2)).
		Render(label)
	return strings.Split(box, "\n")
}

// itoa is a tiny strconv.Itoa alias kept local to avoid an import in this file.
func itoa(n int) string { return toStr(n) }
