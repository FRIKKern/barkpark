package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── M21: table typed columns ─────────────────────────────────────────────────
//
// The table gains an optional `cols` spec — an index-aligned array of {type}
// maps — that tags each column text | num | delta | spark. It touches only the
// CELL BODY (and num/delta alignment via the existing StyleFunc); the
// lipgloss/table auto-sizer stays the sole width authority (no width math, no
// Flex/joincols port — TestNoInlineDivideFormulaOutsideSolver stays green).
// sample_m21.json is the milestone trio: ONE table exercising all four types —
//   - text   Metric   legacy inline body, left-aligned;
//   - num    Total    right-aligned digits (content-identical to text);
//   - delta  Δ 7d     leading ▲ / ▼ / - glyph from the numeric sign (glyph-first,
//            so the direction survives with zero color);
//   - spark  Trend    the canonical stat.go sparkline capped to 14 cells.
//
// The backward-compat law (cols-absent output byte-identical) is proven by every
// pre-existing table golden (m1 …) staying untouched — this file only adds NEW
// coverage.

// renderM21Fixture renders the M21 typed-columns fixture with NoColor pinned so
// the goldens are byte-stable in CI (same discipline as every milestone fixture).
func renderM21Fixture(t *testing.T, name string, width int) string {
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

// TestGoldenM21 byte-locks the typed-columns render at every golden width
// (40/60/80/120): right-aligned num, ▲/▼/- deltas, 14-cell sparks. Regenerate
// with -update.
func TestGoldenM21(t *testing.T) {
	const fx = "sample_m21.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM21Fixture(t, fx, w)
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
				t.Errorf("M21 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestM21TypedColsStripParity is the detail-ceiling proof for typed columns: the
// ANSI-stripped render is byte-identical across NoColor / ANSI256 / TrueColor at
// every golden width (via the shared assertStripComplete helper), so the deltas
// and the spark curve survive with ZERO color — color is reinforcement only,
// never the carrier. It also asserts every type's datum is structurally present
// so TestGoldenM21 can never pass vacuously.
func TestM21TypedColsStripParity(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m21.json"))
	if err != nil {
		t.Fatal(err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}

	// Strip law across the three profiles at every golden width.
	assertStripComplete(t, "table_typed_cols_m21", func(w int, p Profile) string {
		reg := DefaultRegistry(DarkTheme())
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})

	// Structural asserts on the NoColor render at w80 (columns fully visible).
	got := renderM21Fixture(t, "sample_m21.json", 80)

	// delta glyphs — up (▲), down (▼), flat (-) — glyph-first, not color-only.
	for _, want := range []string{"▲ 8.4", "▼ 2.1", "- 0"} {
		if !strings.Contains(got, want) {
			t.Errorf("stripped render missing delta datum %q:\n%s", want, got)
		}
	}
	// A delta cell never double-shows its sign (the glyph carries direction, the
	// magnitude is absolute) — so "▼ -2.1" must NOT appear.
	if strings.Contains(got, "-2.1") || strings.Contains(got, "-8.4") {
		t.Errorf("delta cell double-encoded its sign (glyph + signed magnitude):\n%s", got)
	}
	// spark — the full 14-rune curve for the rising Sessions series and the flat
	// p95 baseline. Both are exactly 14 runes and render at every profile.
	for _, want := range []string{"▁▂▂▂▃▄▃▅▅▅▆▇▇█", "▁▁▁▁▁▁▁▁▁▁▁▁▁▁"} {
		if !strings.Contains(got, want) {
			t.Errorf("stripped render missing 14-cell spark %q:\n%s", want, got)
		}
		if n := len([]rune(want)); n != 14 {
			t.Fatalf("test bug: spark literal %q is %d runes, not 14", want, n)
		}
	}
	// num right-alignment: "12480" is the widest Total, so the narrower "312" and
	// "128" pad LEFT (a space precedes them inside their padded cell).
	if !strings.Contains(got, " 312 ") || !strings.Contains(got, " 128 ") {
		t.Errorf("num column not right-aligned as expected:\n%s", got)
	}

	// No-wrap law: each of the three data rows carries its 14-rune spark on ONE
	// physical line at every golden width (Wrap(true) must not fold the spark).
	for _, w := range goldenWidths {
		render := renderM21Fixture(t, "sample_m21.json", w)
		sparkLines := 0
		for _, ln := range strings.Split(render, "\n") {
			if strings.ContainsAny(ln, "▁▂▃▄▅▆▇█") {
				sparkLines++
			}
		}
		if sparkLines != 3 {
			t.Errorf("w%d: expected 3 spark-bearing lines (no wrap), got %d:\n%s", w, sparkLines, render)
		}
	}
}
