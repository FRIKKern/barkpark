package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestFlowchartLRRectangular: the LR canvas is a perfect rectangle at widths that
// fit, and non-vacuously draws boxes + horizontal arrows.
func TestFlowchartLRRectangular(t *testing.T) {
	graphs := map[string]string{
		"linear": "flowchart LR\n A[Ingest]-->B[Parse]-->C[Emit]",
		"tree":   "flowchart LR\n R-->A\n R-->B\n A-->Z\n B-->Z",
		"fan":    "flowchart LR\n A-->B{Ok}\n B-->|y|C\n B-->|n|D",
	}
	for name, src := range graphs {
		g := parseMermaid(src).graph
		for _, w := range []int{80, 100, 120} {
			ctx := RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}
			out := renderFlowchartLR(g, ctx)
			if out == nil {
				t.Fatalf("%s@%d: nil (should fit)", name, w)
			}
			var box, arrow bool
			for i, ln := range out {
				if got := ansi.StringWidth(ln); got != w {
					t.Errorf("%s@%d line %d width = %d, want %d: %q",
						name, w, i, got, w, ansi.Strip(ln))
				}
				p := ansi.Strip(ln)
				if strings.ContainsAny(p, "┌╱") {
					box = true
				}
				if strings.Contains(p, "▶") {
					arrow = true
				}
			}
			if !box || !arrow {
				t.Errorf("%s@%d: vacuous (box=%v arrow=%v)", name, w, box, arrow)
			}
		}
	}
}

// TestFlowchartLRCollapse: when an LR graph can't fit the width, renderFlowchartLR
// returns nil so the caller re-lays-out as TD — the responsive flex-direction
// transpose. The dispatch then produces a top-down render (▼ present, no ▶).
func TestFlowchartLRCollapse(t *testing.T) {
	// Four ranks of wide labels won't fit horizontally at w=40.
	g := parseMermaid("flowchart LR\n A[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]").graph
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	if out := renderFlowchartLR(g, ctx); out != nil {
		t.Fatalf("LR at w=40 should collapse to nil, got %d lines", len(out))
	}
	// Through dispatch: the collapse yields a TD render (vertical arrows).
	blk := Block{Type: "diagram", Attrs: map[string]any{
		"source": "flowchart LR\n A[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]"}}
	got := ansi.Strip(strings.Join(diagramRenderer{}.Render(blk, ctx), "\n"))
	if !strings.Contains(got, "▼") {
		t.Errorf("collapsed LR should render top-down (▼):\n%s", got)
	}
	if strings.Contains(got, "▶") {
		t.Errorf("collapsed LR should not have horizontal arrows:\n%s", got)
	}
}

// TestFlowchartLRDispatch: a comfortable width honours LR (horizontal ▶); the
// same graph at a tight width collapses to TD (▼). One graph, two directions,
// width-driven — the headline responsive behaviour.
func TestFlowchartLRDispatch(t *testing.T) {
	src := "flowchart LR\n A[One]-->B[Two]-->C[Three]"
	wide := ansi.Strip(strings.Join(diagramRenderer{}.Render(
		Block{Type: "diagram", Attrs: map[string]any{"source": src}},
		RenderCtx{Width: 90, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(wide, "▶") {
		t.Errorf("LR at w=90 should flow horizontally (▶):\n%s", wide)
	}
	narrow := ansi.Strip(strings.Join(diagramRenderer{}.Render(
		Block{Type: "diagram", Attrs: map[string]any{"source": src}},
		RenderCtx{Width: 30, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(narrow, "▼") {
		t.Errorf("LR at w=30 should collapse to TD (▼):\n%s", narrow)
	}
}
