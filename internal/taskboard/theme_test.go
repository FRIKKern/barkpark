package taskboard

import (
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/semrole"
	"github.com/charmbracelet/lipgloss"
)

// TestLifecycleColorsSourceGeneratedTokens locks the board's LIFECYCLE hues to
// the emitted token source (tokens_gen.go, from design/tokens.json). The values
// are read via genColor, so this is the ratchet that fails if anyone re-hand-codes
// one of these hex literals back into theme.go — the drift the unified-aesthetic
// endgame forbids. okColor/dangerColor are covered by TestStatusColorsSourceGeneratedTones
// below (graduated onto semrole's status tones in au-w4 W4.10); neutral/dim/title
// are deliberately absent — pure chrome with no generated twin.
func TestLifecycleColorsSourceGeneratedTokens(t *testing.T) {
	cases := []struct {
		key   string
		got   lipgloss.AdaptiveColor
		named string
	}{
		{"in_progress", infoColor, "infoColor"},
		{"blocked", warnColor, "warnColor"},
		{"done", doneColor, "doneColor"},
		{"ready", readyColor, "readyColor"},
		{"open", openColor, "openColor"},
		{"cancelled", cancelColor, "cancelColor"},
	}
	for _, c := range cases {
		tok, ok := GenLifecycle[c.key]
		if !ok {
			t.Errorf("GenLifecycle missing %q — %s cannot source it", c.key, c.named)
			continue
		}
		if c.got.Light != tok.ColorLight || c.got.Dark != tok.ColorDark {
			t.Errorf("%s = {Light:%q Dark:%q}, want generated {Light:%q Dark:%q} for %q",
				c.named, c.got.Light, c.got.Dark, tok.ColorLight, tok.ColorDark, c.key)
		}
	}
}

// TestStatusColorsSourceGeneratedTones is the STATUS peer of
// TestLifecycleColorsSourceGeneratedTokens: it locks okColor/dangerColor to the
// GENERATED semrole status tones (GenStatusTone, from design/tokens.json) after
// their au-w4 W4.10 graduation. The expectation IS the generated value — a
// re-hand-coded status hex (e.g. reverting okColor to #10b981) fails HERE, and the
// visible graduation (okColor #10b981→#137236, dangerColor #dc2626→#b42222) is
// asserted by ALIGNMENT to the shared manifest, never a hand-copied snapshot.
func TestStatusColorsSourceGeneratedTones(t *testing.T) {
	cases := []struct {
		role  string
		got   lipgloss.AdaptiveColor
		named string
	}{
		{"ok", okColor, "okColor"},
		{"danger", dangerColor, "dangerColor"},
	}
	for _, c := range cases {
		want := semrole.GenStatusTone[c.role]
		if c.got != want {
			t.Errorf("%s = %+v, want generated status tone %+v for role %q",
				c.named, c.got, want, c.role)
		}
	}
}

// TestLifecycleConstsMatchGeneratedTokens locks board.go's life* string consts to
// the generated lifecycle set (GenLifecycle keys + GenLifecycleOrder), so adding a
// token to design/tokens.json without teaching the board its const fails HERE, in
// the same tree. It is the coupling that keeps the hand-named consts and the
// generated vocabulary from drifting apart in either direction.
func TestLifecycleConstsMatchGeneratedTokens(t *testing.T) {
	consts := map[string]string{
		"in_progress": lifeInProgress,
		"blocked":     lifeBlocked,
		"done":        lifeDone,
		"closed":      lifeClosed,
		"cancelled":   lifeCancelled,
		"ready":       lifeReady,
		"open":        lifeOpen,
		"considering": lifeConsidering,
		"researching": lifeResearching,
	}
	for want, got := range consts {
		if got != want {
			t.Errorf("life const for %q = %q, want %q", want, got, want)
		}
		if _, ok := GenLifecycle[got]; !ok {
			t.Errorf("life const %q is absent from GenLifecycle", got)
		}
	}
	if len(GenLifecycleOrder) != len(consts) {
		t.Fatalf("GenLifecycleOrder has %d tokens, board has %d life consts — vocabulary drift",
			len(GenLifecycleOrder), len(consts))
	}
	for _, lc := range GenLifecycleOrder {
		if _, ok := consts[lc]; !ok {
			t.Errorf("GenLifecycleOrder token %q has no board life const", lc)
		}
	}
}

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
