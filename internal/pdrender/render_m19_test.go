package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── M19: stat KPI cell denominator ───────────────────────────────────────────
//
// The stat-grid cell gains an optional `denom`: a dim "/<denom>" that rides
// beside the accent value so a KPI reads as a share of a dim total ("71/118").
// This is a SURGICAL delta on the existing statCell — no new renderer, no width
// arithmetic, no flex change. sample_m19.json mixes denom-bearing and denom-less
// cells (in the grid AND as singular stats, plus a bullet-bar cell carrying both
// max and denom) so the golden proves:
//   - the denom rides beside the value, dim, as "value/denom";
//   - a denom-less cell is a bare big number (the backward-compat law);
//   - the singular `stat` and the `stats` grid share ONE cell body.
//
// The backward-compat law (denom-absent output byte-identical) is proven by the
// pre-existing m12/m15 goldens staying untouched — this file only adds NEW
// coverage.

// renderM19Fixture renders the M19 KPI-denom fixture with NoColor pinned so the
// goldens are byte-stable in CI (same discipline as every milestone fixture).
func renderM19Fixture(t *testing.T, name string, width int) string {
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

// TestGoldenM19 byte-locks the KPI-denom render at every golden width
// (40/60/80/120): the dim "/<denom>" beside the accent value, denom-less cells
// bare, singular + grid sharing the cell body. Regenerate with -update.
func TestGoldenM19(t *testing.T) {
	const fx = "sample_m19.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM19Fixture(t, fx, w)
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
				t.Errorf("M19 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestM19DenomStripParity is the detail-ceiling proof for the denom cell: via the
// shared assertStripComplete helper the ANSI-stripped render is byte-identical
// across all three colour profiles (NoColor / ANSI256 / TrueColor) at every golden
// width, so the "71/118" datum survives with ZERO colour — colour is reinforcement
// (the dim tone), never the carrier. It also asserts the denom datum is
// structurally present and a denom-less cell grows no spurious slash, so
// TestGoldenM19 can never pass vacuously.
func TestM19DenomStripParity(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m19.json"))
	if err != nil {
		t.Fatal(err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "stat_denom_sample_m19", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})

	// Non-vacuous anchors at width 80 (NoColor): every denom datum is a complete
	// artifact, and a denom-less cell grows no spurious trailing slash.
	base := renderM19Fixture(t, "sample_m19.json", 80)
	for _, want := range []string{"71/118", "14/20", "340/512"} {
		if !strings.Contains(base, want) {
			t.Errorf("stripped render missing denom datum %q:\n%s", want, base)
		}
	}
	if strings.Contains(base, "92%/") || strings.Contains(base, "1.2k/") {
		t.Errorf("denom-less cell grew a spurious slash:\n%s", base)
	}
}
