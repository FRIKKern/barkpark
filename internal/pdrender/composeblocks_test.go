package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestComposeBlocksNeverPanic asserts note/stage/card degrade gracefully on
// empty attrs, empty slots, deeply-typed slot values, and a sub-MinWidth column
// — a document-controlled block must never crash the whole RenderDoc (the same
// contract TestPdTableNeverPanic enforces for the grid).
func TestComposeBlocksNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		// note: empty, partial, control-byte laden.
		{Type: "note", Attrs: map[string]any{}},
		{Type: "note", Attrs: map[string]any{"text": "body only"}},
		{Type: "note", Attrs: map[string]any{"label": "L", "lead": "lead", "text": "\x1b[2Jhijack"}},
		// stage: empty, partial, all fields.
		{Type: "stage", Attrs: map[string]any{}},
		{Type: "stage", Attrs: map[string]any{"kind": "todo", "title": "t"}},
		{Type: "stage", Attrs: map[string]any{"kind": "k", "title": "t", "detail": "d", "files": "f", "source": "s"}},
		// card: no slots, empty slots map, slots as a single map, slots as []any,
		// a slot holding a bare scalar (skipped), and a wrong-typed slots value.
		{Type: "card", Attrs: map[string]any{}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{}}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{
			"title": map[string]any{"type": "heading", "level": 2, "text": "hi"},
		}}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{
			"body": []any{map[string]any{"type": "paragraph", "content": []any{
				map[string]any{"type": "text", "value": "x"}}}},
		}}},
		{Type: "card", Attrs: map[string]any{"slots": map[string]any{"title": "bare scalar"}}},
		{Type: "card", Attrs: map[string]any{"slots": "not-a-map"}},
	}
	// Exercise a normal width AND a sub-MinWidth column (the flat-degrade path).
	for _, width := range []int{40, 10} {
		for _, b := range cases {
			b := b
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("compose block %q panicked on %v at width %d: %v", b.Type, b.Attrs, width, r)
					}
				}()
				out := reg.Render(b, RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor})
				if len(out) == 0 {
					t.Fatalf("compose block %q returned zero lines on %v at width %d", b.Type, b.Attrs, width)
				}
			}()
		}
	}
}

// TestNoteRendersNormally checks the definition row carries its label, bold lead
// and body text, and that control bytes in the body are stripped (not spliced
// into the terminal stream).
func TestNoteRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "note", Attrs: map[string]any{
		"label": "NB", "lead": "Lead in", "text": "the wrapped body of the note.",
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"▌", "NB", "Lead in", "the wrapped body"} {
		if !strings.Contains(got, want) {
			t.Fatalf("note missing %q, got:\n%s", want, got)
		}
	}

	// Below MinWidth the bar is dropped (flat degrade).
	flat := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 10, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if strings.Contains(flat, "▌") {
		t.Errorf("note should drop the bar below MinWidth, got:\n%s", flat)
	}
}

// TestStageRendersNormally checks the stacked cell UPPER-cases the kind kicker,
// keeps the title, and emits labelled files:/source: provenance lines.
func TestStageRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "stage", Attrs: map[string]any{
		"kind": "milestone", "title": "Renderers land", "detail": "shipped",
		"files": "composeblocks.go", "source": "pbp",
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"MILESTONE", "Renderers land", "shipped", "files: composeblocks.go", "source: pbp"} {
		if !strings.Contains(got, want) {
			t.Fatalf("stage missing %q, got:\n%s", want, got)
		}
	}

	// Omitted optionals: no detail/files/source lines when absent.
	partial := ansi.Strip(strings.Join(reg.Render(
		Block{Type: "stage", Attrs: map[string]any{"kind": "todo", "title": "just a title"}},
		RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if strings.Contains(partial, "files:") || strings.Contains(partial, "source:") {
		t.Errorf("stage should omit absent provenance lines, got:\n%s", partial)
	}
}

// TestCardRendersNormally checks the box draws a rounded border and stacks the
// title/body slots plus the labelled media/action slots (recursed content).
func TestCardRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"title": map[string]any{"type": "heading", "level": 2, "text": "The Title"},
		"body":  map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "the body prose"}}},
		"media": map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "media prose"}}},
		"action": map[string]any{"type": "action", "label": "Go", "href": "https://x.example", "priority": "primary"},
	}}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"╭", "╰", "The Title", "the body prose", "media", "action", "Go"} {
		if !strings.Contains(got, want) {
			t.Fatalf("card missing %q, got:\n%s", want, got)
		}
	}

	// Below MinWidth the border is dropped but the slot content survives.
	flat := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 12, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if strings.Contains(flat, "╭") {
		t.Errorf("card should drop the border below MinWidth, got:\n%s", flat)
	}
	if !strings.Contains(flat, "The Title") {
		t.Errorf("card flat-degrade should keep slot content, got:\n%s", flat)
	}
}
