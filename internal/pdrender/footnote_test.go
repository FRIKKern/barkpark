package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestFootnoteRenderer proves the footnote block renders its numbered notes
// THROUGH the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestFootnoteRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "footnote", Attrs: map[string]any{
		"notes": []any{
			map[string]any{"id": "fn1", "text": "First note body."},
			map[string]any{"id": "fn2", "text": "Second note body."},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"1. First note body.", "2. Second note body."} {
		if !strings.Contains(got, want) {
			t.Fatalf("footnote render missing %q, got %q", want, got)
		}
	}
}

// TestFootnoteRendererEmptyIsSilent pins the honest empty state: a
// footnote block with no notes contributes zero lines.
func TestFootnoteRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "footnote", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty footnote should render nothing, got %d lines", len(lines))
	}
}
