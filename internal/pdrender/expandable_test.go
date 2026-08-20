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

// TestExpandableDecodeChildrenRendersNestedSteps locks the persisted wire
// shape used by expandable blocks. Renderer-only tests that construct
// Block.Children by hand cannot catch a decoder that silently drops the
// canonical `children` key before dispatch reaches the steps renderer.
func TestExpandableDecodeChildrenRendersNestedSteps(t *testing.T) {
	blocks, err := Decode([]byte(`{
		"version": 1,
		"blocks": [{
			"id": "appendix",
			"type": "expandable",
			"summary": "Next wave",
			"children": [{
				"id": "actions",
				"type": "steps",
				"steps": [{
					"title": "File the four rows first",
					"blocks": [{
						"type": "paragraph",
						"content": [{"type": "text", "value": "They gate the merge."}]
					}]
				}]
			}]
		}]
	}`))
	if err != nil {
		t.Fatalf("Decode returned error: %v", err)
	}
	if len(blocks) != 1 || len(blocks[0].Children) != 1 {
		t.Fatalf("expandable children were not decoded: %#v", blocks)
	}

	reg := testRegistry()
	got := ansi.Strip(strings.Join(reg.Render(blocks[0], RenderCtx{
		Width: 60, Theme: DarkTheme(), Profile: NoColor,
	}), "\n"))
	for _, want := range []string{
		"Next wave",
		"1. File the four rows first",
		"They gate the merge.",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("decoded expandable render missing %q, got %q", want, got)
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
