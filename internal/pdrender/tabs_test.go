package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestTabsRenderer proves each tab's label + child blocks render THROUGH the
// registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestTabsRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "tabs", Attrs: map[string]any{
		"tabs": []any{
			map[string]any{
				"label": "macOS",
				"blocks": []any{
					map[string]any{"type": "paragraph", "content": []any{
						map[string]any{"type": "text", "value": "brew install barkpark"},
					}},
				},
			},
			map[string]any{
				"label": "Linux",
				"blocks": []any{
					map[string]any{"type": "paragraph", "content": []any{
						map[string]any{"type": "text", "value": "curl -fsSL install.sh | sh"},
					}},
				},
			},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"macOS", "brew install barkpark", "Linux", "curl -fsSL install.sh | sh"} {
		if !strings.Contains(got, want) {
			t.Fatalf("tabs render missing %q, got %q", want, got)
		}
	}
}

// TestTabsRendererBlankLabelPlaceholder pins the honest blank-label degrade:
// an unlabeled tab still renders under the dashboardTabs "·" placeholder.
func TestTabsRendererBlankLabelPlaceholder(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "tabs", Attrs: map[string]any{
		"tabs": []any{map[string]any{"blocks": []any{
			map[string]any{"type": "paragraph", "content": []any{
				map[string]any{"type": "text", "value": "body"},
			}},
		}}},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "·") {
		t.Fatalf("tabs blank label should degrade to \"·\", got %q", got)
	}
}

// TestTabsRendererEmptyIsSilent pins the honest empty state: a tabs block
// with no tabs contributes zero lines.
func TestTabsRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "tabs", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty tabs should render nothing, got %d lines", len(lines))
	}
}
