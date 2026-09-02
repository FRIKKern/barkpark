//go:build unix

package agent

import (
	"os"
	"syscall"
)

// NewDeviceProbe builds the production st_dev reader: a plain os.Stat, no
// shell, microseconds.
//
// It exists as its own seam because the residual's disjointness rule needs an
// answer `du` cannot give. `du -x` refuses to cross INTO a mount, so a root
// that SITS ON one is measured in full while its parent's walk stopped at the
// boundary — measured on the build-plane box: the overlay at
// /var/lib/docker/rootfs/overlayfs/63036f65… reads 1,506,432 KiB when du is
// ROOTED at it and 8 KiB when the walk arrives from /var/lib/docker. Summing
// both against a root-filesystem denominator subtracts 1.44 GiB of bytes that
// are not on the root filesystem at all, and the residual goes NEGATIVE. The
// only way to tell those two roots apart is the device number.
//
// ok=false is "we could not read it", which the caller must not read as "same
// device": an unverifiable root is EXCLUDED and named, never silently summed.
func NewDeviceProbe() func(string) (uint64, bool) {
	return func(path string) (uint64, bool) {
		info, err := os.Stat(path)
		if err != nil {
			return 0, false
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok || st == nil {
			return 0, false
		}
		// Dev is uint64 on Linux and int32 on Darwin; the conversion is the one
		// expression that compiles on both and the value is only ever compared
		// for equality, never interpreted.
		return uint64(st.Dev), true
	}
}
