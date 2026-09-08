package pdrender

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestNestedListCarriers(t *testing.T) {
	raw, err := os.ReadFile("../../api/test/support/fixtures/nested-list-carriers.json")
	if err != nil {
		t.Fatal(err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	before, _ := json.Marshal(blocks)
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	text := ansi.Strip(DefaultRegistry(ctx.Theme).RenderDoc(blocks, ctx))
	for _, line := range []string{"• Plan", "  1. Build", "     • Verify", "  2. Ship", "• Flat sibling", "• Fallback parent", "  1. Alias child"} {
		if !strings.Contains(text, line) {
			t.Errorf("missing nested line %q in:\n%s", line, text)
		}
	}
	if strings.Contains(text, "Inactive parent fallback") {
		t.Fatal("inactive fallback rendered")
	}
	after, _ := json.Marshal(blocks)
	if string(before) != string(after) {
		t.Fatal("render mutated source")
	}
	assertStripComplete(t, "nested-lists", func(width int, profile Profile) string {
		return DefaultRegistry(ctx.Theme).RenderDoc(blocks, RenderCtx{Width: width, Theme: ctx.Theme, Profile: profile})
	})
}

func TestNestedListInvalidChildrenStayOpaque(t *testing.T) {
	ctx := RenderCtx{Width: 20, Theme: DarkTheme(), Profile: NoColor}
	for _, children := range []any{nil, "invalid", map[string]any{}, []any{map[string]any{"type": "paragraph", "text": "opaque"}}, []any{map[string]any{"type": "list", "items": "invalid"}}} {
		item := map[string]any{"text": "Flat", "audit": true, "children": children}
		b := Block{Type: "list", Attrs: map[string]any{"items": []any{item}}}
		before, _ := json.Marshal(b)
		got := ansi.Strip(DefaultRegistry(ctx.Theme).RenderDoc([]Block{b}, ctx))
		flat := Block{Type: "list", Attrs: map[string]any{"items": []any{"Flat"}}}
		want := ansi.Strip(DefaultRegistry(ctx.Theme).RenderDoc([]Block{flat}, ctx))
		if got != want {
			t.Errorf("invalid children changed flat output: %q != %q", got, want)
		}
		after, _ := json.Marshal(b)
		if string(before) != string(after) {
			t.Fatal("invalid metadata mutated")
		}
	}
}

func TestNestedListNarrowWrapping(t *testing.T) {
	raw := []byte(`{"blocks":[{"type":"list","items":[{"text":"Parent", "children":[{"type":"list","ordered":true,"items":[{"text":"A longer child line with 世界 and more words", "children":[{"type":"list","items":["Deep child also wraps across several lines"]}]}]}]}]}]}`)
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	for _, width := range []int{12, 20, 40} {
		ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
		text := DefaultRegistry(ctx.Theme).RenderDoc(blocks, ctx)
		for _, line := range strings.Split(text, "\n") {
			if ansi.StringWidth(line) > width {
				t.Errorf("width %d overflow: %q", width, line)
			}
		}
		if !strings.Contains(ansi.Strip(text), "世界") {
			t.Fatal("lost Unicode child text")
		}
	}
}
