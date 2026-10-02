package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The Go leg of the INLINE `code` source parity lock (task-e4833f198e293ed1).
//
// Three engines render an inline code chip and they all read ONE fixture file —
// api/test/support/fixtures/inline-code-source.json:
//
//	Elixir  api/lib/barkpark/portable_doc/render/inline.ex  inline_code_source/1
//	        tested by api/test/barkpark/portable_doc/render/inline_code_source_parity_test.exs
//	JS      js/packages/react/src/inline.tsx                inlineCodeSource
//	        tested by js/packages/react/tests/inline-code-source.parity.test.ts
//	Go      internal/pdrender/inline.go                     inlineCodeSource
//	        tested HERE
//
// ONE file, not three generated mirrors — a mirror set drifts the moment one
// side is regenerated and the others are not, which is exactly the bug this row
// exists to close: react shipped the value-or-children law while inline.ex and
// this file still read `value` only.
//
// DRIFT PROOF: drop the inlineNodesText fall-through from inlineCodeSource and
// the children-shaped cases red HERE while the Elixir and JS legs stay green.

type inlineCodeCase struct {
	Name   string         `json:"name"`
	Node   map[string]any `json:"node"`
	Source string         `json:"source"`
}

func loadInlineCodeFixture(t *testing.T) []inlineCodeCase {
	t.Helper()
	path := filepath.Join("..", "..", "api", "test", "support", "fixtures", "inline-code-source.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture %s: %v", path, err)
	}
	var fixture struct {
		Cases []inlineCodeCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	// Guard the fixture itself: a shrunken case list would make every
	// assertion below vacuously pass.
	if len(fixture.Cases) < 13 {
		t.Fatalf("shared fixture shrank to %d cases; expected >= 13", len(fixture.Cases))
	}
	return fixture.Cases
}

func TestInlineCodeSourceMatchesSharedFixture(t *testing.T) {
	for _, c := range loadInlineCodeFixture(t) {
		if got := inlineCodeSource(c.Node); got != c.Source {
			t.Errorf("inlineCodeSource disagreed with the fixture for %q:\n got  %q\n want %q",
				c.Name, got, c.Source)
		}
	}
}

func TestInlineCodeChildrenFallThroughIsReached(t *testing.T) {
	reached := 0
	for _, c := range loadInlineCodeFixture(t) {
		if c.Node["children"] == nil || c.Source == "" {
			continue
		}
		withoutChildren := map[string]any{}
		for k, v := range c.Node {
			if k != "children" {
				withoutChildren[k] = v
			}
		}
		if inlineCodeSource(withoutChildren) != c.Source {
			reached++
		}
	}
	if reached < 6 {
		t.Fatalf("only %d fixture cases exercise the children fall-through; expected >= 6", reached)
	}
}

func TestInlineCodeWhitespaceValueWinsOverChildren(t *testing.T) {
	node := map[string]any{
		"type":     "code",
		"value":    " ",
		"children": []any{map[string]any{"type": "text", "value": "never"}},
	}
	if got := inlineCodeSource(node); got != " " {
		t.Fatalf("first NON-EMPTY, not non-blank: got %q, want %q", got, " ")
	}
}

// A bare ARRAY where an inline node was expected — `content: [[{text…}]]`,
// flattened one level too shallow by an upstream author path. 59 live
// paragraphs + 18 list blocks carry the shape (2026-07-25 census). The Elixir
// twin wraps the composed children in a PdText (inline.ex `compose_inline(l)
// when is_list(l)`) and the SDK emits a `<span>` (inline.tsx renderInline,
// `if (Array.isArray(node))`); this reader alone returned "" and the text
// vanished in the TUI.
//
// DRIFT PROOF: delete the `case []any` arm of InlineRenderer.node and this
// reds while the Elixir and JS legs stay green.
func TestBareArrayInlineNodeRendersItsChildren(t *testing.T) {
	ir := InlineRenderer{theme: DarkTheme()}
	nodes := []any{
		[]any{
			map[string]any{"type": "text", "value": "nested_array_survives()"},
		},
	}
	got := ir.Inline(nodes, RenderCtx{})
	if !strings.Contains(got, "nested_array_survives()") {
		t.Fatalf("bare-array inline node dropped its text: got %q", got)
	}
}
