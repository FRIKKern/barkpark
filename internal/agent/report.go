// Package agent is the barkpark-agent: a transparent on-box Go binary that runs
// on each managed server, reports health/status to the control plane, and runs
// APPROVED commands pulled from a poll-based queue. It is deliberately small —
// report + poll + a fixed 6-command allowlist — and entirely injectable so the
// whole cycle is exercised against an httptest fake control plane with no live
// server. The agent is a plain binary plus a systemd unit; `bp agent
// disable/uninstall` (cloud-11) act on it, and it keeps NO hidden persistence.
package agent

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"time"

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

	// Vitals — the host's live resource pressure, gathered every beat behind the
	// same injectable-probe seam as disk (Linux /proc readers in production).
	// Each carries a -1 sentinel when its probe was not wired or failed, so a
	// partial box still phones home the rest and the control plane renders a null
	// point (nil-not-zero) rather than a fake reading.
	//
	// CPUUsedPercent is host CPU busy percent (0..100). -1 when not wired/failed.
	CPUUsedPercent int `json:"cpu_percent"`
	// MemUsedPercent is used-memory percent (0..100). -1 when not wired/failed.
	MemUsedPercent int `json:"mem_used_percent"`
	// Load1 is the 1-minute load average. -1 when the probe was not wired/failed.
	Load1 float64 `json:"load1"`

	// ReqPerS is the instance's recent requests-per-second, read from the
	// instance RequestStats route over the SAME base+token seam as the health
	// gate. -1 when the probe was not wired, failed, or the instance is old and
	// lacks the route (a 404 degrades silently — version-skew honesty, D48/D51).
	ReqPerS float64 `json:"req_per_s"`
	// P95Ms is the instance's p95 request latency in milliseconds. -1 when the
	// probe was not wired/failed, OR when the instance reported p95 null (no
	// samples in the window yet) — the CP renders that unmetered, never a fake 0.
	P95Ms int `json:"p95_ms"`

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
	// CPUProbe returns host CPU busy-percent (0..100). nil → CPUUsedPercent=-1.
	CPUProbe func() (int, error)
	// MemProbe returns used-memory percent (0..100). nil → MemUsedPercent=-1.
	MemProbe func() (int, error)
	// LoadProbe returns the 1-minute load average. nil → Load1=-1.
	LoadProbe func() (float64, error)
	// ReqStatsProbe returns (req/s, p95 ms) from the instance RequestStats route.
	// nil → ReqPerS=-1 and P95Ms=-1. Fail-soft like the other probes: a non-nil
	// error leaves BOTH sentinels; a successful read with a null instance-side p95
	// lands req/s but keeps P95Ms=-1 (see NewReqStatsProbe). Wire the production
	// implementation with NewReqStatsProbe(base, token, rootCAs).
	ReqStatsProbe func() (reqPerS float64, p95Ms int, err error)
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
		CPUUsedPercent:  -1,
		MemUsedPercent:  -1,
		Load1:           -1,
		ReqPerS:         -1,
		P95Ms:           -1,
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

	// CPU / memory / load — the per-beat vitals, each independently fail-soft.
	if cfg.CPUProbe != nil {
		if pct, err := cfg.CPUProbe(); err == nil {
			r.CPUUsedPercent = pct
		}
	}
	if cfg.MemProbe != nil {
		if pct, err := cfg.MemProbe(); err == nil {
			r.MemUsedPercent = pct
		}
	}
	if cfg.LoadProbe != nil {
		if l, err := cfg.LoadProbe(); err == nil {
			r.Load1 = l
		}
	}

	// Request stats (req/s + p95). Fail-soft as one unit: a probe error leaves
	// both at the -1 sentinel; a null instance-side p95 arrives as P95Ms=-1 with
	// a real req/s (NewReqStatsProbe applies that mapping).
	if cfg.ReqStatsProbe != nil {
		if rps, p95, err := cfg.ReqStatsProbe(); err == nil {
			r.ReqPerS = rps
			r.P95Ms = p95
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

// requestStatsPath is the instance route the ReqStatsProbe reads, served by the
// sibling wave-5 slice (cloud-console-w5-instance-req-stats). It answers
// 200 {"req_per_s": float, "p95_ms": int|null, "window_s": int} for a valid
// bearer token; an instance built before that slice returns 404, which the probe
// degrades to sentinels (version-skew honesty, D48/D51). This string is the
// cross-slice contract — keep it in lockstep with the route the instance mounts.
const requestStatsPath = "/v1/request-stats"

// reqStatsTimeout bounds the per-beat RequestStats GET. It is short by design:
// the stats read must never stall the whole report cycle, and a slow/hung box
// degrades to the -1 sentinel rather than blocking every other vital.
const reqStatsTimeout = 3 * time.Second

// reqStatsBody is the instance RequestStats response. P95Ms is a pointer so a
// JSON null (no samples in the window yet) is distinguishable from a real 0 and
// maps to the -1 sentinel — never a fake zero latency.
type reqStatsBody struct {
	ReqPerS float64 `json:"req_per_s"`
	P95Ms   *int    `json:"p95_ms"`
}

// NewReqStatsProbe builds the production ReqStatsProbe: a short-timeout HTTP GET
// against the instance RequestStats route (base+requestStatsPath) carrying the
// health gate's bearer token — the SAME base+token seam the health gate uses.
//
// It is fail-soft to sentinels: any transport error, non-200 status (a 404 from
// an old instance without the route included), or undecodable body returns a
// non-nil error so gatherReport keeps ReqPerS=-1 and P95Ms=-1. On a 200 the
// decoded req/s always lands; a null p95_ms maps to the -1 sentinel while req/s
// still reports. base=="" returns a nil probe (unwired), mirroring how the
// health gate is skipped when HealthBaseURL is empty.
func NewReqStatsProbe(base, token string, rootCAs *x509.CertPool) func() (float64, int, error) {
	base = strings.TrimRight(base, "/")
	if base == "" {
		return nil
	}
	url := base + requestStatsPath
	return func() (float64, int, error) {
		req, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			return -1, -1, err
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		client := &http.Client{Timeout: reqStatsTimeout}
		if rootCAs != nil {
			tr := http.DefaultTransport.(*http.Transport).Clone()
			tr.TLSClientConfig = &tls.Config{RootCAs: rootCAs}
			client.Transport = tr
		}
		resp, err := client.Do(req)
		if err != nil {
			return -1, -1, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return -1, -1, fmt.Errorf("request-stats: status %d", resp.StatusCode)
		}
		var body reqStatsBody
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return -1, -1, err
		}
		p95 := -1
		if body.P95Ms != nil {
			p95 = *body.P95Ms
		}
		return body.ReqPerS, p95, nil
	}
}
