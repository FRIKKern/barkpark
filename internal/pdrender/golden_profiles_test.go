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

// This file is the executable half of docs/contracts/tui-render-doctrine.md: the
// detail-ceiling "strip law" as a shared, reusable assertion. Color is
// REINFORCEMENT — the datum lives in geometry — so stripping every ANSI escape
// from the ANSI256 and TrueColor renders must leave EXACTLY the NoColor render.
// Every data-viz block (heatmap, chart, stat, and every block added after) is
// held to it at the golden widths.

// lipglossProfileFor maps a pdrender Profile onto the termenv Profile that the
// process-global lipgloss renderer expects. THE TWO ENUMS RUN OPPOSITE WAYS:
// pdrender ascends (NoColor=0 … TrueColor=3, pdrender.go), termenv is INVERTED
// (TrueColor=0, ANSI256=1, ANSI=2, Ascii=3 — verified against muesli/termenv
// v0.16.0 profile.go). Getting this backwards silently renders truecolor blocks
// as plain text (or leaks escapes a floor terminal can't draw) — the exact class
// of bug this helper exists to catch.
func lipglossProfileFor(p Profile) termenv.Profile {
	switch p {
	case TrueColor:
		return termenv.TrueColor
	case ANSI256:
		return termenv.ANSI256
	case ANSI16:
		return termenv.ANSI
	default: // NoColor
		return termenv.Ascii
	}
}

// profileName is a readable label for assertion failures.
func profileName(p Profile) string {
	switch p {
	case ANSI16:
		return "ANSI16"
	case ANSI256:
		return "ANSI256"
	case TrueColor:
		return "TrueColor"
	default:
		return "NoColor"
	}
}

// assertStripComplete renders the SAME input at NoColor, ANSI256, and TrueColor
// and asserts the strip law: the color-stripped ANSI256 and TrueColor renders are
// byte-identical to the NoColor render, at every golden width.
//
// TWO-KNOB PLUMBING (the load-bearing gotcha): a profile-aware render has two
// independent knobs that MUST agree — pdrender's ctx.Profile (the render closure
// sets this from p) AND the process-global lipgloss color profile (this helper
// owns it). assertStripComplete sets the lipgloss global to match p before each
// render and SAVES/RESTORES it around the whole run, because it is process-wide
// and would otherwise leak into later tests. The render closure must build its
// ctx with ctx.Profile == p.
func assertStripComplete(t *testing.T, name string, render func(width int, p Profile) string) {
	t.Helper()
	saved := lipgloss.ColorProfile()
	defer lipgloss.SetColorProfile(saved)

	profiles := []Profile{NoColor, ANSI256, TrueColor}
	for _, w := range goldenWidths {
		w := w
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			var base string
			for i, p := range profiles {
				lipgloss.SetColorProfile(lipglossProfileFor(p))
				stripped := ansi.Strip(render(w, p))
				// Shared blind-spot guard (unknown_block_guard_test.go): assert it at
				// EVERY profile, not just the NoColor golden.
				assertNoUnknownBlock(t, name+" "+profileName(p), stripped)
				if i == 0 {
					base = stripped
					if strings.TrimSpace(base) == "" {
						t.Fatalf("%s w%d: NoColor render is empty — nothing to prove", name, w)
					}
					continue
				}
				if stripped != base {
					t.Errorf("%s w%d: ansi.Strip(%s) != NoColor render — color is not reinforcement-only (detail-ceiling doctrine).\n--- strip(%s) ---\n%s\n--- NoColor ---\n%s",
						name, w, profileName(p), profileName(p), stripped, base)
				}
			}
		})
	}
}

// TestStripCompleteProfiles proves the helper on the three existing data-viz
// families, establishing the baseline the slate-2 blocks will be held to.
func TestStripCompleteProfiles(t *testing.T) {
	// (1) heatmap — the sample_m11 SHADE grid AND the TRUECOLOR grid. Both dual-encode
	// by construction: the `·░▒▓█` shade-ladder glyph carries intensity at EVERY
	// profile, and the truecolor path (heatCell) now layers the ramp colour on top of
	// the SAME glyph as reinforcement — so stripping the colour leaves the identical
	// ladder and both grids are complete artifacts (charter-D13: dual-encode the legacy
	// truecolor grid rather than converge it onto the quantile modes).
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m11.json"))
	if err != nil {
		t.Fatalf("read sample_m11: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode sample_m11: %v", err)
	}
	var shade, trueGrid *Block
	for i := range blocks {
		if blocks[i].Type != "heatmap" {
			continue
		}
		switch attrStr(blocks[i].Attrs, "ramp") {
		case "shade":
			if shade == nil {
				shade = &blocks[i]
			}
		case "truecolor":
			if trueGrid == nil {
				trueGrid = &blocks[i]
			}
		}
	}
	if shade == nil {
		t.Fatal("sample_m11: no shade heatmap block found (fixture changed?)")
	}
	if trueGrid == nil {
		t.Fatal("sample_m11: no truecolor heatmap block found (fixture changed?)")
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "heatmap_shade_sample_m11", func(w int, p Profile) string {
		return reg.RenderDoc([]Block{*shade}, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})
	assertStripComplete(t, "heatmap_truecolor_sample_m11", func(w int, p Profile) string {
		return reg.RenderDoc([]Block{*trueGrid}, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})

	// (2) stat grid — a big-number cell + a bullet-bar cell with a sparkline. The
	// value, the ▓/░ proportion bar, and the eighth-block spark are all geometry;
	// color only tones them.
	statsGrid := Block{Type: "stats", Attrs: map[string]any{"items": []any{
		map[string]any{"value": "1.24M", "label": "Tokens"},
		map[string]any{"value": "73", "max": 100.0, "label": "Cache hit", "spark": []any{1.0, 3.0, 2.0, 8.0}},
	}}}
	assertStripComplete(t, "stats_grid", func(w int, p Profile) string {
		return strings.Join(statsRenderer{}.Render(statsGrid, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p}), "\n")
	})

	// (3) chart — a two-series braille step-line. The braille curve IS the datum
	// and renders at every profile; per-series color is the TrueColor-only
	// reinforcement (chartUseTrueColor), so the strip law holds.
	chartB := Block{Type: "chart", Attrs: map[string]any{
		"series": []any{
			map[string]any{"label": "req", "points": []any{1.0, 3.0, 2.0, 8.0, 5.0, 9.0}},
			map[string]any{"label": "err", "points": []any{0.0, 1.0, 0.5, 2.0, 1.0, 3.0}},
		},
		"axes": map[string]any{"xLabels": []any{"Mon", "Sun"}},
	}}
	assertStripComplete(t, "chart_two_series", func(w int, p Profile) string {
		return strings.Join(chartRenderer{}.Render(chartB, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p}), "\n")
	})
}
