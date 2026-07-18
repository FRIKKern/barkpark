package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestExpandableRenderer proves the expandable block renders its summary +
// nested child blocks THROUGH the registry — one assertion covering the
// renderer, its DefaultRegistry registration, and recursive child dispatch.
func TestExpandableRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{
		Type:  "expandable",
		Attrs: map[string]any{"summary": "Show the full trace", "open": false},
		Children: []Block{
			{Type: "paragraph", Attrs: map[string]any{
				"content": []any{map[string]any{"type": "text", "value": "Hidden detail."}},
			}},
		},
	}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	// TUI always shows expanded, regardless of `open: false` (no fold affordance).
	for _, want := range []string{"Show the full trace", "Hidden detail."} {
		if !strings.Contains(got, want) {
			t.Fatalf("expandable render missing %q, got %q", want, got)
		}
	}
}

// TestExpandableRendererEmptyIsSilent pins the honest empty state: an
// expandable block with no summary and no children contributes zero lines.
func TestExpandableRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "expandable", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty expandable should render nothing, got %d lines", len(lines))
	}
}
