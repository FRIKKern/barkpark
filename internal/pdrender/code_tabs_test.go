package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestCodeTabsRenderer proves each tab's label + snippet render THROUGH the
// registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestCodeTabsRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "code-tabs", Attrs: map[string]any{
		"tabs": []any{
			map[string]any{"label": "JS", "language": "js", "value": "console.log(1)"},
			map[string]any{"label": "Go", "language": "go", "value": "fmt.Println(1)"},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"JS", "console.log(1)", "Go", "fmt.Println(1)"} {
		if !strings.Contains(got, want) {
			t.Fatalf("code-tabs render missing %q, got %q", want, got)
		}
	}
}

// TestCodeTabsRendererBlankLabelPlaceholder pins the honest blank-label
// degrade: an unlabeled tab still renders under the dashboardTabs "·"
// placeholder, never collapsing to an unlabeled panel.
func TestCodeTabsRendererBlankLabelPlaceholder(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "code-tabs", Attrs: map[string]any{
		"tabs": []any{map[string]any{"language": "js", "value": "1"}},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "·") {
		t.Fatalf("code-tabs blank label should degrade to \"·\", got %q", got)
	}
}

// TestCodeTabsRendererEmptyIsSilent pins the honest empty state: a
// code-tabs block with no tabs contributes zero lines.
func TestCodeTabsRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "code-tabs", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty code-tabs should render nothing, got %d lines", len(lines))
	}
}
