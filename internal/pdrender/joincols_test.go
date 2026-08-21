package pdrender

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
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

// TestNodeWidthIsANSIAware proves nodeWidth measures DISPLAY cells, not bytes:
// it returns the widest of a Node's lines via lipgloss.Width, so a styled
// (colored) line whose escape bytes far outnumber its visible cells is measured
// at its visible width, never its byte length. The load-bearing case is the
// styled line: a naive len() would count the SGR bytes and wildly over-measure,
// which would make the Fits gate collapse a surface that actually fits.
func TestNodeWidthIsANSIAware(t *testing.T) {
	// Force a real color profile so lipgloss actually emits SGR escapes; restore
	// Ascii(3) after so later goldens strip clean.
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(0) // termenv.TrueColor → real escapes
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })

	styled := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#ff0000")).
		Bold(true).
		Render("hello") // 5 visible cells, but many more bytes of SGR
	if len(styled) <= 5 {
		t.Fatalf("test precondition: styled string should carry SGR bytes, got %q (len %d)", styled, len(styled))
	}

	n := Node{Lines: []string{"ab", styled, "abcd"}, Width: 10}
	if got := nodeWidth(n); got != 5 {
		t.Errorf("nodeWidth = %d, want 5 (widest line is the 5-cell styled run, measured ANSI-aware not by its %d bytes)",
			got, len(styled))
	}
}

// TestFlexFits pins the SECOND-pass measure verdict. A Node whose realized
// min-content (nodeWidth) exceeds its allotted Width does NOT fit → Fits false
// (the caller must degrade to its verbatim stack). A span-aware Node whose Width
// is spanWidth(cellW, span) fits when its content sits inside that spanned width.
func TestFlexFits(t *testing.T) {
	// A single unbreakable token wider than its cell → overflow → Fits false.
	overflow := Node{Lines: []string{strings.Repeat("x", 45)}, Width: 39, Span: 1}
	if DefaultFlex.Fits([]Node{overflow}) {
		t.Errorf("Fits = true for a node whose 45-cell content overflows its 39-cell width; want false")
	}

	// The SAME token in a span-2 cell: its allotted Width is spanWidth(cellW,2) =
	// 2*39 + 1*gutter(2) = 80, which comfortably holds the 45-cell token → fits.
	cellW := 39
	spanW := DefaultFlex.spanWidth(cellW, 2)
	spanned := Node{Lines: []string{strings.Repeat("x", 45)}, Width: spanW, Span: 2}
	if !DefaultFlex.Fits([]Node{spanned}) {
		t.Errorf("Fits = false for a 45-cell token in a span-2 cell of width %d; want true", spanW)
	}

	// A mixed set fits only if EVERY node fits — one overflowing node fails the set.
	ok := Node{Lines: []string{"short", "lines"}, Width: 20, Span: 1}
	if DefaultFlex.Fits([]Node{ok, overflow}) {
		t.Errorf("Fits = true for a set containing an overflowing node; want false (all-or-nothing)")
	}
	if !DefaultFlex.Fits([]Node{ok, spanned}) {
		t.Errorf("Fits = false for a set where every node fits; want true")
	}
}

// moduleRootFrom walks up from the test's cwd to the directory that owns go.mod.
// The tripwire below must grep the WHOLE module (single-module repo, verified), not
// just the pdrender package dir — a divide-formula copy planted in internal/cli/ or
// anywhere else must red the test, and a grep rooted at the package dir structurally
// cannot see it.
func moduleRootFrom(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found walking up from the test cwd — cannot root the divide-formula grep")
		}
		dir = parent
	}
}

// trackedGoFiles enumerates the module's OWN tracked .go files, repo-relative.
//
// THIS IS THE SCOPING INSTRUMENT, and it is the whole fix. The tripwire below
// used to shell out to `grep -rn --include=*.go <pattern> .` rooted here. That
// walk cannot tell the module apart from copies of the module: this repo hosts
// agent worktrees under .claude/worktrees/ and .omx/, each a full checkout, so
// the walk found 228 copies of joincols.go and the guard drowned in its own
// reflections — a guaranteed ~150s FAIL in any working copy that has them, and
// a guard that could no longer distinguish a real violation from an echo.
//
// Those trees are gitignored (.gitignore:118), which is exactly why CI never
// saw this: a fresh actions/checkout has no worktrees, so go-tests.yml on main
// stayed green while every local dev with agent worktrees ate a false red.
// `git ls-files` inherits that same ignore semantics deliberately — it reports
// what the module TRACKS, which is precisely the domain the tripwire means to
// police, since a real violation arrives as committed code.
//
// Enumerating here also lets the match run in-process below, so the guard no
// longer depends on grep's semantics at all. That matters on this host: an
// interactive `grep` is a ugrep wrapper carrying --ignore-files, while
// exec.Command resolves the real grep from PATH — the two disagree about
// ignored paths, so a guard built on grep behaves differently depending on who
// runs it. Go's regexp is the same engine everywhere.
func trackedGoFiles(t *testing.T, root string) []string {
	t.Helper()
	cmd := exec.Command("git", "ls-files", "-z", "--", "*.go")
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git ls-files failed in %s (the tripwire cannot scope its walk): %v", root, err)
	}
	files := []string{}
	for _, p := range strings.Split(string(out), "\x00") {
		if p != "" {
			files = append(files, p)
		}
	}
	// A check that enumerates nothing would pass vacuously. Red instead.
	if len(files) == 0 {
		t.Fatal("git ls-files reported zero tracked .go files — the tripwire would pass vacuously")
	}
	return files
}

// TestNoInlineDivideFormulaOutsideSolver is the "one solver" tripwire: NO renderer
// anywhere in the module may re-inline the per-cell width divide-formula assignment.
// joincols.go is the single owner (and joincols_test.go carries the pattern as data);
// a copy reappearing in any other .go file — a fresh renderer, internal/cli/, a web
// helper — reds this test. Scoped to the module's TRACKED sources (see
// trackedGoFiles), so it keeps repo-wide reach over the real module without
// mistaking nested agent checkouts for it.
func TestNoInlineDivideFormulaOutsideSolver(t *testing.T) {
	root := moduleRootFrom(t)
	// The same pattern the shelled-out grep asserted: the divide-formula
	// assignment to cellW whose right-hand side mentions the gutter.
	pattern := regexp.MustCompile(`cellW *:=.*[Gg]utter`)

	lines := []string{}
	ownerSeen := false
	for _, rel := range trackedGoFiles(t, root) {
		body, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			// A tracked file we cannot read is an unreadable guard, not a pass.
			t.Fatalf("reading tracked file %s (tripwire cannot run): %v", rel, err)
		}
		// The solver itself is the one allowed OWNER; its test file legitimately
		// carries the pattern as the match string / measured fixtures.
		owner := rel == "internal/pdrender/joincols.go" || rel == "internal/pdrender/joincols_test.go"
		for i, ln := range strings.Split(string(body), "\n") {
			if !pattern.MatchString(ln) {
				continue
			}
			if owner {
				ownerSeen = true
				continue
			}
			lines = append(lines, fmt.Sprintf("%s:%d:%s", rel, i+1, strings.TrimSpace(ln)))
		}
	}
	// Liveness self-check: the solver ALWAYS carries the formula. Zero allowlisted
	// hits means the pattern drifted from the code and the tripwire is dead.
	if !ownerSeen {
		t.Fatal("divide-formula pattern matched nothing in the joincols solver — the tripwire regex has drifted and guards nothing")
	}
	if len(lines) > 0 {
		t.Errorf("inline divide-formula copies remain outside the joincols solver:\n%s", strings.Join(lines, "\n"))
	}
}

// bpEntry is a single {minWidth, tracks} breakpoint as it decodes from JSON
// (numbers arrive as float64, but attrInt tolerates int too — we use int here
// for readability; the resolution rule is agnostic to the encoding).
func bpEntry(minWidth, tracks int) map[string]any {
	return map[string]any{"minWidth": minWidth, "tracks": tracks}
}

// TestEffectiveTracks pins the ratified breakpoint resolution rule (pd-layout-
// engine W3): the valid {minWidth,tracks} entries are sorted DESC by minWidth
// and the FIRST whose minWidth <= avail wins; below EVERY threshold the grid
// collapses to a single stacked track; absent / empty / all-malformed
// breakpoints fall back to the fixed gridTracks(layout["tracks"]). The section
// grid in sample_m9 carries breakpoints [{100,3},{70,2}] with tracks:3.
func TestEffectiveTracks(t *testing.T) {
	// The canonical m9 layout: two thresholds over a base tracks:3.
	m9 := map[string]any{
		"tracks": 3,
		"breakpoints": []any{
			bpEntry(100, 3),
			bpEntry(70, 2),
		},
	}
	// Deliberately UNSORTED input to prove effectiveTracks sorts DESC itself and
	// does not lean on author ordering.
	unsorted := map[string]any{
		"tracks": 3,
		"breakpoints": []any{
			bpEntry(70, 2),
			bpEntry(100, 3),
		},
	}

	cases := []struct {
		name   string
		layout map[string]any
		avail  int
		want   int
	}{
		// avail >= 100 → the 100-threshold wins → 3 tracks.
		{"at-or-above top threshold", m9, 120, 3},
		// 70 <= avail < 100 → the 70-threshold wins (NOT the 100), proving the
		// DESC-sort first-match picks the largest threshold that still fits, not
		// merely any matching entry.
		{"middle threshold", m9, 80, 2},
		// avail below every threshold → single stacked track.
		{"below all thresholds (60)", m9, 60, 1},
		{"below all thresholds (40)", m9, 40, 1},
		// Same three answers regardless of author ordering.
		{"unsorted input still picks top", unsorted, 120, 3},
		{"unsorted input still picks middle", unsorted, 80, 2},
		{"unsorted input still collapses", unsorted, 40, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := effectiveTracks(tc.layout, tc.avail); got != tc.want {
				t.Errorf("effectiveTracks(avail=%d) = %d, want %d", tc.avail, got, tc.want)
			}
		})
	}
}

// TestEffectiveTracksFallback proves that when NO usable breakpoints are present
// the resolver falls back to the fixed gridTracks(layout["tracks"]) — so a
// section without breakpoints is unchanged at any width (this is what keeps the
// existing corpus byte-identical). Covers absent, empty, and all-malformed.
func TestEffectiveTracksFallback(t *testing.T) {
	cases := []struct {
		name   string
		layout map[string]any
		want   int // gridTracks over the layout's tracks field
	}{
		// No breakpoints key at all → fixed tracks:4.
		{"absent breakpoints", map[string]any{"tracks": 4}, 4},
		// Present but empty array → fixed tracks:4.
		{"empty breakpoints", map[string]any{"tracks": 4, "breakpoints": []any{}}, 4},
		// Missing tracks entirely → gridTracks default of 2.
		{"absent breakpoints, no tracks", map[string]any{}, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Fallback must be width-invariant: same answer at every golden width.
			for _, avail := range goldenWidths {
				if got := effectiveTracks(tc.layout, avail); got != tc.want {
					t.Errorf("effectiveTracks(avail=%d) = %d, want fixed %d", avail, got, tc.want)
				}
			}
		})
	}
}

// TestEffectiveTracksMalformedSkipped proves malformed entries are IGNORED, not
// fatal: an entry that is not an object, or is missing minWidth, or carries
// tracks<1, is skipped. A valid entry alongside malformed ones still resolves;
// if EVERY entry is malformed the resolver falls back to the fixed tracks.
func TestEffectiveTracksMalformedSkipped(t *testing.T) {
	// One good entry {80,2} buried among junk: a non-object, an entry with no
	// minWidth, and an entry with tracks:0. Only {80,2} is usable.
	mixed := map[string]any{
		"tracks": 5,
		"breakpoints": []any{
			"not-an-object",
			map[string]any{"tracks": 3},                 // missing minWidth → skip
			map[string]any{"minWidth": 90, "tracks": 0}, // tracks<1 → skip
			bpEntry(80, 2),                              // the one usable entry
		},
	}
	if got := effectiveTracks(mixed, 120); got != 2 {
		t.Errorf("effectiveTracks with one usable entry {80,2} at avail=120 = %d, want 2", got)
	}
	// Below the one usable threshold → collapse to 1 (NOT the fixed tracks:5).
	if got := effectiveTracks(mixed, 50); got != 1 {
		t.Errorf("effectiveTracks below the one usable threshold = %d, want 1 (collapse)", got)
	}

	// ALL entries malformed → no usable breakpoints → fall back to fixed tracks:5.
	allBad := map[string]any{
		"tracks": 5,
		"breakpoints": []any{
			"junk",
			map[string]any{"tracks": 2}, // missing minWidth
			map[string]any{"minWidth": 60, "tracks": -1}, // tracks<1
		},
	}
	for _, avail := range goldenWidths {
		if got := effectiveTracks(allBad, avail); got != 5 {
			t.Errorf("effectiveTracks(avail=%d) with all-malformed breakpoints = %d, want fixed 5", avail, got)
		}
	}
}

// TestGapGutter pins the gap vocabulary (pd-layout-engine W3): none·sm·md·lg map
// to inter-cell gutters 0·1·2·4. The load-bearing default is md=2: any absent,
// unknown, or non-string token yields 2 == DefaultFlex.Gutter, which is exactly
// what keeps a gap-less section byte-identical to today's corpus. Case- and
// whitespace-insensitive.
func TestGapGutter(t *testing.T) {
	cases := []struct {
		name  string
		token any
		want  int
	}{
		{"none", "none", 0},
		{"sm", "sm", 1},
		{"md", "md", 2},
		{"lg", "lg", 4},
		// The corpus-freezing default: everything that is not an explicit token
		// resolves to md=2 (== DefaultFlex.Gutter).
		{"unknown string", "wat", 2},
		{"nil", nil, 2},
		{"non-string (int)", 3, 2},
		{"empty string", "", 2},
		// Case- and whitespace-insensitive so authoring is forgiving.
		{"uppercase LG", "LG", 4},
		{"padded none", "  none  ", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := gapGutter(tc.token); got != tc.want {
				t.Errorf("gapGutter(%#v) = %d, want %d", tc.token, got, tc.want)
			}
		})
	}
	// Guard the invariant that makes the corpus stay frozen: the default equals
	// the solver's gutter.
	if gapGutter(nil) != DefaultFlex.Gutter {
		t.Errorf("gapGutter default %d != DefaultFlex.Gutter %d — a gap-less section would shift", gapGutter(nil), DefaultFlex.Gutter)
	}
}
