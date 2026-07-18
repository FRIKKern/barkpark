package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestActionAndRenderDocRespectResolvedWidths(t *testing.T) {
	reg := testRegistry()
	const href = "https://example.test/read?q=a&amp;b=c"
	block := Block{Type: "action", Attrs: map[string]any{
		"type": "action", "label": "Read &amp; inspect " + strings.Repeat("wide-label-", 8),
		"href": href, "priority": "primary",
	}}

	for _, width := range []int{20, 40, 80} {
		ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: TrueColor}
		for name, out := range map[string]string{
			"direct":    strings.Join(reg.Render(block, ctx), "\n"),
			"renderdoc": reg.RenderDoc([]Block{block}, ctx),
		} {
			t.Run(name+"_w"+itoa(width), func(t *testing.T) {
				for i, line := range strings.Split(out, "\n") {
					if got := ansi.StringWidth(line); got > width {
						t.Errorf("line %d width %d > %d: %q", i, got, width, ansi.Strip(line))
					}
				}
				if !strings.Contains(out, "\x1b]8;;"+href+"\x1b\\") {
					t.Errorf("OSC8 destination changed or disappeared: %q", out)
				}
				if strings.Contains(out, "https://example.test/read?q=a&b=c") {
					t.Errorf("href entity bytes were decoded globally: %q", out)
				}
				if !strings.Contains(ansi.Strip(out), "Read & inspect") {
					t.Errorf("semantic action label was not decoded once: %q", ansi.Strip(out))
				}
			})
		}
	}
}

func TestDisplayEntitiesDecodeOnceWithoutChangingLiteralCode(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	blocks := []Block{
		{Type: "paragraph", Attrs: map[string]any{"type": "paragraph", "content": []any{
			map[string]any{"type": "text", "value": "A &amp;amp; B | A &amp; B | "},
			map[string]any{"type": "code", "value": "&amp; &lt; &quot;"},
			map[string]any{"type": "text", "value": " | "},
			map[string]any{"type": "text", "value": "&amp;", "marks": []any{map[string]any{"type": "code"}}},
		}}},
		{Type: "code", Attrs: map[string]any{"type": "code", "code": "literal = `&amp; &lt; &quot;`", "language": "text"}},
	}
	got := ansi.Strip(reg.RenderDoc(blocks, ctx))
	if !strings.Contains(got, "A &amp; B | A & B") {
		t.Errorf("semantic text did not decode exactly once: %q", got)
	}
	for _, literal := range []string{"&amp; &lt; &quot;", "literal = `&amp; &lt; &quot;`"} {
		if !strings.Contains(got, literal) {
			t.Errorf("literal/code text changed; missing %q in %q", literal, got)
		}
	}
}
