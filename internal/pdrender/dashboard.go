package pdrender

import (
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── dashboard: a tabbed container that composes child blocks in a grid ────────
//
// The terminal counterpart of a Claude-Code-/usage-style cockpit: authored tabs
// over the top, and the ACTIVE tab's child blocks (chart / heatmap / stat-grid /
// gauge-list …) laid out through the shared Flex solver as a two-track grid. It
// is the composition capstone of the TUI creative slate — every slate block is a
// leaf; the dashboard is the one container that arranges them into a single screen.
//
// This is a Go-only container renderer (charter-D22, pbp-tui-slate-2-charter.md:47
// — dashboard ships Go-only, NO Elixir twin): the web/Studio reader draws its own
// tabbed dashboard, and until the Elixir compose seam gains a `dashboard` case the
// web reader falls back to its unknown-block box — an ACCEPTED, conscious
// ⊆-projection divergence (the gauge-list precedent: a registered Go block ahead of
// its Elixir sibling). D12 is the wave-process rule (Go gate, worktrees mandatory);
// D22 is the per-block ratification that actually owns this divergence.
//
// Import discipline holds: only lipgloss + the stdlib, styles come from the
// injected Theme, every document-controlled string passes through sanitizeText
// before display, and the renderer degrades (never panics) on empty tabs, an
// empty active tab, or a sub-MinWidth surface.
//
// SNAPSHOT-AUTHORITATIVE ($span is INERT). A tab's child block may carry a
// `query` map with a `$span` variable naming the active tab — pdrender NEVER reads
// it. Child blocks render from their pinned snapshot data exactly as they do at
// top level; wiring `$span` into a live child query is a future Elixir resolver
// wave (the `agg_for_query/2` seam, tasks/query.ex), out of this Go-only slice.
// The token is carried through the wire untouched so the resolver can adopt it.
//
// ACTIVE-TAB TOKEN ROLE (Unified Aesthetic manifest decision). The active tab and
// its rail use ONE tone — the accent (ctx.Theme.Accent) — reinforced by weight
// (Bold), NOT a second background/inverse token. Rationale: the manifest reserves
// inverse/filled chips for PRESSABLE affordances (ActionPrimary); a dashboard tab
// is a reader-state selector, not a button, so it borrows the same accent the
// eyebrow/heading-1 use for "this is the live thing" and lets the heavy ━ rail
// (geometry, not colour) carry the selection at every profile — the detail-ceiling
// law: an ANSI strip must still show which tab is active. The rail's ━ vs ─ IS
// that proof (a bold-only active label would strip away and pass the law vacuously).

type dashboardRenderer struct{ reg *Registry }

// dashTab is one authored tab: its display label and its (already-decoded) child
// blocks. Absent/blank label → a dim "·" placeholder so the strip never collapses.
type dashTab struct {
	label  string
	blocks []Block
}

// dashStripRows is the fixed height of the tab strip + its rhythm gap (labels
// row, rail row, one blank line) — subtracted from the height budget.
const dashStripRows = 3

func (dr dashboardRenderer) Render(b Block, ctx RenderCtx) []string {
	tabs := dashboardTabs(b.Attrs)
	if len(tabs) == 0 {
		return []string{""}
	}
	w := clampWidth(ctx.Width)

	// Reader-state active tab (attrInt default 0), clamped into range so a stale
	// index never panics or renders an empty body.
	active := attrInt(b.Attrs, "active", 0)
	if active < 0 {
		active = 0
	}
	if active >= len(tabs) {
		active = len(tabs) - 1
	}

	// Height budget: the renderer owns its own height because the layout engine is
	// width-only (Flex.Measure/Arrange never bound height). `rows` (default 22)
	// caps the WHOLE card incl. the tab strip; clamp so the body always keeps at
	// least one line under the strip.
	rows := attrInt(b.Attrs, "rows", 22)
	if rows < dashStripRows+1 {
		rows = dashStripRows + 1
	}

	head := dr.tabStrip(tabs, active, w, ctx)
	head = append(head, "") // rhythm blank between strip and body

	body := dr.renderBody(tabs[active].blocks, w, ctx)
	body = budgetLines(body, rows-len(head), ctx.Theme)

	return append(head, body...)
}

// renderBody composes the active tab's child blocks into a two-track grid via the
// shared Flex solver (charter: "composing child blocks via the layout engine").
// Each child is measured at full width first (to drop blank leaves and count N
// honestly), then re-rendered at the resolved cell width and Arranged into a grid
// of `tracks=2`. Below the per-cell floor (or when a child's min-content overflows
// its cell) it degrades to the byte-identical verbatim vertical stack.
func (dr dashboardRenderer) renderBody(blocks []Block, w int, ctx RenderCtx) []string {
	fullCtx := ctx.Deeper().WithWidth(w)
	kept := make([]Block, 0, len(blocks))
	fullGroups := make([][]string, 0, len(blocks))
	for _, blk := range blocks {
		lines := dr.reg.Render(blk, fullCtx)
		if isBlankGroup(lines) {
			continue
		}
		kept = append(kept, blk)
		fullGroups = append(fullGroups, lines)
	}
	n := len(fullGroups)
	if n == 0 {
		return []string{""}
	}

	// Grid path: 2 uniform tracks. Measure owns the (W-(N-1)*gutter)/N divide and
	// the degrade verdict; re-render each child at cellW so its content binds to
	// the cell, then ArrangeGrid chunks the nodes into rows of 2.
	const tracks = 2
	if cellW, sideBySide := DefaultFlex.Measure(w, tracks); sideBySide {
		cellCtx := ctx.Deeper().WithWidth(cellW)
		nodes := make([]Node, n)
		for i, blk := range kept {
			nodes[i] = Node{Lines: dr.reg.Render(blk, cellCtx), Width: cellW, Span: 1}
		}
		if DefaultFlex.Fits(nodes) {
			return DefaultFlex.ArrangeGrid(nodes, tracks)
		}
	}

	// Narrow degrade: stack full-width with a blank rhythm line between children.
	out := make([]string, 0, n*2)
	for i, g := range fullGroups {
		if i > 0 {
			out = append(out, "")
		}
		out = append(out, g...)
	}
	return out
}

// tabStrip draws the two-row selector: a labels row (inactive Dim, active
// Accent+Bold) and a full-width rule row with a heavy ━ (Accent+Bold) under the
// active tab and dim ─ elsewhere. The rail is placed by the active label's plain
// column span so the heavy run sits exactly beneath it. A many-tab strip that
// outgrows the surface is clamped to width with the house … ellipsis (the rail
// already clamps; the labels row must never be the one over-wide line a
// dashboard emits).
func (dr dashboardRenderer) tabStrip(tabs []dashTab, active, w int, ctx RenderCtx) []string {
	const gap = 2 // blank columns between adjacent tab labels

	activeStyle := ctx.Theme.Body.Bold(true).Foreground(ctx.Theme.Accent)
	inactiveStyle := ctx.Theme.Dim

	var labels strings.Builder
	col, activeStart, activeWidth := 0, 0, 0
	for i, t := range tabs {
		if i > 0 {
			labels.WriteString(strings.Repeat(" ", gap))
			col += gap
		}
		lw := lipgloss.Width(t.label)
		if i == active {
			activeStart, activeWidth = col, lw
			labels.WriteString(activeStyle.Render(t.label))
		} else {
			labels.WriteString(inactiveStyle.Render(t.label))
		}
		col += lw
	}

	return []string{truncateANSI(labels.String(), w), dr.tabRail(activeStart, activeWidth, w, ctx)}
}

// tabRail builds the full-width rule under the labels: dim ─ up to the active
// label, a heavy Accent+Bold ━ run exactly the active label's width, dim ─ for the
// rest. The heavy run is the geometry that survives an ANSI strip — the machine
// form of "which tab is active" (detail-ceiling doctrine). Clamped so an
// over-wide label strip never draws past the surface.
func (dashboardRenderer) tabRail(start, width, w int, ctx RenderCtx) string {
	if start > w {
		start = w
	}
	if start+width > w {
		width = w - start
	}
	if width < 0 {
		width = 0
	}
	suffix := w - start - width
	if suffix < 0 {
		suffix = 0
	}

	heavy := ctx.Theme.Body.Bold(true).Foreground(ctx.Theme.Accent)
	dim := ctx.Theme.Dim
	var sb strings.Builder
	if start > 0 {
		sb.WriteString(dim.Render(strings.Repeat("─", start)))
	}
	if width > 0 {
		sb.WriteString(heavy.Render(strings.Repeat("━", width)))
	}
	if suffix > 0 {
		sb.WriteString(dim.Render(strings.Repeat("─", suffix)))
	}
	return sb.String()
}

// budgetLines caps a rendered body to `budget` lines. When the body overflows,
// its tail is replaced by a single dim truncation marker naming the elided row
// count — so an over-tall composition degrades honestly instead of blowing the
// dashboard's height budget. Uses ctx.Theme.Dim (a foreground colour), never
// lipgloss.Faint (charter-D8: the wasm reader has no SGR-2 case).
func budgetLines(lines []string, budget int, theme Theme) []string {
	if budget < 1 {
		budget = 1
	}
	if len(lines) <= budget {
		return lines
	}
	elided := len(lines) - (budget - 1)
	kept := make([]string, 0, budget)
	kept = append(kept, lines[:budget-1]...)
	marker := theme.Dim.Render("… " + strconv.Itoa(elided) + " more rows")
	return append(kept, marker)
}

// dashboardTabs reads the `tabs` array off a dashboard block. Each entry is a
// {label, blocks} object; non-object entries are skipped. A blank label becomes a
// dim "·" placeholder so the strip never collapses to nothing. Child blocks are
// normalized via slotBlocks (the same []any-or-single-map tolerance the card slots
// and columns use), reusing blockFromMap so nested containers still recurse.
func dashboardTabs(m map[string]any) []dashTab {
	raw := attrSlice(m, "tabs")
	if raw == nil {
		return nil
	}
	out := make([]dashTab, 0, len(raw))
	for _, el := range raw {
		obj, ok := el.(map[string]any)
		if !ok {
			continue
		}
		label := sanitizeText(strings.TrimSpace(attrStr(obj, "label")))
		if label == "" {
			label = "·"
		}
		out = append(out, dashTab{label: label, blocks: slotBlocks(obj["blocks"])})
	}
	return out
}
