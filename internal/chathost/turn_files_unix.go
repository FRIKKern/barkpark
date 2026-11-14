//go:build unix

package chathost

import "syscall"

// oNoFollow makes an open refuse a link at the final name.
const oNoFollow = syscall.O_NOFOLLOW
