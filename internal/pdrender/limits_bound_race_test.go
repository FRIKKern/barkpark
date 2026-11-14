//go:build race

package pdrender

import "time"

// limitDocTime is the wall-clock bound for rendering one worst-case limit doc
// under the race detector. The detector slows the slowest doc ("table") from
// 89 ms to up to 1.02 s on a laptop and 1.2 to 1.7 s on a hosted CI runner, so
// the 1 s bound failed PRs that never touched pdrender. Five seconds is three
// times the slowest CI render.
//
// This is a backstop, not the bound. The detector slows code unevenly: a
// byte-scanning loop runs about as fast with it as without, so a regression
// there could pass five seconds here while it breaks one second in a normal
// build. CI therefore also runs this test without -race, against the 1 s bound
// in limits_bound_test.go.
const limitDocTime = 5 * time.Second
