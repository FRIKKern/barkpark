//go:build !darwin && !linux

package cli

import "os"

// stdinPendingBytes has no cheap non-blocking byte-count primitive on this
// platform via the stdlib syscall package (Windows would need
// PeekNamedPipe from x/sys/windows). Report "unknown" so the caller keeps the
// historical conservative behavior: any redirected stdin trips the
// unused-input guard, empty or not.
func stdinPendingBytes(_ *os.File) (int, bool) {
	return 0, false
}
