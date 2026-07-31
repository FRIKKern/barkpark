package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestEmptyParagraphEmitsNoTerminalRows(t *testing.T) {
	reg := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	empty := Block{
		Type:  "paragraph",
		Attrs: map[string]any{"type": "paragraph", "content": []any{}},
	}

	if got := reg.Render(empty, ctx); len(got) != 0 {
		t.Fatalf("empty paragraph should emit zero rows, got %#v", got)
	}
}

func TestEmptyParagraphDoesNotMultiplyDocumentRhythm(t *testing.T) {
	reg := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	paragraph := func(text string) Block {
		return Block{
			Type: "paragraph",
			Attrs: map[string]any{
				"type": "paragraph",
				"content": []any{
					map[string]any{"type": "text", "value": text},
				},
			},
		}
	}

	blocks := []Block{
		paragraph("first"),
		{Type: "paragraph", Attrs: map[string]any{"type": "paragraph", "content": []any{}}},
		paragraph("second"),
	}

	got := ansi.Strip(reg.RenderDoc(blocks, ctx))
	want := ansi.Strip(reg.RenderDoc([]Block{paragraph("first"), paragraph("second")}, ctx))
	if got != want {
		t.Fatalf("empty paragraph changed reader rhythm:\ngot  %q\nwant %q", got, want)
	}
	if strings.Contains(got, "\n\n\n") {
		t.Fatalf("reader contains a spacer run: %q", got)
	}
}
