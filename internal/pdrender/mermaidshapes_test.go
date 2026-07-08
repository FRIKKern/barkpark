package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestShapeFramesDistinct: each Mermaid shape renders a DISTINCT terminal frame.
// Asserts the signature glyph of each frame is present, so a regression that
// collapses shapes back to three families fails here.
func TestShapeFramesDistinct(t *testing.T) {
	cases := []struct {
		src  string // single-node flowchart
		want string // a glyph unique to that shape's frame
		name string
	}{
		{"flowchart TD\n A[Rect]", "┌", "rect"},
		{"flowchart TD\n A(Round)", "╭", "rounded"},
		{"flowchart TD\n A([Stadium])", "(", "stadium"},
		{"flowchart TD\n A((Circle))", "╔", "circle"},
		{"flowchart TD\n A{Diamond}", "╱", "diamond"},
		{"flowchart TD\n A{{Hexagon}}", "<", "hexagon"},
		{"flowchart TD\n A[[Sub]]", "╓", "subroutine"},
		{"flowchart TD\n A[(DB)]", "╒", "cylinder"},
	}
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	for _, c := range cases {
		g := parseMermaid(c.src).graph
		out := renderFlowchart(g, ctx)
		plain := ansi.Strip(strings.Join(out, "\n"))
		if !strings.Contains(plain, c.want) {
			t.Errorf("%s: frame glyph %q missing:\n%s", c.name, c.want, plain)
		}
		for i, ln := range out {
			if w := ansi.StringWidth(ln); w != 60 {
				t.Errorf("%s line %d width %d != 60", c.name, i, w)
			}
		}
	}
	// Circle (double frame) and rounded must NOT share a signature — a guard that
	// the two rounded-ish shapes stay visually separable.
	circle := ansi.Strip(strings.Join(renderFlowchart(parseMermaid("flowchart TD\n A((C))").graph, ctx), "\n"))
	if !strings.Contains(circle, "═") || !strings.Contains(circle, "║") {
		t.Errorf("circle should use the double frame (═/║):\n%s", circle)
	}
}

// TestLRFanComposesJunctions: a fan-out+merge in LR composes shared-column bits
// into a cross (┼) where the straight edge crosses the vertical bus — the old
// per-edge routing overwrote that cell, so a ┼ here proves the accumulate-then-
// resolve fix. Also asserts rectangularity.
func TestLRFanComposesJunctions(t *testing.T) {
	src := "flowchart LR\n In-->R{Route}\n R-->A[Auth]\n R-->C[Cache]\n R-->L[Log]\n A-->H[Handler]\n C-->H\n L-->H"
	g := parseMermaid(src).graph
	ctx := RenderCtx{Width: 100, Theme: DarkTheme(), Profile: NoColor}
	out := renderFlowchartLR(g, ctx)
	if out == nil {
		t.Fatal("LR should fit at w=100")
	}
	plain := ansi.Strip(strings.Join(out, "\n"))
	if !strings.Contains(plain, "┼") {
		t.Errorf("fan-out/merge should compose a ┼ cross (straight edge crossing the bus):\n%s", plain)
	}
	// The old overwrite bug produced "┐─" / "┌─" runs on the main row; the bus is
	// now a clean vertical, so a corner glyph never abuts a horizontal run mid-band.
	for i, ln := range out {
		if w := ansi.StringWidth(ln); w != 100 {
			t.Errorf("line %d width %d != 100: %q", i, w, ansi.Strip(ln))
		}
	}
}
