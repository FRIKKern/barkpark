package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func heurRender(src string, w int) []string {
	doc := parseMermaid(src)
	return renderFlowchartAuto(doc.graph, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor})
}

// TestHeuristicChainAutoOrients: a TD-declared chain renders sideways (▶, no ▼)
// when the terminal is wide, and as the TD tower (▼) when narrow — the same
// source, width-driven. The mirror of the LR→TD collapse.
func TestHeuristicChainAutoOrients(t *testing.T) {
	src := "flowchart TD\n A[Fetch]-->B[Parse]-->C[Validate]-->D[Store]"
	wide := ansi.Strip(strings.Join(heurRender(src, 100), "\n"))
	if !strings.Contains(wide, "▶") || strings.Contains(wide, "▼") {
		t.Errorf("wide chain should auto-orient LR:\n%s", wide)
	}
	narrow := ansi.Strip(strings.Join(heurRender(src, 34), "\n"))
	if !strings.Contains(narrow, "▼") || strings.Contains(narrow, "▶") {
		t.Errorf("narrow chain should stay a TD tower:\n%s", narrow)
	}
}

// TestHeuristicForkStaysTD: a branching graph is NOT auto-oriented — no false
// positive from the chain heuristic.
func TestHeuristicForkStaysTD(t *testing.T) {
	src := "flowchart TD\n A[In]-->B{Ok?}\n B-->|y|C[Do]\n B-->|n|D[Skip]"
	got := ansi.Strip(strings.Join(heurRender(src, 100), "\n"))
	if !strings.Contains(got, "▼") {
		t.Errorf("fork should render TD:\n%s", got)
	}
}

// TestHeuristicOverflowGoesTree: a rank whose boxes would crush below the
// readable floor renders as the indented tree — full labels, no box borders,
// rectangular.
func TestHeuristicOverflowGoesTree(t *testing.T) {
	var b strings.Builder
	b.WriteString("flowchart TD\n")
	for _, c := range []string{"Auth", "Rate limit", "Routing", "Logging", "Metrics", "Tracing", "Caching", "Compression", "Session", "Websocket"} {
		b.WriteString(" R[Dispatcher]-->X" + c[:2] + "[" + c + "]\n")
	}
	out := heurRender(b.String(), 80)
	plain := ansi.Strip(strings.Join(out, "\n"))
	if strings.Contains(plain, "┌") {
		t.Errorf("overflowing fan should use the tree view (no boxes):\n%s", plain)
	}
	for _, want := range []string{"├─▶", "└─▶", "Compression", "Websocket"} {
		if !strings.Contains(plain, want) {
			t.Errorf("tree view missing %q:\n%s", want, plain)
		}
	}
	for i, ln := range out {
		if w := ansi.StringWidth(ln); w != 80 {
			t.Errorf("tree line %d width %d != 80", i, w)
		}
	}
}

// TestHeuristicMeshGoesTree: when legend edges would outnumber drawable ones,
// the tree carries the graph — cycles marked ↺, re-visits referenced ·↑, and
// EVERY edge present exactly once as a branch.
func TestHeuristicMeshGoesTree(t *testing.T) {
	src := "flowchart TD\n A-->B\n A-->C\n B-->D\n C-->D\n D-->A\n B-->A\n C-->B\n D-->C"
	out := heurRender(src, 80)
	plain := ansi.Strip(strings.Join(out, "\n"))
	if !strings.Contains(plain, "↺") {
		t.Errorf("mesh tree should mark cycles ↺:\n%s", plain)
	}
	if !strings.Contains(plain, "·↑") {
		t.Errorf("mesh tree should mark re-visits ·↑:\n%s", plain)
	}
	// Every edge appears as exactly one branch line: 8 edges → 8 branch glyphs.
	branches := strings.Count(plain, "├─") + strings.Count(plain, "└─")
	if branches != 8 {
		t.Errorf("tree should draw every edge once: got %d branches, want 8:\n%s", branches, plain)
	}
}

// TestHeuristicTreeCycleOnlyComponent: a component with no in-degree-0 root
// (a pure cycle) is still drawn (the sweep picks its first-seen node).
func TestHeuristicTreeCycleOnlyComponent(t *testing.T) {
	g := parseMermaid("flowchart TD\n A-->B\n B-->C\n C-->A\n A-->C\n B-->A\n C-->B").graph
	out := renderFlowTree(g, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor})
	plain := ansi.Strip(strings.Join(out, "\n"))
	for _, n := range []string{"A", "B", "C"} {
		if !strings.Contains(plain, n) {
			t.Errorf("cycle-only component dropped node %q:\n%s", n, plain)
		}
	}
}

// TestFlowTreePreservesLongLabelsAndLegend proves the tree/legend degradation
// tier adds continuation rows instead of silently clipping graph semantics.
func TestFlowTreePreservesLongLabelsAndLegend(t *testing.T) {
	src := "flowchart TD\n" +
		" Root[Dispatcher coordinating every production reader]-->Child[Revision fenced correction outcome]\n" +
		" Child-->Root\n" +
		" Root-->|requires exact current revision evidence|Far[Immutable reconciliation ledger]"
	g := parseMermaid(src).graph
	out := renderFlowTree(g, RenderCtx{Width: 34, Theme: DarkTheme(), Profile: NoColor})
	plain := ansi.Strip(strings.Join(out, "\n"))
	compact := semanticCompact(plain)
	for _, want := range []string{
		"Dispatcher coordinating every production reader",
		"Revision fenced correction outcome",
		"requires exact current revision evidence",
		"Immutable reconciliation ledger",
	} {
		if !strings.Contains(compact, semanticCompact(want)) {
			t.Errorf("tree lost %q:\n%s", want, plain)
		}
	}
	if strings.Contains(plain, "…") {
		t.Errorf("tree introduced ellipsis:\n%s", plain)
	}
	for i, line := range out {
		if width := ansi.StringWidth(line); width != 34 {
			t.Errorf("tree line %d width %d != 34: %q", i, width, ansi.Strip(line))
		}
	}
}

// TestFlowTreeCapsDeepIndentation proves generated tree chrome can never consume
// the final content cell, even for a dependency chain deeper than the surface.
func TestFlowTreeCapsDeepIndentation(t *testing.T) {
	var src strings.Builder
	src.WriteString("flowchart TD\n")
	for i := 0; i < 40; i++ {
		src.WriteString("N")
		src.WriteString(itoa(i))
		src.WriteString("[node")
		src.WriteString(itoa(i))
		src.WriteString("]-->N")
		src.WriteString(itoa(i + 1))
		src.WriteString("[node")
		src.WriteString(itoa(i + 1))
		src.WriteString("]\n")
	}
	g := parseMermaid(src.String()).graph
	out := renderFlowTree(g, RenderCtx{Width: 20, Theme: DarkTheme(), Profile: NoColor})
	plain := ansi.Strip(strings.Join(out, "\n"))
	if strings.Contains(plain, "…") {
		t.Fatalf("deep tree introduced ellipsis:\n%s", plain)
	}
	for i := 0; i <= 40; i++ {
		want := "node" + itoa(i)
		if !strings.Contains(plain, want) {
			t.Errorf("deep tree lost %q:\n%s", want, plain)
		}
	}
	for i, line := range out {
		if width := ansi.StringWidth(line); width != 20 {
			t.Errorf("tree line %d width %d != 20: %q", i, width, ansi.Strip(line))
		}
	}
}

// TestSequenceCompactsBeforeFolding: six participants at a width the roomy solve
// rejects renders via the tight solve (boxes + arrows present); only a truly
// unworkable width folds.
func TestSequenceCompactsBeforeFolding(t *testing.T) {
	src := "sequenceDiagram\n A->>B: one\n B->>C: two\n C->>D: three\n D->>E: four\n E->>F: five"
	s := parseMermaid(src).seq
	// w=50: roomy cellW=(50-10)/6=6 < 8 → tight cellW=(50-5)/6=7 ≥ 6 → renders.
	out := renderSequence(s, RenderCtx{Width: 50, Theme: DarkTheme(), Profile: NoColor})
	if out == nil {
		t.Fatal("6 actors at w=50 should compact, not fold")
	}
	plain := ansi.Strip(strings.Join(out, "\n"))
	if !strings.Contains(plain, "┌") || !strings.Contains(plain, "▶") {
		t.Errorf("compact ladder missing boxes/arrows:\n%s", plain)
	}
	for i, ln := range out {
		if w := ansi.StringWidth(ln); w != 50 {
			t.Errorf("line %d width %d != 50", i, w)
		}
	}
	// Truly unworkable still folds.
	if out := renderSequence(s, RenderCtx{Width: 24, Theme: DarkTheme(), Profile: NoColor}); out != nil {
		t.Errorf("6 actors at w=24 should fold, got %d lines", len(out))
	}
}
