package pdrender

import (
	"github.com/charmbracelet/lipgloss"
)

// ── scenario heuristics — measure the graph, choose the strategy ─────────────
//
// One layout forced onto every graph is wrong somewhere: a chain declared TD is
// a 30-row tower a terminal would rather read sideways; a 10-way fan crushes
// its boxes to ellipses; a mesh whose legend outnumbers its drawn edges is a
// picture of exceptions. So the diagram block measures the parsed graph first
// (flowMetrics) and picks a strategy (chooseFlowStrategy):
//
//	scenario (measured)                  strategy
//	─────────────────────────────────    ────────────────────────────────────
//	chain, fits sideways                 LR box-art (auto-orient — the mirror
//	                                     of the LR→TD narrow collapse)
//	declared LR/RL, fits                 LR box-art (author intent)
//	rank overflow (boxes < readable)     TREE view (indented, every edge a
//	mesh (legend would outnumber bus)    branch — honest at any width)
//	everything else                      TD box-art (+ legend)
//
// The ladder of degradation is now box-art → tree-text → folded source; every
// tier is rectangular and every relationship in the source stays visible.

// flowMinReadable is the smallest per-box content width (label columns) that
// still reads as a box rather than an ellipsis. Ranks that would fall below it
// push the graph to the tree view.
const flowMinReadable = 8

// flowMetrics is the measured shape of a parsed flowchart at a given width.
type flowMetrics struct {
	layers    [][]*mmNode
	rank      map[string]int
	chain     bool // every rank holds exactly one node and no non-adjacent edges
	overflow  bool // some rank's boxes would fall below flowMinReadable
	meshy     bool // non-adjacent (legend) edges outnumber drawable ones
	drawable  int  // edges with rank delta exactly 1
	nonAdjac  int  // everything else (skip / back / same-rank)
	edgeCount int
}

// measureFlow computes the layout-relevant shape of g at width W. It reuses the
// same rank assignment the renderers use, so the verdict and the render agree.
func measureFlow(g *mmGraph, W int) flowMetrics {
	m := flowMetrics{rank: assignRanks(g)}
	m.layers = groupByRank(g, m.rank)
	m.edgeCount = len(g.edges)

	for _, e := range g.edges {
		if m.rank[e.to]-m.rank[e.from] == 1 {
			m.drawable++
		} else {
			m.nonAdjac++
		}
	}

	m.chain = len(g.nodes) >= 2 && m.nonAdjac == 0
	for _, l := range m.layers {
		if len(l) != 1 {
			m.chain = false
		}
		// Per-rank box readability at this width (the TD divide-formula).
		if n := len(l); n > 1 {
			cellW, _ := flowFlex.Measure(clampWidth(W), n)
			if cellW-4 < flowMinReadable {
				m.overflow = true
			}
		}
	}
	// A mesh: the legend would carry more of the graph than the bus does. Small
	// graphs (< 4 edges) never trip this — a lone back-edge is a loop, not a mesh.
	m.meshy = m.edgeCount >= 4 && m.nonAdjac > m.drawable
	return m
}

// flowStrategy names the renderer the heuristics chose.
type flowStrategy int

const (
	stratTD flowStrategy = iota
	stratLR
	stratTree
)

// chooseFlowStrategy is the scenario ladder. Order matters: author-declared LR
// is honoured first (it collapses to TD when narrow, as before); a chain
// auto-orients sideways when the terminal is wide enough (declared TD or not —
// the terminal is a wide, short medium and a tower wastes it); a rank that
// would crush its boxes, or a graph that is mostly legend, reads better as a
// tree than as a misleading picture.
func chooseFlowStrategy(g *mmGraph, m flowMetrics, ctx RenderCtx) flowStrategy {
	if g.dir == "LR" || g.dir == "RL" {
		if lrFits(g, m, ctx) {
			return stratLR
		}
		// declared-LR that can't fit falls through the same ladder as TD
	}
	if m.chain && len(g.nodes) >= 3 && lrFits(g, m, ctx) {
		return stratLR // auto-orient: a chain reads sideways
	}
	if m.overflow || m.meshy {
		return stratTree
	}
	return stratTD
}

// lrFits reports whether the LR canvas would accept this graph at this width —
// the same width/height arithmetic renderFlowchartLR performs, without drawing.
func lrFits(g *mmGraph, m flowMetrics, ctx RenderCtx) bool {
	if len(m.layers) < 2 {
		return false
	}
	W := clampWidth(ctx.Width)
	total := (len(m.layers) - 1) * lrBand
	maxH := 0
	for _, layer := range m.layers {
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
		total += content + 4
		if h := len(layer)*3 + (len(layer)-1)*lrVGap; h > maxH {
			maxH = h
		}
	}
	return total <= W && maxH <= lrMaxH
}

// renderFlowchartAuto is the heuristic entry point the diagram block uses: it
// measures, chooses, renders — falling down the ladder if a tier declines
// (renderFlowchartLR can still return nil on geometry the estimate missed).
func renderFlowchartAuto(g *mmGraph, ctx RenderCtx) []string {
	if g == nil || len(g.nodes) == 0 {
		return nil
	}
	m := measureFlow(g, ctx.Width)
	switch chooseFlowStrategy(g, m, ctx) {
	case stratLR:
		if art := renderFlowchartLR(g, ctx); art != nil {
			return art
		}
		if m.overflow || m.meshy {
			return renderFlowTree(g, ctx)
		}
		return renderFlowchart(g, ctx)
	case stratTree:
		return renderFlowTree(g, ctx)
	default:
		return renderFlowchart(g, ctx)
	}
}

// ── tree view — the honest middle tier ───────────────────────────────────────
//
// An indented dependency tree, the `tree`-command idiom: every edge is a branch
// (labelled when the edge is), a node already expanded elsewhere renders as a
// reference (·↑), and a true cycle back to an ancestor on the current path is a
// loop (↺). It carries ANY graph at ANY width — wide fans become sibling lists,
// meshes become repeated references — which is exactly what the box tiers can't
// do without crushing or misleading. Rectangular like everything else.

// renderFlowTree draws g as one or more indented trees (one per root; roots are
// in-degree-0 nodes in first-seen order, then any still-unvisited node so a
// cycle-only component is never dropped). Every line is padded to ctx.Width.
func renderFlowTree(g *mmGraph, ctx RenderCtx) []string {
	W := clampWidth(ctx.Width)

	indeg := map[string]int{}
	for _, e := range g.edges {
		indeg[e.to]++
	}
	expanded := map[string]bool{} // node already expanded somewhere in the output

	var out []string
	emit := func(prefix, wire, label, mark string) {
		line := ctx.Theme.Dim.Render(prefix+wire) + ctx.Theme.Body.Render(label)
		if mark != "" {
			line += ctx.Theme.Dim.Render(mark)
		}
		out = append(out, truncateANSI(line, W))
	}

	// children returns g's out-edges from id in source order.
	children := func(id string) []mmEdge {
		var cs []mmEdge
		for _, e := range g.edges {
			if e.from == id {
				cs = append(cs, e)
			}
		}
		return cs
	}

	var walk func(id, prefix string, onPath map[string]bool)
	walk = func(id, prefix string, onPath map[string]bool) {
		cs := children(id)
		for i, e := range cs {
			last := i == len(cs)-1
			branch, cont := "├─", "│  "
			if last {
				branch, cont = "└─", "   "
			}
			// The wire: branch + optional label + arrow (or plain for open links).
			wire := branch
			if e.label != "" {
				wire += " " + sanitizeText(e.label) + " ─"
			}
			if e.head {
				wire += "▶ "
			} else {
				wire += "─ "
			}
			label := labelFor(g, e.to)
			switch {
			case onPath[e.to]: // true cycle back to an ancestor
				emit(prefix, wire, label, " ↺")
			case expanded[e.to]: // shown elsewhere — reference, don't re-expand
				emit(prefix, wire, label, " ·↑")
			default:
				emit(prefix, wire, label, "")
				expanded[e.to] = true
				onPath[e.to] = true
				walk(e.to, prefix+cont, onPath)
				delete(onPath, e.to)
			}
		}
	}

	roots := func() []*mmNode {
		var rs []*mmNode
		for _, n := range g.nodes {
			if indeg[n.id] == 0 {
				rs = append(rs, n)
			}
		}
		return rs
	}()

	drawRoot := func(n *mmNode) {
		if len(out) > 0 {
			out = append(out, "")
		}
		out = append(out, truncateANSI(ctx.Theme.Body.Render(labelFor(g, n.id)), W))
		expanded[n.id] = true
		walk(n.id, "", map[string]bool{n.id: true})
	}
	for _, n := range roots {
		drawRoot(n)
	}
	// Cycle-only components have no in-degree-0 root — sweep for the unvisited.
	for _, n := range g.nodes {
		if !expanded[n.id] {
			drawRoot(n)
		}
	}

	for i := range out {
		out[i] = padRight(out[i], W)
	}
	return out
}
