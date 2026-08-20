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

func TestRenderDocHardBoundsRealCorpusParagraphAfterWordWrap(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	text := "Ledger evidence (the strongest signal class): the 294-paper census behind the wishlist counts 23 stat uses, 207 hand-typed tables, and ZERO video blocks - absence-by-missing-block, not absence of appetite. The broken-block drift is cited per charter D14 in its only citable form: the storage-path COALESCE census - coalesce(content->'blocks', content->'body'->'blocks') over published papers -> 77 placeholders (bulleted-list 27, bullet_list 22, bulleted_list 15, quote 8, numbered_list 3, bulletList 2), triple-confirmed; a naive single-path query undercounts to 51 and is not citable."
	block := Block{Type: "paragraph", Attrs: map[string]any{
		"type":    "paragraph",
		"content": []any{map[string]any{"type": "text", "value": text}},
	}}

	got := reg.RenderDoc([]Block{block}, ctx)
	for i, line := range strings.Split(got, "\n") {
		if width := ansi.StringWidth(line); width > ctx.Width {
			t.Errorf("line %d width %d > %d: %q", i, width, ctx.Width, ansi.Strip(line))
		}
	}
	plain := ansi.Strip(got)
	for _, token := range []string{"Ledger evidence", "storage-path", "triple-confirmed", "not citable"} {
		if !strings.Contains(plain, token) {
			t.Errorf("hard boundary lost authored token %q in %q", token, plain)
		}
	}
}
