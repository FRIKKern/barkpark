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
	return ansi.Strip(reg.RenderDoc(blocks, ctx))
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
