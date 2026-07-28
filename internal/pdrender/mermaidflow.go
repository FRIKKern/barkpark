package pdrender

import (
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── flowchart → responsive layered terminal art ──────────────────────────────
//
// The unconventional thesis (see the terminal-diagram paper): a Mermaid
// flowchart is a layered DAG, and a layered DAG is exactly what a terminal draws
// well — boxes in ranked rows, connected by an orthogonal box-drawing BUS whose
// junction glyphs are chosen from cell connectivity, so alignment is STRUCTURAL
// (every band cell resolves to the one glyph its U/D/L/R neighbours demand; there
// is no free-hand line to misalign). We never route spaghetti: edges that span
// adjacent ranks draw as a clean bus; edges that skip ranks or loop back degrade
// to a labelled edge legend below the graph — honest, aligned, unmistakable.
//
// Direction is a responsive flex-direction (Ink/Yoga's lesson): wave 1 renders
// every flowchart TOP-DOWN (the topology is identical whatever the declared
// dir); a later wave honours LR side-by-side ranks and COLLAPSES them to TD when
// the terminal is too narrow — the CSS-grid-to-single-column breakpoint, in a
// terminal. Every returned line is padded to ctx.Width: the render is a
// rectangle, so it can never misalign inside the figure card.

const (
	flowGutter   = 3  // blank columns between sibling boxes in a rank
	flowMaxNodeW = 24 // absolute cap on a node's inner content width
)

// flowFlex is the shared side-by-side solver tuned for flowchart ranks: the
// wider flow gutter (terminal cells are ~1:2, so horizontal air reads better)
// and a small MinWidth floor (a node box can shrink to an ellipsis).
var flowFlex = Flex{Gutter: flowGutter, MinWidth: 3}

// renderFlowchart lays a parsed graph into ranked rows of boxes joined by
// connector bands, plus a legend for any edge a band can't cleanly carry. All
// lines are padded to ctx.Width. Returns nil when the graph is empty (caller
// keeps the folded-source box).
func renderFlowchart(g *mmGraph, ctx RenderCtx) []string {
	if g == nil || len(g.nodes) == 0 {
		return nil
	}
	W := clampWidth(ctx.Width)

	ranks := assignRanks(g)
	layers := groupByRank(g, ranks)
	orderLayers(layers, g, ranks)

	// Render each rank into a row of boxes; remember every node's center column
	// (0..W) so the bands between ranks know where to enter/exit.
	rows := make([][]string, len(layers))
	centers := make([]map[string]int, len(layers))
	for li, layer := range layers {
		row, cen := renderRank(layer, g, W, ctx)
		rows[li] = row
		centers[li] = cen
	}

	var out []string
	var deferred []mmEdge
	for li := range layers {
		if li > 0 {
			// Band carries only edges from rank li-1 into rank li; it returns any
			// bipartite crossers it declined to draw for the legend.
			band, drop := renderBand(g, ranks, li-1, centers[li-1], centers[li], W, ctx)
			out = append(out, band...)
			deferred = append(deferred, drop...)
		}
		out = append(out, rows[li]...)
	}

	// Edges no band drew (skip-rank / back / same-rank) plus bipartite crossers a
	// band deferred become a legend.
	if legend := renderEdgeLegend(g, ranks, deferred, W, ctx); len(legend) > 0 {
		out = append(out, "")
		out = append(out, legend...)
	}

	// Guarantee rectangularity: every line exactly W columns.
	for i := range out {
		out[i] = padRight(out[i], W)
	}
	return out
}

// assignRanks computes a longest-path rank per node (roots at 0). Cycles are
// broken by ignoring edges that point back to an ancestor on the DFS stack, so a
// cyclic graph still ranks (the back-edge later shows in the legend). The result
// is stable and deterministic (nodes processed in first-seen order).
func assignRanks(g *mmGraph) map[string]int {
	// Adjacency (forward) with cycle-safe edge set.
	adj := map[string][]string{}
	forward := map[[2]string]bool{}
	state := map[string]int{} // 0=unseen 1=on-stack 2=done
	// DFS to classify back-edges (target currently on the stack).
	var dfs func(u string)
	dfs = func(u string) {
		state[u] = 1
		for _, e := range g.edges {
			if e.from != u {
				continue
			}
			if state[e.to] == 1 {
				continue // back-edge — skip so ranking stays a DAG
			}
			if !forward[[2]string{u, e.to}] {
				forward[[2]string{u, e.to}] = true
				adj[u] = append(adj[u], e.to)
			}
			if state[e.to] == 0 {
				dfs(e.to)
			}
		}
		state[u] = 2
	}
	for _, n := range g.nodes {
		if state[n.id] == 0 {
			dfs(n.id)
		}
	}

	// Longest-path relaxation over the acyclic forward set. Iterate to a fixpoint
	// (bounded by node count — the DAG's longest path can't exceed it).
	rank := map[string]int{}
	for _, n := range g.nodes {
		rank[n.id] = 0
	}
	for i := 0; i < len(g.nodes); i++ {
		changed := false
		for u, tos := range adj {
			for _, v := range tos {
				if rank[u]+1 > rank[v] {
					rank[v] = rank[u] + 1
					changed = true
				}
			}
		}
		if !changed {
			break
		}
	}
	return rank
}

// groupByRank buckets nodes by rank, each bucket in first-seen order.
func groupByRank(g *mmGraph, rank map[string]int) [][]*mmNode {
	maxR := 0
	for _, r := range rank {
		if r > maxR {
			maxR = r
		}
	}
	layers := make([][]*mmNode, maxR+1)
	for _, n := range g.nodes {
		r := rank[n.id]
		layers[r] = append(layers[r], n)
	}
	// Drop any empty ranks (shouldn't happen, but keep the render dense).
	out := layers[:0]
	for _, l := range layers {
		if len(l) > 0 {
			out = append(out, l)
		}
	}
	return out
}

// orderLayers reduces edge crossings with the classic median heuristic: four
// alternating down/up sweeps that reorder each rank by the median position of a
// node's neighbours in the adjacent rank (Sugiyama phase 3). Nodes with no
// neighbour in the reference rank keep their slot; ties break by node id so the
// render is byte-identical run to run (golden-test determinism). Only forward
// edges (rank strictly increases) drive the medians, so back/skip edges — which
// the legend carries — never perturb the ordering.
func orderLayers(layers [][]*mmNode, g *mmGraph, rank map[string]int) {
	if len(layers) < 2 {
		return
	}
	// pos[id] = current index of a node within its own rank.
	pos := map[string]int{}
	reindex := func() {
		for _, layer := range layers {
			for i, n := range layer {
				pos[n.id] = i
			}
		}
	}
	reindex()

	// neighbours in the adjacent rank, in the sweep direction.
	median := func(node string, down bool) float64 {
		var ps []int
		for _, e := range g.edges {
			var other string
			if down && e.to == node && rank[e.from] == rank[node]-1 {
				other = e.from
			} else if !down && e.from == node && rank[e.to] == rank[node]+1 {
				other = e.to
			} else {
				continue
			}
			ps = append(ps, pos[other])
		}
		if len(ps) == 0 {
			return -1 // no anchor — keep slot
		}
		sort.Ints(ps)
		return float64(ps[len(ps)/2])
	}

	sweep := func(down bool) {
		for _, layer := range layers {
			meds := make(map[string]float64, len(layer))
			for _, n := range layer {
				m := median(n.id, down)
				if m < 0 {
					m = float64(pos[n.id]) // anchorless: hold position
				}
				meds[n.id] = m
			}
			sort.SliceStable(layer, func(i, j int) bool {
				if meds[layer[i].id] != meds[layer[j].id] {
					return meds[layer[i].id] < meds[layer[j].id]
				}
				return layer[i].id < layer[j].id // stable id tiebreak
			})
		}
		reindex()
	}

	for i := 0; i < 4; i++ {
		sweep(i%2 == 0) // down, up, down, up
	}
}

// renderRank builds one rank's boxes side-by-side, centered in W, and returns
// the assembled lines plus each node's center column (for the connector bands).
func renderRank(layer []*mmNode, g *mmGraph, W int, ctx RenderCtx) ([]string, map[string]int) {
	n := len(layer)
	// Per-node inner content width from the shared solver (the flowchart is just
	// another side-by-side surface) using the flow gutter, so the assembled row
	// never exceeds W. Capped so a sparse rank doesn't blow up into giant boxes;
	// floored so a label still fits.
	cellW, _ := flowFlex.Measure(W, n)
	content := cellW - 4 // 2 border + 2 padding
	if content > flowMaxNodeW {
		content = flowMaxNodeW
	}
	if content < 3 {
		content = 3
	}

	boxes := make([][]string, n)
	widths := make([]int, n)
	for i, node := range layer {
		box := renderNodeBox(node, content, ctx)
		boxes[i] = box
		widths[i] = lipgloss.Width(box[0])
	}

	rowWidth := 0
	for i, w := range widths {
		rowWidth += w
		if i < n-1 {
			rowWidth += flowGutter
		}
	}
	leftPad := 0
	if rowWidth < W {
		leftPad = (W - rowWidth) / 2
	}

	// Centers: leftPad + running offset + half box width.
	centers := map[string]int{}
	off := leftPad
	for i, node := range layer {
		centers[node.id] = off + widths[i]/2
		off += widths[i] + flowGutter
	}

	joined := joinColumns(boxes, widths, flowGutter)
	pad := strings.Repeat(" ", leftPad)
	for i := range joined {
		joined[i] = pad + joined[i]
	}
	return joined, centers
}

// renderNodeBox draws one node as a rectangular box whose corners encode its
// shape. The label wraps to `content` columns; every line is exactly
// content+4 wide (2 border + 2 padding), so the box is a clean rectangle.
func renderNodeBox(n *mmNode, content int, ctx RenderCtx) []string {
	g := shapeGlyphs(n.shape)
	label := sanitizeText(n.label)
	lines := wrapLines(label, content)
	if len(lines) == 0 {
		lines = []string{""}
	}

	inner := content + 2 // 1-cell padding each side
	top := ctx.Theme.Dim.Render(string(g.tl) + strings.Repeat(string(g.th), inner) + string(g.tr))
	bot := ctx.Theme.Dim.Render(string(g.bl) + strings.Repeat(string(g.bh), inner) + string(g.br))
	lv := ctx.Theme.Dim.Render(string(g.lv))
	rv := ctx.Theme.Dim.Render(string(g.rv))

	out := make([]string, 0, len(lines)+2)
	out = append(out, top)
	for _, ln := range lines {
		out = append(out, lv+" "+ctx.Theme.Body.Render(padRight(ln, content))+" "+rv)
	}
	out = append(out, bot)
	return out
}

// shapeBox is the full glyph set for a node frame: four corners, the top and
// bottom horizontal fills (which can differ from the sides — a database uses a
// double line ═), and the left/right verticals (which can differ from each other
// — a stadium's ( ) caps, a hexagon's < >).
type shapeBox struct{ tl, tr, bl, br, th, bh, lv, rv rune }

// shapeGlyphs maps a node shape to a DISTINCT terminal frame, using only
// display-width-1 box-drawing + ASCII glyphs (verified — exotic arc/angle glyphs
// are ambiguous-width and would break rectangularity). Each frame is a recognisable
// analogue of its Mermaid shape:
//
//	rect        ┌─┐ │ │ └─┘     process
//	rounded     ╭─╮ │ │ ╰─╯     soft process
//	stadium     ╭─╮ ( ) ╰─╯     pill (rounded corners + paren caps)
//	circle      ╔═╗ ║ ║ ╚═╝     start/end/event (double frame)
//	diamond     ╱─╲ │ │ ╲─╱     decision
//	hexagon     ╱─╲ < > ╲─╱     prepare (angled corners + angle caps)
//	subroutine  ╓─╖ ║ ║ ╙─╜     subroutine (double side bars)
//	cylinder    ╒═╕ │ │ ╘═╛     database (double top+bottom caps)
func shapeGlyphs(s mmShape) shapeBox {
	switch s {
	case shapeRound:
		return shapeBox{'╭', '╮', '╰', '╯', '─', '─', '│', '│'}
	case shapeStadium:
		return shapeBox{'╭', '╮', '╰', '╯', '─', '─', '(', ')'}
	case shapeCircle:
		return shapeBox{'╔', '╗', '╚', '╝', '═', '═', '║', '║'}
	case shapeDiamond:
		return shapeBox{'╱', '╲', '╲', '╱', '─', '─', '│', '│'}
	case shapeHexagon:
		return shapeBox{'╱', '╲', '╲', '╱', '─', '─', '<', '>'}
	case shapeSubroutine:
		return shapeBox{'╓', '╖', '╙', '╜', '─', '─', '║', '║'}
	case shapeCylinder:
		return shapeBox{'╒', '╕', '╘', '╛', '═', '═', '│', '│'}
	default: // rect, bare
		return shapeBox{'┌', '┐', '└', '┘', '─', '─', '│', '│'}
	}
}

// ── connector bands ──────────────────────────────────────────────────────────

// dir bits for band-cell connectivity → box-drawing glyph.
const (
	cU = 1 << iota
	cD
	cL
	cR
)

// bandGlyph maps a cell's U/D/L/R connectivity bitmask to its box-drawing rune.
var bandGlyph = map[int]rune{
	cU | cD: '│', cL | cR: '─',
	cD | cR: '┌', cD | cL: '┐', cU | cR: '└', cU | cL: '┘',
	cU | cD | cR: '├', cU | cD | cL: '┤',
	cL | cR | cD: '┬', cL | cR | cU: '┴',
	cU | cD | cL | cR: '┼',
	cU:                '│', cD: '│', cL: '─', cR: '─',
}

// renderBand draws the orthogonal bus connecting rank `pr` (parents, exits at
// their center columns) to rank pr+1 (children, arrow entries). Only edges from
// pr to pr+1 are drawn; every band cell's glyph is derived from connectivity, so
// junctions (tees, crosses, corners) resolve correctly and nothing misaligns.
//
// A single ASCII bus can faithfully draw a fan-out (one parent → many children),
// a fan-in (many → one), or parallel verticals — but NOT a bipartite MANY-to-MANY
// mapping, where several parents each cross to several different children: the
// shared bus row would merge them into an ambiguous tangle of ┼ that reads as
// "everything connects to everything". So in a mixed band we draw only the
// unambiguous edges (vertical, straight down) and RETURN the crossing edges for
// the caller's legend — honest wiring over a misleading picture.
func renderBand(g *mmGraph, rank map[string]int, pr int, parents, children map[string]int, W int, ctx RenderCtx) ([]string, []mmEdge) {
	// Collect the adjacent edges (carrying their ids so crossers can be deferred).
	type link struct {
		xp, xc int
		from   string
		to     string
		label  string
		head   bool
	}
	var links []link
	for _, e := range g.edges {
		if rank[e.from] != pr || rank[e.to] != pr+1 {
			continue
		}
		xp, okp := parents[e.from]
		xc, okc := children[e.to]
		if !okp || !okc {
			continue
		}
		links = append(links, link{xp, xc, e.from, e.to, e.label, e.head})
	}
	if len(links) == 0 {
		return []string{strings.Repeat(" ", W)}, nil // one blank spacer row
	}

	// Classify: a band is cleanly drawable when it fans out from ONE source column
	// or fans in to ONE target column. Otherwise it is bipartite — draw only the
	// vertical edges (unambiguous) and defer every crossing edge to the legend.
	srcCols, tgtCols := map[int]bool{}, map[int]bool{}
	for _, lk := range links {
		srcCols[lk.xp] = true
		tgtCols[lk.xc] = true
	}
	mixed := len(srcCols) > 1 && len(tgtCols) > 1
	var deferred []mmEdge
	if mixed {
		kept := links[:0]
		for _, lk := range links {
			if lk.xp == lk.xc {
				kept = append(kept, lk)
			} else {
				deferred = append(deferred, mmEdge{from: lk.from, to: lk.to, label: lk.label, head: lk.head})
			}
		}
		links = kept
	}
	if len(links) == 0 {
		return []string{strings.Repeat(" ", W)}, deferred
	}
	horizontal := false
	for _, lk := range links {
		if lk.xp != lk.xc {
			horizontal = true
		}
	}

	H := 2
	busRow := 1
	if horizontal {
		H = 3
		busRow = 1
	}

	bits := make([][]int, H)
	for i := range bits {
		bits[i] = make([]int, W)
	}
	mark := func(r, c, b int) {
		if r >= 0 && r < H && c >= 0 && c < W {
			bits[r][c] |= b
		}
	}
	arrows := map[[2]int]bool{}
	// Route each edge: drop from parent exit to bus, run to child column, drop
	// to child entry. Pure-vertical edges collapse to a single column.
	for _, lk := range links {
		// Vertical leg: parent box bottom DOWN to the bus row (exclusive) — the bus
		// cell itself only gains an "up" bit, so a mid-bus parent reads ┴ (splits to
		// children) and an end parent reads └/┘, never a spurious ┼.
		for r := 0; r < busRow; r++ {
			mark(r, lk.xp, cU|cD)
		}
		mark(busRow, lk.xp, cU)
		// Vertical leg: bus row DOWN to the child arrow — the bus cell gains only a
		// "down" bit, so a child column reads ┬ (or a corner at an end).
		for r := busRow + 1; r < H; r++ {
			mark(r, lk.xc, cU|cD)
		}
		mark(busRow, lk.xc, cD)
		// Horizontal run along the bus between the two columns. Endpoints get only
		// the INWARD bit so a run end reads as a corner (┌┐└┘); interior cells get
		// both. Overlapping runs OR together, so a shared column that is one run's
		// left end and another's right end correctly becomes a tee/cross.
		lo, hi := lk.xp, lk.xc
		if lo > hi {
			lo, hi = hi, lo
		}
		for c := lo; c <= hi; c++ {
			b := cL | cR
			if c == lo {
				b = cR
			}
			if c == hi {
				b = cL
			}
			mark(busRow, c, b)
		}
		arrows[[2]int{H - 1, lk.xc}] = true
	}

	// Assemble each row into a plain rune buffer (glyphs from connectivity),
	// place best-effort edge labels, THEN style the whole row dim. Building on the
	// plain buffer keeps width math trivial and never strips ANSI mid-run.
	grid := make([][]rune, H)
	for r := 0; r < H; r++ {
		grid[r] = make([]rune, W)
		for c := 0; c < W; c++ {
			grid[r][c] = ' '
		}
		for c := 0; c < W; c++ {
			b := bits[r][c]
			if b == 0 {
				continue
			}
			if arrows[[2]int{r, c}] {
				grid[r][c] = '▼'
				continue
			}
			if gl, ok := bandGlyph[b]; ok {
				grid[r][c] = gl
			} else {
				grid[r][c] = '│'
			}
		}
	}

	// Edge labels (e.g. a decision's yes/no): write to the right of the arrow when
	// exactly one edge targets that column and the cells are free. Anything that
	// would collide is left for the legend, so the band never smears.
	count := map[int]int{}
	for _, lk := range links {
		count[lk.xc]++
	}
	arrowRow := grid[H-1]
	for _, lk := range links {
		if lk.label == "" || count[lk.xc] != 1 {
			continue
		}
		txt := []rune(" " + sanitizeText(lk.label))
		start := lk.xc + 1
		if start+len(txt) > W {
			continue
		}
		free := true
		for i := range txt {
			if arrowRow[start+i] != ' ' {
				free = false
				break
			}
		}
		if free {
			copy(arrowRow[start:], txt)
		}
	}

	rows := make([]string, H)
	for r := 0; r < H; r++ {
		rows[r] = ctx.Theme.Dim.Render(strings.TrimRight(string(grid[r]), " "))
	}
	return rows, deferred
}

// ── edge legend ──────────────────────────────────────────────────────────────

// renderEdgeLegend lists edges no adjacent band drew — rank-skipping, back
// (loop), or same-rank edges, plus the bipartite crossers a band deferred — as
// "A → B  label" lines, so every relationship in the source is visible without
// routing spaghetti (or an ambiguous many-to-many bus) across the graph.
func renderEdgeLegend(g *mmGraph, rank map[string]int, deferred []mmEdge, W int, ctx RenderCtx) []string {
	type item struct{ text string }
	var items []item
	emit := func(e mmEdge) {
		arrow := "→"
		if !e.head {
			arrow = "—"
		}
		if rank[e.to] <= rank[e.from] {
			arrow = "↺" // loops back
		}
		line := labelFor(g, e.from) + " " + arrow + " " + labelFor(g, e.to)
		if e.label != "" {
			line += "  " + sanitizeText(e.label)
		}
		items = append(items, item{line})
	}
	for _, e := range g.edges {
		if rank[e.to]-rank[e.from] == 1 {
			continue // adjacent — a band drew it (or deferred it below)
		}
		emit(e)
	}
	for _, e := range deferred { // bipartite crossers a band declined to draw
		emit(e)
	}
	if len(items) == 0 {
		return nil
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].text < items[j].text })
	out := []string{ctx.Theme.Dim.Render("· also")}
	for _, it := range items {
		for _, line := range hardBoundDisplayLines(
			[]string{ctx.Theme.Dim.Render(it.text)},
			W-2,
		) {
			out = append(out, "  "+line)
		}
	}
	return out
}

// labelFor returns a node's display label (falling back to its id).
func labelFor(g *mmGraph, id string) string {
	if n, ok := g.byID[id]; ok && n.label != "" {
		return sanitizeText(n.label)
	}
	return sanitizeText(id)
}
