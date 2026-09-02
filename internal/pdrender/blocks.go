package pdrender

import (
	"encoding/json"
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
	text := sanitizeDisplayText(attrStr(b.Attrs, "text"))
	if text == "" {
		text = h.ir.Inline(attrSlice(b.Attrs, "content"), ctx)
	}
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
		return nil
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

// orderedListRenderer forces ordered:true, then defers to the list renderer.
// It backs the `numbered_list` authoring-drift alias (mirrors compose.ex, which
// maps numbered_list → list with ordered:true). The Attrs map is COPIED before
// the flag is set so the caller's block is never mutated.
type orderedListRenderer struct{ lr listRenderer }

func (o orderedListRenderer) Render(b Block, ctx RenderCtx) []string {
	attrs := make(map[string]any, len(b.Attrs)+1)
	for k, v := range b.Attrs {
		attrs[k] = v
	}
	attrs["ordered"] = true
	b.Attrs = attrs
	return o.lr.Render(b, ctx)
}

// headingAtLevel forces `level`, then defers to the heading renderer. It backs
// the h1/h2/h3 authoring-drift aliases (mirrors compose.ex's @heading_aliases
// clause and react's headingAtLevel): the level comes from the TYPE, not from
// `level`, because SIX of the 18 drifted headings (1 h2 + all 5 h3s) carry no
// `level` key and would otherwise render at headingLevel's default of 2. The
// type wins outright; zero live blocks contradict it. The Attrs map is
// COPIED before the level is set so the caller's block is never mutated (the
// orderedListRenderer precedent directly above).
type headingAtLevel struct {
	hr    headingRenderer
	level int
}

func (h headingAtLevel) Render(b Block, ctx RenderCtx) []string {
	attrs := make(map[string]any, len(b.Attrs)+1)
	for k, v := range b.Attrs {
		attrs[k] = v
	}
	attrs["level"] = h.level
	b.Attrs = attrs
	return h.hr.Render(b, ctx)
}

// itemNodes normalizes a list item to a []any of inline nodes. The wire shape
// for an item is an array of inline nodes; a bare string/number item is
// tolerated and wrapped (mirrors compose_inline_children's scalar clauses). A
// STRING item that parses as a JSON array of inline-node objects is decoded to
// that array — the drifted list variants (bullet_list especially) persisted
// their items as JSON-encoded strings, which would otherwise render as literal
// JSON. Mirrors compose.ex's normalize_list_item/1.
func itemNodes(item any) []any {
	switch v := item.(type) {
	case []any:
		return v
	case nil:
		return nil
	case string:
		if nodes, ok := decodeInlineJSON(v); ok {
			return nodes
		}
		return []any{v}
	case map[string]any:
		// The map-shaped item: 2,033 of the 10,455 published list items in the
		// live corpus are maps, not inline arrays ({content:[…]} ×2,020,
		// {text:…} ×13 — full-corpus census, 537 papers, 2026-07-25). Read
		// `content` FIRST and the flat `text` second, the content ⟂ text law
		// paragraph_inline/1 holds on the Elixir side. An EMPTY content array is
		// NOT a body: it falls through to `text` exactly as the Elixir guard
		// (`is_list(content) and content != []`) does, or the two runtimes
		// disagree about the {content:[],text:"…"} item and the Go reader alone
		// renders a blank bullet.
		if content, ok := v["content"].([]any); ok && len(content) > 0 {
			return content
		}
		if text, ok := v["text"].(string); ok {
			return []any{text}
		}
		return []any{v}
	default:
		return []any{v}
	}
}

// decodeInlineJSON decodes a string that holds a JSON array whose first element
// is an object (an inline-node array), returning (nodes, true). Any other
// string — plain text, a JSON scalar, a non-object array — yields (nil, false)
// so the caller keeps it verbatim.
func decodeInlineJSON(s string) ([]any, bool) {
	trimmed := strings.TrimSpace(s)
	if !strings.HasPrefix(trimmed, "[") {
		return nil, false
	}
	var arr []any
	if err := json.Unmarshal([]byte(trimmed), &arr); err != nil || len(arr) == 0 {
		return nil, false
	}
	if _, ok := arr[0].(map[string]any); !ok {
		return nil, false
	}
	return arr, true
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
	content := attrSlice(b.Attrs, "content")
	if len(content) == 0 {
		if text := attrStr(b.Attrs, "text"); text != "" {
			content = []any{text}
		}
	}
	head.WriteString(cr.ir.Inline(content, ctx))
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
	// FRAMED variant (charter D19 — the framed-finale device): a SQUARE
	// lipgloss.NormalBorder frame in rule color REPLACES the two-rule band.
	// Honest degrade below MinWidth (the boxLines discipline): too narrow for
	// the border+padding chrome → fall through to the byte-identical band path
	// rather than emit a crushed frame. Any other variant value falls through
	// too (fail-soft, mirroring the web reader's unknown-variant bytes).
	const frameChrome = 4 // border (2) + padding (2)
	if attrStr(b.Attrs, "variant") == "framed" && ctx.Width-frameChrome >= MinWidth {
		body := sr.body(b, ctx.WithWidth(ctx.Width-frameChrome))
		frame := lipgloss.NewStyle().
			Border(lipgloss.NormalBorder()).
			BorderForeground(ruleColor(ctx.Theme)).
			Padding(0, 1).
			Width(clampWidth(ctx.Width - 2)) // 2 = the border's two columns
		return strings.Split(frame.Render(strings.Join(body, "\n")), "\n")
	}

	w := clampWidth(ctx.Width)
	rule := ctx.Theme.Rule.Render(strings.Repeat("─", w))

	out := []string{rule}
	out = append(out, sr.body(b, ctx)...)
	out = append(out, rule)
	return out
}

// body renders the section's interior — optional bold title + child blocks
// (grid or stack) — WITHOUT the surrounding chrome (the two-rule band or the
// framed border), so both chromes wrap the exact same lines. Extracted
// verbatim from the pre-frame Render loop: the band path's output is
// byte-identical to before.
func (sr sectionRenderer) body(b Block, ctx RenderCtx) []string {
	var out []string
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
			return append(out, grid...)
		}
	}

	// Stack path. Empty paragraph scaffolds emit no rows and therefore cannot
	// create phantom rhythm inside a section.
	emitted := 0
	for _, child := range b.Children {
		lines := sr.reg.Render(child, childCtx)
		if len(lines) == 0 {
			continue
		}
		if emitted > 0 {
			out = append(out, "")
		}
		for _, line := range lines {
			out = append(out, pad+line)
		}
		emitted++
	}

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
	// effectiveTracks honors a data-carried `breakpoints` array (resolve DESC by
	// minWidth against the available inner width; below every threshold → 1),
	// else the fixed gridTracks(layout["tracks"]). The `gap` token selects the
	// inter-cell gutter (none·sm·md·lg → 0·1·2·4; absent/unknown → md=2 =
	// DefaultFlex.Gutter, keeping gap-less sections byte-identical). A per-section
	// Flex threads that one gutter through the whole solve — divide, span, fit,
	// arrange.
	tracks := effectiveTracks(layout, inner)
	flex := Flex{Gutter: gapGutter(layout["gap"]), MinWidth: MinWidth}
	// The shared Flex solver owns the divide-formula + degrade verdict: cellW :=
	// (inner-(tracks-1)*gutter)/tracks; side-by-side only when tracks>1 AND
	// cellW>=MinWidth. A false verdict (tracks<2 or any cell too narrow) → nil,
	// signaling the caller to degrade to the byte-identical stack path.
	cellW, sideBySide := flex.Measure(inner, tracks)
	if !sideBySide {
		return nil
	}

	// Stable CSS-order reorder: the reader emits `order:`, i.e. it DOES reorder,
	// so a terminal stable-sort by order is parity-correct.
	items := make([]Block, 0, len(b.Children))
	for _, child := range b.Children {
		if len(sr.reg.Render(child, childCtx)) > 0 {
			items = append(items, child)
		}
	}
	if len(items) == 0 {
		return []string{}
	}
	sort.SliceStable(items, func(i, j int) bool { return cellOrder(items[i]) < cellOrder(items[j]) })

	nodes := make([]Node, len(items))
	for i, child := range items {
		s := cellSpan(child, tracks)
		cw := flex.spanWidth(cellW, s)
		nodes[i] = Node{Lines: sr.reg.Render(child, childCtx.WithWidth(cw)), Width: cw, Span: s}
	}

	// Measure-into-arrange: if any cell's realized min-content overflows its
	// (span-aware) allotted width, degrade — return nil so the caller takes the
	// byte-identical stack path rather than emit an over-wide grid row.
	if !flex.Fits(nodes) {
		return nil
	}

	rows := flex.ArrangeGrid(nodes, tracks)
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
