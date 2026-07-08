package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// heatBlock builds a single ramp:"truecolor" heatmap block with non-zero cells
// (one cell is exactly max=1.0, so both the truecolor and the shade path emit a
// visible peak glyph/colour). Constructed directly rather than via a fixture so
// the profile invariant is asserted on the renderer in isolation.
func heatBlock() Block {
	return Block{
		Type: "heatmap",
		Attrs: map[string]any{
			"ramp": "truecolor",
			"cells": []any{
				[]any{0.2, 0.9},
				[]any{0.5, 1.0},
			},
		},
	}
}

// TestHeatmapAutoDegrade is the load-bearing proof of the cell primitive's
// auto-degrade contract: a raw 24-bit foreground escape (\x1b[38;2) appears IFF
// ramp=="truecolor" AND ctx.Profile==TrueColor. Under a non-truecolor profile the
// same block MUST fall back to the shade ladder and emit no truecolor escape, so a
// NO_COLOR / 256-colour terminal never receives bytes it can't render.
func TestHeatmapAutoDegrade(t *testing.T) {
	const trueColorEsc = "\x1b[38;2" // 24-bit SGR foreground introducer

	// (a) TrueColor profile → the truecolor ramp must emit a 24-bit fg escape.
	t.Run("truecolor_profile_emits_24bit", func(t *testing.T) {
		old := lipgloss.ColorProfile()
		lipgloss.SetColorProfile(termenv.TrueColor)
		t.Cleanup(func() { lipgloss.SetColorProfile(old) })

		ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: TrueColor}
		got := strings.Join(heatmapRenderer{}.Render(heatBlock(), ctx), "\n")

		if !strings.Contains(got, trueColorEsc) {
			t.Fatalf("TrueColor profile: expected a 24-bit fg escape %q in raw output, found none\nraw: %q",
				trueColorEsc, got)
		}
	})

	// (b) NoColor profile → the truecolor ramp AUTO-DEGRADES to the shade ladder:
	// no 24-bit escape at all, and a visible shade glyph in its place.
	t.Run("nocolor_profile_degrades_to_shade", func(t *testing.T) {
		old := lipgloss.ColorProfile()
		lipgloss.SetColorProfile(termenv.Ascii) // strip all colour, mirror a NO_COLOR pipe
		t.Cleanup(func() { lipgloss.SetColorProfile(old) })

		ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
		got := strings.Join(heatmapRenderer{}.Render(heatBlock(), ctx), "\n")

		if strings.Contains(got, trueColorEsc) {
			t.Fatalf("NoColor profile: truecolor escape %q leaked into a non-truecolor terminal\nraw: %q",
				trueColorEsc, got)
		}
		if !strings.ContainsAny(got, "·░▒▓█") {
			t.Fatalf("NoColor profile: expected a shade-ladder glyph (·░▒▓█) in the degraded output, found none\nraw: %q", got)
		}
	})
}

// TestParseHeatCellsEdges pins the tolerant parse contract: a non-numeric cell
// reads as 0 (a gap that keeps the row's column shape), while missing / empty /
// all-non-array cells yield ok=false so the renderer draws the dim placeholder.
func TestParseHeatCellsEdges(t *testing.T) {
	// Non-numeric entry → 0, grid keeps its shape, ok true.
	grid, ok := parseHeatCells(map[string]any{
		"cells": []any{[]any{"x", 5.0}},
	})
	if !ok {
		t.Fatalf("mixed row: expected ok=true, got false")
	}
	if len(grid) != 1 || len(grid[0]) != 2 {
		t.Fatalf("mixed row: expected 1×2 grid, got %v", grid)
	}
	if grid[0][0] != 0 {
		t.Errorf("non-numeric cell: expected 0, got %v", grid[0][0])
	}
	if grid[0][1] != 5 {
		t.Errorf("numeric cell: expected 5, got %v", grid[0][1])
	}

	// Missing cells key → ok=false (placeholder degrade).
	if _, ok := parseHeatCells(map[string]any{}); ok {
		t.Errorf("missing cells: expected ok=false")
	}
	// Empty cells array → ok=false.
	if _, ok := parseHeatCells(map[string]any{"cells": []any{}}); ok {
		t.Errorf("empty cells: expected ok=false")
	}
}
