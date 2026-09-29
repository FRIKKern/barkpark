package taskboard

import "time"

// defaultClock is THE binding of the real wall clock into the taskboard. Every
// other site in this package — every renderer, every reducer — takes its
// instant from Model.now (the injectable `func() time.Time` seam), and tests
// override that field with a fixed clock so the goldens stay time-independent.
// Somebody has to bind the seam to the real thing exactly once; this is that
// one place.
//
// It lives in its own file on purpose. The render-clock guard
// (TestRenderPathTakesItsClockFromTheCaller) allows a wall-clock read only in a
// file listed in clockOwners, and an allowance is granted to a FILE. Binding
// the clock inside program.go would have meant granting the 2,000-line file
// that also holds View() and frameContent() a standing licence to read the
// clock — which is the opposite of what the guard is for. Here the allowance
// covers a single binding and can cover nothing else.
var defaultClock = time.Now
