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

// TestRenderStripsControlBytesFields covers the sibling leak paths sealed in the
// cycle-25 follow-up sweep: the v2 nested field blocks (composite / localizedText
// / codelist) render both their VALUE and their field LABEL, and the field-* leaf
// blocks render their LABEL — all of which splice document-supplied text into a
// lipgloss Render (which styles but does NOT strip escapes). Every case carries a
// raw \x1b repaint + \x07 BEL and must render with both bytes removed. The color
// profile is pinned to Ascii so lipgloss emits no SGR of its own.
func TestRenderStripsControlBytesFields(t *testing.T) {
	reg := testRegistry()
	lipgloss.SetColorProfile(3) // termenv.Ascii — no SGR styling escapes
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	blocks := []Block{
		// composite: an escape-laden field label AND a nested scalar value.
		{Type: "composite", Attrs: map[string]any{
			"type":  "composite",
			"label": "Comp\x1b[2Jlabel\x07",
			"fields": []any{
				map[string]any{"name": "title", "title": "Ti\x1b[31mtle\x07"},
			},
			"value": map[string]any{"title": "val\x1b[2Jue\x07"},
		}},
		// localizedText: language rows carrying escapes in the value.
		{Type: "localizedText", Attrs: map[string]any{
			"type":      "localizedText",
			"label":     "Loc\x1blabel",
			"languages": []any{"en"},
			"value":     map[string]any{"en": "hel\x1b[2Jlo\x07"},
		}},
		// field-string leaf: an escape-laden label (value already covered above).
		{Type: "field-string", Attrs: map[string]any{
			"type":  "field-string",
			"label": "Fld\x1b[2Jlabel\x07",
			"value": "plain",
		}},
		// field-color non-hex fallback: the raw hex string is rendered as-is.
		{Type: "field-color", Attrs: map[string]any{
			"type":  "field-color",
			"label": "Col\x07label",
			"value": "notahex\x1b[2J\x07",
		}},
		// codelist: label + display (no resolver → raw code path).
		{Type: "codelist", Attrs: map[string]any{
			"type":  "codelist",
			"label": "Code\x1b[2Jlist\x07",
			"value": "AB\x1b[31mC\x07",
		}},
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

// TestRenderStripsControlBytesBlockChrome covers the block-chrome leak paths
// sealed in this sweep: the callout/section titles, figure/diagram captions, the
// action CTA label, the eyebrow kicker, the diagram source + detected kind, and
// every form field string (prompt / rationale / recommendation / option label) —
// all document-controlled strings spliced into a lipgloss Render (which styles
// but does NOT strip escapes). Each case carries a raw \x1b[31m…\x1b[0m repaint +
// \x07 BEL in the attacker-controlled attr and must render with those bytes gone.
// The color profile is pinned to Ascii so lipgloss emits no SGR of its own; any
// \x1b/\x07 in the output can only have leaked from the input string.
func TestRenderStripsControlBytesBlockChrome(t *testing.T) {
	reg := testRegistry()
	lipgloss.SetColorProfile(3) // termenv.Ascii — no SGR styling escapes
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	const evil = "\x1b[31mX\x1b[0m evil \x07"

	blocks := []struct {
		name  string
		block Block
	}{
		{"callout title", Block{Type: "callout", Attrs: map[string]any{
			"type": "callout", "tone": "info", "title": evil,
			"content": []any{map[string]any{"type": "text", "value": "body"}},
		}}},
		{"section title", Block{Type: "section", Attrs: map[string]any{
			"type": "section", "title": evil,
		}, Children: []Block{}}},
		{"figure caption", Block{Type: "figure", Attrs: map[string]any{
			"type": "figure", "caption": evil,
		}}},
		{"action label", Block{Type: "action", Attrs: map[string]any{
			"type": "action", "label": evil,
		}}},
		{"eyebrow text", Block{Type: "eyebrow", Attrs: map[string]any{
			"type": "eyebrow", "text": evil,
		}}},
		{"diagram caption+source", Block{Type: "diagram", Attrs: map[string]any{
			"type": "diagram", "source": "flow" + evil + "chart TD\nA-->B", "caption": evil,
		}}},
		{"byline items", Block{Type: "byline", Attrs: map[string]any{
			"type": "byline", "items": []any{"By " + evil, "2026"},
		}}},
		{"byline text", Block{Type: "byline", Attrs: map[string]any{
			"type": "byline", "text": "By " + evil,
		}}},
		{"form question strings", Block{Type: "form", Attrs: map[string]any{
			"type": "form", "questions": []any{map[string]any{
				"prompt":         "Prompt " + evil,
				"rationale":      "Why " + evil,
				"recommendation": "Do " + evil,
				"type":           "single",
				"options":        []any{"Opt " + evil, "Other"},
			}},
		}}},
	}
	for _, c := range blocks {
		t.Run(c.name, func(t *testing.T) {
			out := strings.Join(reg.Render(c.block, ctx), "\n")
			if strings.ContainsRune(out, 0x1b) {
				t.Errorf("%s: ESC byte leaked into output: %q", c.name, out)
			}
			if strings.ContainsRune(out, 0x07) {
				t.Errorf("%s: BEL byte leaked into output: %q", c.name, out)
			}
		})
	}
}

// TestRenderStripsControlBytesColoredCode covers the colored-code path: on a
// non-NoColor profile the source is fed to chroma and truncated with SGR intact.
// A source line containing \x1b[2J must NOT reach the terminal — sanitizeCodeText
// strips it before lexing (and in both chroma error fallbacks). We assert only
// that the injected repaint sequence is gone; chroma's own SGR escapes are
// expected and legitimate, so we scan for the specific injected control sequence
// rather than any 0x1b byte.
func TestRenderStripsControlBytesColoredCode(t *testing.T) {
	reg := testRegistry()
	// Colored profile: lipgloss/chroma emit real SGR. We do NOT reset the process
	// color profile to Ascii here because we WANT chroma to run its colored path.
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: ANSI256}

	block := Block{Type: "code", Attrs: map[string]any{
		"type":     "code",
		"language": "bash",
		"code":     "echo hi\x1b[2Jrm -rf /\x07",
	}}
	out := strings.Join(reg.Render(block, ctx), "\n")
	// The injected repaint (ESC [ 2 J) and BEL must be gone even though other
	// (chroma) SGR escapes remain.
	if strings.Contains(out, "\x1b[2J") {
		t.Errorf("colored code: injected repaint sequence leaked: %q", out)
	}
	if strings.ContainsRune(out, 0x07) {
		t.Errorf("colored code: BEL byte leaked into output: %q", out)
	}
}
