package pdrender

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The TUI leg of the framed-finale section variant (charter D19). A section
// carrying variant="framed" renders inside a SQUARE lipgloss.NormalBorder
// frame in rule color that REPLACES the two-rule band; below MinWidth (plus
// the border+padding chrome) it degrades honestly to the byte-identical band
// path. The fixture (testdata/section-framed.golden.json) is the ADDITIVE
// sibling of the generator-owned section.golden.json, which stays
// byte-unchanged — this file asserts the framed projection only.

type framedProjection struct {
	ContainerRole string   `json:"container_role"`
	Border        string   `json:"border"`
	Title         string   `json:"title"`
	Prose         []string `json:"prose"`
}

// bandRuleRe matches a full-width two-rule band line: nothing but ─ runs.
// The frame's own top/bottom edges carry corner glyphs, so they never match.
var bandRuleRe = regexp.MustCompile(`^─+$`)

func renderSectionAt(t *testing.T, block map[string]any, width int) string {
	t.Helper()
	raw, err := json.Marshal([]any{block})
	if err != nil {
		t.Fatalf("marshal section block: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode section block: %v", err)
	}
	reg := testRegistry()
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	stripped := ansi.Strip(reg.RenderDoc(blocks, ctx))
	// Shared blind-spot guard (unknown_block_guard_test.go).
	assertNoUnknownBlock(t, "section-framed.golden.json", stripped)
	return stripped
}

func framedFixtureInput(t *testing.T) (map[string]any, framedProjection) {
	t.Helper()
	fx := loadComponentGolden(t, "section-framed")
	var proj framedProjection
	if err := json.Unmarshal(fx.Expected, &proj); err != nil {
		t.Fatalf("decode framed projection: %v", err)
	}
	var input map[string]any
	if err := json.Unmarshal(fx.Input, &input); err != nil {
		t.Fatalf("decode framed input: %v", err)
	}
	return input, proj
}

// TestSectionFramedGolden proves the framed render realizes the fixture's
// projection: square corners (NormalBorder — not the rounded boxStyle), side
// walls, NO surviving two-rule band line, and the title + prose inside.
func TestSectionFramedGolden(t *testing.T) {
	input, proj := framedFixtureInput(t)
	if proj.ContainerRole != "section-framed" || proj.Border != "square" {
		t.Fatalf("projection = %q/%q, want section-framed/square", proj.ContainerRole, proj.Border)
	}

	out := renderSectionAt(t, input, 80)

	for _, glyph := range []string{"┌", "┐", "└", "┘", "│"} {
		if !strings.Contains(out, glyph) {
			t.Errorf("framed render missing square-border glyph %q:\n%s", glyph, out)
		}
	}
	for _, rounded := range []string{"╭", "╮", "╰", "╯"} {
		if strings.Contains(out, rounded) {
			t.Errorf("framed render uses ROUNDED corner %q — must be NormalBorder (square):\n%s", rounded, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if bandRuleRe.MatchString(strings.TrimSpace(line)) {
			t.Errorf("two-rule band line survived inside the framed render — the frame must REPLACE it:\n%s", out)
		}
	}
	if !strings.Contains(out, proj.Title) {
		t.Errorf("framed render missing title %q:\n%s", proj.Title, out)
	}
	for _, prose := range proj.Prose {
		// Prose may wrap; assert the leading words survive on one line.
		head := prose
		if words := strings.Fields(prose); len(words) > 3 {
			head = strings.Join(words[:3], " ")
		}
		if !strings.Contains(out, head) {
			t.Errorf("framed render missing prose %q:\n%s", head, out)
		}
	}
}

// TestSectionUnframedByteIdentity pins the band path: a section WITHOUT a
// variant renders byte-identically to the pre-frame renderer's shape (two
// full-width rules, no border glyphs), and an UNKNOWN variant fail-softs to
// those exact bytes.
func TestSectionUnframedByteIdentity(t *testing.T) {
	input, _ := framedFixtureInput(t)

	unframed := map[string]any{}
	for k, v := range input {
		if k != "variant" {
			unframed[k] = v
		}
	}
	base := renderSectionAt(t, unframed, 80)

	if strings.Contains(base, "┌") || strings.Contains(base, "│") {
		t.Fatalf("unframed section grew border glyphs:\n%s", base)
	}
	rules := 0
	for _, line := range strings.Split(base, "\n") {
		if bandRuleRe.MatchString(strings.TrimSpace(line)) {
			rules++
		}
	}
	if rules != 2 {
		t.Fatalf("unframed section band = %d rule lines, want 2:\n%s", rules, base)
	}

	unknown := map[string]any{}
	for k, v := range unframed {
		unknown[k] = v
	}
	unknown["variant"] = "bogus"
	if got := renderSectionAt(t, unknown, 80); got != base {
		t.Errorf("unknown variant must fail-soft to the unframed bytes.\nunknown:\n%s\nunframed:\n%s", got, base)
	}
}

// TestSectionFramedDegradesBelowMinWidth: when the width cannot fit the frame's
// border+padding chrome on top of MinWidth, the framed section renders the
// byte-identical band path — an honest degrade, never a crushed frame.
func TestSectionFramedDegradesBelowMinWidth(t *testing.T) {
	input, _ := framedFixtureInput(t)
	unframed := map[string]any{}
	for k, v := range input {
		if k != "variant" {
			unframed[k] = v
		}
	}

	// frameChrome = 4, so MinWidth+3 leaves MinWidth-1 inside — one short.
	narrow := MinWidth + 3
	framed := renderSectionAt(t, input, narrow)
	base := renderSectionAt(t, unframed, narrow)
	if framed != base {
		t.Errorf("below the frame floor the render must equal the band path.\nframed:\n%s\nband:\n%s", framed, base)
	}
	if strings.Contains(framed, "┌") {
		t.Errorf("crushed frame emitted below MinWidth:\n%s", framed)
	}
}
