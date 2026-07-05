package taskboard

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// glyphAllowlist is the CLOSED set of non-ASCII runes the calm board is allowed
// to paint (charter D14 — one steady vocabulary). Every non-ASCII rune in every
// regenerated golden must be in here; anything else is vocabulary creep
// (a re-introduced spinner, a chip hue glyph, a ▰▱ bar, a stray arrow) and fails
// CI. Keeping the allowlist tiny is the whole point — the subtraction is only
// real if new glyphs cannot sneak back in.
//
//	status glyphs   ⠋…⠏ in_progress spinner (10 frames) · ⠿ frozen (reduced-motion)
//	                ! blocked (ASCII) · ○ ready/open · ✓ done · ✕ cancelled
//	connection dot  ● live · ◐ polling · ✗ offline (the honest degraded state)
//	momentum        ✓ done tally · █ progress fill · ░ progress track
//	structure       ─ rule · ▎ selection bar · · dotted leader/separator · ↳ subtask guide
//	header identity ⇄ server
//	honest overflow … truncation · ↑ ↓ scroll affordances
//
// ~ (tilde, the derived-cluster cue) and ! (blocked glyph) are ASCII, so they
// are not — and need not be — listed here; this test only inventories runes
// outside ASCII. The design-language redesign (charter D44) promoted the spinner
// frames + ⠿ + ✕ + ↳ + the progress-bar cells to the board set on purpose.
var glyphAllowlist = map[rune]string{
	'⠋': "in_progress spinner frame 0 / steady representative",
	'⠙': "in_progress spinner frame 1",
	'⠹': "in_progress spinner frame 2",
	'⠸': "in_progress spinner frame 3",
	'⠼': "in_progress spinner frame 4",
	'⠴': "in_progress spinner frame 5",
	'⠦': "in_progress spinner frame 6",
	'⠧': "in_progress spinner frame 7",
	'⠇': "in_progress spinner frame 8",
	'⠏': "in_progress spinner frame 9",
	'⠿': "in_progress spinner frozen frame (reduced-motion / NO_MOTION)",
	'●': "live connection dot",
	'◐': "polling connection dot",
	'○': "ready/open status glyph",
	'✓': "done status glyph / met criterion / momentum done tally",
	'✕': "cancelled status glyph",
	'✗': "offline connection dot",
	'█': "progress-bar fill (momentum)",
	'░': "progress-bar track (momentum)",
	'─': "section rule",
	'▎': "selection bar",
	'·': "dotted leader / meta separator",
	'–': "en-dash in a phase-band W-code range (W3–4) — charter wave-10 W10-A",
	'↳': "nested-subtask guide",
	'⇄': "server marker",
	'…': "honest truncation ellipsis",
	'↑': "scroll-up affordance",
	'↓': "scroll-down affordance",
}

// readingGlyphAllowlist is the SECOND closed set, for the reading frames only
// (detail_*/paper_* goldens — wave-5 integration decision, charter checklist
// item 3): prose typeset through mdlite/pdrender legitimately carries a richer
// typographic vocabulary than the board's status grid. It is a superset of the
// board list plus the documented reading runes — still CLOSED; a new rune in a
// reading golden fails CI exactly like vocabulary creep on the board. Do NOT
// fold these into glyphAllowlist: the board stays tight on purpose.
var readingGlyphExtras = map[rune]string{
	'—': "em dash in prose / hybrid timestamp separator",
	'•': "mdlite bullet",
	'→': "status-timeline arrow",
	'↳': "evidence hook under a criterion",
	'═': "detail header rule",
	'▌': "pdrender quote/callout bar (thick)",
	'▍': "pdrender quote/callout bar (thin)",
	'▸': "detail section marker",
	'⧉': "twin-task marker",
	'›': "breadcrumb separator (navigation-shell trail, charter D11/D18)",
}

func allowedGlyphs(golden string) map[rune]string {
	base := filepath.Base(golden)
	// compose_* goldens composite the reading frames (detail/paper body) under a
	// breadcrumb — so they carry the reading vocabulary, not just the board grid.
	reading := strings.HasPrefix(base, "detail_") ||
		strings.HasPrefix(base, "paper_") ||
		strings.HasPrefix(base, "compose_")
	out := map[rune]string{}
	for r, why := range glyphAllowlist {
		out[r] = why
	}
	if reading {
		for r, why := range readingGlyphExtras {
			out[r] = why
		}
	}
	return out
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
		allowed := allowedGlyphs(name)
		offenders := map[rune]int{}
		for _, r := range string(raw) {
			if r < 0x80 { // ASCII (incl. ~, digits, letters, spaces) is always fine
				continue
			}
			if _, ok := allowed[r]; !ok {
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
