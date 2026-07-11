package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// boxFixtures are the side-by-side surfaces the ambition wave built: columns
// (m4), task lanes + momentum bar (m6), and grid sections (m7). Their output
// must be a perfect RECTANGLE — every non-blank line padded to exactly the
// target width. Rectangularity is precisely what makes walls line up: if every
// row is the same width, a border glyph at column c on one row sits directly
// above the border glyph at column c on the next, so a box can never draw its
// bottom corner a column short (the class of bug a hand-authored diagram hit).
// This is the alignment complement of the no-overflow lock: overflow catches
// "too wide", ragged catches "walls don't meet".
//
// Deliberately NOT here: the grid WIDGETS (notes/cards/pipeline — sample_m5
// stacked, sample_m10 side-by-side). Unlike a full-bleed columns/section
// container, these widgets LEFT-PACK in the TUI: their side-by-side row is exactly
// N*cellW+(N-1)*gutter (the shared Flex solver's packed width), so the surface's
// floor-division remainder rides as a ragged right margin rather than being
// stretched into the cells — and even their vertical stack leaves short prose
// lines unpadded. A border glyph still sits above a border glyph because each CELL
// is internally rectangular; their horizontal output is guarded instead by
// TestNoLineOverflow (overflowFixtures carries sample_m10) + the byte-exact
// TestGoldenM10.
//
// Per-block reader-parity matrix (NOT a blanket "all three left-pack on both
// surfaces" — that earlier claim was FALSE for cards):
//   - pipeline: left-packs on BOTH surfaces — TUI packed row; web `flex flex-wrap
//     items-stretch` from a flex-start origin (portable-doc.tsx:985). Matched.
//   - notes: content-left on BOTH surfaces — TUI leaves short prose unpadded; web
//     is a `flex flex-col` label+text stack (portable-doc.tsx:881). Matched.
//   - cards: left-pack in the TUI, but the web reader STRETCHES them —
//     `grid gap-3 sm:grid-cols-2` (portable-doc.tsx:925) gives implicit 1fr tracks
//     with the grid's default justify-items:stretch, so each card fills its column.
//     TUI-packs vs web-stretches is an ACCEPTED per-surface divergence, ratified by
//     charter D3 (the gauge-list/dashboard ⊆-projection family) — by design, not a
//     bug to fix. boxFixtures membership is unaffected either way.
var boxFixtures = []string{"sample_m4.json", "sample_m6.json", "sample_m7.json", "sample_m8.json", "sample_m9.json"}

// raggedLines returns the indices of ANSI-stripped lines whose display width is
// neither 0 (a blank rhythm line between blocks) nor exactly w. In a box render
// a ragged line is a wall that stops short of its border column — the
// misalignment this lock forbids. Measured ANSI-aware so a wide-rune or a
// len()-vs-cells slip both surface.
func raggedLines(s string, w int) []int {
	var out []int
	for i, line := range strings.Split(s, "\n") {
		if wd := ansi.StringWidth(line); wd != 0 && wd != w {
			out = append(out, i)
		}
	}
	return out
}

// TestBoxRendersAreRectangular is the P9 alignment guarantee: for every
// box-producing fixture at every golden width, the render is a perfect
// rectangle, so borders, grid cells, and lane walls cannot drift out of
// column. A single ragged line reds it.
func TestBoxRendersAreRectangular(t *testing.T) {
	for _, fx := range boxFixtures {
		for _, w := range goldenWidths {
			got := renderFixture(t, fx, w)
			for _, i := range raggedLines(got, w) {
				line := strings.Split(got, "\n")[i]
				t.Errorf("%s w%d: line %d width %d != %d — a wall that doesn't reach its border column: %q",
					fx, w, i, ansi.StringWidth(line), w, line)
			}
		}
	}
}

// TestRectangularityCatchesMisalignment is the load-bearing proof that the lock
// is NOT vacuous: it reconstructs the exact defect a hand-authored pipeline
// diagram shipped — a box whose bottom border is one column short — and asserts
// raggedLines flags it. If this ever stops catching a short wall, the lock
// above has rotted into a green that means nothing.
func TestRectangularityCatchesMisalignment(t *testing.T) {
	const w = 8
	aligned := "╭──────╮\n│ hi   │\n╰──────╯" // every line is width 8
	if r := raggedLines(aligned, w); len(r) != 0 {
		t.Fatalf("aligned box flagged as ragged at lines %v — the lock over-reports", r)
	}

	// The paper bug: the bottom border drew one ─ too few, so its ╯ lands a
	// column left of the ╮ above it.
	shortBottom := "╭──────╮\n│ hi   │\n╰─────╯" // bottom is width 7
	if r := raggedLines(shortBottom, w); len(r) == 0 {
		t.Fatal("a box with a short bottom border was NOT caught — the alignment lock is vacuous")
	}

	// And a wall that overshoots is caught too (right for completeness).
	longMid := "╭──────╮\n│ hi    │\n╰──────╯" // mid is width 9
	if r := raggedLines(longMid, w); len(r) == 0 {
		t.Fatal("a box with an overlong wall was NOT caught — the alignment lock is vacuous")
	}
}
