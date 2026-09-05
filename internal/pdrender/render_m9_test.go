package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// renderM9Fixture renders the M9 breakpoint-reflow fixture (a grid section
// carrying a `breakpoints` array + a non-md `gap` token) with NoColor pinned so
// the goldens are byte-stable. No RefResolver is needed — the fixture holds only
// element children.
func renderM9Fixture(t *testing.T, name string, width int) string {
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

// TestGoldenM9 is the data-carried breakpoint reflow (pd-layout-engine W3). The
// grid section carries breakpoints [{100,3},{70,2}] resolved against the section
// inner width (== render width for a top-level section). Effective tracks STEP
// 3 → 2 → 1 → 1 as the render width narrows 120 → 80 → 60 → 40: at w120 the three
// cells lay side-by-side (3 tracks), at w80 two-up (2 tracks), and at w60/w40 the
// grid drops below every threshold → 1 track → the byte-identical vertical stack.
// The `gap:"lg"` token widens the inter-cell gutter to 4. Regenerate with -update.
func TestGoldenM9(t *testing.T) {
	const fx = "sample_m9.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM9Fixture(t, fx, w)
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
				t.Errorf("M9 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}
