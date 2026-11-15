//go:build !unix

package pdrender

import "time"

// processCPUTime has no portable source off unix, so the cost check skips
// there and only the wall-clock bound applies.
func processCPUTime() (time.Duration, bool) { return 0, false }
