package main

import "testing"

// The worker's boot log says whether the warm pool is on, and says so when it
// is off (task-5d99ad9ae8d780f1).
func TestWarmPoolBootLine(t *testing.T) {
	if got, want := warmPoolBootLine(0), "barkpark-provisioner: warm pool DISABLED (WARM_POOL_SIZE=0 or unset) — every launch creates a new server"; got != want {
		t.Errorf("warmPoolBootLine(0) = %q, want %q", got, want)
	}
	if got, want := warmPoolBootLine(3), "barkpark-provisioner: warm pool ENABLED (target size 3)"; got != want {
		t.Errorf("warmPoolBootLine(3) = %q, want %q", got, want)
	}
}
