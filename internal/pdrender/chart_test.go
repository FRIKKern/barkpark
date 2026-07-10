package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// chartTestCtx is a NoColor ctx for the non-golden chart unit tests. testRegistry
// pins the lipgloss color profile to Ascii so ansi.Strip yields the plain glyphs.
func chartTestCtx(width int) RenderCtx {
	testRegistry() // pin NoColor globally
	return RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
}

func stripLines(lines []string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		out[i] = ansi.Strip(l)
	}
	return out
}

// TestBrailleKnownStroke is the EXACT-braille anchor: a known top-row horizontal
// stroke on a 2×1-cell canvas must produce the specific braille glyphs — the dot
// bitmask + rune math is not free to drift. Points (0,0)→(3,0) light dots 1 & 4
// in both cells → U+2809 (⠉) twice.
func TestBrailleKnownStroke(t *testing.T) {
	ctx := chartTestCtx(40)
	c := newBrailleCanvas(2, 1) // dotW=4, dotH=4
	c.line(0, 0, 3, 0, 0)       // horizontal along the TOP dot-row
	got := ansi.Strip(c.rows(ctx, nil, false)[0])
	if want := "⠉⠉"; got != want {
		t.Fatalf("known top stroke: got %q want %q", got, want)
	}

	// A bottom-row stroke lights dots 7 & 8 → U+28C0 (⣀) twice.
	c2 := newBrailleCanvas(2, 1)
	c2.line(0, 3, 3, 3, 0)
	got2 := ansi.Strip(c2.rows(ctx, nil, false)[0])
	if want := "⣀⣀"; got2 != want {
		t.Fatalf("known bottom stroke: got %q want %q", got2, want)
	}
}

// TestPointDotY pins the normaliser wiring: min → bottom dot-row, max → top,
// inverted, and out-of-span values CLAMP to an edge (never expand the scale).
func TestPointDotY(t *testing.T) {
	const dotH = 16
	if y := pointDotY(0, 0, 10, dotH); y != dotH-1 {
		t.Errorf("min should map to the bottom row %d, got %d", dotH-1, y)
	}
	if y := pointDotY(10, 0, 10, dotH); y != 0 {
		t.Errorf("max should map to the top row 0, got %d", y)
	}
	// Above the span → clamp to top; below → clamp to bottom.
	if y := pointDotY(999, 0, 10, dotH); y != 0 {
		t.Errorf("over-span should clamp to top 0, got %d", y)
	}
	if y := pointDotY(-999, 0, 10, dotH); y != dotH-1 {
		t.Errorf("under-span should clamp to bottom %d, got %d", dotH-1, y)
	}
}

// TestApplyAxes proves BOTH partial pins drive the scale and that malformed axes
// fall back to the auto span — the load-bearing "min/max is not decorative" test.
func TestApplyAxes(t *testing.T) {
	series := []chartSeries{{points: []float64{0, 5, 10}}} // auto span 0..10

	// min-only pin: min moves, max stays auto.
	if mn, mx := applyAxes(map[string]any{"axes": map[string]any{"min": float64(-5)}}, series, 0, 10); mn != -5 || mx != 10 {
		t.Errorf("min-only pin: got (%v,%v) want (-5,10)", mn, mx)
	}
	// max-only pin (the tall-max compression case): min stays auto, max moves.
	if mn, mx := applyAxes(map[string]any{"axes": map[string]any{"max": float64(60)}}, series, 0, 10); mn != 0 || mx != 60 {
		t.Errorf("max-only pin: got (%v,%v) want (0,60)", mn, mx)
	}
	// Malformed inverted pins (min >= max) → ignored, auto span stands.
	if mn, mx := applyAxes(map[string]any{"axes": map[string]any{"min": float64(9), "max": float64(1)}}, series, 0, 10); mn != 0 || mx != 10 {
		t.Errorf("inverted pins should auto-scale: got (%v,%v) want (0,10)", mn, mx)
	}
	// Non-numeric pins → treated as absent, auto span stands.
	if mn, mx := applyAxes(map[string]any{"axes": map[string]any{"min": "oops", "max": nil}}, series, 0, 10); mn != 0 || mx != 10 {
		t.Errorf("non-numeric pins should auto-scale: got (%v,%v) want (0,10)", mn, mx)
	}
}

// TestChartAutoVsPinnedDiffer is the render-level proof that a tall pinned max
// COMPRESSES the curve — auto and pinned produce different plots, and the pinned
// plot leaves the top rows blank (the curve sinks to the floor).
func TestChartAutoVsPinnedDiffer(t *testing.T) {
	ctx := chartTestCtx(60)
	pts := []any{float64(0), float64(3), float64(6), float64(9), float64(12), float64(9), float64(6), float64(3), float64(0)}
	series := []any{map[string]any{"label": "s", "points": pts}}

	auto := stripLines(chartRenderer{}.Render(Block{Type: "chart", Attrs: map[string]any{"series": series}}, ctx))
	pinned := stripLines(chartRenderer{}.Render(Block{Type: "chart", Attrs: map[string]any{
		"series": series,
		"axes":   map[string]any{"min": float64(0), "max": float64(60)},
	}}, ctx))

	if strings.Join(auto, "\n") == strings.Join(pinned, "\n") {
		t.Fatal("auto and pinned-tall-max renders are identical — min/max is not driving the plot")
	}
	// The pinned top plot row (row 0, index 0) must be blank braille — the curve
	// compressed away from the ceiling. The auto top row must NOT be blank.
	if !isAllBlankPlot(pinned[0]) {
		t.Errorf("pinned top row should be blank braille, got %q", pinned[0])
	}
	if isAllBlankPlot(auto[0]) {
		t.Errorf("auto top row should carry the curve peak, got blank %q", auto[0])
	}
}

// isAllBlankPlot reports whether a plot line's braille cells are all U+2800.
func isAllBlankPlot(line string) bool {
	for _, r := range line {
		if r >= 0x2801 && r <= 0x28FF {
			return false // a lit braille cell
		}
	}
	return true
}

// TestChartDegrade proves the empty/malformed-series placeholder and that a
// malformed-axes render never panics.
func TestChartDegrade(t *testing.T) {
	ctx := chartTestCtx(60)

	// Empty series → placeholder.
	empty := stripLines(chartRenderer{}.Render(Block{Type: "chart", Attrs: map[string]any{"series": []any{}}}, ctx))
	if len(empty) != 1 || !strings.Contains(empty[0], "unresolved") {
		t.Errorf("empty series should degrade to the placeholder, got %v", empty)
	}

	// Series present but malformed axes (inverted) → auto-scale, no panic.
	out := chartRenderer{}.Render(Block{Type: "chart", Attrs: map[string]any{
		"series": []any{map[string]any{"points": []any{float64(1), float64(2), float64(3)}}},
		"axes":   map[string]any{"min": float64(100), "max": float64(1)},
	}}, ctx)
	if len(out) == 0 {
		t.Error("malformed-axes render produced no output")
	}
}

// TestFormatTickCompact pins the compact formatter contract exactly: the SI
// thresholds, one-decimal with a trimmed ".0", sign preservation, and — the
// backward-compat law — byte-identity with formatTick for every |v| < 10000 (so
// no existing small-value chart golden can move).
func TestFormatTickCompact(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{45500000, "45.5M"},
		{12500, "12.5k"},
		{2000000000, "2B"},
		{10000, "10k"},        // threshold boundary → compact
		{500000, "500k"},      // whole → ".0" trimmed
		{1500000, "1.5M"},     // M with one decimal
		{-45500000, "-45.5M"}, // sign carried through
		{9999, "9999"},        // just below threshold → formatTick
	}
	for _, c := range cases {
		if got := formatTickCompact(c.in); got != c.want {
			t.Errorf("formatTickCompact(%v) = %q, want %q", c.in, got, c.want)
		}
	}

	// Backward-compat law: below 10000, byte-identical to formatTick across a
	// spread of integers and fractionals the existing chart goldens exercise.
	for _, v := range []float64{0, 1, 3.7, 6, 100, 999, 1234, 5000, 9999.4, -42, -9999} {
		if got, plain := formatTickCompact(v), formatTick(v); got != plain {
			t.Errorf("formatTickCompact(%v) = %q diverged from formatTick = %q below the threshold", v, got, plain)
		}
	}
}

// TestChartCapsAtTwoSeries proves the max-2-series law directly on the renderer: a
// three-series block renders exactly the first two swatches (plot + legend), and
// the third series' larger max does NOT stretch the auto-scale — the cap runs
// BEFORE scaling. The synthetic twin of the sample_m20 golden proof.
func TestChartCapsAtTwoSeries(t *testing.T) {
	ctx := chartTestCtx(60)
	three := stripLines(chartRenderer{}.Render(Block{Type: "chart", Attrs: map[string]any{"series": []any{
		map[string]any{"label": "aaa", "points": []any{1.0, 2.0, 3.0}},
		map[string]any{"label": "bbb", "points": []any{2.0, 1.0, 2.0}},
		map[string]any{"label": "ccc", "points": []any{9.0, 9.0, 9.0}},
	}}}, ctx))
	joined := strings.Join(three, "\n")

	if strings.Contains(joined, "ccc") {
		t.Errorf("third series 'ccc' leaked past the cap:\n%s", joined)
	}
	if !strings.Contains(joined, "aaa") || !strings.Contains(joined, "bbb") {
		t.Errorf("expected the first two series (aaa, bbb) in the legend:\n%s", joined)
	}

	// The dropped series peaks at 9; the two kept series peak at 3. If the cap ran
	// AFTER scaling, the top tick would read 9. A capped 3-series render must be
	// byte-identical to the equivalent bare 2-series render — the cap fences the
	// scale, the plot, and the legend alike.
	two := stripLines(chartRenderer{}.Render(Block{Type: "chart", Attrs: map[string]any{"series": []any{
		map[string]any{"label": "aaa", "points": []any{1.0, 2.0, 3.0}},
		map[string]any{"label": "bbb", "points": []any{2.0, 1.0, 2.0}},
	}}}, ctx))
	if got, want := strings.Join(three, "\n"), strings.Join(two, "\n"); got != want {
		t.Errorf("capped 3-series render differs from the equivalent 2-series render — the cap is not clean\n--- 3-series (capped) ---\n%s\n--- 2-series ---\n%s", got, want)
	}
}
