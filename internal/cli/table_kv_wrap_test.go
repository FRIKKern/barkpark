package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
	"github.com/charmbracelet/x/ansi"
)

// kvWrapWidthTestCols is the window every test here pins. 80 is the width the
// defect was reported at and the one a wrap must be measured at: a width read
// from the harness's own terminal would make these tests pass or fail on which
// machine ran them.
const kvWrapWidthTestCols = 80

// kvLinesAt renders one key/value pair at a pinned width and returns the lines.
func kvLinesAt(t *testing.T, width int, obj map[string]any) []string {
	t.Helper()
	out, buf, _ := newTestWriter()
	out.kvWrapWidth = width
	renderKV(out, obj)
	return strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
}

// TestRenderKVHangsLongValuesAtTheValueColumn is the arm. renderKV padded the
// key and printed the value as the rest of the line, so a ~200-cell status
// value became three terminal hard-wraps: broken mid-word, each continuation
// restarting at column 0 UNDER the key, where it reads as a new key. This
// asserts the three properties a wrap must have and that a hard wrap never has.
//
// REVERT-REDS: drop the wrap from renderKV and every one of the three fails —
// the render is one line, so the line-count check, the width check, and the
// hanging-indent check all go.
func TestRenderKVHangsLongValuesAtTheValueColumn(t *testing.T) {
	const long = "live — the NEWEST deploy was DEFERRED by the box (nothing newer than it is on the page this status read, so whether a rebuild has been re-queued is not visible from here — it is not evidence your publish was dropped)"

	lines := kvLinesAt(t, kvWrapWidthTestCols, map[string]any{
		"status":            long,
		"newest deployment": "dep-77",
	})

	// The value column: widest key ("newest deployment", 17) + the 2-cell gutter.
	const valueCol = len("newest deployment") + 2

	var statusLines []string
	for i, l := range lines {
		if strings.HasPrefix(l, "status") {
			statusLines = lines[i:]
			break
		}
	}
	if len(statusLines) < 2 {
		t.Fatalf("a %d-cell value in an %d-column window must occupy MORE THAN ONE line; got %d:\n%s",
			ansi.StringWidth(long), kvWrapWidthTestCols, len(statusLines), strings.Join(lines, "\n"))
	}

	for _, l := range lines {
		if w := ansi.StringWidth(l); w > kvWrapWidthTestCols {
			t.Errorf("no rendered line may exceed the %d-column window; %q is %d cells",
				kvWrapWidthTestCols, l, w)
		}
	}

	for i, l := range statusLines[1:] {
		if !strings.HasPrefix(l, strings.Repeat(" ", valueCol)) {
			t.Errorf("continuation %d must HANG at the value column (%d spaces), not restart under the key: %q",
				i+1, valueCol, l)
		}
		if strings.HasPrefix(l, strings.Repeat(" ", valueCol+1)) {
			t.Errorf("continuation %d is indented PAST the value column — the block no longer aligns: %q", i+1, l)
		}
	}

	// The COPY is untouched: the wrap is a renderer change, so re-joining the
	// segments on the spaces the wrap consumed must reproduce the sentence the
	// wave decided to say, character for character.
	rejoined := strings.TrimSpace(statusLines[0][len("status")+2:])
	for _, l := range statusLines[1:] {
		rejoined += " " + strings.TrimSpace(l)
	}
	if rejoined != long {
		t.Errorf("the wrap must not alter the sentence.\n want: %q\n  got: %q", long, rejoined)
	}
}

// TestRenderKVLeavesAFittingValueOnOneLine is the QUIET arm: a value that fits
// must render byte-identically to the pre-wrap renderer — one line, the key
// padded, two spaces, the value, no trailing pad and no hanging continuation.
// Without it a wrap that fires unconditionally (or off a stale width) would
// pass the arm above while shredding every short value in the CLI.
func TestRenderKVLeavesAFittingValueOnOneLine(t *testing.T) {
	lines := kvLinesAt(t, kvWrapWidthTestCols, map[string]any{
		"status": "live",
		"slug":   "auto-proof",
	})
	want := []string{"slug    auto-proof", "status  live"}
	if len(lines) != len(want) {
		t.Fatalf("fitting values must render one line each; got %d:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	for i := range want {
		if lines[i] != want[i] {
			t.Errorf("line %d must be byte-identical to the un-wrapped render\n want: %q\n  got: %q", i, want[i], lines[i])
		}
	}
}

// TestRenderKVWrapsOnDisplayCellsNotBytes is the non-ASCII arm. A wrapper keyed
// on len() or on rune count mis-measures everything this CLI actually renders:
// a CJK ideograph is 3 bytes / 1 rune / TWO columns, and the status surfaces
// carry ↺ ✓ → and emoji. Both failures are visible here — a byte-keyed wrap
// would split a multi-byte rune (the round-trip check catches it) and a
// rune-keyed wrap would emit lines up to twice the window (the width check).
func TestRenderKVWrapsOnDisplayCellsNotBytes(t *testing.T) {
	// 60 ideographs = 60 runes, 180 bytes, 120 display cells.
	wide := strings.Repeat("台", 60)
	// A mixed value: emoji (2 cells each) and box-drawing glyphs among ASCII.
	mixed := strings.Repeat("✓ ok ↺ deferred 🚀 ", 12)

	for _, tc := range []struct{ name, value string }{
		{"cjk", wide},
		{"emoji-and-arrows", mixed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			lines := kvLinesAt(t, kvWrapWidthTestCols, map[string]any{"status": tc.value})
			if len(lines) < 2 {
				t.Fatalf("a %d-cell value must wrap in an %d-column window; got one line", ansi.StringWidth(tc.value), kvWrapWidthTestCols)
			}
			for _, l := range lines {
				if w := ansi.StringWidth(l); w > kvWrapWidthTestCols {
					t.Errorf("a display-width wrap keeps every line within %d cells; %q is %d", kvWrapWidthTestCols, l, w)
				}
			}
			joined := strings.Join(lines, "")
			if strings.Contains(joined, "\uFFFD") {
				t.Errorf("the wrap split a multi-byte rune — U+FFFD in the output:\n%s", strings.Join(lines, "\n"))
			}
		})
	}
}

// TestRenderKVDegenerateWidthsDoNotShredOrHang pins the three answers a width
// that cannot be honoured must give. A window narrower than the value column is
// not a crash and not a one-glyph-per-line column: it is the unwrapped line,
// which is exactly today's behaviour and what the terminal can still hard-wrap.
func TestRenderKVDegenerateWidthsDoNotShredOrHang(t *testing.T) {
	const long = "the box refused this round; nothing was built and nothing was switched, so visitors still see the previous build"
	obj := map[string]any{"deferral": long}
	// valueCol here is len("deferral")+2 = 10, so 10..29 are all below the
	// kvMinValueWidth floor and 0/-1 are the unresolvable cases.
	for _, width := range []int{-1, 0, 1, 2, 11, 12, 29} {
		lines := kvLinesAt(t, width, obj)
		if len(lines) != 1 {
			t.Errorf("width %d cannot support a readable value column, so the value must stay on ONE line; got %d:\n%s",
				width, len(lines), strings.Join(lines, "\n"))
		}
		if !strings.HasSuffix(lines[0], long) {
			t.Errorf("width %d must render the value verbatim; got %q", width, lines[0])
		}
	}
	// And the first width that CLEARS the floor does wrap — without this the
	// loop above would pass for a renderer that never wraps at all.
	if lines := kvLinesAt(t, 30, obj); len(lines) < 2 {
		t.Errorf("width 30 clears the value-column floor (10+20) and must wrap; got:\n%s", strings.Join(lines, "\n"))
	}
}

// TestRenderKVDoesNotWrapWhenPiped is the blast-radius fence. renderKV feeds
// grep, goldens, and `bp ... | while read`, all of which want one value per
// line. A writer with no sizeable terminal (every test writer, every pipe)
// therefore gets the unwrapped line — the wrap is a TTY affordance, not a
// change to what the CLI emits into a pipe.
func TestRenderKVDoesNotWrapWhenPiped(t *testing.T) {
	const long = "live — the NEWEST deploy was DEFERRED by the box (nothing newer than it is on the page this status read, so whether a rebuild has been re-queued is not visible from here — it is not evidence your publish was dropped)"
	out, buf, _ := newTestWriter()
	out.isTTY = true // even CLAIMING a tty: the stdout here is a buffer, not sizeable
	renderKV(out, map[string]any{"status": long})
	if got := strings.Count(strings.TrimRight(buf.String(), "\n"), "\n"); got != 0 {
		t.Errorf("a writer whose stdout is not a sizeable terminal must not wrap; got %d extra lines:\n%s", got, buf.String())
	}
}

// TestSiteStatusDeferredNewestSentenceSurvivesTheWrap drives the ACTUAL defect
// surface — spawnSiteStatusMap → renderKV, the path the W14 finding named —
// rather than a hand-built map, so a change to how the status value is
// assembled cannot make this pass vacuously. Criterion 2 lives here: the
// sentence is the wave's decision, and the fix is the renderer.
func TestSiteStatusDeferredNewestSentenceSurvivesTheWrap(t *testing.T) {
	site := cloudclient.SpawnSite{ID: "site-1", Name: "search", Slug: "search", Kind: "static"}
	deferred := cloudclient.SiteDeployment{ID: "dep-9", Status: "deferred"}

	m := spawnSiteStatusMap(site, nil, &deferred, []cloudclient.SiteDeployment{deferred})
	status, _ := m["status"].(string)
	// ANTI-VACUITY: the arm below measures the WRAP, so prove the surface still
	// produces the long deferred-newest sentence before asserting on its shape.
	if !strings.Contains(status, "DEFERRED by the box") || ansi.StringWidth(status) < 120 {
		t.Fatalf("the deferred-newest status sentence is the subject of this test; got %q", status)
	}

	out, buf, _ := newTestWriter()
	out.kvWrapWidth = kvWrapWidthTestCols
	renderKV(out, m)
	for _, l := range strings.Split(strings.TrimRight(buf.String(), "\n"), "\n") {
		if w := ansi.StringWidth(l); w > kvWrapWidthTestCols {
			t.Errorf("`bp cloud site status` must fit an %d-column terminal; %q is %d cells", kvWrapWidthTestCols, l, w)
		}
	}
	// The copy is unchanged: the honest blind-spot clause is still the sentence.
	if !strings.Contains(status, "whether a rebuild has been re-queued is not visible from here") {
		t.Errorf("the fix is the renderer, not the copy — the blind-spot clause must survive: %q", status)
	}
}

// TestRenderKVDoesNotPaintWrappedSegments is a CONTROL PAIR, and the control is
// the point: the status painter keys on the WHOLE cell (statusRole/semrole.Color
// match a bare "failed", never a sentence containing it), so painting each
// wrapped segment would colour whichever line the wrap happened to isolate a
// token onto — one arbitrarily green line in the middle of a paragraph.
//
// The pair: the SAME token, same writer, same width. Alone it must still paint
// (or this test would pass against a renderer that had simply lost colour), and
// as the tail of a wrapped sentence it must not.
func TestRenderKVDoesNotPaintWrappedSegments(t *testing.T) {
	var sout, serr bytes.Buffer
	w := coloredWriter(&sout, &serr, pdrender.ANSI16, true)
	w.kvWrapWidth = kvWrapWidthTestCols

	// CONTROL: the token on its own still paints. Without this arm, a renderer
	// with colour switched off entirely would satisfy the assertion below.
	renderKV(w, map[string]any{"status": "failed"})
	if !strings.Contains(sout.String(), "\033[") {
		t.Fatalf("CONTROL: a bare status token must still be painted; got %q", sout.String())
	}

	sout.Reset()
	// The value column is len("status")+2 = 8, so the value gets 72 cells. A
	// 72-cell first token exactly fills line one and pushes the token ALONE onto
	// line two — which is the whole hazard: a per-segment painter would key on
	// that isolated "failed" and colour it. A sentence that merely CONTAINS the
	// token proves nothing here, because the wrap would never isolate it and the
	// painter would decline for the ordinary reason.
	const valueCol = len("status") + 2
	long := strings.Repeat("x", kvWrapWidthTestCols-valueCol) + " failed"
	renderKV(w, map[string]any{"status": long})
	got := sout.String()
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	// PRECONDITION, not a control: assert the SETUP the assertion depends on.
	// If the wrap does not isolate the bare token, the painter has nothing to
	// key on and the check below is green with no subject.
	if len(lines) < 2 {
		t.Fatalf("PRECONDITION: the value must actually WRAP or this measures nothing:\n%s", got)
	}
	if last := strings.TrimSpace(lines[len(lines)-1]); last != "failed" {
		t.Fatalf("PRECONDITION: the wrap must ISOLATE the bare status token on its own line for the painter to have a subject; last line is %q", last)
	}
	if strings.Contains(got, "\033[") {
		t.Errorf("a wrapped value is prose — no segment may be painted as a status token, even one the wrap isolated:\n%q", got)
	}
}
