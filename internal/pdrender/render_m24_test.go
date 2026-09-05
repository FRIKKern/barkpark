package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// M24 is the pipeline layout:{mode:"flow"} slice: a pipeline opts into a LINEAR
// flowchart that renders as ──▶ boxes left-to-right when the chain fits and
// COLLAPSES to the TD ▼ stack when it can't. The adapter (pipelineflow.go) builds
// the mmGraph model directly and hands it to renderFlowchartAuto — no synthesized
// mermaid text is re-parsed. These tests pin the golden at every width, the strip
// law THROUGH the pipelineRenderer entry point (the existing mermaid tests bypass
// it), the honest narrow degrade, and the absent-layout parity.

// pipelineFlowBlock renders one pipeline block from the m24 fixture at NoColor and
// strips ANSI, so the flow art is byte-stable geometry.
func renderM24Fixture(t *testing.T, name string, width int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	reg := testRegistry() // pins lipgloss to Ascii (NoColor)
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	out := reg.RenderDoc(blocks, ctx)
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM24 renders the flow fixture at every golden width and diffs it
// against the checked-in golden (regenerate with -update). w40 proves the honest
// TD ▼ degrade; w60/80/120 prove the ──▶ LR chain.
func TestGoldenM24(t *testing.T) {
	const fx = "sample_m24.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM24Fixture(t, fx, w)
			goldenPath := filepath.Join("testdata", "golden", name+"_w"+itoa(w)+".txt")
			if *update {
				if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden (run with -update to create): %v", err)
			}
			if got != string(want) {
				t.Errorf("M24 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// flowPipeline renders ONE pipeline block through the pipelineRenderer entry point
// at NoColor and strips, returning the whole render as lines. Going through the
// registered renderer (not renderFlowchartAuto directly) is the point: it exercises
// the flowOptIn predicate + the direct-mmGraph adapter, the seam m24 owns.
func flowPipeline(attrs map[string]any, width int) string {
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	defer lipgloss.SetColorProfile(old)
	b := Block{Type: "pipeline", Attrs: attrs}
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	return ansi.Strip(strings.Join(pipelineRenderer{}.Render(b, ctx), "\n"))
}

func m24FlowAttrs() map[string]any {
	return map[string]any{
		"layout": map[string]any{"mode": "flow"},
		"nodes": []any{
			map[string]any{"kind": "stage", "title": "Draft"},
			map[string]any{"kind": "stage", "title": "Review"},
			map[string]any{"kind": "stage", "title": "Merge"},
			map[string]any{"kind": "stage", "title": "Deploy"},
		},
	}
}

// TestPipelineFlowWideDrawsArrows proves a short chain draws the ──▶ LR flow at a
// roomy width — the ▶ arrowhead riding a ── wire is the connector the slice ships.
func TestPipelineFlowWideDrawsArrows(t *testing.T) {
	for _, w := range []int{60, 80, 120} {
		out := flowPipeline(m24FlowAttrs(), w)
		if !strings.Contains(out, "──▶") {
			t.Errorf("flow pipeline at w%d should draw a ──▶ LR chain, got:\n%s", w, out)
		}
		if strings.Contains(out, "↓") {
			t.Errorf("flow pipeline at w%d must not fall back to the legacy ↓ stack:\n%s", w, out)
		}
		for _, title := range []string{"Draft", "Review", "Merge", "Deploy"} {
			if !strings.Contains(out, title) {
				t.Errorf("flow pipeline at w%d dropped node %q:\n%s", w, title, out)
			}
		}
	}
}

// TestPipelineFlowDegradesToTD proves the honest degrade: at a width too narrow to
// carry the LR chain, renderFlowchartLR returns nil and the render collapses to the
// TD ▼ stack — never a half-drawn sideways chain, never the legacy ↓ connector.
func TestPipelineFlowDegradesToTD(t *testing.T) {
	out := flowPipeline(m24FlowAttrs(), 40)
	if strings.Contains(out, "──▶") {
		t.Errorf("flow pipeline at w40 should not fit the LR chain (expected TD degrade):\n%s", out)
	}
	if !strings.Contains(out, "▼") {
		t.Errorf("flow pipeline at w40 should degrade to the TD ▼ stack, got:\n%s", out)
	}
	// Every node still carries through the degrade — the chain is complete, just
	// re-oriented top-down.
	for _, title := range []string{"Draft", "Review", "Merge", "Deploy"} {
		if !strings.Contains(out, title) {
			t.Errorf("TD degrade dropped node %q:\n%s", title, out)
		}
	}
}

// TestPipelineFlowAbsentLayoutIsLegacy is the parity guard: with no layout the
// pipeline keeps its verbatim ↓-connector stack (flowOptIn false), so no ──▶ / ▼
// flow art leaks into the legacy corpus. mustContain, not a byte golden — no golden
// pins the legacy pipeline, and this slice must not add one.
func TestPipelineFlowAbsentLayoutIsLegacy(t *testing.T) {
	attrs := map[string]any{
		"nodes": []any{
			map[string]any{"kind": "stage", "title": "Draft"},
			map[string]any{"kind": "stage", "title": "Deploy"},
		},
	}
	out := flowPipeline(attrs, 80)
	if !strings.Contains(out, "↓") {
		t.Errorf("legacy pipeline (no layout) should keep the ↓ connector, got:\n%s", out)
	}
	for _, g := range []string{"──▶", "▼"} {
		if strings.Contains(out, g) {
			t.Errorf("legacy pipeline must not draw flow art %q, got:\n%s", g, out)
		}
	}
}

// TestPipelineFlowEmptyLabelNeverBlankBox proves the label-never-empty guarantee:
// a node with no title/kind still gets a non-empty box label (the synthetic id),
// so the flow never draws a blank box.
func TestPipelineFlowEmptyLabelNeverBlankBox(t *testing.T) {
	attrs := map[string]any{
		"layout": map[string]any{"mode": "flow"},
		"nodes": []any{
			map[string]any{"title": "Start"},
			map[string]any{"detail": "no title here"}, // renders non-blank via detail
			map[string]any{"title": "End"},
		},
	}
	out := flowPipeline(attrs, 80)
	if strings.TrimSpace(out) == "" {
		t.Fatalf("flow render is empty")
	}
	// The middle node has no title/kind → its box falls back to the synthetic id n1.
	if !strings.Contains(out, "n1") {
		t.Errorf("titleless node should fall back to a synthetic id label, got:\n%s", out)
	}
}

// TestPipelineFlowProfileStripEquality is the acceptance proof at all three
// profiles THROUGH the pipelineRenderer entry point: the ANSI-stripped ANSI256 and
// TrueColor renders are byte-identical to NoColor at every golden width. The boxes,
// ──▶ wire, and ▼ degrade are pure geometry — color is reinforcement only.
func TestPipelineFlowProfileStripEquality(t *testing.T) {
	assertStripComplete(t, "pipeline_flow_m24", func(w int, p Profile) string {
		b := Block{Type: "pipeline", Attrs: m24FlowAttrs()}
		return strings.Join(pipelineRenderer{}.Render(b, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p}), "\n")
	})
}
