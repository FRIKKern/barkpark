package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestFiletreeRenderer proves the filetree block renders its text
// THROUGH the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestFiletreeRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "filetree", Attrs: map[string]any{"text": "hello from filetree"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "hello from filetree") {
		t.Fatalf("filetree render missing text, got %q", got)
	}
}

// TestFiletreeRendererEmptyIsSilent pins the honest empty state: a
// filetree block with no text contributes zero lines.
func TestFiletreeRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "filetree", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty filetree should render nothing, got %d lines", len(lines))
	}
}
