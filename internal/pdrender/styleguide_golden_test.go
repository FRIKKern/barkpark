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

// TestPdrenderTokensGolden renders the emitted status tones + reading tokens.
func TestPdrenderTokensGolden(t *testing.T) {
	var b strings.Builder
	b.WriteString("pdrender status tones (emitted from design/tokens.json)\n")
	b.WriteString("tone     light      dark\n")
	b.WriteString("------   -------    -------\n")
	tones := []struct {
		name string
		c    lipgloss.AdaptiveColor
	}{
		{"info", GenToneInfo},
		{"ok", GenToneOK},
		{"warn", GenToneWarn},
		{"danger", GenToneDanger},
	}
	for _, tone := range tones {
		b.WriteString(fmt.Sprintf("%-8s %-10s %s\n", tone.name, tone.c.Light, tone.c.Dark))
	}
	b.WriteString("\nreading tokens\n")
	b.WriteString(fmt.Sprintf("font stack:     %s\n", GenReadingFontStack))
	b.WriteString(fmt.Sprintf("heading weight: %d\n", GenReadingHeadingWeight))
	b.WriteString(fmt.Sprintf("body size:      %dpx\n", GenReadingBodySize))

	styleguideGolden(t, "styleguide_tokens.txt", b.String())
}
