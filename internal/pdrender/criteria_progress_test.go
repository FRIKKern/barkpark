package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestCriteriaProgressRenderer proves the criteria-progress block renders its
// rows THROUGH the registry — one assertion covering both the renderer and
// its DefaultRegistry registration.
func TestCriteriaProgressRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "criteria-progress", Attrs: map[string]any{
		"rows": []any{
			map[string]any{"label": "survey", "met": 2, "total": 5},
			map[string]any{"label": "file tasks", "met": 5, "total": 5},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "survey") || !strings.Contains(got, "file tasks") {
		t.Fatalf("criteria-progress render missing labels, got %q", got)
	}
	if !strings.Contains(got, "2/5") || !strings.Contains(got, "5/5") {
		t.Fatalf("criteria-progress render missing met/total digits, got %q", got)
	}
}

// TestCriteriaProgressRendererDetailTotal pins the `detail: "total"`
// aggregation: all rows collapse into one "Total" bar, summed.
func TestCriteriaProgressRendererDetailTotal(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "criteria-progress", Attrs: map[string]any{
		"rows": []any{
			map[string]any{"label": "a", "met": 2, "total": 5},
			map[string]any{"label": "b", "met": 5, "total": 5},
		},
		"detail": "total",
	}}
	got := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor})
	if len(got) != 1 {
		t.Fatalf("expected 1 aggregated line, got %d", len(got))
	}
	plain := ansi.Strip(got[0])
	if !strings.Contains(plain, "Total") || !strings.Contains(plain, "7/10") {
		t.Fatalf("criteria-progress total aggregation wrong, got %q", plain)
	}
}

// TestCriteriaProgressRendererEmptyIsSilent pins the honest empty state: a
// criteria-progress block with no rows contributes zero lines.
func TestCriteriaProgressRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "criteria-progress", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty criteria-progress should render nothing, got %d lines", len(lines))
	}
}
