package cli

// style_golden_test.go — unified-aesthetic W4.11 golden gate for `bp style`.
//
// Freezes the two rendered surfaces of the design-token style sheet:
//   • styleguide_color.txt   — unicode glyphs + real truecolor SGR (styleColor,
//     pinned TrueColor + dark background for byte-determinism).
//   • styleguide_nocolor.txt — ASCIIGlyph fallback, no SGR (styleNoColor, pinned
//     Ascii profile). This fixture is AC3's proof: it must contain no tofu and no
//     escape bytes.
//
// Both are rendered by the SAME renderStyleSheet off internal/semrole +
// taskboard.GenLifecycle — nothing hand-copied — so re-emitting design/tokens.json
// moves the goldens (AC2 byte-drift gate). Run with -update to regenerate, then
// EYEBALL the fixture before committing.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/semrole"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

func styleGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *updateGolden { // shared -update flag (declared in cloud_cmd_test.go)
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden (run with -update): %v", err)
	}
	if got != string(want) {
		t.Errorf("style sheet render diverged from %s\n--- got ---\n%s\n--- want ---\n%s", path, got, want)
	}
}

// TestStyleSheetColorGolden pins the colour profile so the AdaptiveColor tones
// resolve to deterministic truecolor SGR (TrueColor + dark background), then
// freezes the unicode+colour render.
func TestStyleSheetColorGolden(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	oldDark := lipgloss.HasDarkBackground()
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(oldProfile)
		lipgloss.SetHasDarkBackground(oldDark)
	})

	styleGolden(t, "styleguide_color.txt", renderStyleSheet(styleColor))
}

// TestStyleSheetNoColorGolden pins the Ascii profile (SGR stripped) and renders
// the ASCII-glyph mode — the tofu-free, colour-free surface (AC3).
func TestStyleSheetNoColorGolden(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldProfile) })

	styleGolden(t, "styleguide_nocolor.txt", renderStyleSheet(styleNoColor))
}

// TestThemeSlateGolden is the NEW theme-parameterized golden (the existing
// color/nocolor goldens stay frozen to renderStyleSheet). It pins the per-theme
// slate render — status / lifecycle / chrome roles painted through the
// THEME-KEYED accessors — under TrueColor + dark. With only evergreen
// registered it is a one-theme block; when ts-w5c lands ember + fjord this
// fixture GROWS to three blocks with no code edit here, only a `-update` regen
// (the zero-edit growth property, made a diff you can eyeball).
func TestThemeSlateGolden(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	oldDark := lipgloss.HasDarkBackground()
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(oldProfile)
		lipgloss.SetHasDarkBackground(oldDark)
	})

	styleGolden(t, "styleguide_themes.txt", renderThemeSlate(styleColor))
}

// TestThemeSlateGrowsWithRegisteredThemes proves the zero-edit growth property
// BY CONSTRUCTION rather than by the golden alone: the slate renders exactly one
// block per semrole.Themes() entry, so registering theme N+1 (one keyed genTones
// entry) widens the render with no edit to renderThemeSlate. It counts the block
// headers (each theme id on its own line, preceded by a "chrome:" row from the
// prior block or the slate header) against the enumeration. Ascii mode keeps the
// count independent of SGR bytes.
func TestThemeSlateGrowsWithRegisteredThemes(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldProfile) })

	themes := semrole.Themes()
	if len(themes) == 0 {
		t.Fatal("semrole.Themes() returned no themes — the slate would be empty")
	}

	out := renderThemeSlate(styleNoColor)
	for _, theme := range themes {
		header := "\n" + theme + "\n"
		if !strings.Contains(out, header) {
			t.Errorf("theme slate missing a block header for registered theme %q", theme)
		}
		// each block carries all three role rows painted for THAT theme
		for _, row := range []string{"  status:   ", "  glyphs:   ", "  chrome:   "} {
			if !strings.Contains(out, row) {
				t.Errorf("theme slate missing a %q row", strings.TrimSpace(row))
			}
		}
	}

	// one status/glyphs/chrome triad per theme — the render tracks the
	// enumeration, never a hardcoded list.
	if got := strings.Count(out, "  status:   "); got != len(themes) {
		t.Errorf("theme slate rendered %d status rows, want one per registered theme (%d)", got, len(themes))
	}
}
