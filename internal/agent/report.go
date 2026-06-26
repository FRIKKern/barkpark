// Package agent is the barkpark-agent: a transparent on-box Go binary that runs
// on each managed server, reports health/status to the control plane, and runs
// APPROVED commands pulled from a poll-based queue. It is deliberately small —
// report + poll + a fixed 6-command allowlist — and entirely injectable so the
// whole cycle is exercised against an httptest fake control plane with no live
// server. The agent is a plain binary plus a systemd unit; `bp agent
// disable/uninstall` (cloud-11) act on it, and it keeps NO hidden persistence.
package agent

import (
	"crypto/x509"
	"os/exec"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// Version is the agent's own build version, reported verbatim in every Report.
// Stamped here (overridable at build time via -ldflags) rather than read from
// the server so the report tells the truth about THIS binary.
const Version = "0.1.0"

// Report is the payload the agent POSTs to /v1/agent/report. It is the honest
// superset of the cloud-9 registry's health columns
// (health_status/version/git_commit/agent_status/last_seen_at) plus the
// health-gate signals the registry stores as events (disk, PG size, backup,
// TLS/domain, websocket). Field-by-field JSON so the control plane can land it
// straight into upsert_health + record_event.
type Report struct {
	// AgentStatus is always "online" in a report — the agent only reports when
	// it is running. The registry flips a Barkpark to "offline" on staleness.
	AgentStatus string `json:"agent_status"`
	// Version is the agent binary version (Version const above).
	Version string `json:"version"`
	// GitCommit is `git rev-parse HEAD` in the checkout (the deployed code's
	// commit). Empty + DirtyTree=false when the probe could not read it.
	GitCommit string `json:"git_commit"`
	// DirtyTree is true when `git status --porcelain` is non-empty — the
	// deployed checkout has uncommitted changes (a deploy-hygiene red flag).
	DirtyTree bool `json:"dirty_tree"`

	// HealthStatus rolls the health-gate up to the registry's enum
	// (up/down/unknown): "up" iff the gate's OK is true, "down" when the gate
	// ran but failed, "unknown" when no gate probe was wired (test/offline).
	HealthStatus string `json:"health_status"`

	// DiskUsedPercent is the root-filesystem usage from the injected disk probe
	// (statfs/df). -1 when the probe was not wired or failed.
	DiskUsedPercent int `json:"disk_used_percent"`
	// PGSizeBytes is the Postgres database size from the injected probe. -1 when
	// not wired/failed.
	PGSizeBytes int64 `json:"pg_size_bytes"`
	// BackupOK / BackupDetail come from the injected backup-status probe — is a
	// recent backup present and scheduled?
	BackupOK     bool   `json:"backup_ok"`
	BackupDetail string `json:"backup_detail"`

	// Health carries the per-check results of the health gate (websocket-not-403
	// / TLS / capabilities / studio / postgres-via-api …) so the control plane
	// can record the granular event stream, not just the roll-up.
	Health []setup.CheckResult `json:"health_checks"`
}

// CommandRunner runs a single resolved argv and returns combined output. It is
// injected so tests use a fake that records calls and NEVER shells out to a real
// systemctl/make. The production runner (ExecRunner) shells out for real.
type CommandRunner interface {
	Run(name string, args ...string) (output string, err error)
}

// ExecRunner is the production CommandRunner: it runs the argv via os/exec.
type ExecRunner struct{}

// Run executes name+args and returns combined stdout+stderr.
func (ExecRunner) Run(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}

// gitProbe reads the checkout's commit + dirty flag via an injected
// CommandRunner so report-gathering is testable without a real git tree.
type gitProbe struct {
	runner   CommandRunner
	checkout string // -C <checkout>; empty means "current working dir"
}

// commit returns `git rev-parse HEAD` for the checkout, trimmed. Empty on error.
func (g gitProbe) commit() string {
	out, err := g.git("rev-parse", "HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// dirty returns true iff `git status --porcelain` is non-empty (uncommitted
// changes). A probe error reports false — we do not invent dirtiness.
func (g gitProbe) dirty() bool {
	out, err := g.git("status", "--porcelain")
	if err != nil {
		return false
	}
	return strings.TrimSpace(out) != ""
}

// git runs a git subcommand against the configured checkout (via -C) when set.
func (g gitProbe) git(args ...string) (string, error) {
	if g.checkout != "" {
		args = append([]string{"-C", g.checkout}, args...)
	}
	return g.runner.Run("git", args...)
}

// ReportConfig wires gatherReport's probes. EVERY field that is unknowable in a
// test (git tree, disk, PG size, backup, the live health gate) is behind an
// injected function so tests supply fakes and production supplies the real
// thing. A nil probe func means "skip this signal honestly" (the report field
// gets its zero/unknown value), never a panic.
type ReportConfig struct {
	// Runner backs the git probe (and is the same runner the command queue
	// uses). Required for the git signals; nil leaves GitCommit empty.
	Runner CommandRunner
	// Checkout is the deployed code directory git is read from (-C). Empty reads
	// the agent's current working directory.
	Checkout string

	// DiskProbe returns root-fs used-percent (0..100). nil → DiskUsedPercent=-1.
	DiskProbe func() (int, error)
	// PGSizeProbe returns the Postgres DB size in bytes. nil → PGSizeBytes=-1.
	PGSizeProbe func() (int64, error)
	// BackupProbe returns (ok, human-detail). nil → BackupOK=false, detail noted.
	BackupProbe func() (bool, string, error)

	// HealthGate is the injected health-gate runner (defaults to
	// setup.RunHealthGate). BaseURL/Token/probe-URLs/RootCAs configure it; when
	// BaseURL is empty the gate is skipped and HealthStatus is "unknown".
	HealthBaseURL    string
	HealthToken      string
	HealthGateOpts   setup.HealthGate
	HealthRootCAs    *x509.CertPool
	runHealthGateFor func(base, token string, opts setup.HealthGate) (setup.HealthReport, error)
}

// gatherReport assembles a Report from the wired probes. It is total: a missing
// or failing probe yields an honest unknown value, never a panic, so a partial
// box still phones home with whatever it can prove.
func gatherReport(cfg ReportConfig) Report {
	r := Report{
		AgentStatus:     "online",
		Version:         Version,
		HealthStatus:    "unknown",
		DiskUsedPercent: -1,
		PGSizeBytes:     -1,
	}

	// Git signals (deployed commit + dirty tree).
	if cfg.Runner != nil {
		g := gitProbe{runner: cfg.Runner, checkout: cfg.Checkout}
		r.GitCommit = g.commit()
		r.DirtyTree = g.dirty()
	}

	// Disk.
	if cfg.DiskProbe != nil {
		if pct, err := cfg.DiskProbe(); err == nil {
			r.DiskUsedPercent = pct
		}
	}

	// Postgres size.
	if cfg.PGSizeProbe != nil {
		if sz, err := cfg.PGSizeProbe(); err == nil {
			r.PGSizeBytes = sz
		}
	}

	// Backup status.
	if cfg.BackupProbe != nil {
		ok, detail, err := cfg.BackupProbe()
		if err != nil {
			r.BackupOK, r.BackupDetail = false, "backup probe error: "+err.Error()
		} else {
			r.BackupOK, r.BackupDetail = ok, detail
		}
	} else {
		r.BackupDetail = "no backup probe wired"
	}

	// Health gate (websocket-not-403 / TLS / capabilities / studio / pg-via-api).
	if cfg.HealthBaseURL != "" {
		run := cfg.runHealthGateFor
		if run == nil {
			run = setup.RunHealthGate
		}
		opts := cfg.HealthGateOpts
		if cfg.HealthRootCAs != nil {
			opts.RootCAs = cfg.HealthRootCAs
		}
		report, err := run(cfg.HealthBaseURL, cfg.HealthToken, opts)
		r.Health = report.Checks
		if err == nil && report.OK {
			r.HealthStatus = "up"
		} else {
			r.HealthStatus = "down"
		}
	}

	return r
}
