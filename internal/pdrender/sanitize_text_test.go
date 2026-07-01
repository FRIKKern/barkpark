package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestSanitizeText checks control bytes (C0 + DEL) are dropped from display text
// while all valid printable/UTF-8 runes pass through unchanged.
func TestSanitizeText(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"clean untouched", "Hello, world", "Hello, world"},
		{"esc stripped", "a\x1b[2Jb", "a[2Jb"},
		{"bel stripped", "a\x07b", "ab"},
		{"newline stripped", "a\nb", "ab"},
		{"del stripped", "a\x7fb", "ab"},
		{"unicode kept", "exämple ☕", "exämple ☕"},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sanitizeText(c.in); got != c.want {
				t.Errorf("sanitizeText(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// TestRenderStripsControlBytes checks that a heading title and a paragraph text
// node carrying raw terminal control bytes (\x1b to repaint / \x07 BEL) render
// with those bytes removed — the escape can't reach the reader's terminal. The
// color profile is pinned to Ascii so lipgloss emits no SGR of its own; the only
// possible \x1b/\x07 in the output would be the injected ones.
func TestRenderStripsControlBytes(t *testing.T) {
	reg := testRegistry()
	lipgloss.SetColorProfile(3) // termenv.Ascii — no SGR styling escapes
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}

	blocks := []Block{
		{Type: "heading", Attrs: map[string]any{"type": "heading", "level": 1, "text": "clear\x1b[2Jme\x07"}},
		{Type: "paragraph", Attrs: map[string]any{"type": "paragraph", "content": []any{
			map[string]any{"type": "text", "value": "hi\x1b[31mthere\x07"},
		}}},
	}
	for _, b := range blocks {
		out := strings.Join(reg.Render(b, ctx), "\n")
		if strings.ContainsRune(out, 0x1b) {
			t.Errorf("%s: ESC byte leaked into output: %q", b.Type, out)
		}
		if strings.ContainsRune(out, 0x07) {
			t.Errorf("%s: BEL byte leaked into output: %q", b.Type, out)
		}
	}
}
