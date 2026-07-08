package pdrender

import (
	"os/exec"
	"reflect"
	"strings"
	"testing"
)

// TestFlexMeasure pins the two-pass solver's FIRST pass: the divide-formula
// cellW=(avail-(tracks-1)*Gutter)/tracks and the degrade verdict
// sideBySide = tracks>1 && cellW>=MinWidth. These are the exact arithmetic the
// three callers (columns / section-grid / board lanes) used to each inline, plus
// the MinWidth boundary (a cell exactly at the floor side-by-sides; one below it
// stacks). DefaultFlex is gutter=2 / MinWidth=20.
func TestFlexMeasure(t *testing.T) {
	cases := []struct {
		name       string
		avail      int
		tracks     int
		wantCellW  int
		wantSideBy bool
	}{
		// 2-up at width 80: (80-1*2)/2 = 39, well above the floor → side-by-side.
		{"two-up wide", 80, 2, 39, true},
		// 3-up at width 66: (66-2*2)/3 = 20, EXACTLY at MinWidth → side-by-side.
		{"three-up at floor", 66, 3, 20, true},
		// 3-up at width 63: (63-2*2)/3 = 19, just below the floor → stack.
		{"three-up below floor", 63, 3, 19, false},
		// single track never side-by-sides regardless of width.
		{"single track", 80, 1, 80, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cellW, sideBy := DefaultFlex.Measure(tc.avail, tc.tracks)
			if cellW != tc.wantCellW {
				t.Errorf("Measure(%d,%d) cellW = %d, want %d", tc.avail, tc.tracks, cellW, tc.wantCellW)
			}
			if sideBy != tc.wantSideBy {
				t.Errorf("Measure(%d,%d) sideBySide = %v, want %v", tc.avail, tc.tracks, sideBy, tc.wantSideBy)
			}
		})
	}
}

// TestFlexMeasureClampsTracks guards the divide-by-zero clamp: tracks<1 is
// treated as a single track (cellW=avail, never side-by-side).
func TestFlexMeasureClampsTracks(t *testing.T) {
	for _, tracks := range []int{0, -1, -7} {
		cellW, sideBy := DefaultFlex.Measure(80, tracks)
		if cellW != 80 || sideBy {
			t.Errorf("Measure(80,%d) = (%d,%v), want (80,false)", tracks, cellW, sideBy)
		}
	}
}

// TestFlexArrangeMatchesJoinColumns proves the SECOND pass is byte-faithful:
// Flex.Arrange over Nodes produces exactly the same joined lines as calling the
// pre-refactor joinColumns body directly for a representative unequal-height set.
func TestFlexArrangeMatchesJoinColumns(t *testing.T) {
	nodes := []Node{
		{Lines: []string{"aaa", "aa"}, Width: 3},
		{Lines: []string{"bbbb"}, Width: 4},
		{Lines: []string{"c", "cc", "ccc"}, Width: 3},
	}
	groups := [][]string{{"aaa", "aa"}, {"bbbb"}, {"c", "cc", "ccc"}}
	widths := []int{3, 4, 3}

	got := DefaultFlex.Arrange(nodes)
	want := joinColumns(groups, widths, DefaultFlex.Gutter)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Arrange = %q, want %q", got, want)
	}
}

// TestNoInlineDivideFormulaOutsideSolver is the "one solver" tripwire: after the
// refactor NO renderer outside joincols.go may re-inline the per-cell width
// divide-formula assignment. joincols.go is the single owner; a copy reappearing
// elsewhere reds this test.
func TestNoInlineDivideFormulaOutsideSolver(t *testing.T) {
	out, err := exec.Command("grep", "-rn", "cellW *:=.*[Gg]utter", ".").CombinedOutput()
	// grep exit status 1 == no matches at all (also acceptable — zero copies).
	lines := []string{}
	for _, ln := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if ln == "" {
			continue
		}
		if strings.HasPrefix(ln, "./joincols.go:") {
			continue // the solver itself is the one allowed owner
		}
		lines = append(lines, ln)
	}
	if len(lines) > 0 {
		t.Errorf("inline divide-formula copies remain outside joincols.go:\n%s", strings.Join(lines, "\n"))
	}
	_ = err
}
