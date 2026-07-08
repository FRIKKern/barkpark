package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestLayoutBlocksNeverPanic asserts the columns and terminal renderers degrade
// gracefully on empty and degenerate inputs. Portable-doc content is API-served
// and attacker-controllable, so a malformed layout block must never take down the
// whole RenderDoc — it degrades to blank / bare chrome instead of panicking.
func TestLayoutBlocksNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		// columns: missing key, wrong-typed key, empty list, empty inner columns.
		{Type: "columns", Attrs: map[string]any{}},
		{Type: "columns", Attrs: map[string]any{"columns": "not-a-list"}},
		{Type: "columns", Attrs: map[string]any{"columns": []any{}}},
		{Type: "columns", Attrs: map[string]any{"columns": []any{[]any{}, []any{}}}},
		{Type: "columns", Attrs: map[string]any{"columns": []any{nil, 42, "x"}}},
		// terminal: no attrs, non-list children, both children/blocks keys.
		{Type: "terminal", Attrs: map[string]any{}},
		{Type: "terminal", Attrs: map[string]any{"children": "not-a-list"}},
		{Type: "terminal", Attrs: map[string]any{"blocks": []any{}, "title": "t"}},
		{Type: "terminal", Attrs: map[string]any{"live": true, "footer": "done"}},
	}
	// Exercise a range of widths, including a sub-MinWidth width that forces the
	// terminal's flat-degrade branch and a wide one that keeps the box.
	for _, w := range []int{10, 40, 120} {
		for _, b := range cases {
			b := b
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("layout block panicked (w=%d) on %v: %v", w, b.Attrs, r)
					}
				}()
				_ = reg.Render(b, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor})
			}()
		}
	}
}

// TestColumnsRendersNormally checks a well-formed two-column block stacks both
// columns with a hairline rule between them, and that a single column carries no
// separator rule.
func TestColumnsRendersNormally(t *testing.T) {
	reg := testRegistry()
	mkCol := func(text string) []any {
		return []any{map[string]any{
			"type":    "paragraph",
			"content": []any{map[string]any{"type": "text", "value": text}},
		}}
	}

	two := Block{Type: "columns", Attrs: map[string]any{
		"columns": []any{mkCol("alpha"), mkCol("bravo")},
	}}
	joined := ansi.Strip(strings.Join(reg.Render(two, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"alpha", "bravo"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("expected two-column output to contain %q, got:\n%s", want, joined)
		}
	}
	if !strings.Contains(joined, "─") {
		t.Fatalf("expected a hairline rule between two columns, got:\n%s", joined)
	}

	one := Block{Type: "columns", Attrs: map[string]any{
		"columns": []any{mkCol("solo")},
	}}
	joinedOne := ansi.Strip(strings.Join(reg.Render(one, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(joinedOne, "solo") {
		t.Fatalf("expected single-column output to contain %q, got:\n%s", "solo", joinedOne)
	}
	if strings.Contains(joinedOne, "─") {
		t.Errorf("single column must not draw a separator rule, got:\n%s", joinedOne)
	}
}

// TestTerminalRendersNormally checks the terminal frame draws its traffic-light
// bar, an accent `live` chip when live is truthy, wraps a child block, and shows
// a dim footer; and that a narrow width flat-degrades (no rounded border).
func TestTerminalRendersNormally(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "terminal", Attrs: map[string]any{
		"title":  "shell",
		"live":   "live",
		"footer": "bye",
		"children": []any{map[string]any{
			"type":    "paragraph",
			"content": []any{map[string]any{"type": "text", "value": "hello world"}},
		}},
	}}

	boxed := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"● ● ●", "shell", "live", "hello world", "bye", "╭", "╰"} {
		if !strings.Contains(boxed, want) {
			t.Fatalf("expected terminal output to contain %q, got:\n%s", want, boxed)
		}
	}

	// Sub-MinWidth width forces the flat degrade: content survives, box does not.
	flat := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 10, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(flat, "● ● ●") || !strings.Contains(flat, "hello") {
		t.Fatalf("expected flat-degraded terminal to keep its content, got:\n%s", flat)
	}
	if strings.Contains(flat, "╭") || strings.Contains(flat, "╰") {
		t.Errorf("narrow terminal must flat-degrade (no rounded border), got:\n%s", flat)
	}
}

// TestTerminalLiveTruthiness pins the live-chip truthiness to the reader's rule
// (true / "true" / "live" only) — a falsey value draws no chip.
func TestTerminalLiveTruthiness(t *testing.T) {
	reg := testRegistry()
	render := func(live any) string {
		b := Block{Type: "terminal", Attrs: map[string]any{"title": "t", "live": live}}
		return ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	}
	for _, truthy := range []any{true, "true", "live"} {
		if !strings.Contains(render(truthy), "live") {
			t.Errorf("expected a live chip for %#v", truthy)
		}
	}
	for _, falsey := range []any{false, "false", "yes", 1, nil} {
		out := render(falsey)
		// The chip is the padded " live " token; a bare title must not carry it.
		if strings.Contains(out, " live ") {
			t.Errorf("expected NO live chip for %#v, got:\n%s", falsey, out)
		}
	}
}
