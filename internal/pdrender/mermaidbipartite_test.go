package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestBipartiteBandDefersCrossings: a many-to-many band draws the unambiguous
// vertical edges as a bus and sends the crossing edges to the legend, instead of
// merging them into an ambiguous shared bus. Auth→Cache and Users→DB are vertical
// (drawn); Users→Cache and Orders→DB cross (legend).
func TestBipartiteBandDefersCrossings(t *testing.T) {
	src := `flowchart TD
  GW --> Auth
  GW --> Users
  GW --> Orders
  Auth --> Cache
  Users --> DB
  Orders --> DB
  Orders --> Queue
  Users --> Cache`
	g := parseMermaid(src).graph
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	out := strings.Join(renderFlowchart(g, ctx), "\n")
	plain := ansi.Strip(out)

	// The crossing edges must appear in the legend.
	if !strings.Contains(plain, "· also") {
		t.Fatalf("bipartite band should produce a legend:\n%s", plain)
	}
	for _, want := range []string{"Users → Cache", "Orders → DB"} {
		if !strings.Contains(plain, want) {
			t.Errorf("crossing edge %q missing from legend:\n%s", want, plain)
		}
	}
	// Rectangularity still holds.
	for i, ln := range renderFlowchart(g, ctx) {
		if w := ansi.StringWidth(ln); w != 80 {
			t.Errorf("line %d width = %d, want 80: %q", i, w, ansi.Strip(ln))
		}
	}
}

// TestFanOutStillDrawsBus: a pure fan-out (one source, many targets) must NOT be
// treated as bipartite — it still draws as a single clean bus with no legend.
func TestFanOutStillDrawsBus(t *testing.T) {
	g := parseMermaid("flowchart TD\n A-->B\n A-->C\n A-->D").graph
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	plain := ansi.Strip(strings.Join(renderFlowchart(g, ctx), "\n"))
	if strings.Contains(plain, "· also") {
		t.Errorf("a pure fan-out should draw fully with no legend:\n%s", plain)
	}
	if !strings.Contains(plain, "┼") && !strings.Contains(plain, "┬") {
		t.Errorf("fan-out should draw a distribution bus:\n%s", plain)
	}
}

// TestParallelVerticalsDraw: a mixed-column band whose edges are ALL vertical
// (parallel lanes) must draw every edge — verticals are never ambiguous.
func TestParallelVerticalsDraw(t *testing.T) {
	g := parseMermaid("flowchart TD\n A1-->B1\n A2-->B2").graph
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	plain := ansi.Strip(strings.Join(renderFlowchart(g, ctx), "\n"))
	if strings.Contains(plain, "· also") {
		t.Errorf("parallel verticals should all draw, no legend:\n%s", plain)
	}
	if strings.Count(plain, "▼") < 2 {
		t.Errorf("both parallel lanes should draw an arrow:\n%s", plain)
	}
}
