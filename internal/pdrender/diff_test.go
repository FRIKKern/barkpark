package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestDiffRenderer proves the diff block renders its text
// THROUGH the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestDiffRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{"text": "hello from diff"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "hello from diff") {
		t.Fatalf("diff render missing text, got %q", got)
	}
}

// TestDiffRendererEmptyIsSilent pins the honest empty state: a
// diff block with no text contributes zero lines.
func TestDiffRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty diff should render nothing, got %d lines", len(lines))
	}
}
