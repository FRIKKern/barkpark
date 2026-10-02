package pdrender

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── the grid widgets' full-bleed width model ─────────────────────────────────
//
// pd-le-compose-fullbleed-parity, Step 2a. The canonical reader STRETCHES the
// notes / cards / pipeline widgets: measured headless over the emitter's frozen
// golden HTML in the reader's own container geometry (18 cases = 3 families x
// stream/section-grid-cell x 1280/700/390 px), the widget's outer right gap was
// 0.00 px in 18 of 18 and the last child's in 15 of 15 measured cases, while a
// genuinely shrink-to-fit .bp-stat in the SAME run read 450/482/228 px and a
// deliberate sabotage moved the child gap to 286.19/128/38.59 px. And the
// emitter (api/lib/barkpark/portable_doc/render/components.ex) never reads the
// block's `layout` key, so the reader answers ONE width model for BOTH the
// stacked and the horizontal arrangement.
//
// These tests hold pdrender to that: each family fills the content width in
// BOTH orientations, with no one-sided Path-A. They assert on the RENDERER, not
// on a golden file, so a regenerated golden can never make them agree with
// whatever the code happens to do.

// fullBleedWidths are surfaces wide enough that the horizontal path genuinely
// goes side-by-side (cellW >= MinWidth) AND narrow enough to exercise a
// non-zero floor-division remainder. 61/79/101 are deliberately awkward: with 3
// notes the packed row is 2, 1 and 2 columns short of the surface respectively,
// which is exactly the ragged margin this model forbids.
var fullBleedWidths = []int{60, 61, 79, 80, 100, 101, 120}

// shortLines returns "line i is w_i wide" for every line narrower than want. A
// blank line counts: after right-padding, a widget's rhythm line is want spaces,
// not "". Overlong lines are the no-overflow lock's business, not this one.
func shortLines(lines []string, want int) []string {
	var out []string
	for i, ln := range lines {
		if d := ansi.StringWidth(ln); d < want {
			out = append(out, fmt.Sprintf("line %d is %d wide (want %d): %q", i, d, want, ln))
		}
	}
	return out
}

// fullBleedBlocks are the three families, as the {stacked, grid} pair of Blocks
// that differ ONLY by the layout key — the same attrs either way, so a width
// difference between the two can only come from the orientation.
func fullBleedBlocks() map[string][2]Block {
	notes := map[string]any{"items": []any{
		map[string]any{"label": "First", "lead": "Wide lays out", "text": "The notes fan out into columns when the surface is wide."},
		map[string]any{"label": "Second", "text": "Each note wraps inside its own cell at the shared cell width."},
		map[string]any{"lead": "Third", "text": "Narrow it below the floor and the row stacks again."},
	}}
	cards := map[string]any{"items": []any{
		map[string]any{"title": "Info card", "text": "The info tone tints the box border.", "tone": "info"},
		map[string]any{"title": "OK card", "text": "A success card carries the ok tone.", "tone": "ok"},
		map[string]any{"title": "Warn card", "text": "A warning card draws the eye.", "tone": "warn"},
	}}
	pipeline := map[string]any{"nodes": []any{
		map[string]any{"kind": "ingest", "title": "Decode doc", "detail": "Parse the envelope into a block tree.", "source": "cli"},
		map[string]any{"kind": "emit", "title": "Write out", "detail": "Flush the composed lines to the terminal.", "source": "tui"},
	}}
	grid := func(attrs map[string]any) map[string]any {
		cp := make(map[string]any, len(attrs)+1)
		for k, v := range attrs {
			cp[k] = v
		}
		cp["layout"] = map[string]any{"mode": "grid"}
		return cp
	}
	return map[string][2]Block{
		"notes":    {{Type: "notes", Attrs: notes}, {Type: "notes", Attrs: grid(notes)}},
		"cards":    {{Type: "cards", Attrs: cards}, {Type: "cards", Attrs: grid(cards)}},
		"pipeline": {{Type: "pipeline", Attrs: pipeline}, {Type: "pipeline", Attrs: grid(pipeline)}},
	}
}

// TestGridWidgetsFullBleedBothOrientations is THE parity assertion: for each of
// notes / cards / pipeline, at every width, BOTH the default stacked render and
// the gridOptIn horizontal render reach the full content width on every line.
// Revert either half of the width model — drop the padGroupRight on a stacked
// tail, or hand Flex.Arrange the uniform cellW instead of Flex.StretchTracks —
// and this reds, naming the family, the orientation and the short line.
func TestGridWidgetsFullBleedBothOrientations(t *testing.T) {
	reg := testRegistry()
	for family, pair := range fullBleedBlocks() {
		for _, w := range fullBleedWidths {
			ctx := RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}
			for oi, orientation := range []string{"stacked", "grid"} {
				lines := reg.Render(pair[oi], ctx)
				for i := range lines {
					lines[i] = ansi.Strip(lines[i])
				}
				for _, msg := range shortLines(lines, w) {
					t.Errorf("%s/%s w%d: %s — the widget stops short of the content edge; the reader's gap here is 0.00px",
						family, orientation, w, msg)
				}
			}
		}
	}
}

// TestFullBleedCatchesAOneSidedPathA is the non-vacuity control. It rebuilds the
// two failure shapes this lock exists to forbid and asserts shortLines flags
// BOTH: a stacked tail left at its longest line, and a horizontal row left at
// the packed N*cellW+(N-1)*gutter. If either stops being caught, the assertion
// above has rotted into a green that means nothing.
func TestFullBleedCatchesAOneSidedPathA(t *testing.T) {
	const w = 80

	full := []string{strings.Repeat("x", w), strings.Repeat(" ", w)}
	if bad := shortLines(full, w); len(bad) != 0 {
		t.Fatalf("a full-bleed group was flagged short %v — the lock over-reports", bad)
	}

	// Failure shape 1 — the stacked half reverted: prose ends at its own length.
	stackedRagged := []string{"a short note row", strings.Repeat("x", w)}
	if bad := shortLines(stackedRagged, w); len(bad) == 0 {
		t.Fatal("an unpadded STACKED tail was not caught — the full-bleed lock is vacuous")
	}

	// Failure shape 2 — the horizontal half reverted: the row is the packed
	// width, so the floor-division remainder rides as a ragged right margin.
	cellW, sideBySide := DefaultFlex.Measure(w, 3)
	if !sideBySide {
		t.Fatalf("w%d/3 tracks did not go side-by-side (cellW=%d) — the control needs a side-by-side case", w, cellW)
	}
	packed := 3*cellW + 2*DefaultFlex.Gutter
	if packed >= w {
		t.Fatalf("packed width %d is not short of %d — pick a width whose divide leaves a remainder", packed, w)
	}
	gridRagged := []string{strings.Repeat("y", packed)}
	if bad := shortLines(gridRagged, w); len(bad) == 0 {
		t.Fatalf("a packed-width HORIZONTAL row (%d of %d) was not caught — the full-bleed lock is vacuous", packed, w)
	}
}

// TestStretchTracksSpendsTheRemainder pins the arithmetic StretchTracks adds on
// top of Measure: the tracks total the surface EXACTLY, no track is more than
// one column off any other, and the extra columns go to the leading tracks. The
// gutter-only identity (sum + gutters == avail) is the property the reader's
// `1fr` gives for free and integer division does not.
func TestStretchTracksSpendsTheRemainder(t *testing.T) {
	for _, avail := range []int{40, 59, 60, 61, 79, 80, 100, 101, 120, 121} {
		for _, tracks := range []int{1, 2, 3, 4, 5, 7} {
			cellW, _ := DefaultFlex.Measure(avail, tracks)
			if cellW < 1 {
				continue // a surface too narrow to divide; the caller degrades first
			}
			ws := DefaultFlex.StretchTracks(avail, tracks, cellW)
			if len(ws) != tracks {
				t.Fatalf("avail=%d tracks=%d: got %d widths", avail, tracks, len(ws))
			}
			total := (tracks - 1) * DefaultFlex.Gutter
			for _, x := range ws {
				total += x
			}
			if total != avail {
				t.Errorf("avail=%d tracks=%d: widths %v + gutters total %d, want %d", avail, tracks, ws, total, avail)
			}
			for i, x := range ws {
				if x != cellW && x != cellW+1 {
					t.Errorf("avail=%d tracks=%d: track %d width %d is neither cellW=%d nor cellW+1", avail, tracks, i, x, cellW)
				}
				if i > 0 && ws[i] > ws[i-1] {
					t.Errorf("avail=%d tracks=%d: widths %v are not non-increasing — the remainder must go to the LEADING tracks", avail, tracks, ws)
				}
			}
		}
	}
}

// TestCardsBoxReachesTheContentEdge is the one assertion a group-level pad
// cannot satisfy on its own. A `cards` box is the only one of the three families
// whose child edge is VISIBLE (a rounded border), and the measurement says that
// edge sits flush with the container: outer gap 0.00px. Right-padding the group
// would hide a two-column-short box behind trailing spaces, so this measures the
// box itself — the last non-space column of every bordered line must be the
// content width, in both orientations.
//
// It is the arm for the cards half specifically: lipgloss Style.Width() sets the
// block width INCLUDING padding but EXCLUDING the border, so asking for
// width-chrome (W-4) draws W-2. Put the `- chrome` back and this reds.
func TestCardsBoxReachesTheContentEdge(t *testing.T) {
	reg := testRegistry()
	pair := fullBleedBlocks()["cards"]
	for _, w := range fullBleedWidths {
		ctx := RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}
		for oi, orientation := range []string{"stacked", "grid"} {
			for i, raw := range reg.Render(pair[oi], ctx) {
				line := ansi.Strip(raw)
				if !strings.ContainsAny(line, "╭╮╰╯│") {
					continue // a flat-degrade or prose line: no visible child edge
				}
				if edge := ansi.StringWidth(strings.TrimRight(line, " ")); edge != w {
					t.Errorf("cards/%s w%d: line %d's box edge is at column %d, want %d — the reader's card gap here is 0.00px: %q",
						orientation, w, i, edge, w, line)
				}
			}
		}
	}
}
