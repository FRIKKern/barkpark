//go:build darwin || linux

package cli

import (
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

// fionreadRequest is ioctl FIONREAD's request number. The stdlib syscall
// package does not export it on darwin, so it is spelled out per OS: Linux
// fixes it at 0x541b (aliased TIOCINQ); Darwin encodes _IOR('f', 127, int) =
// 0x4004667f.
var fionreadRequest = map[string]uintptr{
	"linux":  0x541b,
	"darwin": 0x4004667f,
}[runtime.GOOS]

// stdinPendingBytes reports how many bytes are available to read from f RIGHT
// NOW, without reading and without blocking, via ioctl(FIONREAD). ok is false
// when the probe cannot answer (unsupported file type), in which case the
// caller keeps the conservative pre-probe behavior.
//
// FIONREAD is the only correct primitive here: poll/select readability is a
// trap — a CLOSED empty pipe polls readable (read would return EOF
// immediately), which is exactly the `: | bp …` case that must NOT count as
// pending input. FIONREAD answers 0 for both a closed-empty and an
// open-but-empty pipe, and never blocks for either.
func stdinPendingBytes(f *os.File) (int, bool) {
	// FIONREAD writes a C int (4 bytes) — the ioctl request encodes that
	// size, so the destination must be an int32, not a Go int.
	var n int32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), fionreadRequest, uintptr(unsafe.Pointer(&n)))
	if errno != 0 {
		return 0, false
	}
	return int(n), true
}
