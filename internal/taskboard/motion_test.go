package taskboard

import (
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
