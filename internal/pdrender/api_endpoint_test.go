package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestApiEndpointRenderer proves the api-endpoint block renders its method
// badge + path THROUGH the registry — one assertion covering both the
// renderer and its DefaultRegistry registration.
func TestApiEndpointRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "api-endpoint", Attrs: map[string]any{"method": "post", "path": "/v1/data/mutate"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "POST") || !strings.Contains(got, "/v1/data/mutate") {
		t.Fatalf("api-endpoint render missing method/path, got %q", got)
	}
}

// TestApiEndpointRendererParamsTable proves a non-empty `params` list grows a
// bordered table beneath the method/path line, with the required column
// coerced through the same yesNo (bool-or-string) rule the field-* blocks use.
func TestApiEndpointRendererParamsTable(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "api-endpoint", Attrs: map[string]any{
		"method": "GET", "path": "/v1/data/query/:dataset/:type",
		"params": []any{
			map[string]any{"name": "dataset", "in": "path", "type": "string", "required": true},
			map[string]any{"name": "limit", "in": "query", "type": "integer", "required": false},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"NAME", "dataset", "path", "Yes", "limit", "query", "No"} {
		if !strings.Contains(got, want) {
			t.Fatalf("api-endpoint params table missing %q, got %q", want, got)
		}
	}
}

// TestApiEndpointRendererEmptyIsSilent pins the honest empty state: a
// api-endpoint block with no method and no path contributes zero lines.
func TestApiEndpointRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "api-endpoint", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty api-endpoint should render nothing, got %d lines", len(lines))
	}
}
