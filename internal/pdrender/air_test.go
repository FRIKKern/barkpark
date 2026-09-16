package pdrender

import (
	"strings"
	"testing"
)

// TestAirLadderIsTwoStep is the INTENT assertion the goldens cannot make: a
// golden freezes whatever we shipped, including a fake six-step ladder. This
// asserts the shape — the terminal ladder takes exactly TWO distinct values,
// because at a 22px beat every rung between 1.1 and 1.82 is between one and two
// rows and anything finer claims a precision no terminal can render.
func TestAirLadderIsTwoStep(t *testing.T) {
	seen := map[int]bool{}
	for _, kind := range GenAirOrder {
		rows := AirRows(kind)
		if rows < 1 || rows > 2 {
			t.Errorf("AirRows(%q) = %d, want 1 or 2 — the terminal ladder has two rungs", kind, rows)
		}
		seen[rows] = true
	}
	if len(seen) != 2 {
		t.Fatalf("the air ladder collapsed to %d distinct row count(s), want exactly 2 — "+
			"one step is no ladder, three is fake precision", len(seen))
	}
	// Monotonic: a heavier ratio never opens with LESS air than a lighter one.
	prev := 0
	for _, kind := range GenAirOrder {
		rows := AirRows(kind)
		if rows < prev {
			t.Errorf("AirRows(%q) = %d after %d — the ladder is not monotonic in GenAirOrder", kind, rows, prev)
		}
		prev = rows
	}
	// The split is a PREDICATE over the generated ratios, not a hand table.
	for kind, ratio := range GenAirRatios {
		want := GenAirRowsDefault
		if ratio >= GenAirRowSplit {
			want = GenAirRowsDefault + 1
		}
		if got := AirRows(kind); got != want {
			t.Errorf("AirRows(%q) = %d, want %d from ratio %v vs split %v", kind, got, want, ratio, GenAirRowSplit)
		}
	}
	// A block not on the ladder opens with the baseline, never two rows.
	if got := AirRows("paragraph"); got != GenAirRowsDefault {
		t.Errorf("AirRows(paragraph) = %d, want the %d-row default", got, GenAirRowsDefault)
	}
}

// TestRuleLadderHasTwoWeights asserts the rule ladder stays two-valued and that
// the heavy weight is distinct from the hairline — a ladder whose two rungs are
// the same glyph is the drift space.rule's note describes (structure and chrome
// drawn at the same weight).
func TestRuleLadderHasTwoWeights(t *testing.T) {
	hair, sec := RuleGlyph("hairline"), RuleGlyph("section")
	if hair == sec {
		t.Fatalf("hairline and section rules are both %q — the ladder has collapsed to one weight", hair)
	}
	if got := RuleGlyph("no-such-weight"); got != hair {
		t.Errorf("RuleGlyph(unknown) = %q, want the hairline %q — a terminal never guesses heavy", got, hair)
	}
}

// TestSectionBoundarySpendsGapAndHeavyRule is the behavioural arm: an L2 heading
// that follows content gets BOTH halves of the boundary device (the section gap
// AND the heavy rule), an L2 heading stacked under a heading gets neither, and
// no ordinary block ever draws the heavy weight.
func TestSectionBoundarySpendsGapAndHeavyRule(t *testing.T) {
	r := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: 40, Theme: DarkTheme()}
	heavy := RuleGlyph("section")

	para := Block{Type: "paragraph", Attrs: map[string]any{"text": "prose before the boundary"}}
	h2 := Block{Type: "heading", Attrs: map[string]any{"level": 2, "text": "Section two"}}
	h1 := Block{Type: "heading", Attrs: map[string]any{"level": 1, "text": "Title"}}

	boundary := r.RenderDoc([]Block{para, h2}, ctx)
	if !strings.Contains(boundary, strings.Repeat(heavy, 4)) {
		t.Errorf("an L2 heading after prose drew no heavy rule:\n%s", boundary)
	}
	gap := strings.Repeat("\n", GenSectionGapRows)
	if !strings.Contains(strings.ReplaceAll(boundary, " ", ""), gap) {
		t.Errorf("an L2 heading after prose did not spend %d blank rows:\n%q", GenSectionGapRows, boundary)
	}

	stacked := r.RenderDoc([]Block{h1, h2}, ctx)
	if strings.Contains(stacked, heavy) {
		t.Errorf("an h1/h2 stack is a title and its first head, not a boundary — it drew a heavy rule:\n%s", stacked)
	}

	plain := r.RenderDoc([]Block{para, para}, ctx)
	if strings.Contains(plain, heavy) {
		t.Errorf("two paragraphs drew the structural weight — it is spent on section heads only:\n%s", plain)
	}
}
