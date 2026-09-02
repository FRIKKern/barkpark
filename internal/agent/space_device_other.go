//go:build !unix

package agent

// NewDeviceProbe on a platform with no st_dev returns a probe that always says
// "we could not read it". That is the honest answer, and it is the SAFE one:
// an unverifiable root is excluded from the residual and named, so the payload
// reports a refusal rather than a sum it cannot stand behind. The agent ships
// to Linux boxes; this arm exists so the package still builds elsewhere.
func NewDeviceProbe() func(string) (uint64, bool) {
	return func(string) (uint64, bool) { return 0, false }
}
