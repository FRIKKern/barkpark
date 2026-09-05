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

// overflowFixtures are the fixtures the no-overflow lock renders. They cover
// every side-by-side surface (columns in m4, task lanes + momentum bar in m6,
// grid sections in m7) plus the prose baselines — the widest blast radius for a
// column-math off-by-one, all measured at once.
var overflowFixtures = []string{
	"sample.json",
	"internal_links.json",
	"sample_m4.json",
	"sample_m6.json",
	"sample_m7.json",
	// sample_m8 is the W2 measure-aware boundary: a wide unbreakable action label
	// that would overflow its side-by-side track at w40/w60/w80. The Fits gate
	// collapses the columns + grid to their verbatim stacks so nothing overflows;
	// remove the gate (Fits→true) and the collapsed row overflows the target width
	// (~w60), which is the anti-vacuity proof this fixture exists to make.
	"sample_m8.json",
	// sample_m9 is the W3 breakpoint reflow: a grid section carrying
	// breakpoints [{100,3},{70,2}] + gap:"lg". As the width narrows the effective
	// track count STEPS 3→2→1→1 across w120/w80/w60/w40. The collapsed tracks at
	// the narrow widths must still hold their content — no line may overflow the
	// target width once the grid drops to fewer (or one) tracks.
	"sample_m9.json",
	// sample_m10 is the W4 side-by-side spine: notes/cards/pipeline widgets that
	// opt INTO the horizontal Flex path via layout:{mode:"grid"}. At the wide
	// widths they lay out horizontally (notes 3-up, cards 3-up, pipeline stages
	// joined by `→`); at w40 every cell drops below its MinWidth floor and stacks.
	// No line may overflow the target width in either regime.
	"sample_m10.json",
}

// TestNoLineOverflow is the P9/80-column guarantee and the anti-vacuity spine:
// for EVERY fixture at EVERY golden width, no rendered line may exceed the
// target width (measured ANSI-aware via ansi.StringWidth, so a wide-rune or a
// len()-vs-cells bug both show). A single real overflow reds it — it cannot go
// vacuously green. The negative control below proves the checker is alive.
func TestNoLineOverflow(t *testing.T) {
	for _, fx := range overflowFixtures {
		for _, w := range goldenWidths {
			got := renderFixture(t, fx, w) // ANSI-stripped
			for i, line := range strings.Split(got, "\n") {
				if wd := ansi.StringWidth(line); wd > w {
					t.Errorf("%s w%d: line %d width %d > %d: %q", fx, w, i, wd, w, line)
				}
			}
		}
	}
}

// TestNoLineOverflowNegativeControl is the load-bearing proof that the lock is
// NOT vacuous: it reconstructs the column-math bug the lock exists to catch —
// dropping the gutter term from cellW — and asserts the resulting join DOES
// overflow the target width. If this ever stops overflowing, the lock above has
// rotted into a green that means nothing.
func TestNoLineOverflowNegativeControl(t *testing.T) {
	reg := testRegistry()
	const w, n = 80, 2
	buggyCellW := w / n // 40 — WRONG: omits the (n-1)*gutter term (correct = 39)

	col := func(tag string) []string {
		// A long single word forces a full-cellW line, so the pad is exact.
		return strings.Split(renderBlock(reg, gridPara(strings.Repeat(tag, 60), nil), buggyCellW), "\n")
	}
	joined := joinColumns([][]string{col("a"), col("b")}, []int{buggyCellW, buggyCellW}, 2)

	over := false
	for _, ln := range joined {
		if ansi.StringWidth(ln) > w {
			over = true
			break
		}
	}
	if !over {
		t.Fatal("NEGATIVE CONTROL FAILED: a gutter-less cellW should overflow w=80, but no line did — the overflow lock is vacuous")
	}
}

// TestTrueColorNoOverflow is the colored-profile smoke: it renders the
// side-by-side task fixture with real SGR emission ON (termenv.TrueColor) so a
// len()-vs-lipgloss.Width padding bug — invisible under the NoColor goldens,
// where stripped bytes == cells — cannot hide. Every visible line must still fit
// the width. The enum is inverted in this termenv (TrueColor=0), so the named
// constant is used rather than a raw int.
func TestTrueColorNoOverflow(t *testing.T) {
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })

	reg := DefaultRegistry(DarkTheme())
	for _, fx := range []string{"sample_m4.json", "sample_m6.json", "sample_m7.json"} {
		for _, w := range goldenWidths {
			raw, err := os.ReadFile(filepath.Join("testdata", fx))
			if err != nil {
				t.Fatalf("read %s: %v", fx, err)
			}
			blocks, err := Decode(raw)
			if err != nil {
				t.Fatalf("decode %s: %v", fx, err)
			}
			ctx := RenderCtx{Width: w, Theme: DarkTheme(), Profile: TrueColor}
			out := reg.RenderDoc(blocks, ctx)
			// Shared blind-spot guard (unknown_block_guard_test.go).
			assertNoUnknownBlock(t, fx, ansi.Strip(out))
			for i, line := range strings.Split(out, "\n") {
				if wd := ansi.StringWidth(line); wd > w {
					t.Errorf("TrueColor %s w%d: line %d visible width %d > %d: %q",
						fx, w, i, wd, w, ansi.Strip(line))
				}
			}
		}
	}
}
