package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go leg of the ONE-RULE-PER-BOUNDARY parity lock (task-a4d1ae76fdb2a6b0).
//
// A section container used to open AND close on a full-width rule, so two
// adjacent sections stacked two lines where the grammar wants one. The Elixir
// engine settled the grammar in #16233 (SectionLayout.stack_rules?/2): an
// UNTITLED stack-mode section whose first child is a heading draws NO pair,
// because the heading itself carries the boundary. This reader kept drawing
// both rules on the same published papers until the row that added this file.
//
// Three engines, ONE fixture file —
// api/test/support/fixtures/section-boundary-rules.json:
//
//	Elixir  api/lib/barkpark/portable_doc/render/section_layout.ex  stack_rules?/2
//	        tested by api/test/barkpark/portable_doc/render/section_boundary_rules_parity_test.exs
//	Go      internal/pdrender/blocks.go                             sectionStackRules
//	        tested HERE
//	JS      js/packages/react/src/blocks/core.ts                    sectionStackRules
//	        tested by js/packages/react/tests/section-boundary-rules.parity.test.ts
//
// DRIFT PROOF: make sectionStackRules return true unconditionally (the
// pre-fix behaviour) and the three zero-rule cases red HERE while the Elixir
// and JS legs stay green.

type sectionBoundaryCase struct {
	Name  string         `json:"name"`
	Rules int            `json:"rules"`
	Block map[string]any `json:"block"`
}

func loadSectionBoundaryFixture(t *testing.T) []sectionBoundaryCase {
	t.Helper()
	path := filepath.Join("..", "..", "api", "test", "support", "fixtures", "section-boundary-rules.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture %s: %v", path, err)
	}
	var fixture struct {
		Cases []sectionBoundaryCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	// Guard the fixture itself: a shrunken case list, or one that lost its
	// zero-rule arm, would make every assertion below vacuously pass.
	zero, pair := 0, 0
	for _, c := range fixture.Cases {
		switch c.Rules {
		case 0:
			zero++
		case 2:
			pair++
		}
	}
	if len(fixture.Cases) < 10 || zero < 3 || pair < 6 {
		t.Fatalf("shared fixture shrank: %d cases (%d zero-rule, %d paired); want >=10 (>=3, >=6)",
			len(fixture.Cases), zero, pair)
	}
	return fixture.Cases
}

// countBandRules counts the FULL-WIDTH rule lines a render emits. Width is
// asserted so a level-1 heading's text-width underline (headingRenderer) can
// never be mistaken for a boundary rule; the fixture avoids level-1 headings
// and hr children anyway, and this is the belt to that braces.
func countBandRules(out string, width int) int {
	n := 0
	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)
		if bandRuleRe.MatchString(trimmed) && len([]rune(trimmed)) == width {
			n++
		}
	}
	return n
}

func TestSectionBoundaryRulesMatchSharedFixture(t *testing.T) {
	const width = 80
	for _, c := range loadSectionBoundaryFixture(t) {
		out := renderSectionAt(t, c.Block, width)
		if got := countBandRules(out, width); got != c.Rules {
			t.Errorf("section boundary rules disagreed with the fixture for %q:\n got  %d\n want %d\n%s",
				c.Name, got, c.Rules, out)
		}
	}
}

// TestSectionBoundaryPredicateArmsAreLive asserts the zero-rule cases really
// are the untitled heading-opening shape — i.e. the loop above exercised the
// discriminator rather than passing for some unrelated reason.
func TestSectionBoundaryPredicateArmsAreLive(t *testing.T) {
	for _, c := range loadSectionBoundaryFixture(t) {
		if c.Rules != 0 {
			continue
		}
		if title, ok := c.Block["title"]; ok && title != nil {
			t.Errorf("zero-rule case %q carries a title %v — it is not testing the predicate", c.Name, title)
		}
		blocks, _ := c.Block["blocks"].([]any)
		if len(blocks) == 0 {
			t.Errorf("zero-rule case %q has no children", c.Name)
			continue
		}
		first, _ := blocks[0].(map[string]any)
		if first["type"] != "heading" {
			t.Errorf("zero-rule case %q does not open on a heading", c.Name)
		}
	}
}

// TestAdjacentHeadingSectionsDrawOneBoundary is the row's whole point: two
// adjacent heading-opening sections must not stack a pair of hairlines
// between them.
func TestAdjacentHeadingSectionsDrawOneBoundary(t *testing.T) {
	const width = 80
	section := func(text string) map[string]any {
		return map[string]any{
			"type": "section",
			"blocks": []any{
				map[string]any{"type": "heading", "level": 2, "text": text},
				map[string]any{"type": "paragraph", "content": []any{
					map[string]any{"type": "text", "value": "body"},
				}},
			},
		}
	}
	raw, err := json.Marshal([]any{section("First"), section("Second")})
	if err != nil {
		t.Fatalf("marshal sections: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode sections: %v", err)
	}
	out := ansi.Strip(testRegistry().RenderDoc(blocks, RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}))

	if got := countBandRules(out, width); got != 0 {
		t.Errorf("two adjacent heading-opening sections drew %d band rules, want 0:\n%s", got, out)
	}
	for _, want := range []string{"First", "Second"} {
		if !strings.Contains(out, want) {
			t.Errorf("render lost the head %q:\n%s", want, out)
		}
	}
}
