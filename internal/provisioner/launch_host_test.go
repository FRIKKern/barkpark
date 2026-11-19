package provisioner

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// TestHostDecisionCaption pins each reason's caption.
func TestHostDecisionCaption(t *testing.T) {
	for _, tc := range []struct {
		d    hostDecision
		want string
	}{
		{hostDecision{hostWarm, "warm-52d0bbcf"}, "Warm server warm-52d0bbcf assigned"},
		{poolOffDecision(Seams{}), "No warm server: warm pool is off on this worker (WARM_POOL_SIZE=0) — creating a new server"},
		{poolOffDecision(Seams{WarmPoolSize: 2}), "No warm server: warm pool has no claim client on this worker — creating a new server"},
		{hostDecision{hostPoolEmpty, "no warm server ready"}, "No warm server: no warm server ready — creating a new server"},
		{pinMismatchDecision(cloud.ServerSpec{Region: "fsn1"}, cloud.ServerSpec{Region: "nbg1", ServerType: "cx23"}),
			"No warm server: this launch pins region fsn1 / type -, the pool is nbg1/cx23 — creating a new server"},
		{hostDecision{hostClaimError, "warm claim failed: boom"}, "No warm server: warm claim failed: boom — creating a new server"},
		{hostDecision{hostAssignFailed, "warm server warm-1 failed to assign: boom"}, "No warm server: warm server warm-1 failed to assign: boom — creating a new server"},
	} {
		t.Run(string(tc.d.reason), func(t *testing.T) {
			if got := tc.d.caption(); got != tc.want {
				t.Errorf("caption = %q, want %q", got, tc.want)
			}
		})
	}
	if poolOffDecision(Seams{}).reason != hostPoolOff || pinMismatchDecision(cloud.ServerSpec{}, cloud.ServerSpec{}).reason != hostPinMismatch {
		t.Error("pool-off / pin-mismatch constructors carry the wrong reason")
	}
}
