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

// TestCardMediaImageFastPath checks the model-B image fast-path: a typed
// `type:"image"` media child renders imageRenderer's box, a typeless `{src,alt}`
// media element is coerced to an image (so it fast-paths instead of degrading),
// and the coercion is scoped to the MEDIA slot only (a typeless `{src,alt}` in a
// non-media slot is NOT coerced).
func TestCardMediaImageFastPath(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	// Typed image in the media slot → 🖼 box.
	typed := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"media": map[string]any{"type": "image", "src": "u.png", "alt": "typed alt"},
	}}}
	gotTyped := ansi.Strip(strings.Join(reg.Render(typed, ctx), "\n"))
	if !strings.Contains(gotTyped, "🖼") || !strings.Contains(gotTyped, "typed alt") {
		t.Fatalf("typed image media should fast-path to the image box, got:\n%s", gotTyped)
	}

	// Typeless {src,alt} in the media slot → coerced to an image box.
	bare := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"media": map[string]any{"src": "u.png", "alt": "bare alt"},
	}}}
	gotBare := ansi.Strip(strings.Join(reg.Render(bare, ctx), "\n"))
	if !strings.Contains(gotBare, "🖼") || !strings.Contains(gotBare, "bare alt") {
		t.Fatalf("typeless {src,alt} media should be coerced to the image box, got:\n%s", gotBare)
	}

	// Scope: a typeless {src,alt} in a NON-media slot is NOT coerced (no 🖼 box).
	nonMedia := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"body": map[string]any{"src": "u.png", "alt": "body alt"},
	}}}
	gotNon := ansi.Strip(strings.Join(reg.Render(nonMedia, ctx), "\n"))
	if strings.Contains(gotNon, "🖼") {
		t.Errorf("typeless {src,alt} outside the media slot must NOT be coerced, got:\n%s", gotNon)
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

func TestStageUsesSlotTextBeforeScalarShadows(t *testing.T) {
	attrs := map[string]any{"title": "stale shadow", "source": "queue.ex:42", "slots": map[string]any{
		"title": []any{map[string]any{"type": "paragraph", "content": []any{
			map[string]any{"type": "strong", "children": []any{map[string]any{"type": "text", "value": "Authored title"}}},
		}}},
	}}
	got := ansi.Strip(strings.Join(testRegistry().Render(Block{Type: "stage", Attrs: attrs}, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "Authored title") || strings.Contains(got, "stale shadow") || !strings.Contains(got, "queue.ex:42") {
		t.Fatalf("Stage must use authoritative slots without changing provenance:\n%s", got)
	}
	for _, slot := range []any{[]any{}, []any{map[string]any{"type": "paragraph", "content": []any{}}}} {
		attrs["slots"].(map[string]any)["title"] = slot
		if got := stageFieldText(attrs, "title"); got != "" {
			t.Fatalf("empty materialized slot must suppress scalar shadow, got %q", got)
		}
	}
}

// TestCardRendersNormally checks the model-B box: a rounded border, the slots
// in media→title→body→action order, all four slots' recursed content present,
// and NO per-slot label chrome (the `media`/`action` caption lines model B
// dropped, #1529).
func TestCardRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "card", Attrs: map[string]any{"slots": map[string]any{
		"title":  map[string]any{"type": "heading", "level": 2, "text": "The Title"},
		"body":   map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "the body prose"}}},
		"media":  map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "media prose"}}},
		"action": map[string]any{"type": "action", "label": "Go", "href": "https://x.example", "priority": "primary"},
	}}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"╭", "╰", "The Title", "the body prose", "media prose", "Go"} {
		if !strings.Contains(got, want) {
			t.Fatalf("card missing %q, got:\n%s", want, got)
		}
	}
	// Model-B slot order: media renders before the title.
	if strings.Index(got, "media prose") > strings.Index(got, "The Title") {
		t.Errorf("card should render media before title (model-B order), got:\n%s", got)
	}
	// No per-slot label chrome: the muted `media`/`action` caption lines are gone.
	// (The media/action *content* still shows; the standalone label lines do not.)
	for _, line := range strings.Split(got, "\n") {
		trimmed := strings.TrimSpace(strings.Trim(line, "│ "))
		if trimmed == "media" || trimmed == "action" {
			t.Errorf("card must drop the %q label caption (model B), got:\n%s", trimmed, got)
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
