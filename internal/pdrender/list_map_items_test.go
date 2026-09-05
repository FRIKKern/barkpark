package pdrender

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── the map-shaped list item (task-993d136b0fbf2fd1) ─────────────────────────
//
// The wire shape of a list item is an ARRAY of inline nodes, but 2,033 of the
// 10,455 published list items in the live corpus (537 papers on guerrilla,
// full-corpus census 2026-07-25) are MAPS instead — {content:[…]} ×2,020 and
// {text:…} ×13. itemNodes grew its `case map[string]any:` arm for exactly that,
// but EVERY committed golden fixture spells its items as inline-node arrays, so
// the arm shipped with no fixture driving it: a vacuous green. These tests are
// that missing fixture — list_map_items.json is the ONLY committed fixture whose
// list items are maps, and TestListMapItemFixtureRendersEveryItem is red the
// moment the arm goes away (the item body renders blank, or as a Go map
// literal, instead of the author's words).

// TestItemNodesMapShapes pins itemNodes' full normalization table, map arms
// included. It mirrors compose.ex's normalize_list_item/1 + paragraph_inline/1.
func TestItemNodesMapShapes(t *testing.T) {
	textNode := map[string]any{"type": "text", "value": "hi"}

	cases := []struct {
		name string
		in   any
		want []any
	}{
		{
			name: "map with a content array yields that array",
			in:   map[string]any{"content": []any{textNode}},
			want: []any{textNode},
		},
		{
			// content ⟂ text: content wins when present, exactly like
			// paragraph_inline/1 reads content before the flat text.
			name: "map with BOTH content and text prefers content",
			in:   map[string]any{"content": []any{textNode}, "text": "stale"},
			want: []any{textNode},
		},
		{
			name: "map with only a flat text yields the scalar wrapped",
			in:   map[string]any{"text": "flat body"},
			want: []any{"flat body"},
		},
		{
			// An EMPTY content array is not a body: fall through to `text`
			// rather than rendering nothing at all.
			name: "map with an empty content array falls back to text",
			in:   map[string]any{"content": []any{}, "text": "flat body"},
			want: []any{"flat body"},
		},
		{
			name: "inline-node array passes through untouched",
			in:   []any{textNode},
			want: []any{textNode},
		},
		{
			name: "bare string is wrapped as one scalar node",
			in:   "plain",
			want: []any{"plain"},
		},
		{
			name: "JSON-encoded inline array is decoded",
			in:   `[{"type":"text","value":"hi"}]`,
			want: []any{textNode},
		},
		{
			name: "nil item yields nil",
			in:   nil,
			want: nil,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got := itemNodes(tc.in)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("itemNodes(%#v) = %#v, want %#v", tc.in, got, tc.want)
			}
		})
	}
}

// TestItemNodesMapWithNeitherKeyIsNotDropped guards the degenerate map: an item
// map carrying neither `content` nor `text` still reaches the inline renderer as
// a node rather than vanishing, so an unknown future item shape degrades in
// place instead of blanking the bullet silently.
func TestItemNodesMapWithNeitherKeyIsNotDropped(t *testing.T) {
	in := map[string]any{"unknown": "shape"}
	got := itemNodes(in)
	if len(got) != 1 {
		t.Fatalf("expected the degenerate map kept as one node, got %#v", got)
	}
}

// renderListMapItemsFixture renders the map-item fixture at NoColor so the
// assertions read plain text.
func renderListMapItemsFixture(t *testing.T, width int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "list_map_items.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if len(blocks) != 2 {
		t.Fatalf("fixture must hold both list blocks, decoded %d", len(blocks))
	}
	reg := testRegistry()
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	stripped := ansi.Strip(reg.RenderDoc(blocks, ctx))
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, "list_map_items.json", stripped)
	return stripped
}

// TestListMapItemFixtureRendersEveryItem is THE tripwire the arm never had: a
// committed fixture whose list items are maps. Every authored word must reach
// the terminal, on the canonical `list` type AND on the `ordered-list` alias.
func TestListMapItemFixtureRendersEveryItem(t *testing.T) {
	want := []string{
		"map item with content",
		"map item with a ",
		"mark",
		"map item with only text",
		"plain inline-array item",
		"bare string item",
		"first ordered map item",
		"second ordered map item",
	}

	for _, w := range goldenWidths {
		w := w
		t.Run("w"+itoa(w), func(t *testing.T) {
			out := renderListMapItemsFixture(t, w)
			for _, s := range want {
				if !strings.Contains(out, strings.TrimSpace(s)) {
					t.Errorf("map-shaped list item lost its body %q at width %d:\n%s", s, w, out)
				}
			}
			// A dropped arm used to print the Go map itself; nothing that looks
			// like a serialized map or raw JSON may reach the reader.
			for _, leak := range []string{"map[", `"type":"text"`, "content:["} {
				if strings.Contains(out, leak) {
					t.Errorf("raw item structure leaked to the terminal (%q) at width %d:\n%s", leak, w, out)
				}
			}
		})
	}
}

// TestListMapItemRendersLikeItsInlineArrayTwin is the CROSS-SHAPE identity: a
// map item and the inline-node array it wraps render byte-identically, which is
// what makes a stored-data normalization of the 2,020 {content:[…]} items
// provably render-preserving (the Elixir twin pins the same law in
// compose_test.exs).
func TestListMapItemRendersLikeItsInlineArrayTwin(t *testing.T) {
	inline := []any{map[string]any{"type": "text", "value": "one"}}

	mapForm := Block{Type: "list", Attrs: map[string]any{
		"type": "list", "items": []any{map[string]any{"content": inline}},
	}}
	arrayForm := Block{Type: "list", Attrs: map[string]any{
		"type": "list", "items": []any{inline},
	}}

	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	got := strings.Join(reg.Render(mapForm, ctx), "\n")
	want := strings.Join(reg.Render(arrayForm, ctx), "\n")
	if got != want {
		t.Errorf("map item diverged from its inline-array twin:\ngot:  %q\nwant: %q", got, want)
	}
	if !strings.Contains(ansi.Strip(got), "one") {
		t.Errorf("map item rendered without its body:\n%s", ansi.Strip(got))
	}
}
