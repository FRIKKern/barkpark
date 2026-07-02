package pdrender

import (
	"strings"
	"testing"
)

// TestPdTableNeverPanic asserts the table renderer degrades gracefully on empty
// and degenerate inputs. A `table` block whose rows decode to empty arrays (no
// head) yields a zero-column table; lipgloss/table's auto-sizer indexes
// colWidths[0] on that and panics (index out of range), which previously took
// down the entire RenderDoc — a document-controlled block crashing the whole
// TUI/CLI viewer. The guard in tableRenderer.Render skips zero-column rows and
// returns empty output when there are no columns at all.
func TestPdTableNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		{Type: "table", Attrs: map[string]any{}},
		{Type: "table", Attrs: map[string]any{"head": []any{}, "rows": []any{}}},
		{Type: "table", Attrs: map[string]any{"rows": []any{[]any{}}}},
		{Type: "table", Attrs: map[string]any{"rows": []any{[]any{}, []any{}}}},
	}
	for _, b := range cases {
		b := b
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("table panicked on degenerate input %v: %v", b.Attrs, r)
				}
			}()
			_ = reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
		}()
	}
}

// TestPdTableRendersNormally is a sanity check that the empty-row guard does not
// disturb a well-formed table: a head plus one empty row still renders the head.
func TestPdTableRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{
		Type: "table",
		Attrs: map[string]any{
			"head": []any{"Name", "Score"},
			"rows": []any{
				[]any{"Alice", "42"},
				[]any{}, // stray empty row — skipped, must not panic or blank the table
				[]any{"Bob", "7"},
			},
		},
	}

	out := reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
	joined := ""
	for _, line := range out {
		joined += line + "\n"
	}

	for _, want := range []string{"NAME", "SCORE", "Alice", "Bob"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("expected rendered table to contain %q, got:\n%s", want, joined)
		}
	}
}
