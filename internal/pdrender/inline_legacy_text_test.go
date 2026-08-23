package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestTextLeafLegacyKeyRenders pins the dual-read of a text leaf's payload:
// raw mutate writers persisted whole papers whose text leaves were keyed
// {"type":"text","text":…} instead of the canonical "value". The Hollow
// predicate counts BOTH spellings as content, so those papers passed every
// write seam — and then rendered as headings with ZERO visible characters
// (2026-08-23, two published papers). The renderers must agree with the
// predicate: value || legacy text, canonical value winning. Twin of the
// compose_inline dual-read in api/.../render/inline.ex.
func TestTextLeafLegacyKeyRenders(t *testing.T) {
	reg := testRegistry()

	render := func(leaf map[string]any) string {
		b := Block{Type: "paragraph", Attrs: map[string]any{"content": []any{leaf}}}
		return ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	}

	if got := render(map[string]any{"type": "text", "text": "legacy prose"}); !strings.Contains(got, "legacy prose") {
		t.Fatalf("legacy `text`-keyed leaf dropped its prose, got %q", got)
	}

	got := render(map[string]any{"type": "text", "value": "canonical", "text": "stale"})
	if !strings.Contains(got, "canonical") || strings.Contains(got, "stale") {
		t.Fatalf("canonical value must win over legacy text, got %q", got)
	}

	// Marks still wrap the fallback-read prose.
	marked := render(map[string]any{
		"type": "text", "text": "bold legacy",
		"marks": []any{map[string]any{"type": "strong"}},
	})
	if !strings.Contains(marked, "bold legacy") {
		t.Fatalf("marked legacy leaf dropped its prose, got %q", marked)
	}
}
