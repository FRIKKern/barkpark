package pdrender

import (
	"strings"
	"testing"
)

func TestHeadingRendersPortableDocInlineContent(t *testing.T) {
	blocks := []Block{{
		Type: "heading",
		Attrs: map[string]any{
			"type":  "heading",
			"level": 1,
			"content": []any{
				map[string]any{"type": "text", "value": "Portable title"},
			},
		},
	}}

	rendered := DefaultRegistry(DarkTheme()).RenderDoc(blocks, RenderCtx{
		Width: 80, Theme: DarkTheme(), Profile: NoColor,
	})
	if !strings.Contains(rendered, "PORTABLE TITLE") {
		t.Fatalf("heading content disappeared: %q", rendered)
	}
}
