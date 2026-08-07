// Package agent is the barkpark-agent: a transparent on-box Go binary that runs
// on each managed server, reports health/status to the control plane, and runs
// APPROVED commands pulled from a poll-based queue. It is deliberately small —
// report + poll + a fixed 6-command allowlist — and entirely injectable so the
// whole cycle is exercised against an httptest fake control plane with no live
// server. The agent is a plain binary plus a systemd unit; `bp agent
// disable/uninstall` (cloud-11) act on it, and it keeps NO hidden persistence.
package agent

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
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
	// PGTopRelations names the biggest consumers inside that total (top 10 by
	// pg_total_relation_size). nil — a JSON null, never an empty list — when the
	// probe was not wired or failed: "we did not measure" is a different fact
	// from "we measured and the database has no relations".
	PGTopRelations []RelationSize `json:"pg_top_relations"`

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
	// Load15 is the 15-minute load average — the SUSTAIN signal (charter D67),
	// carrying the same -1 unmeasured sentinel as Load1 and landing from the same
	// single read of /proc/loadavg (fields[2], which the probe already had in
	// memory and threw away).
	//
	// It exists because the sustain rule D52 asked for is not computable
	// downstream: /v1/barkparks serves ONE beat (a DISTINCT ON … ORDER BY
	// inserted_at DESC), so no consumer of the payload the console and
	// `bp cloud status` read can see a window at all. A 15-minute kernel EWMA is
	// a sustained measurement delivered as a scalar, which is why it needs no
	// window and no client state. Live: a box read load1 0.64/core — dark on any
	// single-beat fence — while its load15 read 1.89/core in the same sample.
	//
	// Load1 is kept, not replaced: it is the present-tense colour in the reason
	// string, while Load15 is what the fence is evaluated on.
	Load15 float64 `json:"load15"`

	// CPUCores is the box's usable core count (runtime.NumCPU()). It is the
	// DENOMINATOR the strained fence needs: sustained load-per-core, not a raw
	// load number. It carries no sentinel and needs none — NumCPU always answers
	// on every platform the agent builds for, so this field is always measured.
	//
	// There is deliberately NO hardcoded core-count fallback anywhere (charter
	// D52). A constant like `load1 >= 4.0` is numerically identical to
	// "2 cores × 2.0" only because every box in the fleet happens to be 2-core
	// today; it goes silently wrong on the first 4-core box, and silently wrong
	// is the failure this whole slice exists to remove.
	CPUCores int `json:"cpu_cores"`

	// SwapUsedPercent is swap consumption (0..100) and SwapTotalBytes is the
	// configured swap size. They travel as a PAIR because a bare percent cannot
	// carry three distinct states: (0, 0) is a swapless box — measured, and the
	// answer is none; (0, >0) is configured-but-idle; (-1, -1) is "could not
	// measure". The control-plane normalizer passes numbers through verbatim and
	// defers interpretation to the view, so the disambiguating total must travel
	// WITH the percent or the consumer cannot tell those apart.
	//
	// This is the vital the shipped mem_used_percent hides: MemAvailable clears
	// the floor precisely BECAUSE the BEAM has been paged out, so a box at 99.9%
	// swap can report a comfortable 58% memory.
	SwapUsedPercent int   `json:"swap_used_percent"`
	SwapTotalBytes  int64 `json:"swap_total_bytes"`

	// BeamPSSBytes and BeamSwapBytes are the BEAM's OWN footprint (Pss + Swap
	// from /proc/<beam pid>/smaps_rollup) — the single largest consumer on a
	// Barkpark box and the process the kernel OOM-kills. Both -1 when the probe
	// was not wired, no beam.smp was found, or the rollup was unreadable.
	BeamPSSBytes  int64 `json:"beam_pss_bytes"`
	BeamSwapBytes int64 `json:"beam_swap_bytes"`

	// ReqPerS is the instance's recent requests-per-second, read from the
	// instance RequestStats route over the SAME base+token seam as the health
	// gate. -1 when the probe was not wired, failed, or the instance is old and
	// lacks the route (a 404 degrades silently — version-skew honesty, D48/D51).
	ReqPerS float64 `json:"req_per_s"`
	// P95Ms is the instance's p95 request latency in milliseconds. -1 when the
	// probe was not wired/failed, OR when the instance reported p95 null (no
	// samples in the window yet) — the CP renders that unmetered, never a fake 0.
	P95Ms int `json:"p95_ms"`
	// Err5xxPerS is the instance's recent 5xx responses per second, read off the
	// SAME request-stats envelope as ReqPerS/P95Ms — the existing 60s ring, now
	// keeping the response status it was already handed and discarding (D75). -1
	// when the probe was not wired, failed, the instance predates the key, OR the
	// instance reported it null (an empty window). Zero 5xx and "no samples yet"
	// are different facts, and only one of them is good news.
	//
	// HONEST BOUND, and it must travel with the number: the ring is 60s and
	// PER-SLOT. It dies on every blue/green flip and reads an empty window for
	// the first minute after boot, so it answers "is this box answering 5xx RIGHT
	// NOW" and can never produce a cumulative count. It is also blind to 5xx the
	// BEAM never served — a Caddy 502/504 while the VM is unresponsive, which is
	// exactly the total-outage case — so a 0 here is not proof the box is
	// answering.
	Err5xxPerS float64 `json:"err_5xx_per_s"`

	// BackupOK / BackupDetail come from the injected backup-status probe — is a
	// recent backup present and scheduled?
	BackupOK     bool   `json:"backup_ok"`
	BackupDetail string `json:"backup_detail"`

	// Health carries the per-check results of the health gate (websocket-not-403
	// / TLS / capabilities / studio / postgres-via-api …) so the control plane
	// can record the granular event stream, not just the roll-up.
	Health []setup.CheckResult `json:"health_checks"`
}

// RelationSize is one named consumer of the database total: a relation and the
// bytes it occupies including indexes and TOAST (pg_total_relation_size). A
// named breakdown is what turns "3.2 GiB" into a diagnosis.
type RelationSize struct {
	Name  string `json:"name"`
	Bytes int64  `json:"bytes"`
}

// SpaceEventType is the agent-event type the space payload is posted under. It
// is deliberately NOT "health": the 60s health beat is the series the metrics
// chart reads (cloud/lib/barkpark_cloud/metrics.ex keeps only `type: "health"`
// events), and a per-slug space payload riding it crosses Postgres's 2032-byte
// TOAST_TUPLE_THRESHOLD on the compressed jsonb at 20-25 realistic slugs —
// after which a 14-day window per box goes 34MB→58MB and a 200-point metrics
// read goes 46 buffers/3.8ms → 637 buffers/9.6ms, because the metrics route
// pulls up to 200 payloads per chart. On its own type the row is never
// detoasted by a chart render at all (charter D58).
const SpaceEventType = "space"

// SiteSize is one named consumer of the sites directory: a site slug and the
// bytes its deploy tree occupies. Per-slug is strictly more useful than a
// total, because it names the site an operator would act on.
type SiteSize struct {
	Slug  string `json:"slug"`
	Bytes int64  `json:"bytes"`
}

// SpaceReport is the space payload: WHO is consuming the disk, by name. It
// answers the question "Disk 75%" never could — 75% of what, spent on what.
//
// It is posted on its own path at its own (slow) cadence, NOT folded into
// Report, and carries its intended agent-event type inline so the control-plane
// landing site records it verbatim rather than guessing (D58).
//
// HONEST ABSENCE: every unmeasured number is -1 and every unmeasured list is
// nil (a JSON null), never 0 and never []. "We did not measure" and "we
// measured and it is empty" are different facts, and under-reporting space is
// exactly the failure this payload exists to prevent.
type SpaceReport struct {
	// Type is SpaceEventType, carried in the body so the landing route records
	// the event under the right type without inferring it from the path.
	Type string `json:"type"`

	// RootUsedBytes / RootTotalBytes are the root filesystem's used and total
	// bytes from `df -P -k /`. They travel as a PAIR and never as a bare
	// percent: "75%" cannot tell a 40 GB box needing 10 GB freed from a 400 GB
	// box needing 100 GB, and the operator's next action depends on which it is.
	// Both -1 when the probe was not wired or failed.
	RootUsedBytes  int64 `json:"root_used_bytes"`
	RootTotalBytes int64 `json:"root_total_bytes"`

	// JournalBytes is what the systemd journal occupies, from
	// `journalctl --disk-usage` — a header read (~8ms warm), NOT a tree walk.
	// -1 when not wired/failed.
	JournalBytes int64 `json:"journal_bytes"`

	// PGSizeBytes / PGTopRelations reuse the EXISTING Postgres size probes
	// (pg_database_size + pg_total_relation_size), never a `du` over the data
	// directory: the database knows its own size, and walking PGDATA as root is
	// both slower and wrong (it counts WAL and temp files the operator cannot
	// act on). -1 / nil when not wired/failed.
	PGSizeBytes    int64          `json:"pg_size_bytes"`
	PGTopRelations []RelationSize `json:"pg_top_relations"`

	// SitesDir is the RESOLVED sites root the sites probe actually read — not
	// the configured one. BARKPARK_SITES_DIR is set on no box in the fleet, so
	// an env-read probe silently falls back to the default on every box; the
	// resolved path travels in the payload so a wrong root is visible instead of
	// silent (D59). It is always populated, even when the measurement failed.
	SitesDir string `json:"sites_dir"`
	// SitesBytes is the whole sites tree's size; SitesTop names the biggest
	// slugs inside it, capped at sitesTopLimit by bytes. -1 / nil when the probe
	// was not wired or failed — including a du killed at its deadline, whose
	// PARTIAL output parses as a plausible list that is silently missing half
	// the tree.
	SitesBytes int64      `json:"sites_bytes"`
	SitesTop   []SiteSize `json:"sites_top"`
}

// CommandRunner runs a single resolved argv and returns combined output. It is
// injected so tests use a fake that records calls and NEVER shells out to a real
// systemctl/make. The production runner (ExecRunner) shells out for real.
type CommandRunner interface {
	Run(name string, args ...string) (output string, err error)
}

// ExecRunner is the production CommandRunner: it runs the argv via os/exec.
type ExecRunner struct{}

// execRunnerTimeout bounds every ExecRunner.Run call. A stuck remote command
// (approved but hung — e.g. `make rebuild` wedged on a lock) must never freeze
// the agent forever; it is unexported so report_test.go can lower it to
// exercise the timeout path without a real 5-minute sleep.
var execRunnerTimeout = 5 * time.Minute

// Run executes name+args under a bounded internal deadline and returns
// combined stdout+stderr. The deadline is entirely internal to Run — the
// CommandRunner interface and its call sites (runCommand in commands.go,
// gitProbe.git above) are untouched, so a hung approved command surfaces as an
// honest "timed out after ..." error instead of wedging the agent.
func (ExecRunner) Run(name string, args ...string) (string, error) {
	return runBounded(execRunnerTimeout, name, args...)
}

// runBounded is the one place a shell-out gets its lifetime. EVERY caller picks
// its own deadline: approved queue commands get the generous execRunnerTimeout,
// per-beat probes get a short one (pgProbeTimeout). A probe that can run for
// five minutes is the three-hour runaway again one layer down — the lesson of
// that incident was an unbounded LIFETIME, not an expensive command.
func runBounded(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return string(out), fmt.Errorf("timed out after %s: %s %s", timeout, name, strings.Join(args, " "))
	}
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
	// LoadProbe returns the 1-minute AND 15-minute load averages. nil → BOTH
	// Load1 and Load15 = -1. Fail-soft as ONE unit like SwapProbe: the two come
	// from a single line of /proc/loadavg, so a failed read leaves both sentinels
	// rather than half a measurement.
	LoadProbe func() (load1 float64, load15 float64, err error)
	// ReqStatsProbe returns (req/s, p95 ms, 5xx/s) from the instance RequestStats
	// route. nil → ReqPerS, P95Ms and Err5xxPerS all -1. Fail-soft like the other
	// probes: a non-nil error leaves ALL sentinels; a successful read with a null
	// instance-side p95 or err_5xx_per_s lands req/s but keeps that field at -1
	// (see NewReqStatsProbe). Wire the production implementation with
	// NewReqStatsProbe(base, token, rootCAs).
	ReqStatsProbe func() (reqPerS float64, p95Ms int, err5xxPerS float64, err error)
	// SwapProbe returns (used percent 0..100, total swap bytes). nil → BOTH swap
	// fields keep the -1 sentinel. Gathered fail-soft as ONE unit like
	// ReqStatsProbe, not independently like CPU/Mem: a percent landed against an
	// unknown total is meaningless, so an error leaves both sentinels.
	SwapProbe func() (pct int, totalBytes int64, err error)
	// BeamProbe returns the BEAM's (PSS, swap) bytes. nil or an error → BOTH
	// BeamPSSBytes and BeamSwapBytes keep -1; the two are one measurement of one
	// process and never half-land.
	BeamProbe func() (pssBytes int64, swapBytes int64, err error)
	// PGSizeProbe returns the Postgres DB size in bytes. nil → PGSizeBytes=-1.
	// Wire the production implementation with NewPGSizeProbe(checkout).
	PGSizeProbe func() (int64, error)
	// PGTopRelationsProbe returns the top relations by total size. nil or an
	// error → PGTopRelations stays nil (unmeasured). It is SEPARATE from
	// PGSizeProbe on purpose: its cost scales with relation count, so a box with
	// thousands of partitions may lose the breakdown while still reporting the
	// cheap total. Wire it with NewPGTopRelationsProbe(checkout).
	PGTopRelationsProbe func() ([]RelationSize, error)
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
		Load15:          -1,
		ReqPerS:         -1,
		P95Ms:           -1,
		Err5xxPerS:      -1,
		SwapUsedPercent: -1,
		SwapTotalBytes:  -1,
		BeamPSSBytes:    -1,
		BeamSwapBytes:   -1,
		// Always measured, never probed: the fence's denominator (D52).
		CPUCores: runtime.NumCPU(),
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
	// Load — one read of /proc/loadavg, two averages, landed together (D67).
	if cfg.LoadProbe != nil {
		if l1, l15, err := cfg.LoadProbe(); err == nil {
			r.Load1 = l1
			r.Load15 = l15
		}
	}

	// Request stats (req/s + p95 + 5xx/s). Fail-soft as one unit: a probe error
	// leaves all three at the -1 sentinel; a null instance-side p95 or
	// err_5xx_per_s arrives as that field's -1 with a real req/s
	// (NewReqStatsProbe applies that mapping).
	if cfg.ReqStatsProbe != nil {
		if rps, p95, err5xx, err := cfg.ReqStatsProbe(); err == nil {
			r.ReqPerS = rps
			r.P95Ms = p95
			r.Err5xxPerS = err5xx
		}
	}

	// Swap. Fail-soft as ONE unit: an error leaves both sentinels, because a
	// percent without its companion total cannot be interpreted. A swapless box
	// is NOT an error — it lands (0, 0), which is a measurement.
	if cfg.SwapProbe != nil {
		if pct, total, err := cfg.SwapProbe(); err == nil {
			r.SwapUsedPercent = pct
			r.SwapTotalBytes = total
		}
	}

	// The BEAM's own footprint (PSS + swap), one process, one measurement.
	if cfg.BeamProbe != nil {
		if pss, sw, err := cfg.BeamProbe(); err == nil {
			r.BeamPSSBytes = pss
			r.BeamSwapBytes = sw
		}
	}

	// Postgres size.
	if cfg.PGSizeProbe != nil {
		if sz, err := cfg.PGSizeProbe(); err == nil {
			r.PGSizeBytes = sz
		}
	}

	// Postgres top consumers by name — independently fail-soft from the total.
	if cfg.PGTopRelationsProbe != nil {
		if rows, err := cfg.PGTopRelationsProbe(); err == nil {
			r.PGTopRelations = rows
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
// sibling wave-5 slice (cloud-console-w5-instance-req-stats — mounted in
// api/lib/barkpark_web/router.ex as GET /v1/instance/request-stats). It answers
// 200 {"req_per_s": float, "p95_ms": int|null, "window_s": int} for a valid
// bearer token; an instance built before that slice returns 404, which the probe
// degrades to sentinels (version-skew honesty, D48/D51). This string is the
// cross-slice contract — keep it in lockstep with the route the instance mounts.
const requestStatsPath = "/v1/instance/request-stats"

// reqStatsTimeout bounds the per-beat RequestStats GET. It is short by design:
// the stats read must never stall the whole report cycle, and a slow/hung box
// degrades to the -1 sentinel rather than blocking every other vital.
const reqStatsTimeout = 3 * time.Second

// reqStatsBody is the instance RequestStats response. P95Ms and Err5xxPerS are
// pointers so a JSON null (no samples in the window yet) — and an ABSENT key, an
// instance built before the field existed — are both distinguishable from a real
// 0 and map to the -1 sentinel. Never a fake zero latency, and never a fake zero
// error rate: "no samples" is not "no errors".
type reqStatsBody struct {
	ReqPerS    float64  `json:"req_per_s"`
	P95Ms      *int     `json:"p95_ms"`
	Err5xxPerS *float64 `json:"err_5xx_per_s"`
}

// NewReqStatsProbe builds the production ReqStatsProbe: a short-timeout HTTP GET
// against the instance RequestStats route (base+requestStatsPath) carrying the
// health gate's bearer token — the SAME base+token seam the health gate uses.
//
// It is fail-soft to sentinels: any transport error, non-200 status (a 404 from
// an old instance without the route included), or undecodable body returns a
// non-nil error so gatherReport keeps ReqPerS=-1, P95Ms=-1 and Err5xxPerS=-1. On
// a 200 the decoded req/s always lands; a null (or absent) p95_ms/err_5xx_per_s
// maps to the -1 sentinel while req/s still reports — an instance built before
// the 5xx field simply omits the key and the beat says "unmeasured", which is
// the same version-skew honesty the 404 path already keeps. base=="" returns a
// nil probe (unwired), mirroring how the health gate is skipped when
// HealthBaseURL is empty.
func NewReqStatsProbe(base, token string, rootCAs *x509.CertPool) func() (float64, int, float64, error) {
	base = strings.TrimRight(base, "/")
	if base == "" {
		return nil
	}
	url := base + requestStatsPath
	return func() (float64, int, float64, error) {
		req, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			return -1, -1, -1, err
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
			return -1, -1, -1, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return -1, -1, -1, fmt.Errorf("request-stats: status %d", resp.StatusCode)
		}
		var body reqStatsBody
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return -1, -1, -1, err
		}
		p95 := -1
		if body.P95Ms != nil {
			p95 = *body.P95Ms
		}
		err5xx := float64(-1)
		if body.Err5xxPerS != nil {
			err5xx = *body.Err5xxPerS
		}
		return body.ReqPerS, p95, err5xx, nil
	}
}

// pgProbeTimeout bounds each psql shell-out. It is deliberately short and
// deliberately NOT execRunnerTimeout: the approved-command runner may take five
// minutes for a rebuild, but a per-beat space probe that takes five minutes IS
// the runaway-diagnostic incident again. Unexported so a test can lower it.
var pgProbeTimeout = 5 * time.Second

// pgStatementTimeout is the server-side twin of pgProbeTimeout: it stops the
// QUERY inside Postgres rather than only killing the client, so a psql we walk
// away from cannot leave a backend churning. The top-relations query's cost
// scales with RELATION count (a box with thousands of partitions), which is why
// it is bounded on both sides as well as by LIMIT.
const pgStatementTimeout = "3000ms"

// pgSizeSQL asks for the whole database's on-disk size — the number the usage
// meter has always rendered "unmetered" because this probe was never wired.
const pgSizeSQL = "SET statement_timeout = '" + pgStatementTimeout + "'; " +
	"SELECT pg_database_size(current_database());"

// pgTopRelationsSQL names the biggest consumers inside that total. LIMIT 10 and
// the statement_timeout are both load-bearing bounds, not decoration.
const pgTopRelationsSQL = "SET statement_timeout = '" + pgStatementTimeout + "'; " +
	"SELECT c.relname, pg_total_relation_size(c.oid) " +
	"FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " +
	"WHERE c.relkind IN ('r','m','p') " +
	"AND n.nspname NOT IN ('pg_catalog','information_schema') " +
	"ORDER BY 2 DESC LIMIT 10;"

// pgTopRelationsLimit mirrors the LIMIT in pgTopRelationsSQL and is enforced
// again client-side: a probe payload must stay bounded even if the query text
// is ever edited without the parser being told.
const pgTopRelationsLimit = 10

// probeRunner is the shell-out seam the Postgres probes use. Production passes
// a runBounded closure carrying pgProbeTimeout; tests pass a fake so the psql
// contract (argv, parsing, failure paths) is provable without a live database.
type probeRunner func(name string, args ...string) (string, error)

// boundedPGRunner is the production probeRunner: psql under pgProbeTimeout.
func boundedPGRunner(name string, args ...string) (string, error) {
	return runBounded(pgProbeTimeout, name, args...)
}

// pgDatabaseURL reads DATABASE_URL out of <checkout>/.env and returns it in a
// form psql accepts.
//
// Two facts make this necessary, both verified on a live box: the agent runs as
// root, and a bare `psql` as root fails with "role root does not exist", so the
// connection string must come from somewhere — and Barkpark stores it as an
// Ecto URL whose `ecto://` scheme libpq does not understand, so the scheme is
// rewritten to `postgres://`. An unreadable .env or a missing DATABASE_URL is
// an ERROR, never a fallback to a default connection: the field must stay at
// its -1 sentinel rather than report a number measured against some other
// database.
func pgDatabaseURL(checkout string) (string, error) {
	if checkout == "" {
		return "", errors.New("pg: no checkout configured")
	}
	path := filepath.Join(checkout, ".env")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("pg: read %s: %w", path, err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		line = strings.TrimPrefix(line, "export ")
		key, val, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(key) != "DATABASE_URL" {
			continue
		}
		val = strings.TrimSpace(val)
		val = strings.Trim(val, `"'`)
		if val == "" {
			continue
		}
		// Ecto's scheme is not libpq's; everything after it is identical.
		if rest, found := strings.CutPrefix(val, "ecto://"); found {
			val = "postgres://" + rest
		}
		return val, nil
	}
	return "", fmt.Errorf("pg: no DATABASE_URL in %s", path)
}

// psqlArgs builds the argv for a single-shot, machine-readable psql query:
// -A unaligned, -t tuples only, -q quiet, -F| explicit field separator, and
// ON_ERROR_STOP so a failed SET does not silently yield a partial answer.
func psqlArgs(url, sql string) []string {
	return []string{url, "-v", "ON_ERROR_STOP=1", "-A", "-t", "-q", "-F", "|", "-c", sql}
}

// NewPGSizeProbe builds the production PGSizeProbe: psql against the checkout's
// own DATABASE_URL, bounded by pgProbeTimeout. checkout=="" returns nil
// (unwired), mirroring NewReqStatsProbe. Every failure path — no .env, no
// DATABASE_URL, no psql binary, a timeout, an unparseable answer — returns an
// error so PGSizeBytes stays -1. A box without psql reports exactly what it
// reports today; it never reports a faked zero.
func NewPGSizeProbe(checkout string) func() (int64, error) {
	return newPGSizeProbeWith(boundedPGRunner, checkout)
}

func newPGSizeProbeWith(run probeRunner, checkout string) func() (int64, error) {
	if checkout == "" {
		return nil
	}
	return func() (int64, error) {
		url, err := pgDatabaseURL(checkout)
		if err != nil {
			return -1, err
		}
		out, err := run("psql", psqlArgs(url, pgSizeSQL)...)
		if err != nil {
			return -1, fmt.Errorf("pg size: %w: %s", err, strings.TrimSpace(out))
		}
		return parsePGSize(out)
	}
}

// parsePGSize reads the single integer psql prints for pg_database_size.
func parsePGSize(out string) (int64, error) {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		n, err := strconv.ParseInt(line, 10, 64)
		if err != nil {
			return -1, fmt.Errorf("pg size: unparseable %q", line)
		}
		return n, nil
	}
	return -1, errors.New("pg size: empty result")
}

// NewPGTopRelationsProbe builds the production PGTopRelationsProbe: the top 10
// relations by pg_total_relation_size, same seam and same bound as the total.
// checkout=="" returns nil (unwired); every failure returns an error so
// PGTopRelations stays nil rather than an invented empty list.
func NewPGTopRelationsProbe(checkout string) func() ([]RelationSize, error) {
	return newPGTopRelationsProbeWith(boundedPGRunner, checkout)
}

func newPGTopRelationsProbeWith(run probeRunner, checkout string) func() ([]RelationSize, error) {
	if checkout == "" {
		return nil
	}
	return func() ([]RelationSize, error) {
		url, err := pgDatabaseURL(checkout)
		if err != nil {
			return nil, err
		}
		out, err := run("psql", psqlArgs(url, pgTopRelationsSQL)...)
		if err != nil {
			return nil, fmt.Errorf("pg top relations: %w: %s", err, strings.TrimSpace(out))
		}
		return parsePGTopRelations(out)
	}
}

// parsePGTopRelations turns psql's "name|bytes" lines into RelationSize rows,
// re-applying pgTopRelationsLimit client-side so the beat payload stays bounded
// no matter what the query returned.
func parsePGTopRelations(out string) ([]RelationSize, error) {
	var rows []RelationSize
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		name, sizeStr, ok := strings.Cut(line, "|")
		if !ok {
			return nil, fmt.Errorf("pg top relations: unparseable %q", line)
		}
		n, err := strconv.ParseInt(strings.TrimSpace(sizeStr), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("pg top relations: unparseable size in %q", line)
		}
		rows = append(rows, RelationSize{Name: strings.TrimSpace(name), Bytes: n})
		if len(rows) == pgTopRelationsLimit {
			break
		}
	}
	if len(rows) == 0 {
		return nil, errors.New("pg top relations: empty result")
	}
	return rows, nil
}

// SpaceConfig wires gatherSpace's probes, exactly like ReportConfig wires the
// beat's. Every probe is injected so the whole space payload is provable
// without a real df/journalctl/du/psql, and a nil probe means "skip this
// consumer honestly" — its field keeps the unmeasured sentinel.
type SpaceConfig struct {
	// RootProbe returns the root filesystem's (used, total) bytes. nil → both -1.
	RootProbe func() (usedBytes int64, totalBytes int64, err error)
	// JournalProbe returns the systemd journal's bytes. nil → -1.
	JournalProbe func() (int64, error)
	// PGSizeProbe / PGTopRelationsProbe are the SAME constructors the beat uses
	// (NewPGSizeProbe / NewPGTopRelationsProbe) — the database is measured one
	// way, in one place, never by a `du` over PGDATA. nil → -1 / nil.
	PGSizeProbe         func() (int64, error)
	PGTopRelationsProbe func() ([]RelationSize, error)
	// SitesDir is the RESOLVED sites root, echoed into the payload whether or
	// not the measurement succeeds.
	SitesDir string
	// SitesProbe returns (total bytes, per-slug sizes) for SitesDir. nil or an
	// error → SitesBytes=-1 and SitesTop=nil, as ONE unit: a total without its
	// breakdown is the uninformative number this payload replaces, and a
	// breakdown without its total cannot be sanity-checked.
	SitesProbe func() (totalBytes int64, top []SiteSize, err error)
}

// gatherSpace assembles a SpaceReport from the wired probes. Like gatherReport
// it is total: a missing or failing probe yields the unmeasured sentinel, never
// a panic and never a partial number.
func gatherSpace(cfg SpaceConfig) SpaceReport {
	s := SpaceReport{
		Type:           SpaceEventType,
		RootUsedBytes:  -1,
		RootTotalBytes: -1,
		JournalBytes:   -1,
		PGSizeBytes:    -1,
		SitesDir:       cfg.SitesDir,
		SitesBytes:     -1,
	}

	// Root filesystem: used AND total, one measurement, never half-landed.
	if cfg.RootProbe != nil {
		if used, total, err := cfg.RootProbe(); err == nil {
			s.RootUsedBytes, s.RootTotalBytes = used, total
		}
	}

	if cfg.JournalProbe != nil {
		if n, err := cfg.JournalProbe(); err == nil {
			s.JournalBytes = n
		}
	}

	if cfg.PGSizeProbe != nil {
		if n, err := cfg.PGSizeProbe(); err == nil {
			s.PGSizeBytes = n
		}
	}
	if cfg.PGTopRelationsProbe != nil {
		if rows, err := cfg.PGTopRelationsProbe(); err == nil {
			s.PGTopRelations = rows
		}
	}

	// Sites: total + per-slug, one unit.
	if cfg.SitesProbe != nil {
		if total, top, err := cfg.SitesProbe(); err == nil {
			s.SitesBytes, s.SitesTop = total, top
		}
	}

	return s
}

// The space probes' deadlines. Each is probe-SPECIFIC, and each is a LIFETIME
// bound on the shell-out (runBounded), not a hint: df and journalctl are header
// reads that finish in milliseconds, while du walks a tree and was measured at
// 2.03s cold / 0.36s warm on a loaded 2-core box. Unexported so tests can lower
// them.
var (
	dfProbeTimeout      = 5 * time.Second
	journalProbeTimeout = 10 * time.Second
	duProbeTimeout      = 60 * time.Second
)

// sitesTopLimit caps the per-slug list. Ten slugs compress to ~1685 B, safely
// inside Postgres's 2032-byte TOAST_TUPLE_THRESHOLD; an uncapped list crosses
// it between 20 and 25 realistic high-entropy slugs (D58). The cap is also the
// useful shape: an operator acts on the biggest site, not on the 40th.
const sitesTopLimit = 10

// boundedSpaceRunner returns a probeRunner bound to timeout. Every space probe
// goes through one — a probe that can run forever is the runaway-diagnostic
// incident again, one layer down.
func boundedSpaceRunner(timeout time.Duration) probeRunner {
	return func(name string, args ...string) (string, error) {
		return runBounded(timeout, name, args...)
	}
}

// dfRootArgs is the root-filesystem argv. `-P` pins the POSIX one-line-per-fs
// format (no wrapped device names) and `-k` pins 1024-byte blocks, so the
// parser never has to guess the unit from the header. DIRECT argv — no shell.
func dfRootArgs() []string { return []string{"-P", "-k", "/"} }

// NewRootSpaceProbe builds the production root-filesystem probe: `df -P -k /`
// under dfProbeTimeout. A non-zero exit or an unparseable table is an error, so
// both bytes keep their -1 sentinel.
func NewRootSpaceProbe() func() (int64, int64, error) {
	return newRootSpaceProbeWith(boundedSpaceRunner(dfProbeTimeout))
}

func newRootSpaceProbeWith(run probeRunner) func() (int64, int64, error) {
	return func() (int64, int64, error) {
		out, err := run("df", dfRootArgs()...)
		if err != nil {
			return -1, -1, fmt.Errorf("df: %w: %s", err, strings.TrimSpace(out))
		}
		return parseDFRoot(out)
	}
}

// parseDFRoot reads (used, total) bytes from `df -P -k` output. Columns are
// indexed from the END (…blocks used avail capacity mount) so a device name
// containing spaces cannot shift the numbers — and the capacity percent is
// deliberately ignored: a bare percent is the number that tells an operator
// nothing.
func parseDFRoot(out string) (int64, int64, error) {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		fields := strings.Fields(lines[i])
		if len(fields) < 6 {
			continue
		}
		total, errT := strconv.ParseInt(fields[len(fields)-5], 10, 64)
		used, errU := strconv.ParseInt(fields[len(fields)-4], 10, 64)
		if errT != nil || errU != nil {
			continue // the header row
		}
		// df -k reports 1024-byte blocks.
		return used * 1024, total * 1024, nil
	}
	return -1, -1, errors.New("df: no data row")
}

// journalArgs is the journal argv: `journalctl --disk-usage` reads the journal
// files' own headers (~8ms warm) rather than walking /var/log/journal.
func journalArgs() []string { return []string{"--disk-usage"} }

// NewJournalSpaceProbe builds the production journal probe under
// journalProbeTimeout. A box without journald errors, so JournalBytes keeps its
// -1 sentinel rather than reporting a fictional zero.
func NewJournalSpaceProbe() func() (int64, error) {
	return newJournalSpaceProbeWith(boundedSpaceRunner(journalProbeTimeout))
}

func newJournalSpaceProbeWith(run probeRunner) func() (int64, error) {
	return func() (int64, error) {
		out, err := run("journalctl", journalArgs()...)
		if err != nil {
			return -1, fmt.Errorf("journalctl: %w: %s", err, strings.TrimSpace(out))
		}
		return parseJournalDiskUsage(out)
	}
}

// parseJournalDiskUsage pulls the size out of journalctl's one prose line
// ("Archived and active journals take up 3.7G in the file system."). The first
// field that parses as a human size wins; the surrounding words never do.
func parseJournalDiskUsage(out string) (int64, error) {
	for _, f := range strings.Fields(out) {
		if n, err := parseHumanBytes(strings.Trim(f, ".,")); err == nil {
			return n, nil
		}
	}
	return -1, fmt.Errorf("journalctl: no size in %q", truncate(strings.TrimSpace(out), 120))
}

// duSitesArgs is the sites argv, and it is a contract, not a preference:
//
//   - `nice -n 19 ionice -c3` — the walk yields to everything else on a box
//     that is already struggling; measuring pressure must not add it.
//   - `-x` never crosses a filesystem boundary (a mounted volume under the
//     tree would otherwise be counted against the sites).
//   - `-d1` bounds the depth to the direct children — one row per slug.
//     (`-s` CONFLICTS with `-d1` in coreutils 9.4; the root total comes from
//     `-d1`'s own last row.)
//   - DIRECT argv, never `sh -c`, no pipes, no `2>&1`, no `; echo rc=$?`.
//     Measured: under an identical 200ms bound, direct argv returned at 200ms
//     while an `sh -c` wrapper returned at 8.77s — 44x over budget — because
//     exec.CommandContext kills only cmd.Process (no process-group kill) and
//     CombinedOutput then blocks in Wait until the orphaned grandchild closes
//     the inherited stdout pipe. BOTH return the identical `signal: killed`, so
//     the caller cannot tell the bound was blown (charter D59).
//
// TestSitesProbeArgvIsDirect pins this shape so no future edit can quietly
// reintroduce a shell.
func duSitesArgs(dir string) []string {
	return []string{"-n", "19", "ionice", "-c3", "du", "-hx", "-d1", dir}
}

// NewSitesSpaceProbe builds the production per-slug sites probe for dir, under
// duProbeTimeout. dir=="" returns nil (unwired), mirroring the PG probes.
func NewSitesSpaceProbe(dir string) func() (int64, []SiteSize, error) {
	return newSitesSpaceProbeWith(boundedSpaceRunner(duProbeTimeout), dir)
}

func newSitesSpaceProbeWith(run probeRunner, dir string) func() (int64, []SiteSize, error) {
	if dir == "" {
		return nil
	}
	return func() (int64, []SiteSize, error) {
		out, err := run("nice", duSitesArgs(dir)...)
		if err != nil {
			// DISCARD, never partially land. A du killed at its deadline prints
			// the rows it had already finished — 5 site rows, then rc=137 — and
			// those rows parse as a perfectly plausible list silently missing
			// the rest of the tree. Under-reporting space is precisely the
			// failure this payload exists to remove, so a non-zero exit reports
			// unmeasured.
			return -1, nil, fmt.Errorf("du %s: %w: %s", dir, err, truncate(strings.TrimSpace(out), 120))
		}
		return parseDuTree(out, dir)
	}
}

// parseDuTree turns `du -hx -d1 <dir>` output into (total bytes, per-slug sizes
// capped at sitesTopLimit by bytes). The row whose path IS dir is the total;
// every other row is one slug, named by its base name.
//
// The total row is REQUIRED: du prints its root last, so output without it is
// output that was cut short, and a truncated walk must not land as a
// measurement.
func parseDuTree(out string, dir string) (int64, []SiteSize, error) {
	want := filepath.Clean(dir)
	var total int64 = -1
	var rows []SiteSize
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		sizeStr, path, ok := strings.Cut(line, "\t")
		if !ok {
			// du separates with a tab; fall back to whitespace for robustness.
			fields := strings.Fields(line)
			if len(fields) < 2 {
				return -1, nil, fmt.Errorf("du: unparseable %q", line)
			}
			sizeStr, path = fields[0], strings.Join(fields[1:], " ")
		}
		n, err := parseHumanBytes(strings.TrimSpace(sizeStr))
		if err != nil {
			return -1, nil, fmt.Errorf("du: unparseable size in %q", line)
		}
		path = filepath.Clean(strings.TrimSpace(path))
		if path == want {
			total = n
			continue
		}
		rows = append(rows, SiteSize{Slug: filepath.Base(path), Bytes: n})
	}
	if total < 0 {
		return -1, nil, fmt.Errorf("du: no total row for %s", want)
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Bytes > rows[j].Bytes })
	if len(rows) > sitesTopLimit {
		rows = rows[:sitesTopLimit]
	}
	return total, rows, nil
}

// humanUnits maps du/journalctl's single-letter suffixes to powers of 1024.
// Both tools report binary multiples (`du -h` 1K = 1024 bytes).
var humanUnits = map[byte]float64{
	'K': 1 << 10,
	'M': 1 << 20,
	'G': 1 << 30,
	'T': 1 << 40,
	'P': 1 << 50,
	'E': 1 << 60,
}

// parseHumanBytes reads "3.7G", "628M", "4.0K", "12B" or a bare byte count into
// bytes. An unsuffixed value is bytes; an unknown suffix is an error, never a
// silently-dropped magnitude — misreading "3.7G" as 3.7 would under-report the
// journal by a billion.
func parseHumanBytes(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, errors.New("empty size")
	}
	// Tolerate an "iB"/"B" suffix (some builds print 3.7GiB / 3.7GB).
	upper := strings.ToUpper(s)
	upper = strings.TrimSuffix(upper, "B")
	upper = strings.TrimSuffix(upper, "I")
	if upper == "" {
		return 0, fmt.Errorf("unparseable size %q", s)
	}
	last := upper[len(upper)-1]
	if mult, ok := humanUnits[last]; ok {
		v, err := strconv.ParseFloat(upper[:len(upper)-1], 64)
		if err != nil {
			return 0, fmt.Errorf("unparseable size %q", s)
		}
		if v < 0 {
			return 0, fmt.Errorf("negative size %q", s)
		}
		return int64(v*mult + 0.5), nil
	}
	v, err := strconv.ParseInt(upper, 10, 64)
	if err != nil || v < 0 {
		return 0, fmt.Errorf("unparseable size %q", s)
	}
	return v, nil
}
