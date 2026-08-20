package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestEquationRenderer proves the equation block renders its tex THROUGH
// the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestEquationRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "equation", Attrs: map[string]any{"tex": "E = mc^2"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "E = mc²") {
		t.Fatalf("equation render missing unicode superscript, got %q", got)
	}
}

// TestEquationRendererGreekAndOperators pins the macro table + frac rewrite.
func TestEquationRendererGreekAndOperators(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "equation", Attrs: map[string]any{"tex": `\alpha \cdot \frac{1}{2} \leq \pi`}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "α · 1/2 ≤ π") {
		t.Fatalf("equation render missing macro substitutions, got %q", got)
	}
}

// TestEquationRendererUnknownMacroFallsBack pins the honest raw-TeX fallback
// for a macro outside the bounded table.
func TestEquationRendererUnknownMacroFallsBack(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "equation", Attrs: map[string]any{"tex": `\unknownmacro{x}`}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, `\unknownmacro{x}`) {
		t.Fatalf("equation render should fall back to raw tex for unknown macros, got %q", got)
	}
}

// TestEquationRendererSubscript pins subscript unicode digits.
func TestEquationRendererSubscript(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "equation", Attrs: map[string]any{"tex": "x_1 + x_2"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "x₁ + x₂") {
		t.Fatalf("equation render missing unicode subscript, got %q", got)
	}
}

// TestEquationRendererEmptyIsSilent pins the honest empty state: an
// equation block with no tex contributes zero lines.
func TestEquationRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "equation", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty equation should render nothing, got %d lines", len(lines))
	}
}
