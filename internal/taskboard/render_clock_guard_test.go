package taskboard

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestRenderPathTakesItsClockFromTheCaller pins the property that makes every
// taskboard golden time-independent BY CONSTRUCTION rather than by luck: no
// rendering code in this package reads the wall clock. RenderTaskDetail and
// friends take `now time.Time` from the caller, and the goldens pass a fixed
// instant (detailNow, 2026-07-04T17:30Z). That is why a golden written months
// ago still renders "created 2d ago (Jul 02, 09:12)" today instead of decaying
// into "2mo ago" and going red every morning.
//
// A single `time.Now()` slipped onto the render path silently converts every
// golden in this package into a one-day-shelf-life fixture, and the resulting
// red looks exactly like an ordinary golden drift — so it gets "fixed" by
// regeneration, which buys one more day. This test is the thing that says the
// cause out loud instead.
//
// The rule is a predicate, not a snapshot: a wall-clock read is allowed only in
// a file that OWNS a clock (it is a data-fetch or a timing site, not a
// renderer), and the ratchet runs in both directions — an owner that no longer
// reads the clock is also an error, so the allowance can never silently widen
// past what it was granted for.
func TestRenderPathTakesItsClockFromTheCaller(t *testing.T) {
	// clockOwners are the non-rendering sites permitted to read the wall clock,
	// each with the reason the allowance exists. Nothing else in the package may.
	clockOwners := map[string]string{
		"detail_data.go": "snapshot assembly stamps the fetch instant it then PASSES to renderers",
		"events.go":      "measures elapsed time for the event-poll backoff; renders nothing",
		"wirelog.go":     "timestamps each wire read for the byte counter; renders nothing and is off unless BARKPARK_TASKBOARD_WIRELOG is set",
	}

	wallClock := regexp.MustCompile(`\btime\.Now\(\)`)

	// POSITIVE CONTROL. An empty scan must not be readable as a pass: prove the
	// matcher actually fires on the shape it is hunting before trusting a zero.
	if !wallClock.MatchString("\tnow := time.Now().UTC()") {
		t.Fatal("scanner does not match a real time.Now() call — every verdict below would be vacuous")
	}
	if wallClock.MatchString("\tnow := clock()") {
		t.Fatal("scanner matches an injected clock call — it would red on correct code")
	}

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}

	found := map[string]int{}
	scanned := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(filepath.Clean(name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		scanned++
		if n := len(wallClock.FindAll(src, -1)); n > 0 {
			found[name] = n
		}
	}

	// A scan that reached no files would report a clean render path having
	// measured nothing at all.
	if scanned == 0 {
		t.Fatal("scanned 0 non-test .go files in internal/taskboard — the scan measured nothing")
	}

	for name, n := range found {
		if _, ok := clockOwners[name]; !ok {
			t.Errorf("%s reads the wall clock %d time(s) via time.Now(). "+
				"Rendering code must take `now time.Time` from its caller — a wall-clock read here "+
				"makes every golden in this package expire the day after it is written. "+
				"If this file genuinely owns a clock (data fetch or timing, not rendering), "+
				"add it to clockOwners in %s with the reason.",
				name, n, "render_clock_guard_test.go")
		}
	}

	// The other direction: a granted allowance that is no longer used must be
	// surrendered, or it sits there ready to cover a future renderer.
	for name, why := range clockOwners {
		if found[name] == 0 {
			t.Errorf("clockOwners grants %s a wall-clock read (%q) but it no longer calls time.Now() — "+
				"remove the entry rather than leaving a widened allowance behind", name, why)
		}
	}
}
