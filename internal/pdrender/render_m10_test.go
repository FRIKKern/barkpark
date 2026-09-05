package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// renderM10Fixture renders the M10 side-by-side-grid fixture (notes / pipeline /
// cards blocks that opt INTO the grid via layout:{mode:"grid"}) with NoColor
// pinned so the goldens are byte-stable. No RefResolver is needed — the fixture
// holds only self-contained grid widgets.
func renderM10Fixture(t *testing.T, name string, width int) string {
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
	ctx := RenderCtx{
		Width:   width,
		Theme:   DarkTheme(),
		Profile: NoColor,
	}
	out := reg.RenderDoc(blocks, ctx)
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM10 is the W4 side-by-side spine (pd-layout-engine W4). The notes,
// pipeline, and cards blocks each carry layout:{mode:"grid"}, so the shared Flex
// solver lays their items HORIZONTALLY when the surface is wide and COLLAPSES them
// to the byte-identical vertical stack when it is narrow. At w120/w80 the three
// widgets go side-by-side (notes 3-up, cards 3-up, pipeline 2 stages joined by a
// `→` separator column); at w40 every one drops below the per-cell MinWidth floor
// and stacks — proving the degrade path. Regenerate with -update.
func TestGoldenM10(t *testing.T) {
	const fx = "sample_m10.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM10Fixture(t, fx, w)
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
				t.Errorf("M10 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}
