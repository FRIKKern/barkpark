package pdrender

// styleguide_golden_test.go — unified-aesthetic W1.4 scaffold.
//
// A living golden render of the pdrender status tones + reading tokens the
// renderer paints FROM the emitted design tokens (tokens_gen.go: GenToneInfo/
// OK/Warn/Danger + GenReadingFontStack/HeadingWeight/BodySize). Nothing is
// hand-copied — re-emitting design/tokens.json moves the golden. Render peer of
// the SPA/Studio/web/paper style guides; interactive `bp style` is W4.11.
//
// Reuses render_test.go's -update flag.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
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

// TestPdrenderTokensGolden renders the status tones the Theme actually paints
// plus the reading tokens. The tone colors are pulled back OUT of a live
// Theme.Callout — not read straight from GenTone* — so this golden guards the
// wiring itself: if theme.go ever reverts to hand literals, the bar foreground
// diverges from the emitted token and this render moves.
func TestPdrenderTokensGolden(t *testing.T) {
	var b strings.Builder
	b.WriteString("pdrender status tones (emitted from design/tokens.json)\n")
	b.WriteString("tone     light      dark\n")
	b.WriteString("------   -------    -------\n")
	th := DarkTheme() // AdaptiveColor carries both L/D regardless of preset name
	tones := []struct {
		name   string
		callTo string // Theme.Callout tone key
	}{
		{"info", "info"},
		{"ok", "success"},
		{"warn", "warning"},
		{"danger", "danger"},
	}
	for _, tone := range tones {
		bar, _ := th.Callout(tone.callTo)
		c, ok := bar.GetForeground().(lipgloss.AdaptiveColor)
		if !ok {
			t.Fatalf("callout %q bar foreground is %T, want lipgloss.AdaptiveColor", tone.callTo, bar.GetForeground())
		}
		b.WriteString(fmt.Sprintf("%-8s %-10s %s\n", tone.name, c.Light, c.Dark))
	}
	b.WriteString("\nreading tokens\n")
	b.WriteString(fmt.Sprintf("font stack:     %s\n", GenReadingFontStack))
	b.WriteString(fmt.Sprintf("heading weight: %d\n", GenReadingHeadingWeight))
	b.WriteString(fmt.Sprintf("body size:      %dpx\n", GenReadingBodySize))

	styleguideGolden(t, "styleguide_tokens.txt", b.String())
}
