package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestBlockquoteRenderer proves the blockquote block renders its text
// THROUGH the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestBlockquoteRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "blockquote", Attrs: map[string]any{"text": "hello from blockquote"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "hello from blockquote") {
		t.Fatalf("blockquote render missing text, got %q", got)
	}
}

// TestBlockquoteRendererEmptyIsSilent pins the honest empty state: a
// blockquote block with no text contributes zero lines.
func TestBlockquoteRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "blockquote", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty blockquote should render nothing, got %d lines", len(lines))
	}
}

// TestBlockquoteContentAndCite proves the grown blockquote renders an inline
// `content` body AND the optional attribution — the real prod quote shape.
func TestBlockquoteContentAndCite(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "blockquote", Attrs: map[string]any{
		"content": []any{map[string]any{"type": "text", "value": "Invent the future."}},
		"cite":    "Alan Kay",
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "Invent the future.") {
		t.Fatalf("blockquote content missing, got %q", got)
	}
	if !strings.Contains(got, "Alan Kay") {
		t.Fatalf("blockquote cite missing, got %q", got)
	}
}

// TestListVariantAndQuoteAliases proves the authoring-drift aliases dispatch
// through the registry: the list-variant spellings render their items, the
// numbered_list alias forces ordering (a "1." prefix), and `quote` renders as a
// blockquote. This is the Go twin of the compose.ex alias choke point.
func TestListVariantAndQuoteAliases(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	for _, typ := range []string{"bulletList", "bullet_list", "bulleted-list", "bulleted_list"} {
		b := Block{Type: typ, Attrs: map[string]any{
			"items": []any{[]any{map[string]any{"type": "text", "value": "point one"}}},
		}}
		got := ansi.Strip(strings.Join(reg.Render(b, ctx), "\n"))
		if !strings.Contains(got, "point one") {
			t.Fatalf("alias %q dropped its item, got %q", typ, got)
		}
		if !strings.Contains(got, "•") {
			t.Fatalf("alias %q lost the unordered bullet, got %q", typ, got)
		}
	}

	// numbered_list → ordered list (a "1." prefix appears).
	num := Block{Type: "numbered_list", Attrs: map[string]any{
		"items": []any{[]any{map[string]any{"type": "text", "value": "first"}}},
	}}
	got := ansi.Strip(strings.Join(reg.Render(num, ctx), "\n"))
	if !strings.Contains(got, "1.") {
		t.Fatalf("numbered_list alias not ordered, got %q", got)
	}

	// bullet_list items persisted as JSON-encoded strings decode to real inline.
	jsonItems := Block{Type: "bullet_list", Attrs: map[string]any{
		"items": []any{`[{"type":"text","value":"decoded item"}]`},
	}}
	gotJSON := ansi.Strip(strings.Join(reg.Render(jsonItems, ctx), "\n"))
	if !strings.Contains(gotJSON, "decoded item") || strings.Contains(gotJSON, "{\"type\"") {
		t.Fatalf("JSON-string list item not decoded, got %q", gotJSON)
	}

	// quote → blockquote.
	q := Block{Type: "quote", Attrs: map[string]any{
		"content": []any{map[string]any{"type": "text", "value": "quoted words"}},
	}}
	gotQ := ansi.Strip(strings.Join(reg.Render(q, ctx), "\n"))
	if !strings.Contains(gotQ, "quoted words") {
		t.Fatalf("quote alias did not render as blockquote, got %q", gotQ)
	}
}
