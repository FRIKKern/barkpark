//go:build unix

package chathost

import "syscall"

// signalZero is kill(pid, 0): nil while the process lives, ESRCH once it is
// gone and reaped.
func signalZero(pid int) error { return syscall.Kill(pid, 0) }
