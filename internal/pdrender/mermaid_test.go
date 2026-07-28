package pdrender

import (
	"strings"
	"testing"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

func semanticCompact(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, s)
}

// TestParseFlowchartShapesAndEdges covers the node-shape + edge-style + label
// grammar the layout engine depends on.
func TestParseFlowchartShapesAndEdges(t *testing.T) {
	src := "flowchart LR\n" +
		"  A[Rect] --> B(Round)\n" +
		"  B --> C{Diamond}\n" +
		"  C -->|yes| D((Circle))\n" +
		"  A -.-> E([Stadium])\n" +
		"  A === F{{Hex}}\n" +
		"  A --- G[[Sub]]"
	doc := parseMermaid(src)
	if doc.kind != "flowchart" {
		t.Fatalf("kind = %q, want flowchart", doc.kind)
	}
	g := doc.graph
	if g.dir != "LR" {
		t.Errorf("dir = %q, want LR", g.dir)
	}
	shapes := map[string]mmShape{
		"A": shapeRect, "B": shapeRound, "C": shapeDiamond,
		"D": shapeCircle, "E": shapeStadium, "F": shapeHexagon, "G": shapeSubroutine,
	}
	for id, want := range shapes {
		n, ok := g.byID[id]
		if !ok {
			t.Fatalf("node %q missing", id)
		}
		if n.shape != want {
			t.Errorf("node %q shape = %d, want %d", id, n.shape, want)
		}
	}
	if g.byID["A"].label != "Rect" {
		t.Errorf("A label = %q, want Rect", g.byID["A"].label)
	}
	// Edge styles + label + open-link (no head).
	var cy, dotted, thick, open bool
	for _, e := range g.edges {
		if e.from == "C" && e.to == "D" {
			if e.label != "yes" {
				t.Errorf("C->D label = %q, want yes", e.label)
			}
			cy = true
		}
		if e.from == "A" && e.to == "E" && e.style == linkDotted {
			dotted = true
		}
		if e.from == "A" && e.to == "F" && e.style == linkThick {
			thick = true
		}
		if e.from == "A" && e.to == "G" && !e.head {
			open = true
		}
	}
	if !cy || !dotted || !thick || !open {
		t.Errorf("edge decode gaps: labeled=%v dotted=%v thick=%v open=%v", cy, dotted, thick, open)
	}
}

// TestParseFlowchartChain expands `A --> B --> C` into two edges through B.
func TestParseFlowchartChain(t *testing.T) {
	g := parseMermaid("flowchart TD\n  A --> B --> C").graph
	if len(g.nodes) != 3 {
		t.Fatalf("nodes = %d, want 3", len(g.nodes))
	}
	if len(g.edges) != 2 || g.edges[0].to != "B" || g.edges[1].from != "B" {
		t.Errorf("chain edges wrong: %+v", g.edges)
	}
}

// TestFlowchartRectangular is the structural-alignment guarantee: every rendered
// line is EXACTLY the target width at every width, for graphs that stress the
// layout (linear, branch/merge, wide fan-out, and a cycle). Non-vacuous: it also
// asserts the render actually drew node boxes.
func TestFlowchartRectangular(t *testing.T) {
	graphs := map[string]string{
		"linear": "flowchart TD\n A[One]-->B[Two]-->C[Three]",
		"branch": "flowchart TD\n A-->B{Q}\n B-->|y|C\n B-->|n|D\n C-->E\n D-->E",
		"wide":   "flowchart TD\n R-->A\n R-->B\n R-->C\n R-->D\n A-->Z\n B-->Z\n C-->Z\n D-->Z",
		"cycle":  "flowchart TD\n A-->B\n B-->C\n C-->A",
	}
	for name, src := range graphs {
		g := parseMermaid(src).graph
		for _, w := range []int{40, 60, 80, 120} {
			ctx := RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}
			out := renderFlowchart(g, ctx)
			if len(out) == 0 {
				t.Fatalf("%s@%d: empty render", name, w)
			}
			drewBox := false
			for i, ln := range out {
				if got := ansi.StringWidth(ln); got != w {
					t.Errorf("%s@%d line %d width = %d, want %d: %q",
						name, w, i, got, w, ansi.Strip(ln))
				}
				if strings.ContainsAny(ansi.Strip(ln), "┌╭╱") {
					drewBox = true
				}
			}
			if !drewBox {
				t.Errorf("%s@%d: no node box drawn (vacuous)", name, w)
			}
		}
	}
}

// TestFlowchartCycleLegend proves a back-edge degrades to the legend (a "↺"
// loop line) rather than being routed as a line — the honest-jump contract.
func TestFlowchartCycleLegend(t *testing.T) {
	g := parseMermaid("flowchart TD\n A[Poll]-->B{Ready?}\n B-->|no|A\n B-->|yes|C[Done]").graph
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	out := strings.Join(renderFlowchart(g, ctx), "\n")
	plain := ansi.Strip(out)
	if !strings.Contains(plain, "↺") {
		t.Errorf("back-edge should appear in legend with ↺:\n%s", plain)
	}
}

// TestFlowchartDeterministic guards the id-tiebreak in the median sweep: the same
// source must render byte-identically twice (Go map iteration is randomized).
func TestFlowchartDeterministic(t *testing.T) {
	src := "flowchart TD\n R-->A\n R-->B\n R-->C\n A-->Z\n B-->Z\n C-->Z"
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	var first string
	for i := 0; i < 8; i++ {
		got := strings.Join(renderFlowchart(parseMermaid(src).graph, ctx), "\n")
		if i == 0 {
			first = got
		} else if got != first {
			t.Fatalf("run %d differs from run 0 — non-deterministic layout", i)
		}
	}
}

// TestDiagramDispatch confirms a flowchart source DRAWS (boxes + Figure caption,
// no folded-source header) while a sequence source still FOLDS honestly.
func TestDiagramDispatch(t *testing.T) {
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	flow := Block{Type: "diagram", Attrs: map[string]any{
		"source": "flowchart TD\n A[Start]-->B[End]", "caption": "Flow."}}
	got := ansi.Strip(strings.Join(diagramRenderer{}.Render(flow, ctx), "\n"))
	if strings.Contains(got, "◇ Mermaid diagram") {
		t.Errorf("flowchart should draw, not fold:\n%s", got)
	}
	if !strings.Contains(got, "Start") || !strings.Contains(got, "Figure") {
		t.Errorf("flowchart render missing box/caption:\n%s", got)
	}

	// An unsupported kind still folds honestly (a reader never sees a half-draw).
	other := Block{Type: "diagram", Attrs: map[string]any{
		"source": "stateDiagram-v2\n [*] --> Idle\n Idle --> Busy", "caption": "St."}}
	got2 := ansi.Strip(strings.Join(diagramRenderer{}.Render(other, ctx), "\n"))
	if !strings.Contains(got2, "◇ Mermaid diagram (stateDiagram-v2)") {
		t.Errorf("unsupported kind should fold:\n%s", got2)
	}
}

// TestDiagramFallbackAndCaptionPreserveAuthoredText locks the reader contract:
// a narrow terminal may add rows, but it must not replace Mermaid source or a
// figure caption with renderer-authored ellipsis.
func TestDiagramFallbackAndCaptionPreserveAuthoredText(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	sourceLine := "Idle --> WaitingForExplicitHumanApprovalBeforeDeployment"
	caption := "The complete deployment approval path remains readable at narrow widths."
	block := Block{Type: "diagram", Attrs: map[string]any{
		"source":  "stateDiagram-v2\n" + sourceLine,
		"caption": caption,
	}}
	got := ansi.Strip(strings.Join(diagramRenderer{}.Render(block, ctx), "\n"))
	compact := semanticCompact(got)
	for _, want := range []string{sourceLine, caption} {
		wantCompact := semanticCompact(want)
		if !strings.Contains(compact, wantCompact) {
			t.Errorf("narrow fallback lost authored text %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "…") {
		t.Errorf("narrow fallback introduced ellipsis:\n%s", got)
	}
}

// TestDrawnDiagramCaptionWrapsWithoutLoss covers the native-art path separately
// from the folded-source path above.
func TestDrawnDiagramCaptionWrapsWithoutLoss(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	caption := "Every stage in the correction ledger keeps its complete explanation."
	block := Block{Type: "diagram", Attrs: map[string]any{
		"source":  "flowchart TD\n A[Start]-->B[Finish]",
		"caption": caption,
	}}
	got := ansi.Strip(strings.Join(diagramRenderer{}.Render(block, ctx), "\n"))
	compact := semanticCompact(got)
	if !strings.Contains(compact, semanticCompact(caption)) {
		t.Fatalf("drawn diagram caption was not preserved:\n%s", got)
	}
	if strings.Contains(got, "…") {
		t.Fatalf("drawn diagram caption introduced ellipsis:\n%s", got)
	}
}
