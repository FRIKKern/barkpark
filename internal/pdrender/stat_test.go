package pdrender

import (
	"strings"
	"testing"
)

// TestSparklineMapping is the load-bearing proof of the eighth-block primitive:
// a strictly ascending series maps ONE glyph per value across the full ladder
// ▁▂▃▄▅▆▇█ (min→▁, max→█), normalised to the series' own min..max.
func TestSparklineMapping(t *testing.T) {
	// Eight ascending values → the exact eighth-block ladder, in order.
	got := sparkline([]float64{1, 2, 3, 4, 5, 6, 7, 8}, 0)
	if want := "▁▂▃▄▅▆▇█"; got != want {
		t.Fatalf("ascending series: got %q, want %q", got, want)
	}

	// Endpoints: the series minimum lands on ▁, the maximum on █, regardless of
	// the absolute scale (here 100..800, big non-unit values).
	got = sparkline([]float64{100, 800}, 0)
	if first, last := []rune(got)[0], []rune(got)[1]; string(first) != "▁" || string(last) != "█" {
		t.Errorf("scaled endpoints: got %q, want first ▁ and last █", got)
	}
}

// TestSparklineGuards pins the divide-by-zero / empty guards: an empty series
// draws nothing; a flat (constant) series draws a baseline row of the lowest
// glyph rather than dividing by a zero span.
func TestSparklineGuards(t *testing.T) {
	if got := sparkline(nil, 10); got != "" {
		t.Errorf("empty series: got %q, want \"\"", got)
	}
	if got := sparkline([]float64{}, 10); got != "" {
		t.Errorf("empty slice: got %q, want \"\"", got)
	}
	// Flat series → baseline (lowest glyph) row, one per value, no panic/NaN.
	if got := sparkline([]float64{5, 5, 5, 5}, 10); got != "▁▁▁▁" {
		t.Errorf("flat series: got %q, want ▁▁▁▁ (baseline)", got)
	}
	// A single point is degenerate (span 0) → baseline glyph, not a divide-by-zero.
	if got := sparkline([]float64{42}, 10); got != "▁" {
		t.Errorf("single point: got %q, want ▁", got)
	}
}

// TestSparklineWidthBound pins the width cap: with width < len(values), the
// glyph count is bounded to width (the caller passes the cell width).
func TestSparklineWidthBound(t *testing.T) {
	got := sparkline([]float64{1, 2, 3, 4, 5, 6, 7, 8}, 3)
	if n := len([]rune(got)); n != 3 {
		t.Fatalf("width bound: got %d glyphs (%q), want 3", n, got)
	}
}

// TestStatModeBranch covers the max-presence mode branch of the single stat cell:
// big-number (no max) renders the value prominently with no bar glyphs; bullet-bar
// (max present) draws the ▓/░ proportion bar; a missing value degrades to the dim
// placeholder.
func TestStatModeBranch(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}

	// Big-number: no max → the value, no bar glyphs.
	big := statCell(map[string]any{"value": "1.24M", "label": "Tokens"}, ctx)
	joined := strings.Join(big, "\n")
	if !strings.Contains(joined, "1.24M") {
		t.Errorf("big-number: value %q missing from %q", "1.24M", joined)
	}
	if strings.ContainsAny(joined, "▓░") {
		t.Errorf("big-number: unexpected bullet-bar glyphs in %q", joined)
	}

	// Bullet-bar: max present → the ▓/░ proportion bar appears.
	bar := statCell(map[string]any{"value": "73", "max": 100.0, "label": "Cache hit"}, ctx)
	joinedBar := strings.Join(bar, "\n")
	if !strings.ContainsAny(joinedBar, "▓░") {
		t.Errorf("bullet-bar: expected a ▓/░ bar in %q", joinedBar)
	}
	if !strings.Contains(joinedBar, "73") {
		t.Errorf("bullet-bar: value 73 missing from %q", joinedBar)
	}

	// Degrade: no value key → the dim placeholder.
	deg := statCell(map[string]any{"label": "orphan"}, ctx)
	if len(deg) != 1 || !strings.Contains(deg[0], "stat") || !strings.Contains(deg[0], "unresolved") {
		t.Errorf("degrade: expected a [stat — unresolved] placeholder, got %q", deg)
	}
}

// TestStatSparkIntegration proves the sparkline row is emitted beneath a stat
// that carries a `spark` series.
func TestStatSparkIntegration(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	lines := statCell(map[string]any{"value": "up", "spark": []any{1.0, 2.0, 3.0, 8.0}}, ctx)
	joined := strings.Join(lines, "\n")
	if !strings.ContainsAny(joined, string(sparkLadder[:])) {
		t.Errorf("spark integration: expected an eighth-block glyph in %q", joined)
	}
}

// TestStatsGridNUp proves the plural KPI grid lays cells side-by-side at a wide
// width (two cells share a line) and stacks them at a narrow width.
func TestStatsGridNUp(t *testing.T) {
	grid := Block{
		Type: "stats",
		Attrs: map[string]any{
			"items": []any{
				map[string]any{"value": "1.24M", "label": "Tokens"},
				map[string]any{"value": "8,391", "label": "Requests"},
			},
		},
	}

	// Wide: 2-up → both values on the SAME line.
	wide := statsRenderer{}.Render(grid, RenderCtx{Width: 120, Theme: DarkTheme(), Profile: NoColor})
	sideBySide := false
	for _, ln := range wide {
		if strings.Contains(ln, "1.24M") && strings.Contains(ln, "8,391") {
			sideBySide = true
		}
	}
	if !sideBySide {
		t.Errorf("wide grid: expected both cells on one line, got %q", wide)
	}

	// Narrow: below the Flex MinWidth floor → stack (never on one line).
	narrow := statsRenderer{}.Render(grid, RenderCtx{Width: 24, Theme: DarkTheme(), Profile: NoColor})
	for _, ln := range narrow {
		if strings.Contains(ln, "1.24M") && strings.Contains(ln, "8,391") {
			t.Errorf("narrow grid: cells should stack, but shared a line: %q", ln)
		}
	}
}
