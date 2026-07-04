package taskboard

import (
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/semrole"
)

// TestRoleForParityWithSemrole locks the board's lifecycle→role mapping to the
// shared internal/semrole vocabulary so the CLI tables (bp task … -o table), the
// cloud dashboard, and the portrait board can never drift. It iterates
// semrole.TaskLifecycles() — EVERY task token semrole maps, not a local copy —
// so extending the shared vocabulary without teaching RoleFor the new token
// fails here, in the same commit. For every task lifecycle, a claim-less task's
// RoleFor(...).String() must equal semrole.For, treating the board's "neutral"
// as semrole's "" (uncoloured). The claim-age escalation (in_progress leaning
// on its lease → warn/danger) is board-only and deliberately NOT part of this
// parity — it keys on claim freshness, not the lifecycle token — so this test
// uses claim-less tasks.
func TestRoleForParityWithSemrole(t *testing.T) {
	now := time.Now()
	lifecycles := semrole.TaskLifecycles()
	if len(lifecycles) < 7 { // in_progress blocked done closed + ready open cancelled
		t.Fatalf("semrole.TaskLifecycles() = %v — expected at least the 7 known tokens", lifecycles)
	}
	for _, lc := range lifecycles {
		want := semrole.For(lc)
		if want == "" {
			want = "neutral" // board renders the neutral role; semrole spells it ""
		}
		got := RoleFor(Task{Lifecycle: lc}, now).String()
		if got != want {
			t.Errorf("RoleFor(%q).String() = %q, want %q (semrole parity)", lc, got, want)
		}
	}
}

// TestRoleForClaimlessInProgressIsInfo is the parity anchor the charter names:
// a claim-less in_progress task is plain info, matching semrole.For.
func TestRoleForClaimlessInProgressIsInfo(t *testing.T) {
	if got := RoleFor(Task{Lifecycle: "in_progress"}, time.Now()); got != RoleInfo {
		t.Fatalf("claim-less in_progress = %v, want RoleInfo", got)
	}
	if got := RoleFor(Task{Lifecycle: "in_progress"}, time.Now()).String(); got != semrole.For("in_progress") {
		t.Fatalf("claim-less in_progress role %q != semrole.For %q", got, semrole.For("in_progress"))
	}
}

// TestClaimEscalationStaysBoardOnly guards the one intentional divergence: a
// claim burning through its lease escalates past info to warn then danger, which
// semrole (a pure token map) knows nothing about. This must NOT be reconciled
// away.
func TestClaimEscalationStaysBoardOnly(t *testing.T) {
	claimedAt := time.Unix(0, 0)
	fresh := claimedAt.Add(time.Minute)                   // <70% of the 5m lease
	leaning := claimedAt.Add(leaseTTL*7/10 + time.Second) // past ~70%
	spent := claimedAt.Add(leaseTTL + time.Minute)        // past the lease
	inProg := func() Task {
		return Task{Lifecycle: "in_progress", Claim: &Claim{ClaimedAt: claimedAt}}
	}
	if got := RoleFor(inProg(), fresh); got != RoleInfo {
		t.Errorf("fresh claim = %v, want RoleInfo", got)
	}
	if got := RoleFor(inProg(), leaning); got != RoleWarn {
		t.Errorf("leaning claim = %v, want RoleWarn", got)
	}
	if got := RoleFor(inProg(), spent); got != RoleDanger {
		t.Errorf("spent claim = %v, want RoleDanger", got)
	}
}

// TestStaleRole pins the day-scale staleness ladder: neutral while fresh, warn
// past 3 days, danger past a week — with EXCLUSIVE boundaries (a task exactly at
// the threshold has not yet crossed it) and an absolute "terminal work is never
// stale" override for done/closed/cancelled.
func TestStaleRole(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	ago := func(d time.Duration) time.Time { return now.Add(-d) }
	day := 24 * time.Hour

	cases := []struct {
		name      string
		updated   time.Time
		lifecycle string
		want      Role
	}{
		{"fresh-open", ago(time.Hour), "open", RoleNeutral},
		{"two-days-open", ago(2 * day), "open", RoleNeutral},
		{"exactly-3d", ago(3 * day), "ready", RoleNeutral}, // exclusive
		{"just-past-3d", ago(3*day + time.Second), "ready", RoleWarn},
		{"five-days-blocked", ago(5 * day), "blocked", RoleWarn},
		{"exactly-7d", ago(7 * day), "open", RoleWarn}, // exclusive
		{"just-past-7d", ago(7*day + time.Second), "open", RoleDanger},
		{"ancient-open", ago(30 * day), "in_progress", RoleDanger},
		// Terminal lifecycles are always neutral, however old.
		{"ancient-done", ago(90 * day), "done", RoleNeutral},
		{"ancient-closed", ago(90 * day), "closed", RoleNeutral},
		{"ancient-cancelled", ago(90 * day), "cancelled", RoleNeutral},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := staleRole(c.updated, now, c.lifecycle); got != c.want {
				t.Errorf("staleRole(%s, %q) = %v, want %v", c.name, c.lifecycle, got, c.want)
			}
		})
	}
}

// The chip-hue tests were retired with the hash-to-hue engine (charter D22):
// labels are dim monochrome text now, so there is no per-tag palette left to
// prove distinct or clear of the role hues.
