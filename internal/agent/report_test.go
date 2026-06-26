package agent

import (
	"errors"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// gitFakeRunner answers the two git probes gatherReport makes (rev-parse HEAD,
// status --porcelain) from canned values, and records the argv so the test can
// assert the -C checkout flag is threaded through.
type gitFakeRunner struct {
	head   string
	status string
	calls  [][]string
}

func (g *gitFakeRunner) Run(name string, args ...string) (string, error) {
	g.calls = append(g.calls, append([]string{name}, args...))
	switch {
	case len(args) > 0 && args[len(args)-1] == "HEAD":
		return g.head + "\n", nil
	case contains(args, "--porcelain"):
		return g.status, nil
	}
	return "", errors.New("unexpected git call")
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

// TestGatherReportFromInjectedProbes proves gatherReport builds the expected
// Report struct entirely from fakes — no real git tree, disk, PG, backup, or
// health gate needed.
func TestGatherReportFromInjectedProbes(t *testing.T) {
	git := &gitFakeRunner{head: "abc123def", status: " M file.go\n"}

	healthReport := setup.HealthReport{
		OK:     true,
		Checks: []setup.CheckResult{{Name: "websocket-not-403", Pass: true, Detail: "200"}},
	}

	r := gatherReport(ReportConfig{
		Runner:      git,
		Checkout:    "/opt/barkpark",
		DiskProbe:   func() (int, error) { return 42, nil },
		PGSizeProbe: func() (int64, error) { return 1234567, nil },
		BackupProbe: func() (bool, string, error) { return true, "last backup 2h ago", nil },

		HealthBaseURL: "https://server.example.com",
		runHealthGateFor: func(base, token string, opts setup.HealthGate) (setup.HealthReport, error) {
			return healthReport, nil
		},
	})

	if r.AgentStatus != "online" {
		t.Errorf("AgentStatus = %q, want online", r.AgentStatus)
	}
	if r.Version != Version {
		t.Errorf("Version = %q, want %q", r.Version, Version)
	}
	if r.GitCommit != "abc123def" {
		t.Errorf("GitCommit = %q, want abc123def", r.GitCommit)
	}
	if !r.DirtyTree {
		t.Error("DirtyTree = false, want true (porcelain was non-empty)")
	}
	if r.DiskUsedPercent != 42 {
		t.Errorf("DiskUsedPercent = %d, want 42", r.DiskUsedPercent)
	}
	if r.PGSizeBytes != 1234567 {
		t.Errorf("PGSizeBytes = %d, want 1234567", r.PGSizeBytes)
	}
	if !r.BackupOK || r.BackupDetail != "last backup 2h ago" {
		t.Errorf("Backup = (%v, %q), want (true, last backup 2h ago)", r.BackupOK, r.BackupDetail)
	}
	if r.HealthStatus != "up" {
		t.Errorf("HealthStatus = %q, want up", r.HealthStatus)
	}
	if len(r.Health) != 1 || r.Health[0].Name != "websocket-not-403" {
		t.Errorf("Health = %+v, want the one websocket check", r.Health)
	}

	// The -C <checkout> flag must reach git.
	if len(git.calls) == 0 || !contains(git.calls[0], "-C") || !contains(git.calls[0], "/opt/barkpark") {
		t.Errorf("git not run against checkout: calls=%v", git.calls)
	}
}

// TestGatherReportHonestUnknowns proves a bare config yields honest unknowns
// (no probes wired) rather than a panic or invented data.
func TestGatherReportHonestUnknowns(t *testing.T) {
	r := gatherReport(ReportConfig{}) // nothing wired

	if r.GitCommit != "" {
		t.Errorf("GitCommit = %q, want empty (no runner)", r.GitCommit)
	}
	if r.DirtyTree {
		t.Error("DirtyTree = true, want false (no runner)")
	}
	if r.DiskUsedPercent != -1 {
		t.Errorf("DiskUsedPercent = %d, want -1 (no probe)", r.DiskUsedPercent)
	}
	if r.PGSizeBytes != -1 {
		t.Errorf("PGSizeBytes = %d, want -1 (no probe)", r.PGSizeBytes)
	}
	if r.HealthStatus != "unknown" {
		t.Errorf("HealthStatus = %q, want unknown (no gate)", r.HealthStatus)
	}
	if r.AgentStatus != "online" {
		t.Errorf("AgentStatus = %q, want online (always)", r.AgentStatus)
	}
}

// TestGatherReportHealthGateDown proves a failing health gate maps to "down".
func TestGatherReportHealthGateDown(t *testing.T) {
	r := gatherReport(ReportConfig{
		HealthBaseURL: "https://server.example.com",
		runHealthGateFor: func(base, token string, opts setup.HealthGate) (setup.HealthReport, error) {
			return setup.HealthReport{OK: false}, errors.New("gate failed")
		},
	})
	if r.HealthStatus != "down" {
		t.Errorf("HealthStatus = %q, want down", r.HealthStatus)
	}
}

// TestGatherReportBackupProbeError surfaces a backup probe error honestly.
func TestGatherReportBackupProbeError(t *testing.T) {
	r := gatherReport(ReportConfig{
		BackupProbe: func() (bool, string, error) { return false, "", errors.New("no cron") },
	})
	if r.BackupOK {
		t.Error("BackupOK = true, want false on probe error")
	}
	if r.BackupDetail == "" {
		t.Error("BackupDetail empty, want the error noted")
	}
}
