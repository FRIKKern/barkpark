package pdrender

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestProseCarrierPrecedence(t *testing.T) {
	inline := func(text string) []any { return []any{map[string]any{"type": "text", "value": text}} }
	for _, tc := range []struct {
		name, kind string
		fields     map[string]any
		want       string
	}{
		{"heading primary", "heading", map[string]any{"content": inline("Primary"), "text": "Stale fallback"}, "Primary"},
		{"heading blank primary", "heading", map[string]any{"content": inline(""), "text": "Stale fallback"}, ""},
		{"heading empty content", "heading", map[string]any{"content": []any{}, "text": "Fallback"}, "Fallback"},
		{"heading number", "heading", map[string]any{"text": 42}, "42"},
		{"heading boolean", "heading", map[string]any{"text": false}, "false"},
		{"heading map", "heading", map[string]any{"text": map[string]any{"secret": "not prose"}}, ""},
		{"heading list", "heading", map[string]any{"text": []any{"not prose"}}, ""},
		{"paragraph text", "paragraph", map[string]any{"text": "Legacy paragraph"}, "Legacy paragraph"},
		{"paragraph empty content", "paragraph", map[string]any{"content": []any{}, "text": "Legacy paragraph"}, "Legacy paragraph"},
		{"paragraph primary", "paragraph", map[string]any{"content": inline("Primary"), "text": "Stale fallback"}, "Primary"},
		{"paragraph blank primary", "paragraph", map[string]any{"content": inline(""), "text": "Stale fallback"}, ""},
		{"paragraph invalid content", "paragraph", map[string]any{"content": "ignored", "text": "Fallback"}, "Fallback"},
		{"paragraph number", "paragraph", map[string]any{"text": 42}, ""},
		{"paragraph boolean", "paragraph", map[string]any{"text": false}, ""},
		{"paragraph map", "paragraph", map[string]any{"text": map[string]any{"value": "not prose"}}, ""},
		{"paragraph literal JSON", "paragraph", map[string]any{"text": "[{\"type\":\"text\",\"value\":\"literal\"}]"}, "[{\"type\":\"text\",\"value\":\"literal\"}]"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.fields["level"] = 2
			tc.fields["audit"] = map[string]any{"keep": true}
			before, _ := json.Marshal(tc.fields)
			block := Block{Type: tc.kind, Attrs: tc.fields}
			ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
			got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(block, ctx), "\n"))
			if got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
			after, _ := json.Marshal(tc.fields)
			if string(before) != string(after) {
				t.Fatal("render mutated source fields")
			}
		})
	}
}

func TestProseCarriersKeepWordsAtEveryProfile(t *testing.T) {
	blocks := []Block{
		{Type: "heading", Attrs: map[string]any{"level": 2, "content": []any{map[string]any{"type": "strong", "children": []any{map[string]any{"type": "text", "value": "Primary heading"}}}}, "text": "Stale fallback"}},
		{Type: "paragraph", Attrs: map[string]any{"text": "Legacy paragraph keeps its words when the reader wraps the line."}},
	}
	assertStripComplete(t, "prose-carriers", func(width int, profile Profile) string {
		ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: profile}
		got := DefaultRegistry(ctx.Theme).RenderDoc(blocks, ctx)
		if strings.Contains(got, "Stale fallback") || !strings.Contains(got, "Legacy") {
			t.Errorf("wrong carrier at width %d: %q", width, got)
		}
		return got
	})
}
