package taskboard

// compose_floor_test.go — the CERTIFICATION of the two 20x8 geometry floors
// (gocorrect-taskboard-floor-coverage-gap), and the regression that finally
// observes one of them.
//
// THE RECORD (measured, not asserted — see the mutation table below):
//
//   1. Compose's OUTER floor (compose.go, `func Compose`) is PROVABLY REDUNDANT,
//      not merely untested. For any m.width w: with the floor, composeAt is
//      handed 20-gl-gr = 17 (w<20 ⇒ w<56 ⇒ gl,gr = 1,2) which composeAt re-floors
//      to 20; without it, composeAt is handed w-3 < 17 which composeAt ALSO
//      re-floors to 20. The gutter pad is 1 on both branches. The height chain is
//      the same story against 8. So the two branches are output-IDENTICAL for
//      every sub-floor size — no test can red on its removal, by construction.
//      TestComposeOuterFloorIsRedundantToTheReFloor pins that equivalence as the
//      durable record: it is a CHARACTERIZATION test (green with or without the
//      outer floor) and it says so, so nobody re-files this gap as "untested".
//
//   2. composeAt's floor is NOT redundant — the original filing said no
//      red-on-removal test was writable, and that was wrong for one path. It is
//      unobservable through the BOARD frame (Render, render.go:41-47, floors 20x8
//      a third time) and through the WIDE split (boardPaneCols / minReadingWidth
//      carry their own floors). But the NARROW READING frame reaches docLayout
//      and the paneH reservation with NO downstream floor at all
//      (compose.go, the `!m.wide` non-FrameBoard branch), so composeAt's floor is
//      the last one standing there and its removal is directly observable.
//      TestComposeAtFloorIsLoadBearingInTheNarrowReadingFrame is that arm.
//
// Mutation table (observed, worktree cli-r21d-w12-taskboard-floor-coverage):
//   drop composeAt width floor   → TestComposeAtFloorIsLoadBearing... RED
//   drop composeAt height floor  → TestComposeAtFloorIsLoadBearing... RED
//   drop Compose outer floors    → both tests here GREEN (that is the record)
//
// DO NOT weaken the floors to make a test pass.

import (
	"strings"
	"testing"
)

// floorFixture parks a model on a pushed reading frame in NARROW mode — the ONE
// composeAt branch with no floor downstream of it. Reuses motion_test.go's
// narrowReadingFixture so the two suites share one reading-frame shape.
func floorFixture(t *testing.T) Model {
	t.Helper()
	m := narrowReadingFixture(3)
	m.wide = false
	if top := m.topFrame(); top.Kind == FrameBoard {
		t.Fatalf("precondition: fixture must sit on a pushed reading frame, got FrameBoard")
	}
	return m
}

// TestComposeAtFloorIsLoadBearingInTheNarrowReadingFrame observes composeAt's
// 20x8 floor AT the seam, before anything downstream can re-floor it: the narrow
// reading frame sends width straight into docLayout and height straight into the
// paneH reservation. The contract is exact — a sub-floor call must paint the
// floored frame byte-for-byte — so dropping either floor diverges immediately.
func TestComposeAtFloorIsLoadBearingInTheNarrowReadingFrame(t *testing.T) {
	m := floorFixture(t)

	// PRECONDITION: the floored frame must be non-degenerate, otherwise an
	// equality against it could pass on two empty strings.
	floored := composeAt(m, 20, 8)
	if lines := strings.Split(floored, "\n"); len(lines) < 8 || strings.TrimSpace(floored) == "" {
		t.Fatalf("precondition: composeAt(20,8) must paint 8 non-empty lines, got %d lines / %q", len(lines), floored)
	}

	for w := 0; w < 20; w++ {
		if got := composeAt(m, w, 8); got != floored {
			t.Errorf("composeAt width floor not applied at w=%d: frame differs from composeAt(20,8)\n--- got ---\n%s\n--- want ---\n%s", w, got, floored)
		}
	}
	for h := 0; h < 8; h++ {
		if got := composeAt(m, 20, h); got != floored {
			t.Errorf("composeAt height floor not applied at h=%d: frame differs from composeAt(20,8)\n--- got ---\n%s\n--- want ---\n%s", h, got, floored)
		}
	}

	// CONTROL: at or above the floor composeAt must NOT clamp — an
	// unconditional `width, height = 20, 8` would pass every assertion above.
	if wide := composeAt(m, 40, 20); wide == floored {
		t.Errorf("composeAt(40,20) == composeAt(20,8): the floor is clamping ABOVE 20x8, not flooring below it")
	}
}

// TestComposeOuterFloorIsRedundantToTheReFloor is the durable certification for
// item (1) above: Compose's own 20x8 floor cannot be observed on removal because
// composeAt re-floors whatever Compose hands it. This test is GREEN with or
// without the outer floor BY DESIGN — it records the equivalence that makes a
// red-on-removal test impossible, so the coverage gap stays closed-with-a-reason
// instead of being re-filed. It still reds if BOTH floors go, since then nothing
// clamps and the sub-floor frames diverge.
func TestComposeOuterFloorIsRedundantToTheReFloor(t *testing.T) {
	base := floorFixture(t)

	composeAtSize := func(w, h int) string {
		m := base
		m.width, m.height = w, h
		return Compose(m)
	}

	floored := composeAtSize(20, 8)
	if strings.TrimSpace(floored) == "" {
		t.Fatalf("precondition: Compose(20,8) must paint something")
	}
	for w := 0; w < 20; w++ {
		for h := 0; h < 8; h++ {
			if got := composeAtSize(w, h); got != floored {
				t.Errorf("Compose(%d,%d) != Compose(20,8): the sub-floor equivalence this certification rests on no longer holds — re-derive the record in compose_floor_test.go's header", w, h)
			}
		}
	}
}
