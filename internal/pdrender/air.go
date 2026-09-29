package pdrender

import "strings"

// air.go — the TERMINAL half of design/tokens.json's space families.
//
// The web surface reads space.air / space.section / space.rule as pixels and can
// paint six distinguishable evidence openings (24.2, 29.9, 31.9, 34.1, 36.1,
// 40.0px against a 22px beat). A terminal has exactly one vertical unit — the
// row — and space.air.beat is 22px ≈ one of them, so the entire ladder lives
// between 1.1 and 1.82 rows. Six web rungs are therefore TWO honest terminal
// values, and the collapse is derived here from the generated ratios rather than
// re-typed as a six-entry table: a table would claim a precision no terminal can
// render, and would drift the moment a ratio in tokens.json moved.
//
// The collapse rule itself is recorded at design/emit.mjs AIR_ROW_SPLIT and
// emitted into tokens_gen.go as GenAirRowSplit. design/check.mjs Part P censuses
// both ends, so neither the ratios nor the split can land dead.

// AirRows is how many blank rows open before a block of the given type: two for
// the heavy end of the ladder (stats, figure), one for everything else — a block
// that is not on the ladder at all included.
func AirRows(blockType string) int {
	ratio, ok := GenAirRatios[blockType]
	if !ok || ratio < GenAirRowSplit {
		return GenAirRowsDefault
	}
	return GenAirRowsDefault + 1
}

// RuleGlyph resolves one of the paper's two rule WEIGHTS to the glyph a terminal
// draws it with: "section" is the structural weight spent on a section boundary,
// "hairline" is every other line (a heading rule, a table underline, a divider).
// An unknown weight resolves to the hairline — a terminal never guesses heavy.
func RuleGlyph(weight string) string {
	if g, ok := GenRuleGlyph[weight]; ok {
		return g
	}
	return GenRuleGlyph["hairline"]
}

// isSectionBoundary reports whether the block at idx opens a new SECTION: an L2
// heading that follows non-heading content. That is the same predicate the web
// surface uses (paper-surface.css hangs both halves of the boundary device on
// the h2 element rule, because a paper's real boundaries are its level-2
// headings and every h2 across the rig fixtures follows non-heading content).
// An h1/h2 stack is a title and its first section head, not a boundary, so it
// keeps the ordinary air.
func isSectionBoundary(blocks []Block, idx int, prevType string) bool {
	if idx >= len(blocks) || blocks[idx].Type != "heading" {
		return false
	}
	if prevType == "" || prevType == "heading" {
		return false
	}
	return headingLevel(blocks[idx].Attrs) == 2
}

// sectionRule draws the STRUCTURAL half of the section-boundary device: a
// full-width heavy rule above the section head, the terminal's rendering of the
// web surface's `border-top: 2px` on h2. It is the only place the heavy weight
// is spent — every other line in a pdrender document is a hairline, which is the
// whole point of a two-weight ladder (space.rule's _note: a table underline as
// loud as a section boundary leaves the reader unable to tell structure from
// chrome by weight).
func sectionRule(width int) string {
	return strings.Repeat(RuleGlyph("section"), clampWidth(width))
}
