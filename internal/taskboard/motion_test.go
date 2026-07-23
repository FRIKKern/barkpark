package taskboard

import (
	"fmt"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// motionNow is the injected clock the motion unit tests measure against.
var motionNow = time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)

func TestLiveElapsed(t *testing.T) {
	cases := []struct {
		name    string
		claimed time.Time
		want    string
	}{
		{"zero time renders nothing", time.Time{}, ""},
		{"just now", motionNow, "0s"},
		{"sub-minute seconds", motionNow.Add(-47 * time.Second), "47s"},
		{"one second before the minute", motionNow.Add(-59 * time.Second), "59s"},
		{"minute boundary flips to m+s", motionNow.Add(-60 * time.Second), "1m00s"},
		{"minutes and seconds", motionNow.Add(-(3*time.Minute + 42*time.Second)), "3m42s"},
		{"seconds zero-padded for a stable width", motionNow.Add(-(3*time.Minute + 5*time.Second)), "3m05s"},
		{"just under ten minutes keeps seconds", motionNow.Add(-(9*time.Minute + 59*time.Second)), "9m59s"},
		{"ten minutes exactly falls back to AgeBadge", motionNow.Add(-10 * time.Minute), "10m"},
		{"past ten minutes is coarse minutes", motionNow.Add(-14 * time.Minute), "14m"},
		{"hours use AgeBadge vocabulary", motionNow.Add(-3 * time.Hour), "3h"},
		{"days use AgeBadge vocabulary", motionNow.Add(-2 * 24 * time.Hour), "2d"},
		{"clock skew clamps to zero, never negative", motionNow.Add(90 * time.Second), "0s"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := LiveElapsed(tc.claimed, motionNow); got != tc.want {
				t.Errorf("LiveElapsed(%v) = %q, want %q", tc.claimed, got, tc.want)
			}
		})
	}
}

// TestLiveElapsedMatchesAgeBadgePastBoundary pins the hand-off: at and past ten
// minutes LiveElapsed IS AgeBadge, so the token reads identically to every other
// age on the board once the seconds stop being useful.
func TestLiveElapsedMatchesAgeBadgePastBoundary(t *testing.T) {
	for _, d := range []time.Duration{tenMinutes, 11 * time.Minute, 90 * time.Minute, 50 * time.Hour} {
		claimed := motionNow.Add(-d)
		if got, want := LiveElapsed(claimed, motionNow), AgeBadge(claimed, motionNow); got != want {
			t.Errorf("at %s: LiveElapsed = %q, AgeBadge = %q — should match past the boundary", d, got, want)
		}
	}
}

// TestLiveElapsedTicksEverySecond proves the second hand actually moves under
// ten minutes — the whole point of the NOW-band elapsed (motion is proportional
// to real work, so where work runs the token must visibly advance).
func TestLiveElapsedTicksEverySecond(t *testing.T) {
	base := motionNow.Add(-30 * time.Second)
	a := LiveElapsed(base, motionNow)
	b := LiveElapsed(base, motionNow.Add(time.Second))
	if a == b {
		t.Errorf("elapsed did not tick across a second: %q == %q", a, b)
	}
}

// TestFlashStyleLadder proves the one-shot ladder on the style PROPERTIES (not
// rendered bytes — the test runner's color profile drops ANSI, which would make
// a byte assertion vacuous): level 2 is bold in the info hue, level 1 is a faint
// remnant in the SAME info hue (not the zinc dim), level 0 is a zero-value no-op
// so a settled row emits nothing. Crucially NEITHER active level sets a
// background — the flash is a foreground tint only (decision 17), so it can
// never widen a cell or paint a block.
func TestFlashStyleLadder(t *testing.T) {
	info := infoStyle.GetForeground()

	// Level 0 is the zero value: no emphasis, and a pure pass-through render so a
	// still row is byte-identical to the pre-slice frame.
	z := flashStyle(0)
	if z.GetBold() || z.GetFaint() || z.GetForeground() != (lipgloss.NoColor{}) {
		t.Errorf("flashStyle(0) is not a zero-value style")
	}
	if got := z.Render("x"); got != "x" {
		t.Errorf("flashStyle(0) added styling to a settled row: %q", got)
	}

	// Level 2: bright — bold, info foreground, no background block.
	two := flashStyle(2)
	if !two.GetBold() {
		t.Errorf("flashStyle(2) is not bold")
	}
	if two.GetForeground() != info {
		t.Errorf("flashStyle(2) foreground = %v, want the info role %v", two.GetForeground(), info)
	}
	if two.GetBackground() != (lipgloss.NoColor{}) {
		t.Errorf("flashStyle(2) set a background block (decision 17 forbids it)")
	}

	// Level 1: fading remnant — faint, the SAME info hue (a single decaying
	// signal, not a hue swap to dim), no background block.
	one := flashStyle(1)
	if !one.GetFaint() {
		t.Errorf("flashStyle(1) is not faint")
	}
	if one.GetForeground() != info {
		t.Errorf("flashStyle(1) foreground = %v, want the info role %v", one.GetForeground(), info)
	}
	if one.GetBackground() != (lipgloss.NoColor{}) {
		t.Errorf("flashStyle(1) set a background block (decision 17 forbids it)")
	}

	// The two active levels are distinct (bright vs remnant).
	if one.GetBold() || !two.GetBold() {
		t.Errorf("flash levels 1 and 2 are not distinguishable by weight")
	}
}

// ── Narrow-mode reading-frame rail-stop hover (charter D99 close-out / D105) ──
//
// mouseMotion gained a reading-frame branch resolving the compose-level hit map
// into UIState.HoverStop, so a pushed FrameTask/FramePaper tints the rail stop
// under the pointer exactly as the wide right pane already did. These drive real
// tea.MouseMsg motion through the FULL reducer (Update → handleMouse →
// mouseMotion) and pin: set on a stop, clear off a stop, clear on a keypress, and
// the board path staying hover-tint-only (never touching HoverStop).

// narrowReadingFixture is a narrow model pushed one level into a FrameTask whose
// subject "p" has nChildren parent-linked children — so the reading frame renders
// a CHILDREN rail of nChildren selectable stops. Callers set width/height; the
// clock is fixed. Shared by the motion, paint, and parity tests.
func narrowReadingFixture(nChildren int) Model {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	p := t("p")
	tasks := []Task{p}
	for i := 0; i < nChildren; i++ {
		id := fmt.Sprintf("ch%02d", i)
		tasks = append(tasks, Task{DocID: id, Title: id, ParentID: "p"})
	}
	m.tasks = tasks
	m.details = DetailIndex{"p": {Task: p}}
	m.stack = append(m.stack, Frame{Kind: FrameTask, Ref: "p", Title: "p"})
	return m
}

// firstStopY returns the first ComposeHitMap screen row that carries the given
// rail-stop index (a LineSpineRow), or -1 — the reading-frame twin of
// firstLineFor's board use.
func firstStopY(hits []LineTarget, stopIdx int) int {
	for i, h := range hits {
		if h.Kind == LineSpineRow && h.CursorIndex == stopIdx {
			return i
		}
	}
	return -1
}

// TestNarrowMotionHoversRailStop drives a Motion through the reducer over a
// pushed FrameTask and asserts the D105 wiring: the pointer over a rail stop
// stores that stop's index in HoverStop; the pointer over the breadcrumb chrome
// clears it to -1; and a subsequent keypress also clears it (handleKey yields the
// tint back to the keyboard). Tall enough (height 40) that every stop is
// on-screen, so the resolution is unambiguous.
func TestNarrowMotionHoversRailStop(t2 *testing.T) {
	m := narrowReadingFixture(3)
	m.width, m.height = 44, 40
	if m.topFrame().Kind != FrameTask {
		t2.Fatalf("fixture top frame is %v, want FrameTask", m.topFrame().Kind)
	}
	if m.frameStopCount() < 2 {
		t2.Fatalf("reading frame has %d stops, want >=2 (the CHILDREN rail)", m.frameStopCount())
	}

	const stop = 1
	y := firstStopY(m.ComposeHitMap(), stop)
	if y < 0 {
		t2.Fatalf("no hit-map line for rail stop %d", stop)
	}

	// Motion over the stop → HoverStop set, navigation untouched.
	m2, _ := step(t2, m, motionAt(5, y))
	if m2.ui.HoverStop != stop {
		t2.Fatalf("motion over stop %d set HoverStop %d, want %d", stop, m2.ui.HoverStop, stop)
	}
	if m2.topFrame().Cursor != 0 || len(m2.stack) != 2 {
		t2.Fatalf("motion mutated navigation: cursor=%d depth=%d", m2.topFrame().Cursor, len(m2.stack))
	}

	// Motion onto the breadcrumb (screen row 1, chrome) → cleared to -1.
	m3, _ := step(t2, m2, motionAt(5, 1))
	if m3.ui.HoverStop != -1 {
		t2.Fatalf("motion onto chrome kept HoverStop %d, want -1", m3.ui.HoverStop)
	}

	// Re-hover the stop, then a keypress hands the tint back to the keyboard.
	m4, _ := step(t2, m3, motionAt(5, y))
	if m4.ui.HoverStop != stop {
		t2.Fatalf("re-hover set HoverStop %d, want %d", m4.ui.HoverStop, stop)
	}
	m5, _ := step(t2, m4, runes("j"))
	if m5.ui.HoverStop != -1 {
		t2.Fatalf("keypress did not clear HoverStop: %d, want -1", m5.ui.HoverStop)
	}
}

// TestNarrowMotionBoardPathUnchanged proves the reading-frame branch did NOT
// bleed into the board path: at depth 0 a Motion still tints the board row's Ref
// (HoverTarget) and never touches HoverStop, which stays its -1 default.
func TestNarrowMotionBoardPathUnchanged(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40
	m.ui.Cursor = 0
	syncScroll(&m)

	const target = 4 // a task row
	y := firstLineFor(m.ComposeHitMap(), target)
	if y < 0 {
		t2.Fatal("no hit-map line for target row 4")
	}
	wantRef := m.visibleRows()[target].docID

	m2, _ := step(t2, m, motionAt(5, y))
	if m2.ui.HoverTarget != wantRef {
		t2.Fatalf("board motion set HoverTarget %q, want %q", m2.ui.HoverTarget, wantRef)
	}
	if m2.ui.HoverStop != -1 {
		t2.Fatalf("board motion touched HoverStop: %d, want -1 (board path unchanged)", m2.ui.HoverStop)
	}
}
