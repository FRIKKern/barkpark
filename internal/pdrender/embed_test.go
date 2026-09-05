package pdrender

import (
	"strings"
	"testing"
)

// An embed block must render its target (mirroring the Elixir PdEmbed walker),
// NOT fall through to the generic "unknown block" fallback — that divergence
// meant an embed showed in the web reader but "Unsupported block" in the TUI.
func TestPdEmbedRendersTargetNotUnknownBlock(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	out := strings.Join(
		reg.Render(Block{Type: "embed", Attrs: map[string]any{"target": "https://example.com/v"}}, ctx),
		"\n",
	)
	if !strings.Contains(out, "https://example.com/v") {
		t.Fatalf("embed should render its target; got %q", out)
	}
	if !strings.Contains(out, "↪") {
		t.Fatalf("embed should use the ↪ placeholder glyph; got %q", out)
	}
	assertNoUnknownBlock(t, "embed with target", out)
}

func TestPdEmbedEmptyTargetDegrades(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	out := strings.Join(reg.Render(Block{Type: "embed"}, ctx), "\n")
	if !strings.Contains(out, "↪") {
		t.Fatalf("empty-target embed should show a ↪ placeholder; got %q", out)
	}
	assertNoUnknownBlock(t, "embed with empty target", out)
}

// A non-URL target (a human reference, not a slug) renders as a plain muted line
// with no OSC-8 hyperlink — matching the Elixir unresolved-embed behavior.
func TestPdEmbedNonURLTargetNoHyperlink(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	out := strings.Join(
		reg.Render(Block{Type: "embed", Attrs: map[string]any{"target": "A Human Reference"}}, ctx),
		"\n",
	)
	if !strings.Contains(out, "A Human Reference") {
		t.Fatalf("embed should render the reference text; got %q", out)
	}
	if strings.Contains(out, "\x1b]8;;") {
		t.Fatalf("a non-URL target must not become an OSC-8 hyperlink; got %q", out)
	}
}
