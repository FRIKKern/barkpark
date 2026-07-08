package taskboard

// styleguide_golden_test.go — unified-aesthetic W1.4 scaffold.
//
// A living golden render of the lifecycle vocabulary the TUI paints FROM the
// emitted design tokens (tokens_gen.go: GenLifecycle / GenLifecycleOrder /
// GenBrailleFrames). It hand-copies nothing — every glyph and hue is read from
// the generated map, so re-emitting design/tokens.json moves the golden. This
// is the TUI's drift-visibility surface (the render peer of the SPA/Studio/web
// style guides); the interactive `bp style` screen is W4.11's job.
//
// Reuses render_test.go's -update flag.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func styleguideGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *update {
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
		t.Errorf("styleguide render diverged from %s\n--- got ---\n%s\n--- want ---\n%s", path, got, want)
	}
}

// TestLifecyclePaletteGolden renders the lifecycle vocabulary table straight
// from the emitted GenLifecycle map, in canonical GenLifecycleOrder.
func TestLifecyclePaletteGolden(t *testing.T) {
	var b strings.Builder
	b.WriteString("Barkpark lifecycle vocabulary (emitted from design/tokens.json)\n")
	b.WriteString("state         glyph  ascii  role   light      dark\n")
	b.WriteString("-----------   -----  -----  -----  -------    -------\n")
	for _, key := range GenLifecycleOrder {
		tok := GenLifecycle[key]
		role := tok.Role
		if role == "" {
			role = "-"
		}
		b.WriteString(fmt.Sprintf("%-13s %-6s %-6s %-6s %-10s %s\n",
			key, tok.Glyph, tok.ASCIIGlyph, role, tok.ColorLight, tok.ColorDark))
	}
	b.WriteString("\nspinner frames: " + strings.Join(GenBrailleFrames[:], " ") + "\n")
	b.WriteString("reduced-motion still: " + GenBrailleStill + "\n")

	styleguideGolden(t, "styleguide_lifecycle.txt", b.String())
}
