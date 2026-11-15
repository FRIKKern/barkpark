//go:build unix

package pdrender

import (
	"syscall"
	"time"
)

// processCPUTime returns the CPU time this process has used, user plus
// system. Other processes on a loaded machine do not add to it, which is why
// the cost check reads it instead of the wall clock.
func processCPUTime() (time.Duration, bool) {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0, false
	}
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano()), true
}
