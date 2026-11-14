//go:build !race

package pdrender

import "time"

// limitDocTime is the wall-clock bound for rendering one worst-case limit doc.
// Without the race detector the slowest doc takes about 0.1 s, so one second
// leaves room for a loaded machine. This is the bound that matters: CI runs
// the test once without -race to hold it (.github/workflows/go-tests.yml).
// limits_bound_race_test.go holds the wider backstop for `go test -race`.
const limitDocTime = time.Second
