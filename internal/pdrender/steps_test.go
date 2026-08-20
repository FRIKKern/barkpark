package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestStepsRenderer proves the steps block renders its titles + nested child
// blocks THROUGH the registry — one assertion covering the renderer, its
// DefaultRegistry registration, and recursive child dispatch.
func TestStepsRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "steps", Attrs: map[string]any{
		"steps": []any{
			map[string]any{
				"title": "Claim the task",
				"blocks": []any{
					map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "Run bp task next."}}},
				},
			},
			map[string]any{"title": "Stamp evidence"},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"1. Claim the task", "Run bp task next.", "2. Stamp evidence"} {
		if !strings.Contains(got, want) {
			t.Fatalf("steps render missing %q, got %q", want, got)
		}
	}
}

// TestStepsRendererEmptyIsSilent pins the honest empty state: a
// steps block with no steps contributes zero lines.
func TestStepsRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "steps", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty steps should render nothing, got %d lines", len(lines))
	}
}
