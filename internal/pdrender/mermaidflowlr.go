package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── flowchart LR — the responsive flex-direction transpose ───────────────────
//
// Ink/Yoga's lesson made literal: Mermaid `direction` is a flex-direction. TD
// stacks ranks vertically (mermaidflow.go); LR marches them left-to-right, each
// rank a vertical stack of boxes, joined by HORIZONTAL connector bands. The
// responsive move the brief insisted on: LR is re-laid-out as TD — not reflowed —
// when it can't fit the terminal (renderFlowchartLR returns nil and the caller
// falls back to the TD engine). Node placement transposes; edges RE-ROUTE.
//
// LR builds on a fixed character CANVAS (2-D is natural here: ranks have
// different heights and boxes sit at arbitrary y), stamping boxes then bands,
// then reading rows out with a per-cell style mask so label text stays readable
// while structure stays dim — the same visual weight as the TD engine. Every
// emitted row is padded to width: rectangular, so it can't misalign.

const (
	lrBand   = 6 // columns of horizontal connector band between ranks
	lrVGap   = 1 // blank rows between stacked boxes within a rank
	lrMaxH   = 120
	kindNone = 0
	kindWire = 1 // structural (box border, connector) → dim
	kindText = 2 // label text → body weight
)

// canvas is a fixed W×H grid of runes plus a parallel style-kind mask, so a
// horizontal layout can be composed 2-D and read back with mixed styling.
type canvas struct {
	w, h  int
	cells [][]rune
	kind  [][]int
}

func newCanvas(w, h int) *canvas {
	c := &canvas{w: w, h: h, cells: make([][]rune, h), kind: make([][]int, h)}
	for y := 0; y < h; y++ {
		c.cells[y] = make([]rune, w)
		c.kind[y] = make([]int, w)
		for x := 0; x < w; x++ {
			c.cells[y][x] = ' '
		}
	}
	return c
}

func (c *canvas) set(x, y int, r rune, k int) {
	if x < 0 || x >= c.w || y < 0 || y >= c.h {
		return
	}
	c.cells[y][x] = r
	c.kind[y][x] = k
}

func (c *canvas) at(x, y int) rune {
	if x < 0 || x >= c.w || y < 0 || y >= c.h {
		return ' '
	}
	return c.cells[y][x]
}

// rows reads the canvas out, styling each maximal same-kind run so label text is
// body-weight and structure is dim. Trailing blanks are trimmed; the caller pads.
func (c *canvas) rows(ctx RenderCtx) []string {
	out := make([]string, c.h)
	for y := 0; y < c.h; y++ {
		var b strings.Builder
		x := 0
		for x < c.w {
			k := c.kind[y][x]
			j := x
			for j < c.w && c.kind[y][j] == k {
				j++
			}
			seg := strings.TrimRight(string(c.cells[y][x:j]), " ")
			if seg != "" {
				switch k {
				case kindText:
					b.WriteString(ctx.Theme.Body.Render(seg))
				default:
					b.WriteString(ctx.Theme.Dim.Render(seg))
				}
			} else if j < c.w {
				// interior blank run inside content — keep the spaces
				b.WriteString(strings.Repeat(" ", j-x))
			}
			x = j
		}
		out[y] = b.String()
	}
	return out
}

// renderFlowchartLR draws a left-to-right flowchart, or returns nil when it can't
// fit ctx.Width cleanly (caller collapses to the TD engine). Only called when the
// declared direction is LR/RL.
func renderFlowchartLR(g *mmGraph, ctx RenderCtx) []string {
	if g == nil || len(g.nodes) == 0 {
		return nil
	}
	W := clampWidth(ctx.Width)

	rank := assignRanks(g)
	layers := groupByRank(g, rank)
	orderLayers(layers, g, rank)
	if len(layers) < 2 {
		return nil // a single rank isn't an LR flow; TD renders it fine
	}

	// Per-rank box width = widest label in the rank (capped); a rank's boxes all
	// share it so their left/right edges line up (clean band attach points).
	rankW := make([]int, len(layers))
	boxes := make([]map[string][]string, len(layers))
	for li, layer := range layers {
		content := 0
		for _, n := range layer {
			if w := lipgloss.Width(sanitizeText(n.label)); w > content {
				content = w
			}
		}
		if content > flowMaxNodeW {
			content = flowMaxNodeW
		}
		if content < 3 {
			content = 3
		}
		rankW[li] = content + 4 // border + padding
		boxes[li] = map[string][]string{}
		for _, n := range layer {
			boxes[li][n.id] = renderNodeBoxPlain(n, content)
		}
	}

	// Total width: rank widths + inter-rank bands. Bail to TD if it overflows.
	totalW := (len(layers) - 1) * lrBand
	for _, w := range rankW {
		totalW += w
	}
	if totalW > W {
		return nil // won't fit horizontally → collapse to TD
	}

	// Vertical geometry: each rank stacks its boxes (height 3 each + vGap),
	// vertically centered against the tallest rank. Compute node y-centers.
	rankH := make([]int, len(layers))
	for li, layer := range layers {
		rankH[li] = len(layer)*3 + (len(layer)-1)*lrVGap
	}
	maxH := 0
	for _, h := range rankH {
		if h > maxH {
			maxH = h
		}
	}
	if maxH > lrMaxH {
		return nil // pathologically tall → TD is the honest choice
	}

	// x offset per rank (left edges) and y-center per node.
	rankX := make([]int, len(layers))
	x := (W - totalW) / 2
	if x < 0 {
		x = 0
	}
	yc := map[string]int{}
	xLeft := map[string]int{}
	xRight := map[string]int{}
	for li, layer := range layers {
		rankX[li] = x
		top := (maxH - rankH[li]) / 2
		for i, n := range layer {
			by := top + i*(3+lrVGap)
			yc[n.id] = by + 1 // box mid row
			xLeft[n.id] = x
			xRight[n.id] = x + rankW[li] - 1
		}
		x += rankW[li] + lrBand
	}

	cv := newCanvas(W, maxH)
	// Stamp boxes.
	for li, layer := range layers {
		top := (maxH - rankH[li]) / 2
		for i, n := range layer {
			by := top + i*(3+lrVGap)
			stampBox(cv, rankX[li], by, boxes[li][n.id])
		}
	}
	// Accumulate ALL adjacent-rank edges' connectivity into one bit grid, THEN
	// resolve glyphs once — so several edges sharing a bus column compose into
	// clean tees/crosses instead of overwriting each other (the transpose of the
	// TD bus). Edges spanning >1 rank go to the legend.
	bits := map[[2]int]int{}
	arrows := map[[2]int]bool{}
	var labels []lrLabelSpec
	for _, e := range g.edges {
		if rank[e.to]-rank[e.from] != 1 {
			continue
		}
		markLR(bits, arrows, &labels, xRight[e.from]+1, yc[e.from], xLeft[e.to]-1, yc[e.to], e.label)
	}
	for pos, b := range bits {
		if arrows[pos] {
			continue // arrowheads stamped below
		}
		if cv.at(pos[0], pos[1]) != ' ' {
			continue // never overwrite a box border
		}
		gl, ok := bandGlyph[b]
		if !ok {
			gl = '─'
		}
		cv.set(pos[0], pos[1], gl, kindWire)
	}
	for pos := range arrows {
		cv.set(pos[0], pos[1], '▶', kindWire)
	}
	for _, lb := range labels {
		placeLRLabel(cv, lb.text, lb.cx, lb.ly, ctx)
	}

	out := cv.rows(ctx)
	// Legend for edges no band drew.
	if legend := renderEdgeLegend(g, rank, nil, W, ctx); len(legend) > 0 {
		out = append(out, "")
		out = append(out, legend...)
	}
	for i := range out {
		out[i] = padRight(out[i], W)
	}
	return out
}

// lrLabelSpec is a deferred edge-label placement (resolved after the bus glyphs
// are laid so the all-or-nothing collision check sees them).
type lrLabelSpec struct {
	cx, ly int
	text   string
}

// markLR marks one horizontal connector from a source right-edge (sx,sy) to a
// target left-edge (tx,ty) into a SHARED bit grid: a source leg to the mid-x bus
// column, an (endpoint-aware) vertical bus segment, and a target leg out to the
// arrowhead. Because every edge in a rank-boundary shares the same mid-x column
// (all boxes in a rank share a width), their bits compose there into correct
// tees/corners — a fan-out reads ├, a merge reads ┤, a straight passthrough that
// a bus crosses reads ┼. Arrowheads + labels are recorded for a later pass.
func markLR(bits map[[2]int]int, arrows map[[2]int]bool, labels *[]lrLabelSpec, sx, sy, tx, ty int, label string) {
	if tx < sx {
		return
	}
	midx := (sx + tx) / 2
	mark := func(x, y, b int) { bits[[2]int{x, y}] |= b }

	for x := sx; x < midx; x++ { // source leg → bus
		mark(x, sy, cL|cR)
	}
	mark(midx, sy, cL)                // enters the bus column from the left
	for x := midx + 1; x <= tx; x++ { // bus → target leg
		mark(x, ty, cL|cR)
	}
	mark(midx, ty, cR) // leaves the bus column to the right
	lo, hi := sy, ty
	if lo > hi {
		lo, hi = hi, lo
	}
	if lo != hi { // vertical bus only when the rows differ
		for y := lo; y <= hi; y++ {
			b := cU | cD
			if y == lo {
				b = cD
			}
			if y == hi {
				b = cU
			}
			mark(midx, y, b)
		}
	}
	arrows[[2]int{tx, ty}] = true
	if lo > 0 {
		*labels = append(*labels, lrLabelSpec{midx, lo - 1, label})
	}
}

// placeLRLabel stamps an edge label centered at cx on row ly — but ALL-or-nothing:
// if any target cell is non-blank it skips entirely, so a label never smears over
// a box or connector (it simply doesn't show, and the TD render still carries it).
func placeLRLabel(cv *canvas, label string, cx, ly int, ctx RenderCtx) {
	if label == "" || ly < 0 {
		return
	}
	txt := []rune(sanitizeText(label))
	start := cx - len(txt)/2
	for i := range txt {
		if cv.at(start+i, ly) != ' ' {
			return // no clean room — defer to the TD render's label
		}
	}
	for i, r := range txt {
		cv.set(start+i, ly, r, kindText)
	}
}

// stampBox writes a plain box's runes onto the canvas, classifying each cell by
// POSITION (not glyph): the top/bottom rows and the first/last column are the
// frame (dim wire); interior spaces are blank; everything else is the label
// (body weight). Position-based so a label containing a frame-like char (`<`,
// `(`) is never miscoloured.
func stampBox(cv *canvas, x, y int, box []string) {
	for dy, line := range box {
		runes := []rune(line)
		last := len(runes) - 1
		for col, r := range runes {
			k := kindText
			if dy == 0 || dy == len(box)-1 || col == 0 || col == last {
				k = kindWire // frame: border rows + side columns
			} else if r == ' ' {
				k = kindNone
			}
			cv.set(x+col, y+dy, r, k)
		}
	}
}

// renderNodeBoxPlain is renderNodeBox without styling — for the LR canvas, which
// applies styling at readout via the kind mask. Same shape glyphs + wrapping.
func renderNodeBoxPlain(n *mmNode, content int) []string {
	g := shapeGlyphs(n.shape)
	lines := wrapLines(sanitizeText(n.label), content)
	if len(lines) == 0 {
		lines = []string{""}
	}
	inner := content + 2
	out := []string{string(g.tl) + strings.Repeat(string(g.th), inner) + string(g.tr)}
	for _, ln := range lines {
		out = append(out, string(g.lv)+" "+padRight(ln, content)+" "+string(g.rv))
	}
	out = append(out, string(g.bl)+strings.Repeat(string(g.bh), inner)+string(g.br))
	return out
}
