package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestTocRenderer proves the toc block renders its items THROUGH the registry
// — one assertion covering both the renderer and its DefaultRegistry
// registration, plus depth capping (a level-3 item is excluded at depth=2).
func TestTocRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "toc", Attrs: map[string]any{
		"items": []any{
			map[string]any{"text": "Getting started", "level": 2, "anchor": "getting-started"},
			map[string]any{"text": "Deep dive", "level": 3, "anchor": "deep-dive"},
		},
		"depth": 1,
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "Getting started") {
		t.Fatalf("toc render missing top-level item, got %q", got)
	}
	if strings.Contains(got, "Deep dive") {
		t.Fatalf("toc render should have capped depth at 1, got %q", got)
	}
}

// TestTocRendererNumbered proves the hierarchical counter prefix.
func TestTocRendererNumbered(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "toc", Attrs: map[string]any{
		"numbered": true,
		"items": []any{
			map[string]any{"text": "One", "level": 2},
			map[string]any{"text": "One-A", "level": 3},
			map[string]any{"text": "Two", "level": 2},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"1 One", "1.1 One-A", "2 Two"} {
		if !strings.Contains(got, want) {
			t.Fatalf("toc numbered render missing %q, got %q", want, got)
		}
	}
}

// TestTocRendererEmptyIsSilent pins the honest empty state: a
// toc block with no items contributes zero lines.
func TestTocRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "toc", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty toc should render nothing, got %d lines", len(lines))
	}
}
