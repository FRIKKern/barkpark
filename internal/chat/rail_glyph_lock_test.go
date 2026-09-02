package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// railGlyphCase is one row of the shared cross-surface fixture
// api/test/support/fixtures/chat_rail_agent_glyphs.json.
type railGlyphCase struct {
	Case     string `json:"case"`
	State    string `json:"state"`
	Terminal bool   `json:"terminal"`
	Failed   bool   `json:"failed"`
	Glyph    string `json:"glyph"`
}

func loadRailGlyphCases(t *testing.T) []railGlyphCase {
	t.Helper()
	path := filepath.Join("..", "..", "api", "test", "support", "fixtures", "chat_rail_agent_glyphs.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the shared rail-glyph fixture: %v", err)
	}
	var fixture struct {
		Cases []railGlyphCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode the shared rail-glyph fixture: %v", err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the shared fixture carries no cases — a vacuous lock proves nothing")
	}
	return fixture.Cases
}

// glyphOf strips the lipgloss styling so the assertion is about the CHARACTER
// the rail paints, not about the colour it wears.
func glyphOf(a WorkflowNode) string { return ansi.Strip(workflowAgentGlyph(a)) }

// TestRailAgentGlyphMatchesTheSharedFixture is the CROSS-SURFACE lock for the
// agents rail. The same api/test/support/fixtures/chat_rail_agent_glyphs.json is
// read by the Elixir suite (chat_rail_agent_glyph_test.exs) against
// BarkparkWeb.Studio.ChatLive.rail_agent_glyph/1, so a glyph edit on EITHER
// surface reds the other one's test. Before this fixture the Go source comment
// ("mirrors Studio's rail_agent_glyph") was the only thing holding the two
// truth tables together.
func TestRailAgentGlyphMatchesTheSharedFixture(t *testing.T) {
	cases := loadRailGlyphCases(t)

	seen := map[string]bool{}
	for _, c := range cases {
		seen[c.Glyph] = true
		got := glyphOf(WorkflowNode{Type: "workflow_agent", State: c.State})
		if got != c.Glyph {
			t.Errorf("workflowAgentGlyph(state=%q) = %q, the shared fixture says %q (%s) — "+
				"chat_rail_agent_glyph_test.exs reads the same row",
				c.State, got, c.Glyph, c.Case)
		}
	}

	var glyphs []string
	for g := range seen {
		glyphs = append(glyphs, g)
	}
	sort.Strings(glyphs)
	want := []string{"✓", "✕", "●"}
	sort.Strings(want)
	if len(glyphs) != len(want) {
		t.Fatalf("the fixture must exercise every arm of workflowAgentGlyph, saw %v", glyphs)
	}
	for i := range want {
		if glyphs[i] != want[i] {
			t.Fatalf("the fixture must exercise every arm of workflowAgentGlyph, saw %v want %v", glyphs, want)
		}
	}
}

// TestRailGlyphStateSetsMatchTheSharedFixture pins the ported state sets
// themselves: the fixture's terminal/failed columns are what this surface must
// answer, so a state quietly added to or dropped from one surface's set reds
// here as well as on the Studio side.
func TestRailGlyphStateSetsMatchTheSharedFixture(t *testing.T) {
	for _, c := range loadRailGlyphCases(t) {
		if got := workflowStateTerminal(c.State); got != c.Terminal {
			t.Errorf("workflowStateTerminal(%q) = %v, fixture says %v", c.State, got, c.Terminal)
		}
		if got := workflowStateFailed(c.State); got != c.Failed {
			t.Errorf("workflowStateFailed(%q) = %v, fixture says %v", c.State, got, c.Failed)
		}
	}
}

// TestRailAgentGlyphPrecedenceFailedBeatsTerminal is the half a naive equality
// fixture misses. The failure set is a SUBSET of the terminal set, so every
// failure state is ALSO terminal; `failed` is checked FIRST on both surfaces,
// which is why such a node paints ✕. Swap the two switch arms in
// workflowAgentGlyph and the glyph SET still matches the fixture while the
// behaviour diverges from Studio — this test is what reds on that.
func TestRailAgentGlyphPrecedenceFailedBeatsTerminal(t *testing.T) {
	both := 0
	for _, c := range loadRailGlyphCases(t) {
		if !c.Failed || !c.Terminal {
			continue
		}
		both++
		if !workflowStateFailed(c.State) || !workflowStateTerminal(c.State) {
			t.Fatalf("fixture row %q claims failed AND terminal, this surface disagrees", c.State)
		}
		if got := glyphOf(WorkflowNode{Type: "workflow_agent", State: c.State}); got != "✕" {
			t.Errorf("state %q is failed AND terminal, so `failed` must be checked BEFORE "+
				"`terminal` — got %q, want %q", c.State, got, "✕")
		}
	}
	if both == 0 {
		t.Fatal("the fixture carries no failed-AND-terminal row, so the arm ORDER is unproved")
	}
}
