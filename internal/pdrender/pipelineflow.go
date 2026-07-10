package pdrender

import "strings"

// ── pipeline layout:flow — linear adapter over the mermaidflow machinery ──────
//
// A pipeline that opts INTO layout:{mode:"flow"} renders as a LINEAR flowchart:
// a left-to-right chain of rect boxes joined by ──▶ connectors, degrading to the
// honest TD ▼ stack when the chain can't fit the terminal cleanly. This is an
// EXTEND-not-fork of the existing flowchart engine: we build the neutral mmGraph
// model DIRECTLY (never synthesize mermaid text to re-parse) and hand it to
// renderFlowchartAuto, which already owns the LR-fits-else-TD degrade ladder
// (renderFlowchartLR returns nil on overflow → renderFlowchart / renderFlowTree).
// The chain is exactly the authored node order — no DAG is invented from the
// snapshot; per-node task binding stays snapshot-driven upstream.

// flowOptIn reports whether a pipeline block opts INTO the linear flow layout via
// a layout:{mode:"flow"} object — the SAME layout seam gridOptIn reads (the mode
// differs). ABSENT / any other mode → false, so a pipeline with no layout (or
// mode:"grid") keeps its existing render, byte-identical to before.
func flowOptIn(b Block) bool {
	layout, ok := b.Attrs["layout"].(map[string]any)
	return ok && attrStr(layout, "mode") == "flow"
}

// pipelineFlow adapts a kept pipeline node list into an LR flowchart: one rect
// mmNode per node (label = the node's title, never empty — falls back to kind,
// then a stable synthetic id so a box always carries text), chained by an
// implicit head edge i→i+1, direction LR. renderFlowchartAuto measures + chooses:
// a short chain draws ──▶ boxes side-by-side; an overflowing chain collapses to
// the TD ▼ stack. Returns nil only for an empty node list (caller keeps its
// legacy stack).
func pipelineFlow(nodes []map[string]any, ctx RenderCtx) []string {
	if len(nodes) == 0 {
		return nil
	}
	g := &mmGraph{dir: "LR", byID: make(map[string]*mmNode, len(nodes))}
	prev := ""
	for i, node := range nodes {
		id := "n" + itoa(i)
		label := strings.TrimSpace(attrStrFirst(node, "title", "kind"))
		if label == "" {
			label = id // guarantee a non-empty box label
		}
		n := &mmNode{id: id, label: label, shape: shapeRect}
		g.nodes = append(g.nodes, n)
		g.byID[id] = n
		if prev != "" {
			g.edges = append(g.edges, mmEdge{from: prev, to: id, head: true})
		}
		prev = id
	}
	return renderFlowchartAuto(g, ctx)
}
