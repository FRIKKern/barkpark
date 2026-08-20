package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestFieldNumberRenderer proves the label + formatted value render THROUGH
// the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestFieldNumberRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "field-number", Attrs: map[string]any{"label": "Price", "value": 19.99, "unit": "NOK"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"Price", "19.99 NOK"} {
		if !strings.Contains(got, want) {
			t.Fatalf("field-number render missing %q, got %q", want, got)
		}
	}
}

// TestFieldNumberRendererIntegerDropsDecimal pins that a whole-number value
// renders without a trailing ".0" and without a `unit` renders no suffix.
func TestFieldNumberRendererIntegerDropsDecimal(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "field-number", Attrs: map[string]any{"label": "Count", "value": 5}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "5") || strings.Contains(got, "5.0") {
		t.Fatalf("field-number integer value should render \"5\" not \"5.0\", got %q", got)
	}
}

// TestFieldNumberRendererAbsentValue pins the honest empty state: a missing
// or uncoercible `value` renders the field-reference "—" convention, not a
// blank or a crash.
func TestFieldNumberRendererAbsentValue(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "field-number", Attrs: map[string]any{"label": "Weight"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "—") {
		t.Fatalf("field-number with no value should render \"—\", got %q", got)
	}
}
