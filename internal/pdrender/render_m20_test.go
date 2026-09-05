package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── M20: chart compact-unit y-ticks + max-2-series cap ───────────────────────
//
// The slate-2 chart upgrade (pbp-slate2-chart-units). Two REAL gaps, one fixture:
//
//  1. COMPACT-UNIT Y-TICKS — formatTickCompact renders a tick with SI-style units
//     once |v| ≥ 10000: 12500→"12.5k", 45500000→"45.5M", 2000000000→"2B", one
//     decimal with a trailing ".0" trimmed. Below the threshold it is byte-
//     identical to formatTick, so every small-value chart golden (m13, m15) is
//     untouched. sample_m20's chart tops out at 45.5M, so the gutter reads "45.5M"
//     / "30.3M" / … instead of eight-digit ticks that would crowd out the plot.
//
//  2. MAX-2-SERIES CAP — a chart renders at most the FIRST two series (plot AND
//     legend), and the cap fences the auto-scale too. sample_m20's chart carries
//     THREE series; the third ("forecast") peaks at 50M but is dropped, so the
//     axis stays pinned to the two-series max of 45.5M — proving the cap runs
//     before scaling, not just at paint time.
//
// The goldens are the NoColor artifact at four widths; TestM20StripComplete holds
// the detail-ceiling strip law across all three profiles. Regenerate with -update.

// renderM20Fixture renders the M20 fixture with NoColor pinned so the goldens are
// byte-stable in CI (same discipline as every milestone fixture).
func renderM20Fixture(t *testing.T, name string, width int) string {
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

// TestGoldenM20 byte-locks the compact-unit + capped chart render at every golden
// width (40/60/80/120). Regenerate with -update.
func TestGoldenM20(t *testing.T) {
	const fx = "sample_m20.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM20Fixture(t, fx, w)
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
				t.Errorf("M20 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestM20StripComplete holds the detail-ceiling strip law on the M20 chart at all
// three colour profiles via the shared assertStripComplete helper: the compact
// ticks and the two braille curves live in the glyph/geometry, so the ANSI-
// stripped ANSI256 and TrueColor renders are byte-identical to NoColor. Also
// asserts the compact "45.5M" datum is present and NO third-series ("forecast")
// swatch leaks — so the golden can never pass vacuously.
func TestM20StripComplete(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m20.json"))
	if err != nil {
		t.Fatal(err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "chart_compact_capped_sample_m20", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})

	// Non-vacuous anchors at width 80 (NoColor).
	base := renderM20Fixture(t, "sample_m20.json", 80)
	if !strings.Contains(base, "45.5M") {
		t.Errorf("compact tick datum %q missing from render:\n%s", "45.5M", base)
	}
	if strings.Contains(base, "forecast") {
		t.Errorf("third series leaked past the max-2 cap (found 'forecast' swatch):\n%s", base)
	}
	if !strings.Contains(base, "revenue") || !strings.Contains(base, "cost") {
		t.Errorf("expected the first two series (revenue, cost) in the legend:\n%s", base)
	}
}
