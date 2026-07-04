package taskboard

import (
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// glyphAllowlist is the CLOSED set of non-ASCII runes the calm board is allowed
// to paint (charter D14 — one steady vocabulary). Every non-ASCII rune in every
// regenerated golden must be in here; anything else is vocabulary creep
// (a re-introduced spinner, a chip hue glyph, a ▰▱ bar, a stray arrow) and fails
// CI. Keeping the allowlist tiny is the whole point — the subtraction is only
// real if new glyphs cannot sneak back in.
//
//	status glyphs   ● in_progress · ◐ blocked · ○ ready/open · ✓ done
//	connection dot  ● live · ◐ polling · ✗ offline (the honest degraded state)
//	structure       ─ rule · ▎ selection bar · · separator
//	header identity ⎇ branch · ⇄ server
//	honest overflow … truncation · ↑ ↓ scroll affordances
//
// ~ (tilde, the derived-cluster cue) is ASCII, so it is not — and need not be —
// listed here; this test only inventories runes outside ASCII.
var glyphAllowlist = map[rune]string{
	'●': "in_progress status glyph / live connection dot",
	'◐': "blocked status glyph / polling connection dot",
	'○': "ready/open status glyph",
	'✓': "done status glyph / met criterion",
	'✗': "offline connection dot",
	'─': "section rule",
	'▎': "selection bar",
	'·': "meta separator",
	'⎇': "branch marker",
	'⇄': "server marker",
	'…': "honest truncation ellipsis",
	'↑': "scroll-up affordance",
	'↓': "scroll-down affordance",
}

// TestGoldenGlyphBudget inventories every non-ASCII rune in EVERY golden under
// testdata — board, motion, still and first-paint frames alike, the whole
// rendered surface — and asserts it is in the allowlist. Regenerating any
// golden with a new glyph (a spinner frame, a hued chip, a ▰▱ meter) trips this
// immediately.
func TestGoldenGlyphBudget(t *testing.T) {
	names, err := filepath.Glob(filepath.Join("testdata", "*.txt"))
	if err != nil {
		t.Fatalf("glob goldens: %v", err)
	}
	if len(names) < 13 {
		t.Fatalf("found %d goldens, want at least 13 — the budget must sweep the whole rendered surface", len(names))
	}
	for _, name := range names {
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		offenders := map[rune]int{}
		for _, r := range string(raw) {
			if r < 0x80 { // ASCII (incl. ~, digits, letters, spaces) is always fine
				continue
			}
			if _, ok := glyphAllowlist[r]; !ok {
				offenders[r]++
			}
		}
		if len(offenders) > 0 {
			var runes []rune
			for r := range offenders {
				runes = append(runes, r)
			}
			sort.Slice(runes, func(i, j int) bool { return runes[i] < runes[j] })
			for _, r := range runes {
				t.Errorf("%s: disallowed non-ASCII glyph %q (U+%04X) appears %d× — vocabulary creep; "+
					"add it to glyphAllowlist only if it is a deliberate new calm-board glyph",
					name, string(r), r, offenders[r])
			}
		}
	}
}
