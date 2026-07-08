package pdrender

import (
	"math"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── side-by-side layout algebra ──────────────────────────────────────────────
//
// The ONE shared primitive behind the terminal's side-by-side surfaces —
// horizontal `columns`, N-up grid `section`s, and the bordered task-`board`
// lanes. Before this file every one of those COLLAPSED grid→stack (the
// documented cop-out compose.ex literally names), because "a terminal has no
// reliable side-by-side grid". It does: lipgloss.JoinHorizontal composes blocks
// column-wise, and the bp tasks TUI (internal/taskboard) already draws lanes.
// This file is the import-disciplined port of that capability: it depends on
// lipgloss + the stdlib ONLY (never internal/taskboard or internal/semrole — the
// go-list-deps invariant in render_test.go).
//
// THE DEGRADE CONTRACT every caller shares: per-cell width is
// (W-(N-1)*gutter)/N with gutter 2; when any cell would fall below MinWidth the
// caller keeps its EXISTING vertical-stack path verbatim, so a narrow surface
// stays byte-identical to today. All width math is ANSI-aware (lipgloss.Width),
// never len — child lines carry styled (colored) runs whose bytes ≠ cells.

// ── the two-pass solver: Flex / Node / Measure / Arrange ─────────────────────
//
// One place owns the divide-formula. Before this seam the SAME arithmetic —
// cellW := (W-(N-1)*gutter)/N plus the `N>1 && cellW>=MinWidth` degrade guard —
// was copy-pasted into three renderers (columns, section-grid, board lanes).
// Flex.Measure IS that arithmetic + the degrade DECISION; Flex.Arrange is the
// pad-and-JoinHorizontal pass. The split is deliberate: a caller Measures FIRST
// (the child width the verdict resolves is what the children are re-rendered at),
// then builds Nodes, then Arranges. Byte-faithful — the formula, gutter=2,
// integer division, and the sub-MinWidth verbatim-stack fallback are unchanged.

// Flex is the shared side-by-side solver's config: the inter-cell Gutter and the
// per-cell MinWidth floor below which a surface degrades to its vertical stack.
type Flex struct {
	Gutter   int
	MinWidth int
}

// DefaultFlex is the gutter=2 / MinWidth solver every terminal side-by-side
// surface uses (horizontal columns, N-up section grid, task-board lanes).
var DefaultFlex = Flex{Gutter: 2, MinWidth: MinWidth}

// Node is one child of a Flex layout: its already-rendered lines, the display
// width it was rendered at, and its span (slot consumption — 1 for an equal
// column, S for a section-grid cell spanning S tracks).
type Node struct {
	Lines []string
	Width int
	Span  int
}

// Measure is the FIRST pass — the divide-formula and the degrade verdict, the
// one arithmetic the three callers used to each inline. Per-track cell width is
// (avail-(tracks-1)*gutter)/tracks with integer division; `avail` is a DISPLAY
// width (ANSI-aware, measured by the caller via lipgloss.Width). sideBySide is
// true ONLY when tracks>1 AND cellW>=MinWidth — otherwise the caller keeps its
// verbatim vertical-stack path, byte-identical to before. tracks<1 is clamped to
// 1 (yields sideBySide=false) so a lone/empty surface never divides by zero.
func (f Flex) Measure(avail, tracks int) (cellW int, sideBySide bool) {
	if tracks < 1 {
		tracks = 1
	}
	cellW = (avail - (tracks-1)*f.Gutter) / tracks
	sideBySide = tracks > 1 && cellW >= f.MinWidth
	return
}

// spanWidth is a span-S cell's display width: S per-track cells plus the (S-1)
// gutters those tracks subsume. The one place the section grid's span arithmetic
// lives (was inlined at the grid caller); span<1 clamps to 1.
func (f Flex) spanWidth(cellW, span int) int {
	if span < 1 {
		span = 1
	}
	return span*cellW + (span-1)*f.Gutter
}

// nodeWidth is a Node's realized min-content: the widest of its already-rendered
// lines (lipgloss.Width — ANSI-aware, never len, since a styled line's bytes ≠
// its cells). It is what the child could NOT shrink below at the width it was
// rendered — a single unbreakable token wider than its allotted cell surfaces
// here as a nodeWidth above the Node's Width.
func nodeWidth(n Node) int {
	w := 0
	for _, ln := range n.Lines {
		if d := lipgloss.Width(ln); d > w {
			w = d
		}
	}
	return w
}

// Fits is the SECOND half of "measure into arrange". Measure decides side-by-side
// purely on the divide-formula (cellW>=MinWidth); it never asks how narrow each
// child can actually go. Fits does: it returns false if any Node's realized
// min-content (nodeWidth) exceeds its ALLOTTED cell Width — span-aware, since a
// section-grid Node's Width already folds its span via spanWidth. A false verdict
// means a wide unbreakable token would overflow its track, so the caller must
// degrade to its verbatim vertical stack instead of emitting an over-wide row.
// The current corpus never over-fills a side-by-side cell, so Fits is true for
// every existing golden — the collapse fires only on genuine content-min overflow.
func (f Flex) Fits(nodes []Node) bool {
	for _, n := range nodes {
		if nodeWidth(n) > n.Width {
			return false
		}
	}
	return true
}

// Arrange is the SECOND pass for equal-track surfaces (columns, board lanes):
// pad each Node's lines to its width and join them side-by-side with Gutter
// blank columns between. Delegates to joinColumns (the byte-faithful body).
func (f Flex) Arrange(nodes []Node) []string {
	cells := make([][]string, len(nodes))
	widths := make([]int, len(nodes))
	for i, nd := range nodes {
		cells[i] = nd.Lines
		widths[i] = nd.Width
	}
	return joinColumns(cells, widths, f.Gutter)
}

// ArrangeGrid is the SECOND pass for the spanning section grid: chunk the Nodes
// into rows of `tracks` slots by span, then join each row. Delegates to gridRows
// (the byte-faithful body); a Node's Span is its slot consumption.
func (f Flex) ArrangeGrid(nodes []Node, tracks int) []string {
	cells := make([][]string, len(nodes))
	widths := make([]int, len(nodes))
	spans := make([]int, len(nodes))
	for i, nd := range nodes {
		cells[i] = nd.Lines
		widths[i] = nd.Width
		spans[i] = nd.Span
	}
	return gridRows(cells, widths, spans, tracks, f.Gutter)
}

// joinColumns pads each group's lines to its width and joins the groups
// side-by-side, row-wise, with `gutter` blank columns between them. Unequal
// heights → lipgloss.JoinHorizontal(Top) bottom-pads the shorter columns with
// spaces of the cell's block width. Widths are ANSI-aware (lipgloss.Width); the
// gutter is baked into each non-last cell's trailing pad (a deterministic
// spacer — a lone spacer string joins oddly across unequal heights).
func joinColumns(groups [][]string, widths []int, gutter int) []string {
	if len(groups) == 0 {
		return nil
	}
	cells := make([]string, 0, len(groups))
	for i, g := range groups {
		w := widths[i]
		padded := make([]string, len(g))
		for j, ln := range g {
			padded[j] = padRight(ln, w)
		}
		cell := strings.Join(padded, "\n")
		if i < len(groups)-1 && gutter > 0 {
			cell = padRightBlock(cell, w+gutter) // gutter as trailing spaces
		}
		cells = append(cells, cell)
	}
	return strings.Split(lipgloss.JoinHorizontal(lipgloss.Top, cells...), "\n")
}

// padRight right-pads s to `w` DISPLAY columns (lipgloss.Width, NOT len — s may
// carry ANSI styling). An already-wide line is left untouched: children are
// recursed at exactly w, so overflow is a wide-token edge case a defensive
// caller pre-truncates; padding never truncates styled content mid-ANSI.
func padRight(s string, w int) string {
	if d := lipgloss.Width(s); d < w {
		return s + strings.Repeat(" ", w-d)
	}
	return s
}

// padRightBlock right-pads every line of a multi-line block to `w` display
// columns, so a whole cell (including its trailing gutter) is a rectangle before
// JoinHorizontal measures it.
func padRightBlock(block string, w int) string {
	lines := strings.Split(block, "\n")
	for i, ln := range lines {
		lines[i] = padRight(ln, w)
	}
	return strings.Join(lines, "\n")
}

// gridRows lays already-rendered cells into rows of `tracks` columns, respecting
// per-cell span slot-consumption: a span-S cell consumes S of the row's `tracks`
// slots (its width already S*cellW+(S-1)*gutter), and a cell that would overflow
// the current row wraps to the next. Each row is JoinHorizontal'd via
// joinColumns; a blank line separates rows. spans are pre-clamped to [1,tracks]
// by the caller.
func gridRows(cells [][]string, widths []int, spans []int, tracks, gutter int) []string {
	// Chunk the cells into rows by slot consumption.
	var rows [][]int
	var cur []int
	used := 0
	for i := range cells {
		s := spans[i]
		if s < 1 {
			s = 1
		}
		if s > tracks {
			s = tracks
		}
		if used+s > tracks && len(cur) > 0 {
			rows = append(rows, cur)
			cur = nil
			used = 0
		}
		cur = append(cur, i)
		used += s
	}
	if len(cur) > 0 {
		rows = append(rows, cur)
	}

	var out []string
	for ri, row := range rows {
		if ri > 0 {
			out = append(out, "") // blank gap between grid rows
		}
		groups := make([][]string, len(row))
		ws := make([]int, len(row))
		for k, idx := range row {
			groups[k] = cells[idx]
			ws[k] = widths[idx]
		}
		out = append(out, joinColumns(groups, ws, gutter)...)
	}
	return out
}

// gapGutter maps a section's `gap` token to the inter-cell gutter cell count:
// none·sm·md·lg → 0·1·2·4. Absent / unknown / non-string → md (2), which equals
// DefaultFlex.Gutter, so a gap-less section stays byte-identical to today.
func gapGutter(token any) int {
	s, _ := token.(string)
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "none":
		return 0
	case "sm":
		return 1
	case "lg":
		return 4
	default: // "md", unknown, absent, non-string
		return 2
	}
}

// effectiveTracks resolves the section grid's track count for a given available
// width. When `layout` carries a `breakpoints` array ([{minWidth, tracks}]) the
// valid entries are sorted DESC by minWidth and the FIRST whose minWidth <= avail
// wins (its tracks). When avail is below EVERY threshold the grid collapses to a
// single stacked track (return 1 — the shared Flex.Measure/Fits machinery then
// governs). Absent / empty / all-malformed breakpoints fall back to the fixed
// gridTracks(layout["tracks"]), so a section without breakpoints is unchanged.
func effectiveTracks(layout map[string]any, avail int) int {
	raw := attrSlice(layout, "breakpoints")
	type bp struct{ minWidth, tracks int }
	var bps []bp
	for _, e := range raw {
		m, ok := e.(map[string]any)
		if !ok {
			continue // ignore malformed (non-object) entries
		}
		mw := attrInt(m, "minWidth", -1)
		tr := attrInt(m, "tracks", -1)
		if mw < 0 || tr < 1 {
			continue // ignore entries missing a usable minWidth/tracks
		}
		bps = append(bps, bp{mw, tr})
	}
	if len(bps) == 0 {
		return gridTracks(layout["tracks"])
	}
	sort.Slice(bps, func(i, j int) bool { return bps[i].minWidth > bps[j].minWidth })
	for _, b := range bps {
		if b.minWidth <= avail {
			return b.tracks
		}
	}
	return 1 // avail below every threshold → single stacked track
}

// gridTracks mirrors compose.ex grid_tracks/1: a positive integer column count,
// a stringy positive int (the WHOLE string must parse), else the default 2.
func gridTracks(v any) int {
	switch n := v.(type) {
	case int:
		if n > 0 {
			return n
		}
	case int64:
		if n > 0 {
			return int(n)
		}
	case float64:
		if n == math.Trunc(n) && n > 0 {
			return int(n)
		}
	case string:
		if i, err := strconv.Atoi(n); err == nil && i > 0 {
			return i
		}
	}
	return 2
}

// cellSpan reads a grid child's `span`: a positive int (or stringy positive int),
// clamped to [1, tracks]; absent/malformed → 1. Mirrors compose.ex span_int (a
// span > tracks wraps to a full row rather than overflowing).
func cellSpan(b Block, tracks int) int {
	s := spanInt(b.Attrs["span"])
	if s < 1 {
		s = 1
	}
	if s > tracks {
		s = tracks
	}
	return s
}

// cellOrder reads a grid child's CSS `order`: any int (or stringy whole int);
// absent/malformed → 0 (the CSS default, so a child with no order keeps its
// source position under a stable sort). Mirrors compose.ex order_int.
func cellOrder(b Block) int {
	if o, ok := orderInt(b.Attrs["order"]); ok {
		return o
	}
	return 0
}

// spanInt mirrors compose.ex span_int: a positive int or stringy positive int,
// else 0 (drop → default slot).
func spanInt(v any) int {
	switch n := v.(type) {
	case int:
		if n > 0 {
			return n
		}
	case int64:
		if n > 0 {
			return int(n)
		}
	case float64:
		if n == math.Trunc(n) && n > 0 {
			return int(n)
		}
	case string:
		if i, err := strconv.Atoi(n); err == nil && i > 0 {
			return i
		}
	}
	return 0
}

// orderInt mirrors compose.ex order_int: any int, or a stringy whole int (0 and
// negatives are legal). ok=false when absent/malformed (→ falls safe to 0).
func orderInt(v any) (int, bool) {
	switch n := v.(type) {
	case int:
		return n, true
	case int64:
		return int(n), true
	case float64:
		if n == math.Trunc(n) {
			return int(n), true
		}
	case string:
		if i, err := strconv.Atoi(n); err == nil {
			return i, true
		}
	}
	return 0, false
}
