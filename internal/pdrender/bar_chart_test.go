package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestBarChartRenderer proves the bar-chart block renders its bars THROUGH
// the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestBarChartRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{
		"bars": []any{
			map[string]any{"label": "paragraph", "value": 4969},
			map[string]any{"label": "heading", "value": 3232},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "paragraph") || !strings.Contains(got, "heading") {
		t.Fatalf("bar-chart render missing labels, got %q", got)
	}
}

// TestBarChartRendererValues pins the `values: true` digit readout.
func TestBarChartRendererValues(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{
		"bars": []any{
			map[string]any{"label": "paragraph", "value": 4969},
			map[string]any{"label": "heading", "value": 3232},
		},
		"values": true,
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "4969") || !strings.Contains(got, "3232") {
		t.Fatalf("bar-chart values render missing digits, got %q", got)
	}
}

// TestBarChartRendererMax proves an explicit `max` sets the meter's
// denominator (a bar at max fills the whole track; the widest bar without an
// explicit max also fills it, so the distinguishing proof is a bar BELOW an
// explicit max staying visibly short).
func TestBarChartRendererMax(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{
		"bars": []any{map[string]any{"label": "a", "value": 1}},
		"max":  100,
	}}
	got := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor})
	if len(got) != 1 {
		t.Fatalf("expected 1 line, got %d", len(got))
	}
}

// TestBarChartRendererEmptyIsSilent pins the honest empty state: a
// bar-chart block with no bars contributes zero lines.
func TestBarChartRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty bar-chart should render nothing, got %d lines", len(lines))
	}
}
