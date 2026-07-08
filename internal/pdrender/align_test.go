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
var boxFixtures = []string{"sample_m4.json", "sample_m6.json", "sample_m7.json", "sample_m8.json"}

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
