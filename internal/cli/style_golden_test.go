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
	"testing"

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
