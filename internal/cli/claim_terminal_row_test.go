package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// task-f788ace33b5ff892: a not_ready refusal on a done/cancelled row is a
// lifecycle answer. Closing a row does not clear claim.worker, so the read-back
// still names whoever held it. The diagnosis must name the lifecycle blocker
// and the reopen remedy, and must not call that leftover worker a live holder
// or tell the caller to re-claim. Measured live on task-147a1340be2cf6d4
// (cancelled): "held live by r3a-scratch-other — wait for them".

var terminalVerdictForbidden = []string{"held live by", "renew the lease", "wait for them", "already lists YOU"}

func TestClaimVerdict_TerminalRowNamesLifecycleNotHolder(t *testing.T) {
	for _, lifecycle := range []string{"cancelled", "done"} {
		for name, claim := range map[string]apiclient.ClaimInfo{
			"foreign map": {Present: true, Worker: "other"},
			"own map":     {Present: true, Worker: "me"},
			"no map":      {},
		} {
			got := claimVerdict("me", lifecycle, claim, queueGate{}, "not_claimable_status")
			if !strings.Contains(got, `lifecycle_status is "`+lifecycle+`"`) || !strings.Contains(got, "bp task stage <id> open") {
				t.Errorf("%s/%s: verdict = %q, want the lifecycle blocker and the stage-open remedy", lifecycle, name, got)
			}
			for _, bad := range terminalVerdictForbidden {
				if strings.Contains(got, bad) {
					t.Errorf("%s/%s: verdict = %q must not say %q on a closed row", lifecycle, name, got, bad)
				}
			}
		}
	}
}

// Positive control: on an OPEN row the holder verdicts are unchanged.
func TestClaimVerdict_OpenRowStillNamesHolder(t *testing.T) {
	if got := claimVerdict("me", "open", apiclient.ClaimInfo{Present: true, Worker: "other"}, queueGate{}, ""); !strings.Contains(got, "held live by other") {
		t.Errorf("open row, foreign holder: verdict = %q, want held-live-by", got)
	}
	if got := claimVerdict("me", "open", apiclient.ClaimInfo{Present: true, Worker: "me"}, queueGate{}, ""); !strings.Contains(got, "YOU (me)") {
		t.Errorf("open row, own holder: verdict = %q, want the already-yours verdict", got)
	}
}

// End to end through `bp task claim`: the read-back of a cancelled row whose
// claim map names another worker.
func TestTaskClaimExecute_NotReadyOnCancelledRowNamesLifecycle(t *testing.T) {
	claimTestServer(t, map[string]any{
		"_id": "task-x", "lifecycle_status": "cancelled",
		"claim": map[string]any{"worker": "other-worker", "epoch": 4},
	})
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, out)
	}
	if !strings.Contains(out, `genuinely not ready: lifecycle_status is "cancelled"`) {
		t.Errorf("output should name the lifecycle blocker; got:\n%s", out)
	}
	if strings.Contains(out, "held live by") {
		t.Errorf("output names a live holder on a cancelled row; got:\n%s", out)
	}
}

// The static not_ready hint puts the lifecycle remedy before the holder
// advice, and scopes the re-claim advice to an open row.
func TestNotReadyHintPutsReopenFirst(t *testing.T) {
	h := (apiError{code: "not_ready"}).hint()
	reopen := strings.Index(h, "bp task stage <id> open")
	reclaim := strings.Index(h, "re-claim")
	if reopen < 0 {
		t.Fatalf("not_ready hint = %q, want the stage-open remedy for a done/cancelled row", h)
	}
	if reclaim >= 0 && reclaim < reopen {
		t.Errorf("not_ready hint = %q prescribes re-claim before the reopen remedy", h)
	}
	if !strings.Contains(h, "isn't claimable") {
		t.Errorf("not_ready hint = %q lost the not-claimable lead", h)
	}
}
