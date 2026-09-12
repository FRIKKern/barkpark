package taskboard

import (
	"encoding/json"
	"testing"
	"time"
)

// TestTwentyMinuteClaimIsNotPaintedDanger is the NAMED mutation guard for
// task-f30dab8c54c605e6.
//
// THE DEFECT IT PINS. internal/taskboard graded the claim tint against
// `leaseTTL = 5 * time.Minute`, carrying the comment "Barkpark's claim leases
// are 5 minutes". The server's lease is `:task_lease_ttl_seconds`, default
// 2700 — 45 minutes (Barkpark.Tasks.QueueGate.lease_ttl_seconds/0, and
// TtlSweeper is what actually reaps on it). A twenty-minute-old claim is
// therefore LIVE by more than twenty minutes of margin, and the board painted
// it RoleDanger: the alarm an operator is meant to act on, fired on healthy
// work.
//
// THE MUTATION: put the claim horizon back to five minutes — either
// `defaultClaimLeaseTTL = 5 * time.Minute` in theme.go, or reverting
// RoleFor/claimRole to grade against pulseTTL — and this test reds on the
// twenty-minute case. It is red against origin/main's constant by
// construction.
func TestTwentyMinuteClaimIsNotPaintedDanger(t *testing.T) {
	claimedAt := time.Date(2026, 9, 12, 10, 0, 0, 0, time.UTC)
	now := claimedAt.Add(20 * time.Minute)

	task := Task{
		Lifecycle: "in_progress",
		Claim:     &Claim{Worker: "w11-taskboard", Epoch: 1, ClaimedAt: claimedAt},
	}
	if got := RoleFor(task, now); got == RoleDanger {
		t.Fatalf("a 20-minute-old claim under the server's %s lease was painted %v — "+
			"the board is alarming on a claim the server keeps for another %s",
			defaultClaimLeaseTTL, got, defaultClaimLeaseTTL-20*time.Minute)
	} else if got != RoleInfo {
		t.Fatalf("a 20-minute-old claim = %v, want RoleInfo (20m is %.0f%% of the "+
			"%s lease, well under the 70%% warn band)",
			got, 100*float64(20*time.Minute)/float64(defaultClaimLeaseTTL), defaultClaimLeaseTTL)
	}

	// The ladder still ESCALATES — this row fixed a wrong horizon, it did not
	// disarm the alarm. 70% of 2700s is 1890s (31m30s); the lease is spent at 45m.
	if got := RoleFor(task, claimedAt.Add(32*time.Minute)); got != RoleWarn {
		t.Errorf("32-minute claim = %v, want RoleWarn (past 70%% of the 45m lease)", got)
	}
	if got := RoleFor(task, claimedAt.Add(46*time.Minute)); got != RoleDanger {
		t.Errorf("46-minute claim = %v, want RoleDanger (the 45m lease is spent)", got)
	}
}

// TestClaimHorizonFallsBackToServerDefaultNotFiveMinutes pins the FALLBACK the
// row names: when the read payload carries no lease horizon, the client falls
// back to the SERVER's default 2700s — never to a five-minute client guess.
// The same number is already in this binary at internal/cli/cmux_hook.go's
// `leaseTTLFloor = 2700 * time.Second`; this package was the one that had it
// wrong.
func TestClaimHorizonFallsBackToServerDefaultNotFiveMinutes(t *testing.T) {
	if defaultClaimLeaseTTL != 2700*time.Second {
		t.Fatalf("defaultClaimLeaseTTL = %s, want 2700s (:task_lease_ttl_seconds)", defaultClaimLeaseTTL)
	}
	if got := claimLeaseTTL(nil); got != defaultClaimLeaseTTL {
		t.Errorf("claimLeaseTTL(nil) = %s, want %s", got, defaultClaimLeaseTTL)
	}
	if got := claimLeaseTTL(&Claim{}); got != defaultClaimLeaseTTL {
		t.Errorf("claimLeaseTTL(no lease_seconds) = %s, want %s", got, defaultClaimLeaseTTL)
	}
	// A server that DOES send a horizon wins over the default, in both directions.
	if got := claimLeaseTTL(&Claim{LeaseSeconds: 600}); got != 10*time.Minute {
		t.Errorf("claimLeaseTTL(600) = %s, want 10m", got)
	}
	if got := claimLeaseTTL(&Claim{LeaseSeconds: 7200}); got != 2*time.Hour {
		t.Errorf("claimLeaseTTL(7200) = %s, want 2h", got)
	}
	// A zero/negative horizon is ABSENT, never "everything is danger".
	if got := claimLeaseTTL(&Claim{LeaseSeconds: -1}); got != defaultClaimLeaseTTL {
		t.Errorf("claimLeaseTTL(-1) = %s, want the default %s", got, defaultClaimLeaseTTL)
	}
}

// TestServerLeaseHorizonRidesTheReadPayload proves the Go half reads the
// horizon the Elixir half now mints: claim.lease_seconds on the /v1/tasks
// render_doc envelope reaches Claim.LeaseSeconds and MOVES the tint.
func TestServerLeaseHorizonRidesTheReadPayload(t *testing.T) {
	body := []byte(`{"docs":[{"doc_id":"task-x","title":"t","lifecycle_status":"in_progress",
	  "claim":{"worker":"w","epoch":2,"ts_iso":"2026-09-12T10:00:00Z","lease_seconds":600}}]}`)
	tasks, _, err := decodeTaskListFull(body)
	if err != nil {
		t.Fatalf("decodeTaskListFull: %v", err)
	}
	if len(tasks) != 1 || tasks[0].Claim == nil {
		t.Fatalf("decoded %d tasks (claim nil? %v)", len(tasks), len(tasks) == 1 && tasks[0].Claim == nil)
	}
	if got := tasks[0].Claim.LeaseSeconds; got != 600 {
		t.Fatalf("claim.lease_seconds decoded to %d, want 600", got)
	}
	claimedAt := time.Date(2026, 9, 12, 10, 0, 0, 0, time.UTC)
	// Under a SERVER-SENT 10-minute lease, a 20-minute claim IS spent — the
	// client obeys the server, it does not substitute its own 45 minutes.
	if got := RoleFor(tasks[0], claimedAt.Add(20*time.Minute)); got != RoleDanger {
		t.Errorf("20m claim under a server-sent 600s lease = %v, want RoleDanger", got)
	}
	if got := RoleFor(tasks[0], claimedAt.Add(time.Minute)); got != RoleInfo {
		t.Errorf("1m claim under a server-sent 600s lease = %v, want RoleInfo", got)
	}
}

// TestLeaseSecondsDecodeIsTolerant holds the frozen wave-5 field contract: a
// malformed lease_seconds degrades to 0 (= absent → server default), never an
// error and never a dropped task.
func TestLeaseSecondsDecodeIsTolerant(t *testing.T) {
	for _, raw := range []string{`"2700"`, `null`, `{}`, `[]`, `true`, ``} {
		if got := decodeLeaseSeconds(json.RawMessage(raw)); got != 0 {
			t.Errorf("decodeLeaseSeconds(%q) = %d, want 0", raw, got)
		}
	}
	if got := decodeLeaseSeconds(json.RawMessage(`2700.9`)); got != 2700 {
		t.Errorf("decodeLeaseSeconds(2700.9) = %d, want 2700", got)
	}
}

// TestPulseHorizonIsStillFiveMinutes is the other half of the split: the row
// says a five-minute horizon is DEFENSIBLE for the pulse (motion = liveness)
// and wrong only for the claim tint. This pins that the fix did not drag the
// spinner out to 45 minutes with it.
func TestPulseHorizonIsStillFiveMinutes(t *testing.T) {
	if pulseTTL != 5*time.Minute {
		t.Fatalf("pulseTTL = %s, want 5m", pulseTTL)
	}
	at := time.Date(2026, 9, 12, 10, 0, 0, 0, time.UTC)
	if got := pulseRole(at, at.Add(6*time.Minute)); got != RoleDanger {
		t.Errorf("a 6-minute-old pulse = %v, want RoleDanger (stale, no spinner)", got)
	}
	// The SAME six minutes on the CLAIM is fresh — the two horizons are now
	// genuinely independent, which is the whole point of the split.
	task := Task{Lifecycle: "in_progress", Claim: &Claim{Worker: "w", ClaimedAt: at}}
	if got := RoleFor(task, at.Add(6*time.Minute)); got != RoleInfo {
		t.Errorf("a 6-minute-old CLAIM = %v, want RoleInfo", got)
	}
}
