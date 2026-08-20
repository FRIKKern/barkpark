package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── layout / container widgets: columns / terminal ───────────────────────────
//
// These two blocks are the terminal counterparts of the PortableDoc container
// widgets the web/Studio reader draws (compose.ex `columns` + `terminal`).
// Before this file they fell through to the "unknown block" fallback box in the
// TUI/CLI while the web reader rendered them fully — a cross-surface divergence
// this closes (pdrender-block-parity: columns / terminal).
//
// Import discipline holds: only lipgloss + the stdlib, styles come from the
// injected Theme, every document-controlled string passes through sanitizeText
// before display, and each renderer degrades (never panics) on empty attrs,
// empty columns/children, or a sub-MinWidth column.

// ── columns ──────────────────────────────────────────────────────────────────
// Mirrors compose_block(columns): `columns` is a LIST of columns, each a list of
// blocks. When the surface is wide enough for every column to clear MinWidth we
// lay them SIDE-BY-SIDE (the P9 80-column standard — the terminal DOES have a
// grid: lipgloss.JoinHorizontal), each column re-recursed at its sub-width so its
// content wraps correctly. Below that per-cell floor we degrade EXACTLY like
// before — STACK the columns vertically, separated by a light hairline rule (the
// same narrow-surface collapse the reader does). Each column's blocks recurse
// through the registry (ctx.Deeper). Columns that render nothing are dropped (no
// doubled rule / no empty lane); no non-empty column → one blank line.
//
// The `columns` key is NOT decoded by decode.go into Block.Children, so we pull
// it straight off Attrs and normalize each column via slotBlocks (the same
// []any-or-single-map tolerance the card slots use), which reuses blockFromMap
// so nested section/figure children inside a column still recurse.
type columnsRenderer struct{ reg *Registry }

func (cr columnsRenderer) Render(b Block, ctx RenderCtx) []string {
	cols, _ := b.Attrs["columns"].([]any)
	if len(cols) == 0 {
		return []string{""}
	}

	w := clampWidth(ctx.Width)
	fullCtx := ctx.Deeper().WithWidth(w)

	// Render each column at full width first; keep only non-empty groups so an
	// empty column never leaves a doubled separator (and to count N honestly).
	kept := make([][]Block, 0, len(cols))
	fullGroups := make([][]string, 0, len(cols))
	for _, col := range cols {
		blocks := slotBlocks(col)
		lines := cr.renderColumn(blocks, fullCtx)
		if len(lines) > 0 {
			kept = append(kept, blocks)
			fullGroups = append(fullGroups, lines)
		}
	}
	n := len(fullGroups)
	if n == 0 {
		return []string{""}
	}

	// Horizontal path: the shared Flex solver resolves per-cell width and the
	// degrade verdict (Measure owns the (W-(N-1)*gutter)/N divide; side-by-side
	// when >1 column clears MinWidth). Re-render each column at cellW (so wrapping is right — the
	// full-width groups above would overflow) and Arrange them side-by-side.
	// Integer division may leave ≤N-1 columns of unused trailing slack; never overflows.
	cellW, sideBySide := DefaultFlex.Measure(w, n)
	if sideBySide {
		cellCtx := ctx.Deeper().WithWidth(cellW)
		nodes := make([]Node, n)
		for i, blocks := range kept {
			nodes[i] = Node{Lines: cr.renderColumn(blocks, cellCtx), Width: cellW, Span: 1}
		}
		// Measure-into-arrange: only lay side-by-side if every column's realized
		// min-content fits its cell. A wide unbreakable token (nodeWidth > cellW)
		// would overflow the track, so fall through to the verbatim stack instead.
		if DefaultFlex.Fits(nodes) {
			return DefaultFlex.Arrange(nodes)
		}
	}

	// Fallback (verbatim): stack the columns with a hairline rule — taken when a
	// cell falls below MinWidth OR a column's content min-width overflows its cell.
	rule := ctx.Theme.Rule.Render(strings.Repeat("─", w))
	out := make([]string, 0)
	for i, g := range fullGroups {
		if i > 0 {
			out = append(out, rule) // light separator between stacked columns
		}
		out = append(out, g...)
	}
	return out
}

// renderColumn renders one column's blocks through the registry at ctx's width,
// with a blank rhythm line between consecutive blocks (the RenderDoc cadence).
func (cr columnsRenderer) renderColumn(blocks []Block, ctx RenderCtx) []string {
	var lines []string
	emitted := 0
	for _, blk := range blocks {
		group := cr.reg.Render(blk, ctx)
		if len(group) == 0 {
			continue
		}
		if emitted > 0 {
			lines = append(lines, "") // rhythm between stacked blocks
		}
		lines = append(lines, group...)
		emitted++
	}
	return lines
}

// ── terminal ───────────────────────────────────────────────────────────────────
// Mirrors compose_block(terminal): a reusable "terminal chrome" frame — a
// traffic-light title bar (● ● ●) with an optional `title` and a `live` tag,
// wrapping any child blocks, plus an optional dim `footer` line. There are NO
// prompt/command/output fields; command-vs-output styling comes from the child
// blocks (e.g. a `code` block) the frame holds, exactly like the reader.
//
// The box borrows figureRenderer's rounded-border idiom (chrome=4, flat-degrade
// below MinWidth). Children come from `children`, falling back to `blocks`
// (mirroring the reader's container_children `children || blocks`), each recursed
// through the registry. Every displayed string passes through sanitizeText.
type terminalRenderer struct{ reg *Registry }

func (tr terminalRenderer) Render(b Block, ctx RenderCtx) []string {
	title := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "title")))
	footer := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "footer")))
	live := attrTruthy(b.Attrs["live"])

	const chrome = 4 // rounded border (2) + padding (2)
	inner := ctx.Width - chrome
	flat := inner < MinWidth
	childWidth := inner
	if flat {
		childWidth = ctx.Width
	}
	childCtx := ctx.Deeper().WithWidth(clampWidth(childWidth))

	// Title bar: traffic-light dots · bold title · accent `live` chip. The dots
	// are the terminal's identity, so the bar is always emitted (even bare).
	var bar strings.Builder
	bar.WriteString(ctx.Theme.Dim.Render("● ● ●"))
	if title != "" {
		bar.WriteString("  ")
		bar.WriteString(ctx.Theme.Body.Bold(true).Render(title))
	}
	if live {
		bar.WriteString("  ")
		bar.WriteString(ctx.Theme.ActionPrimary.Render(" live "))
	}

	lines := []string{bar.String()}
	for _, blk := range tr.terminalChildren(b) {
		lines = append(lines, tr.reg.Render(blk, childCtx)...)
	}
	if footer != "" {
		lines = append(lines, ctx.Theme.Dim.Render(footer))
	}

	if flat {
		return lines
	}

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ruleColor(ctx.Theme)).
		Padding(0, 1).
		// lipgloss Width INCLUDES the padding (border excluded): inner+2 gives the
		// children their full `inner` columns and lands the border on ctx.Width.
		// Width(inner) left inner-2 for content, force-wrapping bordered children.
		Width(clampWidth(inner + 2)).
		Render(body)
	return strings.Split(box, "\n")
}

// terminalChildren normalizes the terminal's child blocks: the `children` key,
// falling back to `blocks` (the reader's container_children order). Only a JSON
// array yields children (a non-list value → none), matching render_blocks/2's
// is_list guard; decodeAnyBlocks reuses blockFromMap so nested containers recurse.
func (terminalRenderer) terminalChildren(b Block) []Block {
	raw := attrSlice(b.Attrs, "children")
	if raw == nil {
		raw = attrSlice(b.Attrs, "blocks")
	}
	if raw == nil {
		return nil
	}
	return decodeAnyBlocks(raw, 0)
}

// attrTruthy mirrors the reader's `live in [true, "true", "live"]` truthiness:
// the bool true, or the strings "true"/"live". Anything else → false.
func attrTruthy(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case string:
		return x == "true" || x == "live"
	}
	return false
}
