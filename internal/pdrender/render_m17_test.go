package pdrender

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// m17TermProfile maps a pdrender Profile onto the termenv global lipgloss must be
// pinned to for that profile to actually EMIT its escapes — so the strip-equality
// proof below exercises REAL colour, not a silently-stripped no-op.
func m17TermProfile(p Profile) termenv.Profile {
	switch p {
	case TrueColor:
		return termenv.TrueColor
	case ANSI256:
		return termenv.ANSI256
	default:
		return termenv.Ascii
	}
}

// renderM17 renders the M17 heat-family fixture at one width under one colour
// profile, pinning BOTH ctx.Profile and the process-global lipgloss profile so a
// colour-capable render emits real SGR (the inverted global the doctrine calls
// for). Returns the RAW output with escapes intact; callers strip to compare.
func renderM17(t *testing.T, width int, p Profile) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m17.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(m17TermProfile(p))
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })
	reg := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: p}
	return reg.RenderDoc(blocks, ctx)
}

// TestGoldenM17 is the slate-2 heat family: the quantile dual-encoded calendar
// (mode:"calendar") and the rows×cols matrix with Σ marginals + exact values. Two
// proofs in one:
//
//  1. GOLDEN: the NoColor render is byte-stable at every width. At width 80 the
//     calendar shows all 38 weeks; narrower widths drop the OLDEST whole weeks.
//  2. STRIP-COMPLETE (the detail-ceiling readability line): stripping the ANSI256
//     and TrueColor renders yields the EXACT SAME artifact as NoColor — the datum
//     lives in the glyph/geometry, colour is pure reinforcement. Every profile
//     survives an ANSI strip as a complete, readable grid.
//
// Regenerate the goldens with -update. (The inline strip-equality here stands in
// for the shared assertStripComplete helper until pbp-slate2-doctrine-goldens
// lands; it will dedupe onto that helper.)
func TestGoldenM17(t *testing.T) {
	for _, w := range goldenWidths {
		w := w
		t.Run("sample_m17_w"+itoa(w), func(t *testing.T) {
			got := ansi.Strip(renderM17(t, w, NoColor))
			goldenPath := filepath.Join("testdata", "golden", "sample_m17_w"+itoa(w)+".txt")
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
			// Strip-complete: colour-capable profiles must strip to the SAME bytes.
			for _, p := range []Profile{ANSI256, TrueColor} {
				if s := ansi.Strip(renderM17(t, w, p)); s != got {
					t.Errorf("M17 strip-equality at width %d, profile %v: stripped render differs from NoColor — colour is carrying the datum\n--- %v stripped ---\n%s\n--- NoColor ---\n%s",
						w, p, p, s, got)
				}
			}
		})
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
