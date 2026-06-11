package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestPdSheet3x3 renders a 3x3 sheet with a head row and col_widths and
// asserts structural + content invariants without a golden file (new block,
// output shape is not yet frozen).
func TestPdSheet3x3(t *testing.T) {
	reg := testRegistry()

	block := Block{
		Type: "PdSheet",
		Attrs: map[string]any{
			"kind": "PdSheet",
			// Three-column header.
			"head": []any{"Name", "Score", "Tag"},
			// Three rows × three columns.
			"rows": []any{
				[]any{"Alice", "42", "alpha"},
				[]any{"Bob", "7", "beta"},
				[]any{"Carol", "100", "gamma"},
			},
			// Explicit column widths: 10, 7, 8 chars.
			"col_widths": []any{float64(10), float64(7), float64(8)},
		},
	}

	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	lines := reg.Render(block, ctx)
	out := ansi.Strip(strings.Join(lines, "\n"))

	// Head row must be present and uppercased.
	if !strings.Contains(out, "NAME") {
		t.Errorf("expected uppercase head cell 'NAME', got:\n%s", out)
	}
	if !strings.Contains(out, "SCORE") {
		t.Errorf("expected uppercase head cell 'SCORE', got:\n%s", out)
	}
	if !strings.Contains(out, "TAG") {
		t.Errorf("expected uppercase head cell 'TAG', got:\n%s", out)
	}

	// All data cells must appear.
	for _, want := range []string{"Alice", "Bob", "Carol", "42", "7", "100", "alpha", "beta", "gamma"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected cell %q in output, got:\n%s", want, out)
		}
	}

	// At least 5 lines: top border + header + header/body separator + 3 data rows + bottom border.
	if len(lines) < 5 {
		t.Errorf("expected at least 5 lines, got %d:\n%s", len(lines), out)
	}

	// Border chars present (NormalBorder uses │ and ─).
	if !strings.Contains(out, "│") {
		t.Errorf("expected vertical border char '│', got:\n%s", out)
	}
	if !strings.Contains(out, "─") {
		t.Errorf("expected horizontal border char '─', got:\n%s", out)
	}
}

// TestPdSheetNoHead renders a sheet without a head row; asserts no uppercase
// spurious header and that data cells still render.
func TestPdSheetNoHead(t *testing.T) {
	reg := testRegistry()
	block := Block{
		Type: "PdSheet",
		Attrs: map[string]any{
			"kind": "PdSheet",
			"rows": []any{
				[]any{"x", "y"},
				[]any{"1", "2"},
			},
		},
	}
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(strings.Join(reg.Render(block, ctx), "\n"))

	for _, want := range []string{"x", "y", "1", "2"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected cell %q in output, got:\n%s", want, out)
		}
	}
}

// TestPdSheetNeverPanic asserts the sheet renderer degrades gracefully for
// empty and degenerate inputs.
func TestPdSheetNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		{Type: "PdSheet", Attrs: map[string]any{"kind": "PdSheet"}},
		{Type: "PdSheet", Attrs: map[string]any{"kind": "PdSheet", "head": []any{}, "rows": []any{}}},
		{Type: "PdSheet", Attrs: map[string]any{"kind": "PdSheet", "rows": []any{[]any{}}}},
	}
	for _, b := range cases {
		b := b
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("PdSheet panicked on degenerate input: %v", r)
				}
			}()
			_ = reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
		}()
	}
}

// TestPdSheetRenderSample logs the rendered output for human review; the
// content is asserted by TestPdSheet3x3 — this is purely an inspection hook.
func TestPdSheetRenderSample(t *testing.T) {
	reg := testRegistry()
	block := Block{
		Type: "PdSheet",
		Attrs: map[string]any{
			"kind": "PdSheet",
			"head": []any{"Name", "Score", "Tag"},
			"rows": []any{
				[]any{"Alice", "42", "alpha"},
				[]any{"Bob", "7", "beta"},
				[]any{"Carol", "100", "gamma"},
			},
			"col_widths": []any{float64(10), float64(7), float64(8)},
		},
	}
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(strings.Join(reg.Render(block, ctx), "\n"))
	t.Logf("PdSheet sample render:\n%s", out)
}

// TestPdSheetColWidthsPadTruncate unit-tests padOrTruncate in isolation.
func TestPdSheetColWidthsPadTruncate(t *testing.T) {
	cases := []struct {
		s    string
		w    int
		want string
	}{
		{"hi", 5, "hi   "},
		{"hello world", 5, "hell…"},
		{"exact", 5, "exact"},
		{"x", 1, "x"},
		{"ab", 1, "…"},
		{"", 4, "    "},
	}
	for _, c := range cases {
		got := padOrTruncate(c.s, c.w)
		if got != c.want {
			t.Errorf("padOrTruncate(%q, %d) = %q, want %q", c.s, c.w, got, c.want)
		}
	}
}
