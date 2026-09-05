package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// renderM17Fixture renders the M17 heat-family fixture with NoColor pinned so the
// goldens are byte-stable in CI (same discipline as every milestone fixture).
func renderM17Fixture(t *testing.T, name string, width int) string {
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
	stripped := ansi.Strip(reg.RenderDoc(blocks, ctx))
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM17 byte-locks the slate-2 heat family: the quantile dual-encoded
// calendar (mode:"calendar") and the rows×cols matrix with Σ marginals + exact
// values. The NoColor render is byte-stable at every width. At width 80 the
// calendar shows all 38 weeks; narrower widths drop the OLDEST whole weeks (the
// full-year >80-col path is proven by sample_m26). Regenerate with -update.
func TestGoldenM17(t *testing.T) {
	const fx = "sample_m17.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM17Fixture(t, fx, w)
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
				t.Errorf("M17 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestM17StripComplete holds the detail-ceiling strip law on the M17 heat family
// at all three colour profiles via the shared assertStripComplete helper: the
// quantile shade glyphs and the exact Σ digits live in the geometry, so the
// ANSI-stripped ANSI256 and TrueColor renders are byte-identical to NoColor.
func TestM17StripComplete(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m17.json"))
	if err != nil {
		t.Fatal(err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "heat_family_sample_m17", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})
}

// TestHeatMatrixPreservesLabelsAtGridWidth is derived from the production
// constraint-frontier Paper. A two-track section gives this matrix 39 columns;
// every row/column label must survive by wrapping instead of becoming "cap…".
func TestHeatMatrixPreservesLabelsAtGridWidth(t *testing.T) {
	block := Block{Type: "heatmap", Attrs: map[string]any{
		"type":      "heatmap",
		"values":    true,
		"max":       3,
		"cells":     []any{[]any{0, 0, 0, 0}, []any{1, 1, 1, 0}},
		"colLabels": []any{"capital", "skill", "network", "violence"},
		"rowLabels": []any{"cultivation", "distribution"},
	}}
	out := ansi.Strip(strings.Join(heatmapRenderer{}.Render(
		block,
		RenderCtx{Width: 39, Theme: DarkTheme(), Profile: NoColor},
	), "\n"))

	if strings.Contains(out, "…") {
		t.Fatalf("heat matrix introduced an ellipsis:\n%s", out)
	}
	compact := semanticCompact(out)
	for _, label := range []string{
		"capital", "skill", "network", "violence", "cultivation", "distribution",
	} {
		if !strings.Contains(compact, semanticCompact(label)) {
			t.Errorf("missing complete label %q:\n%s", label, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if ansi.StringWidth(line) > 39 {
			t.Errorf("line width %d exceeds 39: %q", ansi.StringWidth(line), line)
		}
	}
}

// TestHeatMatrixHighCardinalityFallsBackToCompleteLedger proves a matrix that
// cannot keep all columns aligned in 39 cells changes representation instead of
// relying on the document boundary to wrap rows and sever header/value mapping.
func TestHeatMatrixHighCardinalityFallsBackToCompleteLedger(t *testing.T) {
	block := Block{Type: "heatmap", Attrs: map[string]any{
		"type":   "heatmap",
		"values": true,
		"cells": []any{
			[]any{100, 200, 300, 400, 500, 600, 700, 800},
		},
		"colLabels": []any{
			"admission", "billing", "catalog", "delivery",
			"evidence", "fulfilment", "governance", "handoff",
		},
		"rowLabels": []any{"a deliberately long production row"},
	}}
	out := ansi.Strip(strings.Join(heatmapRenderer{}.Render(
		block,
		RenderCtx{Width: 39, Theme: DarkTheme(), Profile: NoColor},
	), "\n"))

	if !strings.Contains(out, "Matrix ledger") {
		t.Fatalf("expected explicit complete-ledger fallback:\n%s", out)
	}
	if strings.Contains(out, "…") {
		t.Fatalf("matrix ledger introduced an ellipsis:\n%s", out)
	}
	compact := semanticCompact(out)
	for _, want := range []string{
		"admission", "billing", "catalog", "delivery", "evidence",
		"fulfilment", "governance", "handoff",
		"a deliberately long production row",
		"1 100", "2 200", "3 300", "4 400",
		"5 500", "6 600", "7 700", "8 800",
	} {
		if !strings.Contains(compact, semanticCompact(want)) {
			t.Errorf("ledger missing %q:\n%s", want, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if ansi.StringWidth(line) > 39 {
			t.Errorf("line width %d exceeds 39: %q", ansi.StringWidth(line), line)
		}
	}
}

// TestHeatMatrixShadeLedgerKeepsValuesPrivate preserves the author contract:
// values:false stays a shade-only matrix even when cardinality forces the narrow
// ledger representation.
func TestHeatMatrixShadeLedgerKeepsValuesPrivate(t *testing.T) {
	cells := make([]any, 20)
	labels := make([]any, 20)
	for i := range cells {
		cells[i] = 9876 + i
		labels[i] = "dimension-" + itoa(i+1)
	}
	block := Block{Type: "heatmap", Attrs: map[string]any{
		"type":      "heatmap",
		"marginals": true,
		"values":    false,
		"cells":     []any{cells},
		"colLabels": labels,
		"rowLabels": []any{"production row"},
	}}
	out := ansi.Strip(strings.Join(heatmapRenderer{}.Render(
		block,
		RenderCtx{Width: 39, Theme: DarkTheme(), Profile: NoColor},
	), "\n"))

	if !strings.Contains(out, "Matrix ledger") {
		t.Fatalf("expected explicit complete-ledger fallback:\n%s", out)
	}
	if strings.Contains(out, "9876") || strings.Contains(out, "9895") {
		t.Fatalf("shade-only ledger exposed exact values:\n%s", out)
	}
	if !strings.ContainsAny(out, "░▒▓█") {
		t.Fatalf("shade-only ledger lost quantile geometry:\n%s", out)
	}
	for i := 1; i <= 20; i++ {
		if !strings.Contains(semanticCompact(out), semanticCompact("dimension-"+itoa(i))) {
			t.Errorf("shade ledger lost column label %d:\n%s", i, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if ansi.StringWidth(line) > 39 {
			t.Errorf("line width %d exceeds 39: %q", ansi.StringWidth(line), line)
		}
	}
}

// TestHeatMatrixLedgerKeepsRaggedMappingAndIgnoresExtraLabels locks three narrow
// fallback edges: no phantom label beyond nCols, no omitted trailing mapping for
// a short row, and the heat-scale key remains visible.
func TestHeatMatrixLedgerKeepsRaggedMappingAndIgnoresExtraLabels(t *testing.T) {
	labels := make([]any, 11)
	for i := range labels {
		labels[i] = "dimension-" + itoa(i+1)
	}
	block := Block{Type: "heatmap", Attrs: map[string]any{
		"type":   "heatmap",
		"values": true,
		"cells": []any{
			[]any{100, 200, 300, 400, 500, 600, 700, 800, 900, 1000},
			[]any{7, 8},
		},
		"colLabels": labels,
		"rowLabels": []any{"complete row", "ragged row"},
	}}
	out := ansi.Strip(strings.Join(heatmapRenderer{}.Render(
		block,
		RenderCtx{Width: 39, Theme: DarkTheme(), Profile: NoColor},
	), "\n"))
	compact := semanticCompact(out)

	if !strings.Contains(out, "Matrix ledger") {
		t.Fatalf("expected explicit complete-ledger fallback:\n%s", out)
	}
	if strings.Contains(compact, semanticCompact("dimension-11")) {
		t.Fatalf("ledger rendered phantom label beyond nCols:\n%s", out)
	}
	for _, want := range []string{"dimension-10", "ragged row", "10=0", "less", "more"} {
		if !strings.Contains(compact, semanticCompact(want)) {
			t.Errorf("ledger missing %q:\n%s", want, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if ansi.StringWidth(line) > 39 {
			t.Errorf("line width %d exceeds 39: %q", ansi.StringWidth(line), line)
		}
	}
}

// TestHeatQuantileBins pins the quantile binning contract: zero → -1 (the special
// dim bin), and a single dominating spike does NOT flatten the ordinary values into
// the floor (the whole reason quantile beats linear value/max).
func TestHeatQuantileBins(t *testing.T) {
	// One huge spike, a spread of small values, and zeros.
	cells := [][]float64{
		{0, 1, 2, 3, 4, 5, 6, 7, 8, 100},
	}
	bins := HeatQuantileBins(cells)[0]

	if bins[0] != -1 {
		t.Errorf("zero cell: expected bin -1, got %d", bins[0])
	}
	if bins[len(bins)-1] != 3 {
		t.Errorf("spike cell: expected top bin 3, got %d", bins[len(bins)-1])
	}
	// The small nonzero values must NOT all collapse to bin 0 — quantile spreads
	// them across bins. A linear value/100 ramp would put every one of 1..8 in the
	// bottom bin; quartiles must use at least three distinct bins over 1..8.
	seen := map[int]bool{}
	for _, v := range []float64{1, 2, 3, 4, 5, 6, 7, 8} {
		for j, cv := range cells[0] {
			if cv == v {
				seen[bins[j]] = true
			}
		}
	}
	if len(seen) < 3 {
		t.Errorf("quantile binning flattened the small values into %d bin(s): %v — expected the mass spread across ≥3 bins", len(seen), seen)
	}
}
