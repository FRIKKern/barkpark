package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The Go leg of the inline object parity lock (task-85fee859cf3bfef6).
//
// An inline object is a childless inline node {type, ...fields} with no
// built-in renderer, such as a schema's `blocks.inline` type. Three engines
// read ONE fixture, api/test/support/fixtures/inline-object-text.json:
//
//	Elixir  render/inline.ex inline_object_text/1
//	        tested by api/test/barkpark/portable_doc/render/inline_object_parity_test.exs
//	JS      js/packages/react/src/inline-object.ts inlineObjectText
//	        tested by js/packages/react/tests/inline-object.parity.test.tsx
//	Go      internal/pdrender/inline.go inlineObjectText — tested HERE
//
// Before this, the TUI rendered the node as nothing.

type inlineObjectCase struct {
	Name string         `json:"name"`
	Node map[string]any `json:"node"`
	Text string         `json:"text"`
}

func loadInlineObjectFixture(t *testing.T) []inlineObjectCase {
	t.Helper()
	path := filepath.Join("..", "..", "api", "test", "support", "fixtures", "inline-object-text.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture %s: %v", path, err)
	}
	var fixture struct {
		Cases []inlineObjectCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	// A shrunken fixture would make every assertion below pass vacuously.
	if len(fixture.Cases) < 10 {
		t.Fatalf("shared fixture shrank to %d cases; expected >= 10", len(fixture.Cases))
	}
	return fixture.Cases
}

func TestInlineObjectTextMatchesSharedFixture(t *testing.T) {
	for _, c := range loadInlineObjectFixture(t) {
		if got := inlineObjectText(c.Node); got != c.Text {
			t.Errorf("inlineObjectText disagreed for %q:\n got  %q\n want %q", c.Name, got, c.Text)
		}
	}
}

func TestInlineObjectRendersItsTextInProse(t *testing.T) {
	ir := InlineRenderer{theme: DarkTheme()}
	for _, c := range loadInlineObjectFixture(t) {
		got := ir.Inline([]any{c.Node}, RenderCtx{})
		want := c.Text
		if want == "" {
			// Never dropped silently: a textless node shows its type name.
			want = "[" + attrStr(c.Node, "type") + "]"
		}
		if !strings.Contains(got, want) {
			t.Errorf("inline object text missing for %q: got %q, want %q", c.Name, got, want)
		}
	}
}
