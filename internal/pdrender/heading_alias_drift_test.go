package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// Live-corpus drift guard for the h1/h2/h3 + ordered-list alias family (charter
// D57). Before this slice these four spellings were registered in NO renderer on
// ANY surface, so 20 blocks in live production papers drew the "unknown block"
// box on the TUI, the web and mobile at once.
//
// The inputs are the REAL live blocks, copied out of the production corpus
// (`ctx-compression-wave-2026-07-24`, censused 2026-07-27 across all 553
// published papers). Synthetic inputs would have missed the load-bearing detail:
// SIX of the 18 drifted headings (1 h2 + all 5 h3s) carry no `level` key, so
// borrowing the heading renderer without forcing the level from the TYPE renders
// them at headingLevel's default of 2.

// The three heading levels differ ONLY by foreground color (theme.go:185-187 —
// all three are Bold). Under NoColor they are byte-identical, which would make
// every "renders at level N" assertion below vacuous — the first run of this
// suite proved exactly that. So these tests force TrueColor and read the SGR.
func renderAliasBlock(t *testing.T, b Block) string {
	t.Helper()
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })
	return DefaultRegistry(DarkTheme()).RenderDoc([]Block{b}, RenderCtx{
		Width: 72, Theme: DarkTheme(), Profile: TrueColor,
	})
}

func TestHeadingAliasesRenderTheLiveDriftedBlocks(t *testing.T) {
	// The real h1: `{"id":"w1-002","level":1,"text":"…","type":"h1"}`.
	out := renderAliasBlock(t, Block{Type: "h1", Attrs: map[string]any{
		"level": 1, "text": "The manifest goes brief",
	}})
	assertNoUnknownBlock(t, "heading alias h1", out)
	// Level 1 is the only level that uppercases and draws a hairline rule, so it
	// is what proves the level actually reached the heading renderer.
	if !strings.Contains(out, "THE MANIFEST GOES BRIEF") {
		t.Errorf("h1 did not render at level 1 (no uppercase): %q", out)
	}
	if !strings.Contains(out, "─") {
		t.Errorf("h1 did not draw the level-1 rule: %q", out)
	}
}

func TestHeadingAliasLevelComesFromTheTypeNotTheLevelKey(t *testing.T) {
	// The real level-less blocks: `{"id":"w1-d00","text":"…","type":"h2"}` and
	// `{"id":"w1-d02","text":"Shipped","type":"h3"}`. A naive alias renders BOTH
	// at level 2 — identical bytes. The styles must differ.
	h2 := renderAliasBlock(t, Block{Type: "h2", Attrs: map[string]any{"text": "same words"}})
	h3 := renderAliasBlock(t, Block{Type: "h3", Attrs: map[string]any{"text": "same words"}})
	canonicalL2 := renderAliasBlock(t, Block{Type: "heading", Attrs: map[string]any{"level": 2, "text": "same words"}})
	canonicalL3 := renderAliasBlock(t, Block{Type: "heading", Attrs: map[string]any{"level": 3, "text": "same words"}})

	if h2 != canonicalL2 {
		t.Errorf("level-less h2 is not byte-identical to heading level 2:\n h2=%q\n l2=%q", h2, canonicalL2)
	}
	if h3 != canonicalL3 {
		t.Errorf("level-less h3 is not byte-identical to heading level 3:\n h3=%q\n l3=%q", h3, canonicalL3)
	}
	// The mutation proof that the two assertions above can FAIL: levels 2 and 3
	// must not paint the same, or "h3 renders as level 3" would be vacuous.
	if canonicalL2 == canonicalL3 {
		t.Fatalf("heading levels 2 and 3 paint identically — the level assertions above are vacuous: %q", canonicalL2)
	}

	// A contradicting stored level loses to the type.
	forced := renderAliasBlock(t, Block{Type: "h3", Attrs: map[string]any{"level": 1, "text": "same words"}})
	if forced != canonicalL3 {
		t.Errorf("h3 with level:1 did not render at level 3:\n got=%q\n want=%q", forced, canonicalL3)
	}
}

func TestHeadingAliasDoesNotMutateTheCallersBlock(t *testing.T) {
	attrs := map[string]any{"text": "borrowed"}
	b := Block{Type: "h3", Attrs: attrs}
	_ = renderAliasBlock(t, b)
	if _, ok := attrs["level"]; ok {
		t.Errorf("headingAtLevel wrote `level` into the caller's Attrs map: %v", attrs)
	}
}

func TestOrderedListAliasNumbersItsItems(t *testing.T) {
	// The real ordered-list carries map-shaped items (`{content:[…]}`). Those
	// still render BLANK text on this surface — the pre-existing list-item
	// normalization defect the TUI shares with compose.ex (charter D38,
	// task-993d136b0fbf2fd1), which the canonical `list` reproduces identically.
	// This alias is therefore pinned on the ORDERING, which is what it owns.
	out := renderAliasBlock(t, Block{Type: "ordered-list", Attrs: map[string]any{
		"items": []any{
			[]any{map[string]any{"type": "text", "value": "first point"}},
			[]any{map[string]any{"type": "text", "value": "second point"}},
		},
	}})
	assertNoUnknownBlock(t, "heading alias ordered-list", out)
	for _, want := range []string{"1.", "2.", "first point", "second point"} {
		if !strings.Contains(out, want) {
			t.Errorf("ordered-list missing %q: %q", want, out)
		}
	}
	if strings.Contains(out, "•") {
		t.Errorf("ordered-list drew bullets instead of numbers: %q", out)
	}
	// The canonical unordered sibling is untouched — the alias adds ordering, it
	// does not make every list ordered.
	plain := renderAliasBlock(t, Block{Type: "list", Attrs: map[string]any{
		"items": []any{[]any{map[string]any{"type": "text", "value": "first point"}}},
	}})
	if !strings.Contains(plain, "•") {
		t.Errorf("unordered list lost its bullet: %q", plain)
	}
}
