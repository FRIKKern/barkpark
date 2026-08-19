package taskboard

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestSpineWindowPinsBothSurfaces pins the TWIN clip-and-mark windowing seams at
// the SAME overflow boundary: windowSpine (render.go, the painted spine) and
// windowTargets (hitmap.go, the per-line hit map). Both clip len>avail lines to
// `avail` from a slideTop-chosen top and stamp the ↑/↓ overflow affordances on
// the window's first/last rows — they must stay a 1:1 mirror, so ONE test guards
// BOTH. A render-only golden pins 3 of 6 seam mutations and is a vacuous pass;
// this test enters the overflow branch on both surfaces, which is why all six of
// the named seam mutations RED it (start-clamp len-avail, win[0] top marker,
// win[avail-1] bottom marker — once in each twin). The clamp mutation (len-avail
// -> len-avail+1) PANICS at the bottom-clamp geometry scenario B constructs,
// proving no prior test entered this branch. Boundary: len=20, avail=10.
func TestSpineWindowPinsBothSurfaces(t *testing.T) {
	const (
		total = 20
		avail = 10 // realistic avail >= 8
		width = 80
	)
	lines := make([]string, total)
	targets := make([]LineTarget, total)
	for i := range lines {
		lines[i] = fmt.Sprintf("L%d", i)
		targets[i] = LineTarget{Kind: LineSpineRow, CursorIndex: i}
	}

	// ── Scenario A: a MIDDLE window (0 < start < len-avail) — both overflow
	// markers appear, pinning the top-marker and bottom-marker seams on each
	// twin. top=5 -> start=5, below = 20-15 = 5.
	spineA := windowSpine(lines, 5, avail, width)
	if got := len(spineA); got != avail {
		t.Fatalf("windowSpine middle: len = %d, want %d", got, avail)
	}
	if first := ansi.Strip(spineA[0]); !strings.Contains(first, "↑ 5 more above") {
		t.Errorf("windowSpine first line lost the numbered up-marker: %q", first)
	}
	if last := ansi.Strip(spineA[avail-1]); !strings.Contains(last, "↓ 5 more below") {
		t.Errorf("windowSpine last line lost the numbered down-marker: %q", last)
	}

	winA := windowTargets(targets, 5, avail)
	if got := len(winA); got != avail {
		t.Fatalf("windowTargets middle: len = %d, want %d", got, avail)
	}
	if winA[0] != scrollUpTarget {
		t.Errorf("windowTargets win[0] not scrollUpTarget: %+v", winA[0])
	}
	if winA[avail-1] != scrollDownTarget {
		t.Errorf("windowTargets win[avail-1] not scrollDownTarget: %+v", winA[avail-1])
	}

	// ── Scenario B: a BOTTOM-CLAMP window (top past the end -> start clamps to
	// len-avail). The clamp mutation (+1) would slice out of range and PANIC.
	// The bottom row is the LAST content line, NOT a marker (below == 0), so
	// this proves the clamp reaches the final line/target rather than over- or
	// under-shooting. top=100 -> start=10.
	spineB := windowSpine(lines, 100, avail, width)
	if got := len(spineB); got != avail {
		t.Fatalf("windowSpine clamp: len = %d, want %d", got, avail)
	}
	if first := ansi.Strip(spineB[0]); !strings.Contains(first, "↑ 10 more above") {
		t.Errorf("windowSpine clamp first line: %q", first)
	}
	if last := ansi.Strip(spineB[avail-1]); last != "L19" {
		t.Errorf("windowSpine clamp bottom did not reach the last content line: %q", last)
	}

	winB := windowTargets(targets, 100, avail)
	if got := len(winB); got != avail {
		t.Fatalf("windowTargets clamp: len = %d, want %d", got, avail)
	}
	if winB[0] != scrollUpTarget {
		t.Errorf("windowTargets clamp win[0] not scrollUpTarget: %+v", winB[0])
	}
	if want := (LineTarget{Kind: LineSpineRow, CursorIndex: total - 1}); winB[avail-1] != want {
		t.Errorf("windowTargets clamp bottom did not reach the last target: got %+v want %+v", winB[avail-1], want)
	}
}
