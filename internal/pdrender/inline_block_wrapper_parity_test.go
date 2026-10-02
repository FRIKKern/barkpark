package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go leg of the BLOCK-WRAPPER-IN-AN-INLINE-ARRAY parity lock
// (task-3fd604e7c89d6150, sibling of task-9cab47ce042ccdfb / PR #15701).
//
// Three engines walk a run of inline nodes and they all read ONE fixture file —
// api/test/support/fixtures/inline-block-wrapper.json:
//
//	Elixir  api/lib/barkpark/portable_doc/render/inline.ex  unwrap_block_wrappers/1
//	        tested by api/test/barkpark/portable_doc/render/inline_block_wrapper_parity_test.exs
//	JS      js/packages/react/src/inline.tsx                unwrapBlockWrappers
//	        tested by js/packages/react/tests/inline-block-wrapper.parity.test.ts
//	Go      internal/pdrender/inline.go                     unwrapBlockWrappers
//	        tested HERE
//
// ONE file, not three generated mirrors — a mirror set drifts the moment one
// side is regenerated and the others are not, which is exactly the bug this row
// exists to close: the Elixir engine shipped the unwrap on 2026-09-03 and this
// reader plus the SDK stayed blank on the same published papers.
//
// DRIFT PROOF: drop the unwrapBlockWrappers call from InlineRenderer.Inline and
// the seven wrapper-shaped cases red HERE while the Elixir and JS legs stay
// green.

type blockWrapperCase struct {
	Name  string `json:"name"`
	Nodes []any  `json:"nodes"`
	Text  string `json:"text"`
}

func loadBlockWrapperFixture(t *testing.T) []blockWrapperCase {
	t.Helper()
	path := filepath.Join("..", "..", "api", "test", "support", "fixtures", "inline-block-wrapper.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture %s: %v", path, err)
	}
	var fixture struct {
		Cases []blockWrapperCase `json:"cases"`
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

// The visible text of an inline run: what the reader actually shows once the
// terminal styling is stripped. The JS leg strips tags and the Elixir leg folds
// the Pd tree, so all three compare the SAME string.
func TestInlineRunMatchesSharedBlockWrapperFixture(t *testing.T) {
	ir := InlineRenderer{theme: DarkTheme()}
	for _, c := range loadBlockWrapperFixture(t) {
		got := ansi.Strip(ir.Inline(c.Nodes, RenderCtx{}))
		if got != c.Text {
			t.Errorf("inline run disagreed with the fixture for %q:\n got  %q\n want %q",
				c.Name, got, c.Text)
		}
	}
}

// The mutation control, run in-process rather than promised in a comment: with
// the unwrap removed, the fixture's wrapper-shaped cases must go BLANK. If this
// fails, the assertion above was passing for some other reason and proves
// nothing about unwrapBlockWrappers.
func TestRemovingTheUnwrapBlanksTheWrapperCases(t *testing.T) {
	ir := InlineRenderer{theme: DarkTheme()}
	blanked := 0
	for _, c := range loadBlockWrapperFixture(t) {
		if c.Text == "" {
			continue
		}
		var b []byte
		for _, n := range c.Nodes { // the pre-fix walk: no unwrap
			b = append(b, ir.node(n, RenderCtx{}, false)...)
		}
		if ansi.Strip(string(b)) != c.Text {
			blanked++
		}
	}
	if blanked < 7 {
		t.Fatalf("only %d fixture cases depend on the unwrap; expected >= 7", blanked)
	}
}

// ONE LEVEL, and only on a NON-EMPTY list — the two bounds carried over from
// the Elixir original, asserted on the predicate itself so a future widening of
// unwrapBlockWrappers cannot pass by rendering the same text some other way.
func TestBlockWrapperPredicateBounds(t *testing.T) {
	if got := blockWrapperContent(map[string]any{"type": "paragraph", "content": []any{}}); got != nil {
		t.Errorf("empty content must NOT be a wrapper: got %#v", got)
	}
	if got := blockWrapperContent(map[string]any{"type": "paragraph", "content": "str"}); got != nil {
		t.Errorf("a string content must NOT be a wrapper: got %#v", got)
	}
	if got := blockWrapperContent(map[string]any{"type": "strong", "children": []any{"x"}}); got != nil {
		t.Errorf("a children-keyed inline node must NOT be a wrapper: got %#v", got)
	}
	inner := []any{map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "deep"}}}}
	out := unwrapBlockWrappers([]any{map[string]any{"type": "paragraph", "content": inner}})
	if len(out) != 1 {
		t.Fatalf("one level only: expected 1 node after the unwrap, got %d", len(out))
	}
	if blockWrapperContent(out[0]) == nil {
		t.Fatalf("one level only: the INNER wrapper must survive unwrapped, got %#v", out[0])
	}
}

// A mark node's own children walk is deliberately NOT unwrapped — the Elixir
// twin maps compose_inline/2 over `strong`/`em`/`link` children rather than
// routing them back through compose_inline_children/1, so a wrapper nested
// under a mark stays blank in all three engines until a row rules otherwise.
func TestMarkChildrenAreNotUnwrapped(t *testing.T) {
	ir := InlineRenderer{theme: DarkTheme()}
	nodes := []any{map[string]any{
		"type": "strong",
		"children": []any{map[string]any{
			"type":    "paragraph",
			"content": []any{map[string]any{"type": "text", "value": "under a mark"}},
		}},
	}}
	if got := ansi.Strip(ir.Inline(nodes, RenderCtx{})); got != "" {
		t.Fatalf("the run walk leaked into a mark's children: got %q, want %q", got, "")
	}
}
