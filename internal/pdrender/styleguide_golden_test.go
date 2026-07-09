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

// adaptiveOf pulls the {light,dark} channels out of a resolved TerminalColor,
// failing the test if it is not an AdaptiveColor. It is the load-bearing assert
// of this golden: colors are read back OUT of the live styles the Theme builds,
// so a thread onto the WRONG token (or a revert to a hand literal) moves the
// rendered channels here — the only guard on pdrender's chrome/code/rule/terra/
// label wiring, since every full-document golden is Ascii-stripped.
func adaptiveOf(t *testing.T, label string, c lipgloss.TerminalColor) lipgloss.AdaptiveColor {
	t.Helper()
	ac, ok := c.(lipgloss.AdaptiveColor)
	if !ok {
		t.Fatalf("%s color is %T, want lipgloss.AdaptiveColor", label, c)
	}
	return ac
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
		{"neutral", "neutral"},
	}
	for _, tone := range tones {
		bar, _ := th.Callout(tone.callTo)
		c := adaptiveOf(t, "callout "+tone.callTo+" bar", bar.GetForeground())
		b.WriteString(fmt.Sprintf("%-8s %-10s %s\n", tone.name, c.Light, c.Dark))
	}

	// Chrome / code / rule / terra / label — the ts-w2b threaded roles, read back
	// out of the live styles the Theme builds. Each row proves the pd* var landed
	// on the intended emitted token (chrome ink/dim are the zinc cliChrome set,
	// NOT the warmer reading family — the decoy guard is checkable here).
	b.WriteString("\npdrender chrome/reading roles (threaded onto tokens_gen.go)\n")
	b.WriteString("role         light      dark\n")
	b.WriteString("----------   -------    -------\n")
	rows := []struct {
		name string
		c    lipgloss.TerminalColor
	}{
		{"accent", th.Accent},                      // pal.ChromeAccent
		{"ink", th.Heading[0].GetForeground()},     // pal.ChromeInk
		{"body", th.Body.GetForeground()},          // pal.ChromeTextSecondary
		{"dim", th.Dim.GetForeground()},            // pal.ChromeDim
		{"rule", th.Rule.GetForeground()},          // pal.Rule
		{"code-fg", th.InlineCode.GetForeground()}, // pal.CodeFg
		{"code-bg", th.InlineCode.GetBackground()}, // pal.CodeBg
		{"terra", th.PullquoteBar.GetForeground()}, // pal.ReadingAccent
		{"label", th.FieldLabel.GetForeground()},   // pal.ReadingMuted
	}
	for _, r := range rows {
		c := adaptiveOf(t, "role "+r.name, r.c)
		b.WriteString(fmt.Sprintf("%-12s %-10s %s\n", r.name, c.Light, c.Dark))
	}

	b.WriteString("\nreading tokens\n")
	b.WriteString(fmt.Sprintf("font stack:     %s\n", GenReadingFontStack))
	b.WriteString(fmt.Sprintf("heading weight: %d\n", GenReadingHeadingWeight))
	b.WriteString(fmt.Sprintf("body size:      %dpx\n", GenReadingBodySize))

	styleguideGolden(t, "styleguide_tokens.txt", b.String())
}
