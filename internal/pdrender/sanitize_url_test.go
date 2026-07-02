package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestSanitizeURL checks control bytes (C0 + DEL) are dropped while all valid
// printable/UTF-8 runes pass through unchanged.
func TestSanitizeURL(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"clean untouched", "https://example.com/a?b=1#c", "https://example.com/a?b=1#c"},
		{"esc stripped", "https://x\x1bevil.com", "https://xevil.com"},
		{"st stripped", "https://x\x1b\\evil.com", "https://x\\evil.com"},
		{"bel stripped", "https://x\x07evil.com", "https://xevil.com"},
		{"newline stripped", "https://x\nevil.com", "https://xevil.com"},
		{"del stripped", "https://x\x7fevil.com", "https://xevil.com"},
		{"csi stripped", "https://x\x1b[31mevil.com", "https://x[31mevil.com"},
		{"tab stripped", "a\tb", "ab"},
		{"unicode kept", "https://exämple.com/☕", "https://exämple.com/☕"},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sanitizeURL(c.in); got != c.want {
				t.Errorf("sanitizeURL(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// TestSanitizeURLScheme checks the scheme allowlist ported from the Elixir twin
// (portable_doc/render/util.ex safe_url): dangerous schemes a terminal would
// hand to the OS open handler are dropped, while http/https/mailto/tel and
// schemeless relative URLs survive byte-for-byte.
func TestSanitizeURLScheme(t *testing.T) {
	dropped := []struct {
		name string
		in   string
	}{
		{"javascript", "javascript:alert(1)"},
		{"file", "file:///etc/passwd"},
		{"data", "data:text/html,<script>"},
		{"tab-javascript bypass", "\tjavascript:alert(1)"},
		{"protocol-relative", "//evil.com"},
		{"protocol-relative backslash", "/\\evil.com"},
		{"custom scheme", "vscode://x"},
	}
	for _, c := range dropped {
		t.Run("drop/"+c.name, func(t *testing.T) {
			if got := sanitizeURL(c.in); got != "" {
				t.Errorf("sanitizeURL(%q) = %q, want \"\" (dropped)", c.in, got)
			}
		})
	}

	kept := []struct {
		name string
		in   string
		want string
	}{
		{"https", "https://x", "https://x"},
		{"http", "http://x", "http://x"},
		{"mailto", "mailto:a@b", "mailto:a@b"},
		{"tel", "tel:+1", "tel:+1"},
		{"relative path", "/papers/x", "/papers/x"},
		{"anchor", "#anchor", "#anchor"},
		{"uppercase scheme", "HTTPS://x", "HTTPS://x"},
	}
	for _, c := range kept {
		t.Run("keep/"+c.name, func(t *testing.T) {
			if got := sanitizeURL(c.in); got != c.want {
				t.Errorf("sanitizeURL(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// osc8Injection is a document-controlled URL carrying the three control bytes an
// attacker uses to break out of an OSC 8 sequence: \x1b (ESC, starts an escape /
// with \\ forms the ST terminator), \x07 (BEL, the alt OSC terminator), and \n.
const osc8Injection = "https://x\x1b\x07\nevil.com"
const osc8Clean = "https://xevil.com"

// assertNoInjection asserts the rendered OSC 8 output carries only the two
// framing ST sequences the renderer itself emits — no URL-injected \x1b\\ and no
// \x07 byte leaking into the terminal.
func assertNoInjection(t *testing.T, out string) {
	t.Helper()
	if strings.Contains(out, "\x07") {
		t.Errorf("BEL byte leaked from URL into output: %q", out)
	}
	// The renderer emits exactly two ST bytes: the opener's terminator and the
	// closer's terminator. A URL-injected ST would push the count higher.
	if n := strings.Count(out, "\x1b\\"); n != 2 {
		t.Errorf("expected 2 framing ST sequences, got %d: %q", n, out)
	}
	if !strings.Contains(out, "\x1b]8;;"+osc8Clean+"\x1b\\") {
		t.Errorf("expected sanitized href in OSC 8 opener, got %q", out)
	}
}

// TestLinkSanitizesHref checks an inline link href with terminal control bytes
// is cleaned before it is spliced into the OSC 8 hyperlink.
func TestLinkSanitizesHref(t *testing.T) {
	reg := testRegistry()
	nodes := []any{
		map[string]any{
			"type":     "link",
			"href":     osc8Injection,
			"children": []any{map[string]any{"type": "text", "value": "go"}},
		},
	}
	out := reg.Inline(nodes, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: ANSI256})
	assertNoInjection(t, out)
}

// TestAsciicastSanitizesSrc checks the asciicast placeholder src is cleaned
// before it is spliced into the OSC 8 hyperlink.
func TestAsciicastSanitizesSrc(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "asciicast", Attrs: map[string]any{
		"type": "asciicast", "src": osc8Injection,
	}}
	out := strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: ANSI256}), "\n")
	assertNoInjection(t, out)
}

// TestActionSanitizesHref checks the action CTA href is cleaned before it is
// spliced into the OSC 8 hyperlink (same OSC 8 emitter family as link/asciicast).
func TestActionSanitizesHref(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "action", Attrs: map[string]any{
		"type": "action", "label": "Go", "href": osc8Injection, "priority": "primary",
	}}
	out := strings.Join(reg.Render(block, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: ANSI256}), "\n")
	assertNoInjection(t, out)
}

// TestImageSanitizesAlt checks the image placeholder's document-controlled alt
// text is cleaned before it is spliced into the styled placeholder line — an
// alt of "a\x1b[2Jb" (ESC clears the reader's terminal) must not leak any ESC
// byte, while the surrounding visible text survives. The color profile is pinned
// to Ascii so lipgloss emits no styling escapes of its own; the only possible
// \x1b in the output would be the injected one.
func TestImageSanitizesAlt(t *testing.T) {
	reg := testRegistry()       // note: testRegistry sets the profile to TrueColor, so pin it after
	lipgloss.SetColorProfile(3) // termenv.Ascii — no SGR styling escapes
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	block := Block{Type: "image", Attrs: map[string]any{
		"type": "image", "alt": "a\x1b[2Jb",
	}}
	out := strings.Join(reg.Render(block, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n")
	if strings.ContainsRune(out, 0x1b) {
		t.Errorf("ESC byte leaked from alt into output: %q", out)
	}
	if !strings.Contains(out, "a") || !strings.Contains(out, "b") {
		t.Errorf("expected sanitized alt text (a…b) in output, got %q", out)
	}
}
