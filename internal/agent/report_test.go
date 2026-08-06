package agent

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
		CPUProbe:    func() (int, error) { return 73, nil },
		MemProbe:    func() (int, error) { return 61, nil },
		LoadProbe:   func() (float64, error) { return 1.25, nil },
		PGSizeProbe: func() (int64, error) { return 1234567, nil },
		SwapProbe:   func() (int, int64, error) { return 99, 2147479552, nil },
		BeamProbe:   func() (int64, int64, error) { return 1602224128, 1233125376, nil },
		PGTopRelationsProbe: func() ([]RelationSize, error) {
			return []RelationSize{{Name: "mutation_events", Bytes: 1510000000}}, nil
		},
		ReqStatsProbe: func() (float64, int, error) { return 12.5, 87, nil },
		BackupProbe:   func() (bool, string, error) { return true, "last backup 2h ago", nil },

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
	if r.CPUUsedPercent != 73 {
		t.Errorf("CPUUsedPercent = %d, want 73", r.CPUUsedPercent)
	}
	if r.MemUsedPercent != 61 {
		t.Errorf("MemUsedPercent = %d, want 61", r.MemUsedPercent)
	}
	if r.Load1 != 1.25 {
		t.Errorf("Load1 = %v, want 1.25", r.Load1)
	}
	if r.PGSizeBytes != 1234567 {
		t.Errorf("PGSizeBytes = %d, want 1234567", r.PGSizeBytes)
	}
	if len(r.PGTopRelations) != 1 || r.PGTopRelations[0].Name != "mutation_events" {
		t.Errorf("PGTopRelations = %+v, want the one named consumer", r.PGTopRelations)
	}
	if r.SwapUsedPercent != 99 || r.SwapTotalBytes != 2147479552 {
		t.Errorf("swap = (%d, %d), want (99, 2147479552)", r.SwapUsedPercent, r.SwapTotalBytes)
	}
	if r.BeamPSSBytes != 1602224128 || r.BeamSwapBytes != 1233125376 {
		t.Errorf("beam = (%d, %d), want (1602224128, 1233125376)", r.BeamPSSBytes, r.BeamSwapBytes)
	}
	if r.ReqPerS != 12.5 {
		t.Errorf("ReqPerS = %v, want 12.5", r.ReqPerS)
	}
	if r.P95Ms != 87 {
		t.Errorf("P95Ms = %d, want 87", r.P95Ms)
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
	if r.CPUUsedPercent != -1 {
		t.Errorf("CPUUsedPercent = %d, want -1 (no probe)", r.CPUUsedPercent)
	}
	if r.MemUsedPercent != -1 {
		t.Errorf("MemUsedPercent = %d, want -1 (no probe)", r.MemUsedPercent)
	}
	if r.Load1 != -1 {
		t.Errorf("Load1 = %v, want -1 (no probe)", r.Load1)
	}
	if r.PGSizeBytes != -1 {
		t.Errorf("PGSizeBytes = %d, want -1 (no probe)", r.PGSizeBytes)
	}
	if r.ReqPerS != -1 {
		t.Errorf("ReqPerS = %v, want -1 (no probe)", r.ReqPerS)
	}
	if r.P95Ms != -1 {
		t.Errorf("P95Ms = %d, want -1 (no probe)", r.P95Ms)
	}
	if r.SwapUsedPercent != -1 || r.SwapTotalBytes != -1 {
		t.Errorf("swap = (%d, %d), want both -1 (no probe)", r.SwapUsedPercent, r.SwapTotalBytes)
	}
	if r.BeamPSSBytes != -1 || r.BeamSwapBytes != -1 {
		t.Errorf("beam = (%d, %d), want both -1 (no probe)", r.BeamPSSBytes, r.BeamSwapBytes)
	}
	if r.PGTopRelations != nil {
		t.Errorf("PGTopRelations = %+v, want nil (unmeasured is a JSON null, not an empty list)", r.PGTopRelations)
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

// TestGatherReportVitalsFailSoft proves each vital probe is INDEPENDENTLY
// fail-soft: a CPU probe that errors leaves CPUUsedPercent at the -1 sentinel
// while a wired memory/load probe still lands its reading. A partial box phones
// home whatever it can prove.
func TestGatherReportVitalsFailSoft(t *testing.T) {
	r := gatherReport(ReportConfig{
		CPUProbe:  func() (int, error) { return 0, errors.New("no /proc/stat") },
		MemProbe:  func() (int, error) { return 55, nil },
		LoadProbe: func() (float64, error) { return 0.5, nil },
	})

	if r.CPUUsedPercent != -1 {
		t.Errorf("CPUUsedPercent = %d, want -1 (probe errored)", r.CPUUsedPercent)
	}
	if r.MemUsedPercent != 55 {
		t.Errorf("MemUsedPercent = %d, want 55 (probe ok)", r.MemUsedPercent)
	}
	if r.Load1 != 0.5 {
		t.Errorf("Load1 = %v, want 0.5 (probe ok)", r.Load1)
	}
	// A zero-CPU reading is real data, not the sentinel: a probe returning 0
	// must land 0, distinct from -1.
	r2 := gatherReport(ReportConfig{CPUProbe: func() (int, error) { return 0, nil }})
	if r2.CPUUsedPercent != 0 {
		t.Errorf("CPUUsedPercent = %d, want 0 (idle is real, not the -1 sentinel)", r2.CPUUsedPercent)
	}
}

// TestGatherReportReqStatsWiring proves the ReqStatsProbe is fail-soft as one
// unit: a probe error leaves BOTH req/s and p95 at the -1 sentinel (never a fake
// 0), while a success with a null instance-side p95 lands req/s and keeps p95 at
// -1. This is the version-skew / no-samples honesty the CP relies on.
func TestGatherReportReqStatsWiring(t *testing.T) {
	// Probe error → both sentinels.
	rErr := gatherReport(ReportConfig{
		ReqStatsProbe: func() (float64, int, error) { return 0, 0, errors.New("404") },
	})
	if rErr.ReqPerS != -1 {
		t.Errorf("ReqPerS = %v, want -1 (probe errored, not a fake 0)", rErr.ReqPerS)
	}
	if rErr.P95Ms != -1 {
		t.Errorf("P95Ms = %d, want -1 (probe errored, not a fake 0)", rErr.P95Ms)
	}

	// Success with null p95 → req/s lands, p95 stays the -1 sentinel.
	rNull := gatherReport(ReportConfig{
		ReqStatsProbe: func() (float64, int, error) { return 3.0, -1, nil },
	})
	if rNull.ReqPerS != 3.0 {
		t.Errorf("ReqPerS = %v, want 3.0", rNull.ReqPerS)
	}
	if rNull.P95Ms != -1 {
		t.Errorf("P95Ms = %d, want -1 (instance p95 null)", rNull.P95Ms)
	}

	// A real 0 req/s (idle box) is data, not the sentinel.
	rIdle := gatherReport(ReportConfig{
		ReqStatsProbe: func() (float64, int, error) { return 0, 0, nil },
	})
	if rIdle.ReqPerS != 0 {
		t.Errorf("ReqPerS = %v, want 0 (idle is real, not the -1 sentinel)", rIdle.ReqPerS)
	}
	if rIdle.P95Ms != 0 {
		t.Errorf("P95Ms = %d, want 0 (real 0 latency, not the -1 sentinel)", rIdle.P95Ms)
	}
}

// TestNewReqStatsProbeHTTP exercises the production HTTP probe against a fake
// instance RequestStats route: a 200 maps req/s + p95; a null p95 degrades to
// the -1 sentinel; a 404 (old instance without the route), a non-200, and an
// undecodable body all fail-soft with a non-nil error (so gatherReport keeps the
// sentinels); the bearer token rides the SAME seam as the health gate.
func TestNewReqStatsProbeHTTP(t *testing.T) {
	t.Run("200 maps req/s and p95, token sent", func(t *testing.T) {
		var gotAuth string
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			gotAuth = req.Header.Get("Authorization")
			if req.URL.Path != requestStatsPath {
				t.Errorf("path = %q, want %q", req.URL.Path, requestStatsPath)
			}
			w.Write([]byte(`{"req_per_s": 42.5, "p95_ms": 128, "window_s": 60}`))
		}))
		defer srv.Close()

		probe := NewReqStatsProbe(srv.URL, "sekret", nil)
		if probe == nil {
			t.Fatal("probe is nil, want a wired probe")
		}
		rps, p95, err := probe()
		if err != nil {
			t.Fatalf("probe error: %v", err)
		}
		if rps != 42.5 {
			t.Errorf("req/s = %v, want 42.5", rps)
		}
		if p95 != 128 {
			t.Errorf("p95 = %d, want 128", p95)
		}
		if gotAuth != "Bearer sekret" {
			t.Errorf("Authorization = %q, want Bearer sekret", gotAuth)
		}
	})

	t.Run("null p95 → -1 sentinel, req/s still lands", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`{"req_per_s": 7.0, "p95_ms": null, "window_s": 60}`))
		}))
		defer srv.Close()

		rps, p95, err := NewReqStatsProbe(srv.URL, "", nil)()
		if err != nil {
			t.Fatalf("probe error: %v", err)
		}
		if rps != 7.0 {
			t.Errorf("req/s = %v, want 7.0", rps)
		}
		if p95 != -1 {
			t.Errorf("p95 = %d, want -1 (instance reported null — no samples)", p95)
		}
	})

	t.Run("404 (old instance) → error, sentinels via gatherReport", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "not found", http.StatusNotFound)
		}))
		defer srv.Close()

		rps, p95, err := NewReqStatsProbe(srv.URL, "", nil)()
		if err == nil {
			t.Fatal("err = nil, want a non-nil error on 404")
		}
		if rps != -1 || p95 != -1 {
			t.Errorf("(req/s, p95) = (%v, %d), want (-1, -1) on 404", rps, p95)
		}
		// And the sentinel actually reaches the Report through gatherReport.
		r := gatherReport(ReportConfig{ReqStatsProbe: NewReqStatsProbe(srv.URL, "", nil)})
		if r.ReqPerS != -1 || r.P95Ms != -1 {
			t.Errorf("Report = (%v, %d), want (-1, -1) — an old instance degrades silently", r.ReqPerS, r.P95Ms)
		}
	})

	t.Run("non-200 → error", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
		}))
		defer srv.Close()
		if _, _, err := NewReqStatsProbe(srv.URL, "", nil)(); err == nil {
			t.Error("err = nil, want a non-nil error on 500")
		}
	})

	t.Run("undecodable body → error", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`not json`))
		}))
		defer srv.Close()
		if _, _, err := NewReqStatsProbe(srv.URL, "", nil)(); err == nil {
			t.Error("err = nil, want a non-nil error on an undecodable body")
		}
	})

	t.Run("transport error → error", func(t *testing.T) {
		// A closed server's URL yields a connection-refused transport error.
		srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		url := srv.URL
		srv.Close()
		if _, _, err := NewReqStatsProbe(url, "", nil)(); err == nil {
			t.Error("err = nil, want a transport error against a closed server")
		}
	})

	t.Run("empty base → nil probe (unwired)", func(t *testing.T) {
		if NewReqStatsProbe("", "tok", nil) != nil {
			t.Error("NewReqStatsProbe(\"\") != nil, want nil (unwired, mirrors the health gate)")
		}
	})
}

// TestReportJSONFieldNames pins the wire contract: the control plane stores the
// beat payload verbatim, so the req_per_s / p95_ms JSON key strings ARE the
// contract and must never drift.
func TestReportJSONFieldNames(t *testing.T) {
	blob, err := json.Marshal(gatherReport(ReportConfig{}))
	if err != nil {
		t.Fatalf("marshal Report: %v", err)
	}
	s := string(blob)
	for _, key := range []string{
		`"req_per_s":`, `"p95_ms":`,
		`"swap_used_percent":`, `"swap_total_bytes":`,
		`"beam_pss_bytes":`, `"beam_swap_bytes":`,
		`"pg_top_relations":`,
	} {
		if !strings.Contains(s, key) {
			t.Errorf("Report JSON missing %s — the CP reads this key verbatim; payload=%s", key, s)
		}
	}
}

// TestExecRunnerDeadline proves ExecRunner.Run applies a bounded internal
// deadline: a command that sleeps past a lowered timeout returns PROMPTLY with
// a "timed out" error (never blocking for the command's real duration), while
// a fast command's happy-path output is unchanged. Fails before the fix — a
// bare exec.Command(...).CombinedOutput() would block for the full sleep.
func TestExecRunnerDeadline(t *testing.T) {
	orig := execRunnerTimeout
	defer func() { execRunnerTimeout = orig }()

	t.Run("stuck command times out promptly", func(t *testing.T) {
		execRunnerTimeout = 50 * time.Millisecond

		done := make(chan struct{})
		var out string
		var err error
		go func() {
			out, err = ExecRunner{}.Run("sleep", "5")
			close(done)
		}()

		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Fatal("ExecRunner.Run did not return promptly after the deadline elapsed")
		}

		if err == nil {
			t.Fatal("err = nil, want a timeout error")
		}
		if !strings.Contains(err.Error(), "timed out after") {
			t.Errorf("err = %q, want it to contain %q", err.Error(), "timed out after")
		}
		_ = out
	})

	t.Run("fast command happy path unchanged", func(t *testing.T) {
		execRunnerTimeout = 5 * time.Second

		out, err := ExecRunner{}.Run("echo", "hello")
		if err != nil {
			t.Fatalf("err = %v, want nil for a fast command", err)
		}
		if strings.TrimSpace(out) != "hello" {
			t.Errorf("out = %q, want %q", strings.TrimSpace(out), "hello")
		}
	})
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

// TestGatherReportSwapAndBeamFailSoftAsPairs proves swap and the BEAM footprint
// each fold as ONE unit: an erroring probe leaves BOTH of its fields at -1, and
// a swapless (0, 0) reading LANDS rather than being mistaken for the sentinel.
// A half-landed percent against an unknown total cannot be interpreted.
func TestGatherReportSwapAndBeamFailSoftAsPairs(t *testing.T) {
	t.Run("erroring probes leave both sentinels", func(t *testing.T) {
		r := gatherReport(ReportConfig{
			SwapProbe: func() (int, int64, error) { return 55, 999, errors.New("no /proc/meminfo") },
			BeamProbe: func() (int64, int64, error) { return 5, 6, errors.New("no beam.smp") },
		})
		if r.SwapUsedPercent != -1 || r.SwapTotalBytes != -1 {
			t.Errorf("swap = (%d, %d), want both -1 — a percent must never land without its total",
				r.SwapUsedPercent, r.SwapTotalBytes)
		}
		if r.BeamPSSBytes != -1 || r.BeamSwapBytes != -1 {
			t.Errorf("beam = (%d, %d), want both -1 on probe error", r.BeamPSSBytes, r.BeamSwapBytes)
		}
	})

	t.Run("swapless box lands zeros, not sentinels", func(t *testing.T) {
		r := gatherReport(ReportConfig{
			SwapProbe: func() (int, int64, error) { return 0, 0, nil },
		})
		if r.SwapUsedPercent != 0 || r.SwapTotalBytes != 0 {
			t.Errorf("swap = (%d, %d), want (0, 0) — 'no swap configured' is a MEASUREMENT and must be "+
				"distinguishable from 'could not measure' (-1, -1)", r.SwapUsedPercent, r.SwapTotalBytes)
		}
	})
}

// writeEnv drops a .env carrying an Ecto-style DATABASE_URL into a temp
// checkout and returns the directory.
func writeEnv(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// TestPGDatabaseURL pins the credential path proven on a live box: the agent
// runs as root (a bare psql has no such role), so the URL comes from the
// checkout's .env, and Ecto's scheme is rewritten to one libpq understands.
func TestPGDatabaseURL(t *testing.T) {
	t.Run("rewrites the ecto scheme", func(t *testing.T) {
		dir := writeEnv(t, "SECRET_KEY_BASE=xyz\nexport DATABASE_URL=\"ecto://bp:pw@localhost/barkpark_prod\"\n")
		got, err := pgDatabaseURL(dir)
		if err != nil {
			t.Fatalf("err = %v, want nil", err)
		}
		if got != "postgres://bp:pw@localhost/barkpark_prod" {
			t.Errorf("url = %q, want the postgres:// rewrite — libpq does not understand ecto://", got)
		}
	})

	t.Run("passes a postgres url through untouched", func(t *testing.T) {
		dir := writeEnv(t, "DATABASE_URL=postgres://bp@localhost/barkpark_prod\n")
		got, err := pgDatabaseURL(dir)
		if err != nil || got != "postgres://bp@localhost/barkpark_prod" {
			t.Errorf("got (%q, %v), want the url unchanged and no error", got, err)
		}
	})

	t.Run("missing .env is an error, never a default connection", func(t *testing.T) {
		if _, err := pgDatabaseURL(t.TempDir()); err == nil {
			t.Error("err = nil, want an error — a default connection would measure the WRONG database")
		}
	})

	t.Run("no DATABASE_URL is an error", func(t *testing.T) {
		dir := writeEnv(t, "PHX_HOST=example.com\n")
		if _, err := pgDatabaseURL(dir); err == nil {
			t.Error("err = nil, want an error when DATABASE_URL is absent")
		}
	})
}

// TestPGProbesUnwiredWithoutCheckout proves an empty checkout yields nil probes
// (unwired), mirroring NewReqStatsProbe's base=="" contract.
func TestPGProbesUnwiredWithoutCheckout(t *testing.T) {
	if NewPGSizeProbe("") != nil {
		t.Error("NewPGSizeProbe(\"\") must return nil (unwired)")
	}
	if NewPGTopRelationsProbe("") != nil {
		t.Error("NewPGTopRelationsProbe(\"\") must return nil (unwired)")
	}
}

// TestPGSizeProbeShellOut covers the psql contract and, crucially, the FAILURE
// path: on a box where psql is absent or the .env is unreadable the probe must
// return an error so PGSizeBytes stays -1. No faked zero — that box reports
// exactly what it reports today.
func TestPGSizeProbeShellOut(t *testing.T) {
	t.Run("happy path parses the size and carries the bounds", func(t *testing.T) {
		var gotArgs []string
		dir := writeEnv(t, "DATABASE_URL=ecto://bp@localhost/barkpark_prod\n")
		probe := newPGSizeProbeWith(func(name string, args ...string) (string, error) {
			if name != "psql" {
				t.Errorf("ran %q, want psql", name)
			}
			gotArgs = args
			return "3477617687\n", nil
		}, dir)

		got, err := probe()
		if err != nil {
			t.Fatalf("err = %v, want nil", err)
		}
		if got != 3477617687 {
			t.Errorf("size = %d, want 3477617687", got)
		}
		joined := strings.Join(gotArgs, " ")
		if !strings.Contains(joined, "postgres://bp@localhost/barkpark_prod") {
			t.Errorf("argv %q missing the rewritten connection url", joined)
		}
		if !strings.Contains(joined, "statement_timeout") {
			t.Errorf("argv %q missing the server-side statement_timeout bound", joined)
		}
	})

	t.Run("psql absent leaves the sentinel", func(t *testing.T) {
		dir := writeEnv(t, "DATABASE_URL=ecto://bp@localhost/barkpark_prod\n")
		probe := newPGSizeProbeWith(func(string, ...string) (string, error) {
			return "", errors.New(`exec: "psql": executable file not found in $PATH`)
		}, dir)

		got, err := probe()
		if err == nil {
			t.Fatal("err = nil, want an error when psql is absent")
		}
		if got != -1 {
			t.Errorf("size = %d, want -1 — a box without psql must NOT report a faked zero", got)
		}
		r := gatherReport(ReportConfig{PGSizeProbe: probe})
		if r.PGSizeBytes != -1 {
			t.Errorf("PGSizeBytes = %d, want -1 through gatherReport", r.PGSizeBytes)
		}
	})

	t.Run("unreadable .env leaves the sentinel", func(t *testing.T) {
		probe := newPGSizeProbeWith(func(string, ...string) (string, error) {
			t.Fatal("psql must not run when the .env is unreadable")
			return "", nil
		}, t.TempDir())
		if got, err := probe(); err == nil || got != -1 {
			t.Errorf("got (%d, %v), want (-1, an error)", got, err)
		}
	})

	t.Run("unparseable output errors rather than inventing a number", func(t *testing.T) {
		dir := writeEnv(t, "DATABASE_URL=postgres://bp@localhost/db\n")
		probe := newPGSizeProbeWith(func(string, ...string) (string, error) {
			return "ERROR:  permission denied\n", nil
		}, dir)
		if got, err := probe(); err == nil || got != -1 {
			t.Errorf("got (%d, %v), want (-1, an error)", got, err)
		}
	})
}

// TestPGTopRelationsProbe proves the named-consumer breakdown parses, stays
// bounded, and fails to nil (never an invented empty list).
func TestPGTopRelationsProbe(t *testing.T) {
	dir := writeEnv(t, "DATABASE_URL=ecto://bp@localhost/barkpark_prod\n")

	t.Run("names the consumers", func(t *testing.T) {
		probe := newPGTopRelationsProbeWith(func(_ string, args ...string) (string, error) {
			joined := strings.Join(args, " ")
			if !strings.Contains(joined, "LIMIT 10") {
				t.Errorf("query %q missing the LIMIT bound", joined)
			}
			if !strings.Contains(joined, "statement_timeout") {
				t.Errorf("query %q missing the statement_timeout bound", joined)
			}
			return "mutation_events|1510000000\nrevisions|1310000000\ndocuments|94000000\n", nil
		}, dir)

		rows, err := probe()
		if err != nil {
			t.Fatalf("err = %v, want nil", err)
		}
		if len(rows) != 3 {
			t.Fatalf("rows = %d, want 3", len(rows))
		}
		if rows[0] != (RelationSize{Name: "mutation_events", Bytes: 1510000000}) {
			t.Errorf("rows[0] = %+v, want mutation_events/1510000000", rows[0])
		}
	})

	t.Run("client-side limit keeps the payload bounded", func(t *testing.T) {
		var lines []string
		for i := 0; i < 50; i++ {
			lines = append(lines, "t|1")
		}
		probe := newPGTopRelationsProbeWith(func(string, ...string) (string, error) {
			return strings.Join(lines, "\n"), nil
		}, dir)
		rows, err := probe()
		if err != nil {
			t.Fatalf("err = %v, want nil", err)
		}
		if len(rows) != pgTopRelationsLimit {
			t.Errorf("rows = %d, want at most %d even when the query returns more",
				len(rows), pgTopRelationsLimit)
		}
	})

	t.Run("probe failure leaves PGTopRelations nil", func(t *testing.T) {
		probe := newPGTopRelationsProbeWith(func(string, ...string) (string, error) {
			return "", errors.New("psql: connection refused")
		}, dir)
		r := gatherReport(ReportConfig{PGTopRelationsProbe: probe})
		if r.PGTopRelations != nil {
			t.Errorf("PGTopRelations = %+v, want nil on probe error", r.PGTopRelations)
		}
	})
}

// TestPGProbeTimeoutIsShort pins that the per-beat Postgres probes do NOT
// inherit the approved-command runner's five-minute lifetime, and that the
// bound is real: a command sleeping past a lowered pgProbeTimeout returns
// promptly with a timeout error. A space probe that can run for five minutes is
// the runaway-diagnostic incident one layer down.
func TestPGProbeTimeoutIsShort(t *testing.T) {
	if pgProbeTimeout >= execRunnerTimeout {
		t.Errorf("pgProbeTimeout = %s, must be far shorter than execRunnerTimeout = %s",
			pgProbeTimeout, execRunnerTimeout)
	}

	orig := pgProbeTimeout
	defer func() { pgProbeTimeout = orig }()
	pgProbeTimeout = 50 * time.Millisecond

	done := make(chan error, 1)
	go func() {
		_, err := boundedPGRunner("sleep", "5")
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "timed out after") {
			t.Errorf("err = %v, want a timeout error", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("boundedPGRunner did not return promptly after its deadline elapsed")
	}
}
