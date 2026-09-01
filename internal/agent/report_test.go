package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"runtime/debug"
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
		LoadProbe:   func() (float64, float64, error) { return 1.25, 1.89, nil },
		PGSizeProbe: func() (int64, error) { return 1234567, nil },
		SwapProbe:   func() (int, int64, error) { return 99, 2147479552, nil },
		BeamProbe:   func() (int64, int64, string, string, error) { return 1602224128, 1233125376, "4185178", "green", nil },
		PGTopRelationsProbe: func() ([]RelationSize, error) {
			return []RelationSize{{Name: "mutation_events", Bytes: 1510000000}}, nil
		},
		ReqStatsProbe: func() (float64, int, float64, int, error) { return 12.5, 87, 0.22, 60, nil },
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
	if r.Load15 != 1.89 {
		t.Errorf("Load15 = %v, want 1.89 (the sustain signal, D67)", r.Load15)
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
	if r.Err5xxPerS != 0.22 {
		t.Errorf("Err5xxPerS = %v, want 0.22", r.Err5xxPerS)
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
	if r.Load15 != -1 {
		t.Errorf("Load15 = %v, want -1 (no probe — never a fake idle 0)", r.Load15)
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
	if r.Err5xxPerS != -1 {
		t.Errorf("Err5xxPerS = %v, want -1 (no probe — 'unmeasured', not 'no errors')", r.Err5xxPerS)
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
// TestGatherReportLoadPairFailsAsOneUnit proves the two load averages land
// TOGETHER or not at all: one read of /proc/loadavg produces both, so a failing
// probe must leave BOTH at the -1 sentinel rather than a real load1 beside a
// fabricated load15 — which would read as a box that is busy now but has been
// quiet for fifteen minutes, the exact opposite of the truth the sustain fence
// is looking for.
func TestGatherReportLoadPairFailsAsOneUnit(t *testing.T) {
	rErr := gatherReport(ReportConfig{
		LoadProbe: func() (float64, float64, error) { return 0, 0, errors.New("no /proc/loadavg") },
	})
	if rErr.Load1 != -1 || rErr.Load15 != -1 {
		t.Errorf("load = (%v, %v), want both -1 (probe errored)", rErr.Load1, rErr.Load15)
	}

	// A genuinely idle box reads 0 — real data, distinct from the sentinel.
	rIdle := gatherReport(ReportConfig{
		LoadProbe: func() (float64, float64, error) { return 0, 0, nil },
	})
	if rIdle.Load1 != 0 || rIdle.Load15 != 0 {
		t.Errorf("load = (%v, %v), want (0, 0) — idle is real, not the -1 sentinel",
			rIdle.Load1, rIdle.Load15)
	}

	// The live shape this field exists for: quiet right now, sustained-busy for
	// the last fifteen minutes. Only load15 can say it.
	rSustained := gatherReport(ReportConfig{
		LoadProbe: func() (float64, float64, error) { return 0.64, 1.89, nil },
	})
	if rSustained.Load1 != 0.64 || rSustained.Load15 != 1.89 {
		t.Errorf("load = (%v, %v), want (0.64, 1.89)", rSustained.Load1, rSustained.Load15)
	}
}

func TestGatherReportVitalsFailSoft(t *testing.T) {
	r := gatherReport(ReportConfig{
		CPUProbe:  func() (int, error) { return 0, errors.New("no /proc/stat") },
		MemProbe:  func() (int, error) { return 55, nil },
		LoadProbe: func() (float64, float64, error) { return 0.5, 0.75, nil },
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
		ReqStatsProbe: func() (float64, int, float64, int, error) { return 0, 0, 0, 0, errors.New("404") },
	})
	if rErr.ReqPerS != -1 {
		t.Errorf("ReqPerS = %v, want -1 (probe errored, not a fake 0)", rErr.ReqPerS)
	}
	if rErr.P95Ms != -1 {
		t.Errorf("P95Ms = %d, want -1 (probe errored, not a fake 0)", rErr.P95Ms)
	}

	// Success with null p95 → req/s lands, p95 stays the -1 sentinel.
	rNull := gatherReport(ReportConfig{
		ReqStatsProbe: func() (float64, int, float64, int, error) { return 3.0, -1, -1, -1, nil },
	})
	if rNull.ReqPerS != 3.0 {
		t.Errorf("ReqPerS = %v, want 3.0", rNull.ReqPerS)
	}
	if rNull.P95Ms != -1 {
		t.Errorf("P95Ms = %d, want -1 (instance p95 null)", rNull.P95Ms)
	}

	// A real 0 req/s (idle box) is data, not the sentinel.
	rIdle := gatherReport(ReportConfig{
		ReqStatsProbe: func() (float64, int, float64, int, error) { return 0, 0, 0, 0, nil },
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
		rps, p95, _, windowS, err := probe()
		if err != nil {
			t.Fatalf("probe error: %v", err)
		}
		if rps != 42.5 {
			t.Errorf("req/s = %v, want 42.5", rps)
		}
		if p95 != 128 {
			t.Errorf("p95 = %d, want 128", p95)
		}
		if windowS != 60 {
			t.Errorf("window_s = %d, want 60 — the window must ride the beat with its rates (dr-w14-bl)", windowS)
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

		rps, p95, _, windowS, err := NewReqStatsProbe(srv.URL, "", nil)()
		if err != nil {
			t.Fatalf("probe error: %v", err)
		}
		if rps != 7.0 {
			t.Errorf("req/s = %v, want 7.0", rps)
		}
		if p95 != -1 {
			t.Errorf("p95 = %d, want -1 (instance reported null — no samples)", p95)
		}
		if windowS != 60 {
			t.Errorf("window_s = %d, want 60", windowS)
		}
	})

	t.Run("err_5xx_per_s: real rate lands, null and ABSENT both → -1", func(t *testing.T) {
		// A live 5xx rate lands verbatim, all the way into the Report.
		srvLive := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`{"req_per_s": 12.0, "p95_ms": 90, "err_5xx_per_s": 0.22, "window_s": 60}`))
		}))
		defer srvLive.Close()
		r := gatherReport(ReportConfig{ReqStatsProbe: NewReqStatsProbe(srvLive.URL, "", nil)})
		if r.Err5xxPerS != 0.22 {
			t.Errorf("Err5xxPerS = %v, want 0.22 (a live rate on a box called healthy)", r.Err5xxPerS)
		}

		// An EMPTY window reports null — not zero errors, no samples at all.
		srvNull := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`{"req_per_s": 0.0, "p95_ms": null, "err_5xx_per_s": null, "window_s": 60}`))
		}))
		defer srvNull.Close()
		if _, _, e5, _, err := NewReqStatsProbe(srvNull.URL, "", nil)(); err != nil || e5 != -1 {
			t.Errorf("(err5xx, err) = (%v, %v), want (-1, nil) on a null window", e5, err)
		}

		// VERSION SKEW: an instance built before this field omits the key
		// entirely. That must read -1 (unmeasured), never 0 — otherwise every
		// stale instance in the fleet starts claiming a perfect error rate.
		srvOld := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`{"req_per_s": 9.0, "p95_ms": 40, "window_s": 60}`))
		}))
		defer srvOld.Close()
		rps, _, e5, _, err := NewReqStatsProbe(srvOld.URL, "", nil)()
		if err != nil {
			t.Fatalf("probe error: %v", err)
		}
		if rps != 9.0 {
			t.Errorf("req/s = %v, want 9.0 (the fields it DOES have still land)", rps)
		}
		if e5 != -1 {
			t.Errorf("err5xx = %v, want -1 (key absent — unmeasured, not 'no errors')", e5)
		}

		// A genuine 0.0 (measured window, no 5xx) is data and must survive.
		srvZero := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`{"req_per_s": 5.0, "p95_ms": 12, "err_5xx_per_s": 0.0, "window_s": 60}`))
		}))
		defer srvZero.Close()
		if _, _, e5, _, _ := NewReqStatsProbe(srvZero.URL, "", nil)(); e5 != 0 {
			t.Errorf("err5xx = %v, want 0 (measured clean window, not the -1 sentinel)", e5)
		}
	})

	t.Run("404 (old instance) → error, sentinels via gatherReport", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "not found", http.StatusNotFound)
		}))
		defer srv.Close()

		rps, p95, _, windowS, err := NewReqStatsProbe(srv.URL, "", nil)()
		if err == nil {
			t.Fatal("err = nil, want a non-nil error on 404")
		}
		if windowS != -1 {
			t.Errorf("window_s = %d, want -1 on a 404", windowS)
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
		if _, _, _, _, err := NewReqStatsProbe(srv.URL, "", nil)(); err == nil {
			t.Error("err = nil, want a non-nil error on 500")
		}
	})

	t.Run("undecodable body → error", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`not json`))
		}))
		defer srv.Close()
		if _, _, _, _, err := NewReqStatsProbe(srv.URL, "", nil)(); err == nil {
			t.Error("err = nil, want a non-nil error on an undecodable body")
		}
	})

	t.Run("transport error → error", func(t *testing.T) {
		// A closed server's URL yields a connection-refused transport error.
		srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		url := srv.URL
		srv.Close()
		if _, _, _, _, err := NewReqStatsProbe(url, "", nil)(); err == nil {
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
			BeamProbe: func() (int64, int64, string, string, error) {
				return 5, 6, "4185178", "green", errors.New("no beam.smp")
			},
		})
		if r.SwapUsedPercent != -1 || r.SwapTotalBytes != -1 {
			t.Errorf("swap = (%d, %d), want both -1 — a percent must never land without its total",
				r.SwapUsedPercent, r.SwapTotalBytes)
		}
		if r.BeamPSSBytes != -1 || r.BeamSwapBytes != -1 {
			t.Errorf("beam = (%d, %d), want both -1 on probe error", r.BeamPSSBytes, r.BeamSwapBytes)
		}
		// The attribution folds into the SAME unit: an erroring probe must not
		// leave a pid/slot naming a process whose numbers never landed.
		if r.BeamPID != "" || r.BeamSlot != "" {
			t.Errorf("beam attribution = (%q, %q), want both empty on probe error — a pid without its measurement attributes nothing",
				r.BeamPID, r.BeamSlot)
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

// TestReportCarriesCPUCores proves the beat reports the box's OWN core count —
// the denominator the strained fence divides load by (D52). Without it the
// fence has to assume a core count, and an assumed 2 is silently wrong on the
// first 4-core box.
func TestReportCarriesCPUCores(t *testing.T) {
	r := gatherReport(ReportConfig{})
	if r.CPUCores != runtime.NumCPU() {
		t.Errorf("CPUCores = %d, want runtime.NumCPU() = %d", r.CPUCores, runtime.NumCPU())
	}
	if r.CPUCores < 1 {
		t.Errorf("CPUCores = %d, want >= 1 — the fence's denominator may never be zero", r.CPUCores)
	}
	blob, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal Report: %v", err)
	}
	if !strings.Contains(string(blob), `"cpu_cores":`) {
		t.Errorf("Report JSON missing \"cpu_cores\" — the CP reads this key verbatim; payload=%s", blob)
	}
}

// spaceFakeRunner records every argv a space probe issues and answers from a
// canned table keyed on the binary name, so the whole space payload is provable
// with no real df/journalctl/du on the host running the test.
type spaceFakeRunner struct {
	out   map[string]string
	err   map[string]error
	calls [][]string
}

func (f *spaceFakeRunner) run(name string, args ...string) (string, error) {
	f.calls = append(f.calls, append([]string{name}, args...))
	return f.out[name], f.err[name]
}

func (f *spaceFakeRunner) callFor(name string) []string {
	for _, c := range f.calls {
		if c[0] == name {
			return c
		}
	}
	return nil
}

// TestGatherSpaceNamesEveryConsumer proves the space payload answers "WHO is
// using the disk" by name: root used AND total (never a bare percent), the
// journal, Postgres via the EXISTING pg probes, and the sites tree broken down
// per slug — with the resolved sites directory carried alongside.
func TestGatherSpaceNamesEveryConsumer(t *testing.T) {
	s := gatherSpace(SpaceConfig{
		RootProbe:    func() (int64, int64, error) { return 28812754944, 40193925120, nil },
		JournalProbe: func() (int64, error) { return 3972844748, nil },
		PGSizeProbe:  func() (int64, error) { return 3477617687, nil },
		PGTopRelationsProbe: func() ([]RelationSize, error) {
			return []RelationSize{{Name: "mutation_events", Bytes: 1510000000}}, nil
		},
		SitesDir: "/opt/barkpark/sites",
		SitesProbe: func() (int64, []SiteSize, error) {
			return 4294967296, []SiteSize{
				{Slug: "search-ember", Bytes: 658505728},
				{Slug: "next-proof", Bytes: 605028352},
			}, nil
		},
	})

	if s.Type != SpaceEventType {
		t.Errorf("Type = %q, want %q — space must not ride the health beat's type (D58)", s.Type, SpaceEventType)
	}
	if s.Type == "health" {
		t.Fatal("the space payload must never be typed health — metrics.ex folds health beats into the chart series")
	}
	if s.RootUsedBytes != 28812754944 || s.RootTotalBytes != 40193925120 {
		t.Errorf("root = (%d, %d), want used AND total bytes — a bare percent cannot size the problem", s.RootUsedBytes, s.RootTotalBytes)
	}
	if s.JournalBytes != 3972844748 {
		t.Errorf("JournalBytes = %d, want 3972844748", s.JournalBytes)
	}
	if s.PGSizeBytes != 3477617687 {
		t.Errorf("PGSizeBytes = %d, want the existing pg probe's answer", s.PGSizeBytes)
	}
	if len(s.PGTopRelations) != 1 || s.PGTopRelations[0].Name != "mutation_events" {
		t.Errorf("PGTopRelations = %+v, want the named db consumers", s.PGTopRelations)
	}
	if s.SitesDir != "/opt/barkpark/sites" {
		t.Errorf("SitesDir = %q, want the resolved directory that was read", s.SitesDir)
	}
	if s.SitesBytes != 4294967296 || len(s.SitesTop) != 2 || s.SitesTop[0].Slug != "search-ember" {
		t.Errorf("sites = (%d, %+v), want the total plus the named slugs", s.SitesBytes, s.SitesTop)
	}
}

// TestGatherSpaceHonestUnknowns proves an unwired or failing consumer reports
// UNMEASURED (-1 / nil), never 0 and never an empty list — and that the
// resolved sites directory is reported even when its measurement failed, so a
// wrong root is visible rather than silent.
func TestGatherSpaceHonestUnknowns(t *testing.T) {
	t.Run("nothing wired", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{SitesDir: "/opt/barkpark/sites"})
		if s.RootUsedBytes != -1 || s.RootTotalBytes != -1 || s.JournalBytes != -1 ||
			s.PGSizeBytes != -1 || s.SitesBytes != -1 {
			t.Errorf("unwired space = %+v, want every number at the -1 sentinel", s)
		}
		if s.PGTopRelations != nil || s.SitesTop != nil {
			t.Errorf("unwired lists = (%v, %v), want nil — an unmeasured list is null, never []", s.PGTopRelations, s.SitesTop)
		}
		if s.SitesDir != "/opt/barkpark/sites" {
			t.Errorf("SitesDir = %q, want the resolved path even with no probe wired", s.SitesDir)
		}
	})

	t.Run("every probe fails", func(t *testing.T) {
		boom := errors.New("boom")
		s := gatherSpace(SpaceConfig{
			RootProbe:           func() (int64, int64, error) { return 0, 0, boom },
			JournalProbe:        func() (int64, error) { return 0, boom },
			PGSizeProbe:         func() (int64, error) { return 0, boom },
			PGTopRelationsProbe: func() ([]RelationSize, error) { return []RelationSize{{Name: "x"}}, boom },
			SitesDir:            "/srv/sites",
			SitesProbe:          func() (int64, []SiteSize, error) { return 0, []SiteSize{{Slug: "half"}}, boom },
		})
		if s.RootUsedBytes != -1 || s.JournalBytes != -1 || s.PGSizeBytes != -1 || s.SitesBytes != -1 {
			t.Errorf("failed space = %+v, want the -1 sentinels, never a zero", s)
		}
		if s.PGTopRelations != nil || s.SitesTop != nil {
			t.Error("a failing probe's partial rows must be DISCARDED, never landed")
		}
		if s.SitesDir != "/srv/sites" {
			t.Errorf("SitesDir = %q, want the path that was attempted", s.SitesDir)
		}
	})
}

// TestSitesProbeArgvIsDirect pins the sites argv shape (D59). The bound is a
// LIFETIME bound, and it only holds for DIRECT argv: measured, an `sh -c`
// wrapper under the same 200ms bound returned at 8.77s — 44x over budget —
// with the identical `signal: killed` error, so the caller cannot tell. This
// test exists so a future edit cannot quietly reintroduce a shell.
func TestSitesProbeArgvIsDirect(t *testing.T) {
	f := &spaceFakeRunner{out: map[string]string{"nice": "643072\t/opt/barkpark/sites/a\n4194304\t/opt/barkpark/sites\n"}}
	probe := newSitesSpaceProbeWith(f.run, "/opt/barkpark/sites")
	if _, _, err := probe(); err != nil {
		t.Fatalf("probe err = %v, want nil", err)
	}

	got := f.callFor("nice")
	want := []string{"nice", "-n", "19", "ionice", "-c3", "du", "-kx", "-d1", "/opt/barkpark/sites"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("argv = %v, want %v", got, want)
	}
	for _, arg := range got {
		for _, banned := range []string{"sh", "-c ", "|", "2>&1", ";", "$?", "&&"} {
			if arg == "sh" || (banned != "sh" && strings.Contains(arg, banned)) {
				t.Errorf("argv element %q carries %q — probe argv must be direct: no shell, no pipes, no redirections, no `; echo rc=$?`", arg, banned)
			}
		}
	}
	// -x and -d1 are mandatory (never cross a filesystem, bounded depth), and
	// -s must NOT appear: it conflicts with -d1 in coreutils 9.4.
	joined := strings.Join(got, " ")
	if !strings.Contains(joined, "-kx") || !strings.Contains(joined, "-d1") {
		t.Errorf("argv %q must carry -k (EXACT 1024-blocks, never -h's rounded-up string), "+
			"-x (no filesystem crossing) and -d1 (bounded depth)", joined)
	}
	if strings.Contains(joined, " -s ") {
		t.Errorf("argv %q carries -s, which conflicts with -d1 in coreutils 9.4", joined)
	}
}

// TestSitesProbeNonZeroExitDiscardsPartialOutput is the honesty test that
// matters most here. A killed du prints the rows it finished and THEN exits
// non-zero: a 3s bound printed 5 site rows before rc=137. Those rows parse as a
// perfectly plausible list silently missing half the tree, so a non-zero exit
// must report UNMEASURED — under-reporting space is the exact failure the space
// payload exists to prevent.
func TestSitesProbeNonZeroExitDiscardsPartialOutput(t *testing.T) {
	partial := "643072\t/opt/barkpark/sites/search-ember\n" +
		"643072\t/opt/barkpark/sites/search-capstone\n" +
		"590848\t/opt/barkpark/sites/next-proof\n" +
		"421888\t/opt/barkpark/sites/docs-site\n" +
		"122880\t/opt/barkpark/sites/blog\n"

	// Two shapes, and the second is the one that keeps this test honest. The
	// first is the real killed-du (rows, no root row — du prints its total
	// last). The second ALSO carries a parseable total row: without it, a probe
	// that ignored the error entirely would still pass here, because the parser
	// would reject the truncated output on its own. The rule under test is that
	// a NON-ZERO EXIT discards, independently of whether the output parses.
	for _, c := range []struct {
		name string
		out  string
	}{
		{name: "killed mid-walk, no total row", out: partial},
		{name: "killed with a parseable total row", out: partial + "4194304\t/opt/barkpark/sites\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			probe := newSitesSpaceProbeWith(func(string, ...string) (string, error) {
				// Exactly what runBounded hands back on a killed du: real
				// output AND an error, indistinguishable in shape from a
				// completed run.
				return c.out, errors.New("signal: killed")
			}, "/opt/barkpark/sites")

			total, top, err := probe()
			if err == nil {
				t.Fatal("err = nil, want an error — a killed du is not a measurement")
			}
			if total != -1 || top != nil {
				t.Fatalf("got (%d, %+v), want (-1, nil) — partial du output must NEVER land", total, top)
			}

			s := gatherSpace(SpaceConfig{SitesDir: "/opt/barkpark/sites", SitesProbe: probe})
			if s.SitesBytes != -1 || s.SitesTop != nil {
				t.Errorf("through gatherSpace: sites = (%d, %+v), want unmeasured", s.SitesBytes, s.SitesTop)
			}
		})
	}
}

// TestSitesTopCappedAtTen proves the per-slug list REACHING THE PAYLOAD is
// capped at the top 10 by bytes. Uncapped, the compressed jsonb crosses
// Postgres's 2032-byte TOAST_TUPLE_THRESHOLD between 20 and 25 realistic slugs,
// after which a 14-day window per box goes 34MB→58MB (D58).
//
// The cap lives in gatherSpace, not parseDuTree, so this asserts it there — and
// asserts the half that makes a cap safe to consume: SitesCount reports the 25
// slugs the walk FOUND, not the 10 that survived.
// TestSitesCountSaysWhenTheCapBinds is the honesty twin; this one is the bound.
func TestSitesTopCappedAtTen(t *testing.T) {
	var b strings.Builder
	for i := 1; i <= 25; i++ {
		fmt.Fprintf(&b, "%dM\t/opt/barkpark/sites/site-%02d\n", i, i)
	}
	b.WriteString("40G\t/opt/barkpark/sites\n")

	total, all, degraded, err := parseDuTree(b.String(), "/opt/barkpark/sites", duUnitHuman)
	if err != nil {
		t.Fatalf("parseDuTree: %v", err)
	}
	if degraded != nil {
		t.Errorf("degraded = %v, want nil — this fixture carries no du diagnostics", degraded)
	}
	if total != 40*(1<<30) {
		t.Errorf("total = %d, want the root row's bytes", total)
	}
	// The probe hands over everything it found — the denominator has to survive
	// the walk to be reportable at all.
	if len(all) != 25 {
		t.Fatalf("parseDuTree returned %d slugs, want all 25 — the cap belongs at the payload", len(all))
	}

	s := gatherSpace(SpaceConfig{
		SitesDir:   "/opt/barkpark/sites",
		SitesProbe: func() (int64, []SiteSize, error) { return total, all, nil },
	})
	top := s.SitesTop
	if len(top) != sitesTopLimit {
		t.Fatalf("len(SitesTop) = %d, want %d", len(top), sitesTopLimit)
	}
	if top[0].Slug != "site-25" || top[len(top)-1].Slug != "site-16" {
		t.Errorf("SitesTop = %+v, want the ten BIGGEST slugs, descending", top)
	}
	if top[0].Bytes != 25*(1<<20) {
		t.Errorf("SitesTop[0].Bytes = %d, want 25 MiB", top[0].Bytes)
	}
	if s.SitesCount != 25 {
		t.Errorf("SitesCount = %d, want 25 — a cap that eats its own denominator can never say when it binds", s.SitesCount)
	}
}

// TestSitesCountSaysWhenTheCapBinds is the tripwire for the failure the count
// exists to remove: a truncated list that reads as a complete one.
//
// Ten slugs and a total look IDENTICAL whether the tree holds ten or forty. The
// only thing that separates them is a denominator the cap did not eat, so this
// pins all three states a reader has to be able to tell apart:
//
//	under the cap  → SitesCount == len(SitesTop): the list IS the whole tree
//	over the cap   → SitesCount >  len(SitesTop): the list is a stated tip
//	unmeasured     → SitesCount == -1, never 0 (which claims an empty tree)
func TestSitesCountSaysWhenTheCapBinds(t *testing.T) {
	slugs := func(n int) []SiteSize {
		out := make([]SiteSize, 0, n)
		for i := 0; i < n; i++ {
			out = append(out, SiteSize{Slug: fmt.Sprintf("site-%02d", i), Bytes: int64(n - i)})
		}
		return out
	}

	t.Run("under the cap, the count equals the list", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			SitesDir:   "/opt/barkpark/sites",
			SitesProbe: func() (int64, []SiteSize, error) { return 4096, slugs(3), nil },
		})
		if s.SitesCount != 3 || len(s.SitesTop) != 3 {
			t.Fatalf("count=%d len(top)=%d, want 3/3 — an uncapped list must read as complete",
				s.SitesCount, len(s.SitesTop))
		}
	})

	t.Run("over the cap, the count exceeds the list and says so", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			SitesDir:   "/opt/barkpark/sites",
			SitesProbe: func() (int64, []SiteSize, error) { return 4096, slugs(37), nil },
		})
		if len(s.SitesTop) != sitesTopLimit {
			t.Fatalf("len(top) = %d, want the payload bound %d", len(s.SitesTop), sitesTopLimit)
		}
		if s.SitesCount != 37 {
			t.Fatalf("SitesCount = %d, want 37 — the cap bound and did not announce it", s.SitesCount)
		}
		if s.SitesCount <= len(s.SitesTop) {
			t.Errorf("count %d <= len(top) %d: a reader cannot tell this list was truncated",
				s.SitesCount, len(s.SitesTop))
		}
	})

	t.Run("unmeasured is -1, never a measured zero", func(t *testing.T) {
		// No probe at all, and a probe that fails: both are "we did not measure",
		// and 0 would be the measured claim "this tree is empty".
		for name, cfg := range map[string]SpaceConfig{
			"unwired": {SitesDir: "/opt/barkpark/sites"},
			"failed": {SitesDir: "/opt/barkpark/sites", SitesProbe: func() (int64, []SiteSize, error) {
				return -1, nil, errors.New("du: timed out")
			}},
		} {
			s := gatherSpace(cfg)
			if s.SitesCount != -1 {
				t.Errorf("%s: SitesCount = %d, want -1 (0 would claim an empty tree)", name, s.SitesCount)
			}
		}
	})
}

// TestParseDuTreeRequiresTotalRow proves output without du's own root row —
// which is what a walk cut short looks like — is refused rather than parsed
// into a confident-looking partial list.
func TestParseDuTreeRequiresTotalRow(t *testing.T) {
	out := "628M\t/opt/barkpark/sites/search-ember\n577M\t/opt/barkpark/sites/next-proof\n"
	if total, top, degraded, err := parseDuTree(out, "/opt/barkpark/sites", duUnitHuman); err == nil || total != -1 || top != nil || degraded != nil {
		t.Errorf("got (%d, %+v, %v, %v), want (-1, nil, nil, an error)", total, top, degraded, err)
	}
}

// TestRootSpaceProbeReportsBytesNotPercent proves the root filesystem is
// measured in BYTES used and total, with a `df -P -k /` argv whose block size
// the parser does not have to guess.
func TestRootSpaceProbeReportsBytesNotPercent(t *testing.T) {
	f := &spaceFakeRunner{out: map[string]string{
		"df": "Filesystem     1024-blocks     Used Available Capacity Mounted on\n" +
			"/dev/sda1         39251880 28137456   9091612      76% /\n",
	}}
	used, total, err := newRootSpaceProbeWith(f.run)()
	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if used != 28137456*1024 || total != 39251880*1024 {
		t.Errorf("got (%d, %d), want (%d, %d) bytes", used, total, 28137456*1024, 39251880*1024)
	}
	if got, want := strings.Join(f.callFor("df"), " "), "df -P -k /"; got != want {
		t.Errorf("argv = %q, want %q", got, want)
	}

	t.Run("non-zero exit leaves both sentinels", func(t *testing.T) {
		bad := &spaceFakeRunner{
			out: map[string]string{"df": "df: /: Permission denied\n"},
			err: map[string]error{"df": errors.New("exit status 1")},
		}
		if u, tot, err := newRootSpaceProbeWith(bad.run)(); err == nil || u != -1 || tot != -1 {
			t.Errorf("got (%d, %d, %v), want (-1, -1, an error)", u, tot, err)
		}
	})
}

// TestJournalSpaceProbe proves the journal is read from its own header line
// (`journalctl --disk-usage`, ~8ms warm) rather than by walking
// /var/log/journal, and that a failure keeps the -1 sentinel.
func TestJournalSpaceProbe(t *testing.T) {
	f := &spaceFakeRunner{out: map[string]string{
		"journalctl": "Archived and active journals take up 3.7G in the file system.\n",
	}}
	got, err := newJournalSpaceProbeWith(f.run)()
	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if want := int64(3972844749); got != want {
		t.Errorf("journal = %d, want ~%d", got, want)
	}
	if argv, want := strings.Join(f.callFor("journalctl"), " "), "journalctl --disk-usage"; argv != want {
		t.Errorf("argv = %q, want %q — a tree walk is not the same probe", argv, want)
	}

	t.Run("no journald leaves the sentinel", func(t *testing.T) {
		bad := &spaceFakeRunner{err: map[string]error{"journalctl": errors.New(`exec: "journalctl": not found`)}}
		if n, err := newJournalSpaceProbeWith(bad.run)(); err == nil || n != -1 {
			t.Errorf("got (%d, %v), want (-1, an error)", n, err)
		}
	})
}

// TestParseHumanBytes pins the size vocabulary du and journalctl print. A
// dropped magnitude is not a rounding error: reading "3.7G" as 3.7 would
// under-report the journal by a billion bytes.
func TestParseHumanBytes(t *testing.T) {
	cases := []struct {
		in   string
		want int64
		bad  bool
	}{
		{in: "3.7G", want: int64(3972844749)},
		{in: "628M", want: 628 * (1 << 20)},
		{in: "4.0K", want: 4096},
		{in: "512", want: 512},
		{in: "12B", want: 12},
		{in: "3.7GiB", want: int64(3972844749)},
		{in: "take", bad: true},
		{in: "up", bad: true},
		{in: "", bad: true},
		{in: "-4G", bad: true},
	}
	for _, c := range cases {
		got, err := parseHumanBytes(c.in)
		if c.bad {
			if err == nil {
				t.Errorf("parseHumanBytes(%q) = %d, want an error", c.in, got)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("parseHumanBytes(%q) = (%d, %v), want (%d, nil)", c.in, got, err, c.want)
		}
	}
}

// TestSpaceRidesItsOwnPathAndCadence proves the two halves of D58 at the
// transport layer: the space payload is POSTed to its OWN route (never folded
// into the 60s health beat), carrying its own event type, at a cadence
// materially slower than the beat.
func TestSpaceRidesItsOwnPathAndCadence(t *testing.T) {
	if DefaultSpaceInterval <= DefaultInterval {
		t.Fatalf("DefaultSpaceInterval = %s, must be slower than the %s health beat (D58)", DefaultSpaceInterval, DefaultInterval)
	}
	if spacePath == reportPath {
		t.Fatal("the space payload must not ride the report route — its body would be landed as a health event")
	}

	var gotPath, gotAuth string
	var gotBody SpaceReport
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	a := &Agent{
		ControlURL: srv.URL,
		Token:      "tok",
		HTTPClient: srv.Client(),
		SpaceProbes: SpaceConfig{
			SitesDir:     "/opt/barkpark/sites",
			RootProbe:    func() (int64, int64, error) { return 1, 2, nil },
			JournalProbe: func() (int64, error) { return 3, nil },
		},
	}
	if err := a.ReportSpaceOnce(context.Background()); err != nil {
		t.Fatalf("ReportSpaceOnce: %v", err)
	}
	if gotPath != spacePath {
		t.Errorf("POST path = %q, want %q", gotPath, spacePath)
	}
	if gotAuth != "Bearer tok" {
		t.Errorf("Authorization = %q, want the agent bearer token", gotAuth)
	}
	if gotBody.Type != SpaceEventType {
		t.Errorf("body type = %q, want %q carried inline for the landing route", gotBody.Type, SpaceEventType)
	}
	if gotBody.SitesDir != "/opt/barkpark/sites" {
		t.Errorf("body sites_dir = %q, want the resolved directory", gotBody.SitesDir)
	}

	t.Run("a control plane without the route surfaces an honest error", func(t *testing.T) {
		old := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.NotFound(w, r)
		}))
		defer old.Close()
		b := &Agent{ControlURL: old.URL, Token: "tok", HTTPClient: old.Client()}
		err := b.ReportSpaceOnce(context.Background())
		if err == nil || !strings.Contains(err.Error(), "post space") {
			t.Errorf("err = %v, want a post-space error — a dropped payload must not look like a landed one", err)
		}
	})
}

// TestSpaceJSONFieldNames pins the wire keys the control plane reads verbatim.
func TestSpaceJSONFieldNames(t *testing.T) {
	blob, err := json.Marshal(gatherSpace(SpaceConfig{SitesDir: "/opt/barkpark/sites"}))
	if err != nil {
		t.Fatalf("marshal SpaceReport: %v", err)
	}
	s := string(blob)
	for _, key := range []string{
		`"type":"space"`,
		`"root_used_bytes":`, `"root_total_bytes":`,
		`"journal_bytes":`, `"pg_size_bytes":`, `"pg_top_relations":`,
		`"sites_dir":`, `"sites_bytes":`, `"sites_top":`,
		`"consumer_roots":`,
	} {
		if !strings.Contains(s, key) {
			t.Errorf("space JSON missing %s; payload=%s", key, s)
		}
	}
	if !strings.Contains(s, `"pg_top_relations":null`) || !strings.Contains(s, `"sites_top":null`) ||
		!strings.Contains(s, `"consumer_roots":null`) {
		t.Errorf("unmeasured lists must marshal as null, never []; payload=%s", s)
	}

	// The consumer rows ride RelationSize's keys, not SiteSize's, so the
	// control plane's existing row shaper lands them with no second code path.
	rows, err := json.Marshal(gatherSpace(SpaceConfig{
		ConsumerRoots:      []string{"/var/lib/containerd"},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
			return 15032385536, []DirSize{{Name: "io.containerd.snapshotter.v1.overlayfs", Bytes: 12884901888}}, nil, nil
		},
	}).ConsumerRoots)
	if err != nil {
		t.Fatalf("marshal consumer roots: %v", err)
	}
	for _, key := range []string{`"path":`, `"status":"read"`, `"bytes":`, `"top":`, `"count":`, `"name":`} {
		if !strings.Contains(string(rows), key) {
			t.Errorf("consumer-root JSON missing %s; rows=%s", key, rows)
		}
	}
	if strings.Contains(string(rows), `"slug":`) {
		t.Errorf("consumer rows must not use SiteSize's `slug` key — a containerd directory is a name; rows=%s", rows)
	}
}

// TestSpaceProbeTimeoutsAreShortAndSeparate proves each space probe carries its
// OWN lifetime bound and that none of them inherits the five-minute
// approved-command budget — a per-beat probe that can run for five minutes is
// the runaway-diagnostic incident again, one layer down.
func TestSpaceProbeTimeoutsAreShortAndSeparate(t *testing.T) {
	for name, d := range map[string]time.Duration{
		"df":         dfProbeTimeout,
		"journalctl": journalProbeTimeout,
		"du":         duProbeTimeout,
	} {
		if d <= 0 || d >= execRunnerTimeout {
			t.Errorf("%s probe timeout = %s, want a short bound well under execRunnerTimeout (%s)", name, d, execRunnerTimeout)
		}
	}
	if duProbeTimeout <= dfProbeTimeout {
		t.Error("the du walk needs a longer bound than the df header read — probe-specific means specific")
	}

	// And the bound is a real lifetime bound, not a hint: a runner built by
	// boundedSpaceRunner returns promptly when its deadline elapses.
	run := boundedSpaceRunner(50 * time.Millisecond)
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, err := run("sleep", "5")
		if err == nil {
			t.Error("err = nil, want a timeout error")
		}
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("boundedSpaceRunner did not return promptly after its deadline elapsed")
	}
}

// buildInfoWith returns a ReadBuildInfo stand-in carrying the given vcs
// settings — the shape `go build` embeds when it builds from a git checkout,
// which is exactly how the fleet's agent is (re)built on-box.
func buildInfoWith(mainVersion string, settings map[string]string) func() (*debug.BuildInfo, bool) {
	return func() (*debug.BuildInfo, bool) {
		bi := &debug.BuildInfo{}
		bi.Main.Version = mainVersion
		for k, v := range settings {
			bi.Settings = append(bi.Settings, debug.BuildSetting{Key: k, Value: v})
		}
		return bi, true
	}
}

// TestAgentVersionBothArms proves the beat dates its own producer in BOTH
// directions: a build that carries a stamp emits that stamp, and a build that
// carries none emits the explicit unknown marker — never "" and never a value
// a reader could mistake for a measured version.
func TestAgentVersionBothArms(t *testing.T) {
	noBuildInfo := func() (*debug.BuildInfo, bool) { return nil, false }

	for _, tc := range []struct {
		name     string
		injected string
		read     func() (*debug.BuildInfo, bool)
		want     string
	}{
		// STAMPED arm — a blessed release injects -X agentVersion.
		{"ldflags stamp wins", "v0.2.26", buildInfoWith("(devel)", map[string]string{"vcs.revision": "abc123def4567890"}), "v0.2.26"},
		{"ldflags stamp is trimmed", "  v0.2.26\n", noBuildInfo, "v0.2.26"},
		// STAMPED arm — a plain on-box `go build` from the checkout.
		{"vcs revision, clean", "", buildInfoWith("(devel)", map[string]string{"vcs.revision": "abc123def4567890abcd", "vcs.modified": "false"}), "git-abc123def456"},
		{"vcs revision, dirty tree is carried", "", buildInfoWith("(devel)", map[string]string{"vcs.revision": "abc123def4567890abcd", "vcs.modified": "true"}), "git-abc123def456-dirty"},
		{"tagged module build", "", buildInfoWith("v0.2.26", nil), "v0.2.26"},
		// UNSTAMPED arm — every route to an identity is closed.
		{"no build info at all", "", noBuildInfo, AgentVersionUnknown},
		{"nil reader", "", nil, AgentVersionUnknown},
		{"build info with nothing to say", "", buildInfoWith("(devel)", nil), AgentVersionUnknown},
		{"blank revision is not a stamp", "", buildInfoWith("", map[string]string{"vcs.revision": "   "}), AgentVersionUnknown},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := resolveAgentVersion(tc.injected, tc.read)
			if got != tc.want {
				t.Errorf("resolveAgentVersion = %q, want %q", got, tc.want)
			}
			if got == "" {
				t.Error("resolveAgentVersion returned \"\" — an empty string reads as a measured value; the unknown arm must be explicit")
			}
		})
	}

	// The live resolver used by the real binary is held to the same floor.
	if AgentVersion() == "" {
		t.Error("AgentVersion() = \"\" — the agent must always date its own beat, even unstamped")
	}
}

// TestReportCarriesAgentVersion proves the key the control plane reads out of
// the raw jsonb payload — agent_version — is present on every beat with a
// non-empty value, so a missing vital stops being indistinguishable from a
// healthy one.
func TestReportCarriesAgentVersion(t *testing.T) {
	r := gatherReport(ReportConfig{})
	if r.AgentVersion == "" {
		t.Error("Report.AgentVersion = \"\" — never empty; unknown is spelled explicitly")
	}
	if r.AgentVersion != AgentVersion() {
		t.Errorf("Report.AgentVersion = %q, want the binary's own stamp %q", r.AgentVersion, AgentVersion())
	}

	blob, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal Report: %v", err)
	}
	var payload map[string]any
	if err := json.Unmarshal(blob, &payload); err != nil {
		t.Fatalf("unmarshal Report: %v", err)
	}
	v, ok := payload["agent_version"]
	if !ok {
		t.Fatalf("Report JSON missing \"agent_version\" — the CP reads this key verbatim out of raw jsonb; payload=%s", blob)
	}
	s, isString := v.(string)
	if !isString {
		t.Fatalf("agent_version = %T, want a string", v)
	}
	if s == "" {
		t.Error("agent_version marshalled as \"\" — an absent-or-empty key means two things at once")
	}

	// The pre-existing version field is untouched by this addition.
	if r.Version != Version {
		t.Errorf("Report.Version = %q, want the unchanged %q", r.Version, Version)
	}
	if payload["version"] != Version {
		t.Errorf("JSON version = %v, want the unchanged %q", payload["version"], Version)
	}
}

// newTempGitRepo initialises a real git repository in a temp dir with one
// committed file and returns its path. Identity and signing are pinned on the
// command line so the test does not depend on the host's git config.
func newTempGitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	dir := t.TempDir()

	runGitIn(t, dir, "init", "--quiet")
	if err := os.WriteFile(filepath.Join(dir, "tracked.txt"), []byte("one\n"), 0o644); err != nil {
		t.Fatalf("write tracked file: %v", err)
	}
	runGitIn(t, dir, "add", "tracked.txt")
	runGitIn(t, dir, "commit", "--quiet", "--no-gpg-sign", "-m", "initial")
	return dir
}

// runGitIn runs one git command in dir under a pinned identity and neutralised
// global/system config, so the host's git settings can never change what these
// tests measure. Any failure is fatal — a probe test over a half-built repo
// would assert nothing.
func runGitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// TestGitProbeDirtyIgnoresUntrackedFiles is the assertion that FAILS against
// the unpatched probe (`git status --porcelain`, untracked counted). Every
// working production box accrues untracked operational junk — a built `bp`
// binary, .claude/worktrees/, .env backups, spawned sites/ — none of which any
// deploy can clear. Counting it pins dirty_tree true forever, so the gauge can
// never report the good state. This test is the proof it now can.
func TestGitProbeDirtyIgnoresUntrackedFiles(t *testing.T) {
	dir := newTempGitRepo(t)

	// The exact shapes measured on guerrilla: a stray binary, a backup, a dir.
	if err := os.WriteFile(filepath.Join(dir, "bp"), []byte("binary"), 0o755); err != nil {
		t.Fatalf("write untracked binary: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env.bak-20260706221850"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write untracked backup: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "sites", "demo"), 0o755); err != nil {
		t.Fatalf("mkdir untracked dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sites", "demo", "index.html"), []byte("<p>"), 0o644); err != nil {
		t.Fatalf("write untracked dir file: %v", err)
	}

	g := gitProbe{runner: ExecRunner{}, checkout: dir}
	if g.dirty() {
		t.Error("dirty() = true with ONLY untracked files present — the gauge is pinned true on every live box and can never say clean")
	}
	if g.commit() == "" {
		t.Error("commit() = \"\" over a real repo — the sha probe must still read HEAD")
	}
}

// TestGitProbeDirtyReportsModifiedTrackedFile is the mirror assertion: it fails
// against an OVER-correction (hard-coded false, or a flag combination that
// suppresses tracked changes too). A one-sided test would let the same bug ship
// inverted — a gauge that can never say DIRTY is exactly as useless as one that
// can never say clean.
func TestGitProbeDirtyReportsModifiedTrackedFile(t *testing.T) {
	dir := newTempGitRepo(t)

	if err := os.WriteFile(filepath.Join(dir, "tracked.txt"), []byte("two\n"), 0o644); err != nil {
		t.Fatalf("modify tracked file: %v", err)
	}

	g := gitProbe{runner: ExecRunner{}, checkout: dir}
	if !g.dirty() {
		t.Error("dirty() = false with a MODIFIED TRACKED file — the deploy-hygiene flag can no longer say dirty")
	}
}

// TestGitProbeDirtyReportsIndexOnlyTrackedChanges pins the OTHER half of the
// blast-radius claim: `--untracked-files=no` drops untracked files and NOTHING
// else. A staged ADD (the file is in the index, so it is tracked) and a tracked
// DELETION both still read dirty. Without these, "only untracked stops counting"
// is asserted in prose and proven nowhere — and the next flag edit (`-uall`,
// `--ignore-submodules=all`, a porcelain v2 switch) could quietly widen the
// suppression with every existing test still green.
func TestGitProbeDirtyReportsIndexOnlyTrackedChanges(t *testing.T) {
	t.Run("staged add", func(t *testing.T) {
		dir := newTempGitRepo(t)
		if err := os.WriteFile(filepath.Join(dir, "added.txt"), []byte("new\n"), 0o644); err != nil {
			t.Fatalf("write new file: %v", err)
		}
		runGitIn(t, dir, "add", "added.txt")

		g := gitProbe{runner: ExecRunner{}, checkout: dir}
		if !g.dirty() {
			t.Error("dirty() = false with a STAGED ADD — a file in the index is tracked and must still read dirty")
		}
	})

	t.Run("tracked deletion", func(t *testing.T) {
		dir := newTempGitRepo(t)
		if err := os.Remove(filepath.Join(dir, "tracked.txt")); err != nil {
			t.Fatalf("delete tracked file: %v", err)
		}

		g := gitProbe{runner: ExecRunner{}, checkout: dir}
		if !g.dirty() {
			t.Error("dirty() = false with a DELETED TRACKED file — a missing committed file is the loudest hygiene red flag there is")
		}
	})
}

// TestGitProbeUnreadableStaysUnknown pins the contract documented on
// Report.GitCommit: when the probe cannot read git at all, the sha is empty and
// DirtyTree is false. "We could not measure" must not masquerade as "dirty" —
// and the empty sha alongside it is what keeps unknown distinguishable from
// clean.
func TestGitProbeUnreadableStaysUnknown(t *testing.T) {
	g := gitProbe{runner: errRunner{}, checkout: "/nonexistent-checkout"}

	if sha := g.commit(); sha != "" {
		t.Errorf("commit() = %q, want \"\" when the probe cannot read git", sha)
	}
	if g.dirty() {
		t.Error("dirty() = true when the probe errored — we do not invent dirtiness")
	}
}

// errRunner fails every command, standing in for a box where git is missing or
// the checkout is unreadable.
type errRunner struct{}

func (errRunner) Run(string, ...string) (string, error) {
	return "", errors.New("probe unreadable")
}

// --- the consumer roots (the build plane's disk) ------------------------------
//
// realBuildPlaneDu is VERBATIM `nice -n 19 ionice -c3 du -kx -d1 <dir>` output,
// captured 2026-09-01 over ssh from the build-plane box at 91.98.139.58 — the
// box that motivated this axis.
//
// IT WAS RE-CAPTURED IN -k, AND THE RE-CAPTURE IS ITSELF THE FINDING. The
// original fixture was the same trees read with `du -h`, and comparing the two
// captures of the same directories is what measured the rounding this axis now
// refuses:
//
//	root                        du -h landed   du -k exact    over by
//	/var/lib/containerd         15032385536    14136475648    +895 MB
//	/var/lib/barkpark-builder   11811160064    11575521280    +236 MB
//	/var/log/journal             2040109466     1971761152     +68 MB
//
// Every -h figure is an exact multiple of 0.1 GiB — the signature of a rounded
// string re-inflated by parseHumanBytes. The payload was reporting a precision
// it never had, and always in the same direction: UP.
//
// It is a REAL fixture on purpose. A synthesised one is written in the shape
// the parser is already assumed to handle, which makes a green here mean
// nothing; these strings carry the actual coreutils spacing, the actual
// containerd directory names, and the "4"-block rows a hand-written fixture
// would have tidied away.
var realBuildPlaneDu = map[string]string{
	"/var/lib/containerd": "4\t/var/lib/containerd/tmpmounts\n" +
		"3152\t/var/lib/containerd/io.containerd.metadata.v1.bolt\n" +
		"2012392\t/var/lib/containerd/io.containerd.content.v1.content\n" +
		"8\t/var/lib/containerd/io.containerd.grpc.v1.introspection\n" +
		"12\t/var/lib/containerd/io.containerd.runtime.v2.task\n" +
		"4\t/var/lib/containerd/io.containerd.snapshotter.v1.btrfs\n" +
		"4\t/var/lib/containerd/io.containerd.sandbox.controller.v1.shim\n" +
		"11789556\t/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs\n" +
		"4\t/var/lib/containerd/io.containerd.snapshotter.v1.blockfile\n" +
		"8\t/var/lib/containerd/io.containerd.snapshotter.v1.native\n" +
		"4\t/var/lib/containerd/io.containerd.snapshotter.v1.erofs\n" +
		"13805152\t/var/lib/containerd\n",
	"/var/lib/barkpark-builder": "11302376\t/var/lib/barkpark-builder/images\n" +
		"1840\t/var/lib/barkpark-builder/uploads\n" +
		"11304220\t/var/lib/barkpark-builder\n",
	"/var/log/journal": "8196\t/var/log/journal/f8537ed2a6984286b86d626a60059275\n" +
		"1917348\t/var/log/journal/e82ca0d33eb64f0f84e134be7b72c656\n" +
		"1925548\t/var/log/journal\n",
}

// The build-plane box's exact bytes, from the -k capture above. They are named
// constants because three tests assert against them and a hand-copied literal
// that drifts in one of the three is a green that means nothing.
const (
	buildPlaneContainerdBytes = int64(13805152) * 1024 // 14,136,475,648
	buildPlaneBuilderBytes    = int64(11304220) * 1024 // 11,575,521,280
	buildPlaneJournalBytes    = int64(1925548) * 1024  //  1,971,761,152
	buildPlaneOverlayfsBytes  = int64(11789556) * 1024 // 12,072,505,344
	buildPlaneImagesBytes     = int64(11302376) * 1024 // 11,573,633,024
)

// buildPlaneRunner is a probeRunner that replays realBuildPlaneDu for the roots
// that box has and reproduces coreutils' actual failure for the one it does
// not. `/opt/barkpark/sites` genuinely does not exist there — the ssh capture
// returned exactly this text with rc=1.
func buildPlaneRunner(t *testing.T) probeRunner {
	t.Helper()
	return func(name string, args ...string) (string, error) {
		dir := args[len(args)-1]
		if out, ok := realBuildPlaneDu[dir]; ok {
			return out, nil
		}
		return "du: cannot access '" + dir + "': No such file or directory\n",
			errors.New("exit status 1")
	}
}

// TestConsumerRootAbsentIsNeverZero is the whole point of the axis, and its
// failure message is the bug it exists to catch:
//
//	a root that is not on this box must report ABSENT with the -1 sentinel.
//	Reporting 0 bytes claims "we walked this tree and it is empty" about a
//	directory that does not exist — which is how a probe pointed at the wrong
//	root came to read as good news on a box that was 100% full.
//
// It also pins that the absent root STAYS IN THE LIST. Dropping it would be the
// same bug by omission: a payload with no row for a root nobody can tell from a
// box where that root holds nothing.
func TestConsumerRootAbsentIsNeverZero(t *testing.T) {
	// The build-plane box's real shape: two roots present, one absent.
	present := map[string]bool{
		"/var/lib/containerd":       true,
		"/var/lib/barkpark-builder": true,
	}
	s := gatherSpace(SpaceConfig{
		ConsumerRoots:      []string{"/var/lib/containerd", "/opt/barkpark/sites", "/var/lib/barkpark-builder"},
		ConsumerRootExists: func(p string) bool { return present[p] },
		ConsumerRootProbe:  newConsumerRootProbeWith(buildPlaneRunner(t)),
	})

	if len(s.ConsumerRoots) != 3 {
		t.Fatalf("ConsumerRoots has %d entries, want 3 — the ABSENT root must stay in the list; "+
			"a missing row is indistinguishable from a root that holds nothing", len(s.ConsumerRoots))
	}

	var absent *ConsumerRoot
	for i := range s.ConsumerRoots {
		if s.ConsumerRoots[i].Path == "/opt/barkpark/sites" {
			absent = &s.ConsumerRoots[i]
		}
	}
	if absent == nil {
		t.Fatal("no entry for /opt/barkpark/sites — the root that does not exist is the one that must be reported")
	}
	if absent.Bytes == 0 {
		t.Fatalf("absent root %s reported 0 bytes — that is the measured claim "+
			"\"this tree is empty\" about a directory that is not on the box, and it is "+
			"exactly the reading that let a 100%%-full builder rank healthy", absent.Path)
	}
	if absent.Status != ConsumerRootAbsent {
		t.Errorf("absent root Status = %q, want %q — %q and %q are different operator actions "+
			"(point the probe somewhere real vs. fix the probe)",
			absent.Status, ConsumerRootAbsent, ConsumerRootAbsent, ConsumerRootUnmeasured)
	}
	if absent.Bytes != -1 || absent.Count != -1 {
		t.Errorf("absent root = (bytes %d, count %d), want both at the -1 sentinel", absent.Bytes, absent.Count)
	}
	if absent.Top != nil {
		t.Errorf("absent root Top = %v, want nil — an unmeasured list is null, never []", absent.Top)
	}

	// And the two roots that ARE there were still read: one missing tree must
	// never erase the ones that were measured.
	for _, r := range s.ConsumerRoots {
		if r.Path == "/opt/barkpark/sites" {
			continue
		}
		if r.Status != ConsumerRootRead || r.Bytes <= 0 {
			t.Errorf("root %s = %+v, want a completed read — an absent sibling must not poison it", r.Path, r)
		}
	}
}

// TestConsumerRootsNameTheBuildPlanesTwentyFourGigabytes replays the REAL du
// output from the box and asserts the payload names the bytes that the sites
// axis structurally could not see.
//
// IT USED TO BE NAMED "TwentyFive", AND THAT IS THE POINT OF THIS TEST NOW.
// "25 GiB" was never a measurement: it is 14G + 11G, two `du -h` strings that
// coreutils had already rounded UP, added together and then repeated — into
// this test's name, into DefaultConsumerRoots' doc comment, into a task title,
// and into the console's copy. Read with `du -kx`, the same two trees on the
// same box are 13.166 GiB and 10.781 GiB: 23.95 GiB, not 25. The prose was
// over a gigabyte heavier than the disk.
//
// The number is still the finding — containerd plus the builder are two thirds
// of that box's used space, and the sites axis sees none of it. What changed is
// that the number is now the one the filesystem reports.
func TestConsumerRootsNameTheBuildPlanesTwentyFourGigabytes(t *testing.T) {
	s := gatherSpace(SpaceConfig{
		ConsumerRoots:      DefaultConsumerRoots,
		ConsumerRootExists: func(p string) bool { _, ok := realBuildPlaneDu[p]; return ok },
		ConsumerRootProbe:  newConsumerRootProbeWith(buildPlaneRunner(t)),
	})

	byPath := map[string]ConsumerRoot{}
	for _, r := range s.ConsumerRoots {
		byPath[r.Path] = r
	}

	containerd, builder := byPath["/var/lib/containerd"], byPath["/var/lib/barkpark-builder"]
	if containerd.Status != ConsumerRootRead || builder.Status != ConsumerRootRead {
		t.Fatalf("build-plane roots = (%+v, %+v), want both read", containerd, builder)
	}

	if containerd.Bytes != buildPlaneContainerdBytes {
		t.Errorf("/var/lib/containerd = %d bytes, want %d (13.17 GiB exact — the box's biggest "+
			"single consumer). `du -h` called this 14G; the difference is 895 MB of precision "+
			"the payload never had", containerd.Bytes, buildPlaneContainerdBytes)
	}
	if builder.Bytes != buildPlaneBuilderBytes {
		t.Errorf("/var/lib/barkpark-builder = %d bytes, want %d (10.78 GiB exact; `du -h` called it 11G)",
			builder.Bytes, buildPlaneBuilderBytes)
	}
	if sum, want := containerd.Bytes+builder.Bytes, buildPlaneContainerdBytes+buildPlaneBuilderBytes; sum != want {
		t.Errorf("build plane names %d bytes, want %d — 23.95 GiB, which is what the two trees "+
			"actually hold. Anything that reads 26843545600 here is the old 25-GiB `du -h` sum, "+
			"and it is 1.05 GiB of bytes that are not on the disk", sum, want)
	}

	// EXACTNESS IS THE ASSERTION, not a nicety. A rounded reading is a multiple
	// of a power of ten in GiB; an exact one is not. This is the cheap,
	// direction-free tripwire for a future edit that puts -h back.
	const gib = int64(1) << 30
	for _, r := range []ConsumerRoot{containerd, builder, byPath["/var/log/journal"]} {
		if r.Bytes%(gib/10) == 0 {
			t.Errorf("%s = %d bytes, an exact multiple of 0.1 GiB. Real trees are not; this is a "+
				"`du -h` string re-inflated, which over-reports by up to a whole unit per root and "+
				"drives a multi-root residual negative", r.Path, r.Bytes)
		}
	}

	// The biggest child is named, not just the total: an operator acts on
	// io.containerd.snapshotter.v1.overlayfs, never on "/var/lib/containerd".
	if len(containerd.Top) == 0 || containerd.Top[0].Name != "io.containerd.snapshotter.v1.overlayfs" {
		t.Errorf("containerd Top = %+v, want the overlayfs snapshotter named first", containerd.Top)
	}
	if containerd.Top[0].Bytes != buildPlaneOverlayfsBytes {
		t.Errorf("containerd biggest child = %d bytes, want %d (11.24 GiB)", containerd.Top[0].Bytes, buildPlaneOverlayfsBytes)
	}
	if len(builder.Top) == 0 || builder.Top[0].Name != "images" || builder.Top[0].Bytes != buildPlaneImagesBytes {
		t.Errorf("builder Top = %+v, want images at %d bytes named first", builder.Top, buildPlaneImagesBytes)
	}
	if journal := byPath["/var/log/journal"]; journal.Status != ConsumerRootRead || journal.Bytes != buildPlaneJournalBytes {
		t.Errorf("/var/log/journal = %+v, want a read of %d bytes (1.84 GiB) — measured as a tree, "+
			"so a box without journald still gets an answer", journal, buildPlaneJournalBytes)
	}
}

// TestConsumerRootsHonestUnknowns pins the other two honest states: no roots
// configured is nil (not []), and a root whose walk FAILS is `unmeasured` —
// never `absent`, because "we could not read it" is not "it is not there".
func TestConsumerRootsHonestUnknowns(t *testing.T) {
	t.Run("no roots configured", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{SitesDir: "/opt/barkpark/sites"})
		if s.ConsumerRoots != nil {
			t.Errorf("ConsumerRoots = %v, want nil — an agent never told where to look has not "+
				"measured an empty fleet of roots, it has not measured", s.ConsumerRoots)
		}
	})

	t.Run("probe fails on a root that IS there", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			ConsumerRoots:      []string{"/var/lib/containerd"},
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
				// A du killed at its deadline: rows already printed, non-zero exit.
				return 0, []DirSize{{Name: "half", Bytes: 1}}, nil, errors.New("signal: killed")
			},
		})
		got := s.ConsumerRoots[0]
		if got.Status != ConsumerRootUnmeasured {
			t.Errorf("failed walk Status = %q, want %q — a timeout is not evidence the tree is missing",
				got.Status, ConsumerRootUnmeasured)
		}
		if got.Bytes != -1 || got.Count != -1 || got.Top != nil {
			t.Errorf("failed walk = %+v, want the sentinels — a partial du must be DISCARDED, "+
				"not landed as a measurement", got)
		}
	})

	t.Run("no exists-check wired", func(t *testing.T) {
		// Without a presence check we genuinely do not know why the walk
		// failed, so the honest answer is `unmeasured`, never `absent`.
		s := gatherSpace(SpaceConfig{
			ConsumerRoots:     []string{"/nope"},
			ConsumerRootProbe: newConsumerRootProbeWith(buildPlaneRunner(t)),
		})
		if got := s.ConsumerRoots[0]; got.Status != ConsumerRootUnmeasured || got.Bytes != -1 {
			t.Errorf("unchecked failing root = %+v, want unmeasured/-1 — claiming ABSENT here "+
				"would be a guess dressed as a measurement", got)
		}
	})
}

// TestConsumerRootsAreBounded pins both caps, and pins that the CHILD cap does
// not eat its own denominator: Count is what the walk FOUND, so a short Top can
// say it is short. That is the sites axis's SitesCount lesson applied here.
func TestConsumerRootsAreBounded(t *testing.T) {
	t.Run("root list", func(t *testing.T) {
		many := make([]string, consumerRootsLimit+4)
		for i := range many {
			many[i] = fmt.Sprintf("/root%d", i)
		}
		s := gatherSpace(SpaceConfig{
			ConsumerRoots:      many,
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe:  func(string) (int64, []DirSize, []string, error) { return 1, nil, nil, nil },
		})
		if len(s.ConsumerRoots) != consumerRootsLimit {
			t.Errorf("configured %d roots, payload carried %d, want the %d cap — every root is one "+
				"bounded du, so the cap bounds wall time as well as bytes",
				len(many), len(s.ConsumerRoots), consumerRootsLimit)
		}
	})

	t.Run("children, with the count surviving the cap", func(t *testing.T) {
		children := make([]DirSize, consumerTopLimit+7)
		for i := range children {
			children[i] = DirSize{Name: fmt.Sprintf("d%d", i), Bytes: int64(1000 - i)}
		}
		s := gatherSpace(SpaceConfig{
			ConsumerRoots:      []string{"/var/lib/containerd"},
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe:  func(string) (int64, []DirSize, []string, error) { return 99, children, nil, nil },
		})
		got := s.ConsumerRoots[0]
		if len(got.Top) != consumerTopLimit {
			t.Errorf("Top has %d rows, want the %d cap", len(got.Top), consumerTopLimit)
		}
		if got.Count != len(children) {
			t.Errorf("Count = %d, want %d — the count must be what the walk FOUND, not what "+
				"survived the cap; a cap that eats its denominator can never announce itself",
				got.Count, len(children))
		}
	})
}

// TestSpacePayloadStaysBounded measures rather than hopes: it marshals a
// build-plane-shaped report with the root list at its cap and every root at its
// child cap, and pins the wire size. The caps exist to bound this number; if it
// grows past the ceiling, LOWER A CAP — do not raise the ceiling.
func TestSpacePayloadStaysBounded(t *testing.T) {
	roots := make([]string, consumerRootsLimit)
	children := make([]DirSize, consumerTopLimit)
	for i := range children {
		// Realistic worst case: containerd's longest actual directory name.
		children[i] = DirSize{Name: "io.containerd.sandbox.controller.v1.shim", Bytes: 12884901888}
	}
	for i := range roots {
		roots[i] = fmt.Sprintf("/var/lib/some-fairly-long-consumer-root-%d", i)
	}
	sites := make([]SiteSize, sitesTopLimit)
	for i := range sites {
		sites[i] = SiteSize{Slug: fmt.Sprintf("a-realistic-site-slug-%d", i), Bytes: 658505728}
	}
	degradedNames := make([]string, consumerDegradedLimit)
	for i := range degradedNames {
		degradedNames[i] = fmt.Sprintf("/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/%d", i)
	}

	s := gatherSpace(SpaceConfig{
		RootProbe:          func() (int64, int64, error) { return 37937041408, 39964635136, nil },
		JournalProbe:       func() (int64, error) { return 932184064, nil },
		PGSizeProbe:        func() (int64, error) { return 3477617687, nil },
		SitesDir:           "/opt/barkpark/sites",
		SitesProbe:         func() (int64, []SiteSize, error) { return 4294967296, sites, nil },
		ConsumerRoots:      roots,
		ConsumerRootExists: func(string) bool { return true },
		// Worst case includes the DEGRADED names: every root short, every name
		// list at its cap, and realistically long paths. A ceiling measured on
		// the happy shape is a ceiling that has never met the payload.
		ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
			return 15032385536, children, degradedNames, nil
		},
	})

	body, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal SpaceReport: %v", err)
	}
	const ceiling = 4096
	if len(body) > ceiling {
		t.Errorf("space payload is %d bytes at full caps, over the %d-byte ceiling. "+
			"LOWER consumerRootsLimit (%d) or consumerTopLimit (%d) — the caps exist to bound "+
			"this number, and raising the ceiling instead is how a payload grows without anyone deciding to.",
			len(body), ceiling, consumerRootsLimit, consumerTopLimit)
	}
	t.Logf("space payload at full caps: %d bytes (ceiling %d)", len(body), ceiling)
}

// TestConsumerRootExistsIsAStatNotADuGuess pins the presence check against the
// real filesystem: a directory that is there is PRESENT, one that is not is
// ABSENT, and — the arm that matters — a path we are not allowed to read is
// PRESENT, so its du failure lands as `unmeasured`. Calling an unreadable root
// "absent" would be the original bug wearing a different hat.
func TestConsumerRootExistsIsAStatNotADuGuess(t *testing.T) {
	exists := NewConsumerRootExists()
	dir := t.TempDir()

	// Subtests, so the permission arm's skip cannot swallow these two: a whole
	// test reported SKIP is a test whose passing arms nobody can see.
	t.Run("a directory that is there", func(t *testing.T) {
		if !exists(dir) {
			t.Errorf("exists(%q) = false for a directory that is right there", dir)
		}
	})

	t.Run("a path that is not", func(t *testing.T) {
		if exists(filepath.Join(dir, "definitely-not-here")) {
			t.Error("exists() = true for a path that does not exist")
		}
	})

	t.Run("a directory we may not read into", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("running as root: a 0000 directory is still readable, so this arm cannot be exercised")
		}
		locked := filepath.Join(dir, "locked")
		if err := os.Mkdir(locked, 0o000); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		t.Cleanup(func() { _ = os.Chmod(locked, 0o700) })
		if _, err := os.Stat(filepath.Join(locked, "child")); err == nil {
			t.Skip("this sandbox stats through a 0000 directory; the permission arm is unreachable here")
		}
		if !exists(locked) {
			t.Error("exists() = false for a directory we merely lack permission to READ INTO — " +
				"a permission denial is not evidence the root is missing, and reporting ABSENT " +
				"there recreates the very bug this axis fixes")
		}
	})
}

// --- the exact-units axis ----------------------------------------------------
//
// duHumanTree and duKiBTree are THE SAME TREE in the two units du can print it
// in, byte-for-byte equivalent by construction (every human row is an exact
// power-of-1024 multiple, so the -k row is the same number of 1024-blocks).
// They exist as a PAIR because the failure being pinned is a unit confusion,
// and a single-unit fixture cannot see one.
const (
	duHumanTree = "12G\t/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs\n" +
		"2.0G\t/var/lib/containerd/io.containerd.content.v1.content\n" +
		"14G\t/var/lib/containerd\n"

	duKiBTree = "12582912\t/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs\n" +
		"2097152\t/var/lib/containerd/io.containerd.content.v1.content\n" +
		"14680064\t/var/lib/containerd\n"
)

// TestDuArgvAndParseUnitCannotDrift pins the COUPLING, which is the actual
// repair: duTreeArgs hands back the argv and the unit its output will be in
// from one place, so the flag that picks the unit and the parser that reads it
// cannot be edited apart.
//
// Before the unit parameter existed this drift was one character wide and
// entirely invisible: flipping `-hx` to `-kx` (plus the two argv literals that
// pinned the string) left the whole package green while the payload reported
// 26 MB for 25 GiB. This test reads the flag out of the argv and maps it back
// to a unit INDEPENDENTLY, so a flag-only edit fails here rather than in
// production six weeks later.
func TestDuArgvAndParseUnitCannotDrift(t *testing.T) {
	argv, unit := duTreeArgs("/var/lib/containerd")

	// An independent flag->unit table. It is deliberately NOT built from
	// duUnit's own values: a test that derives its expectation from the code
	// under test can never disagree with it.
	byFlag := map[string]duUnit{"-hx": duUnitHuman, "-kx": duUnitKiB}

	var flags []string
	for _, a := range argv {
		if _, ok := byFlag[a]; ok {
			flags = append(flags, a)
		}
	}
	if len(flags) != 1 {
		t.Fatalf("argv %v carries %d recognised du unit flags, want exactly 1 — the unit must be a "+
			"single stated decision, not something a reader infers", argv, len(flags))
	}
	if want := byFlag[flags[0]]; want != unit {
		t.Errorf("argv asks du for %q (unit %q) but duTreeArgs returns unit %q. These are ONE decision: "+
			"reading `du -k`'s bare 1024-blocks on the -h path reports 26 MB for 25 GiB, and reading "+
			"`du -h`'s \"14G\" on the -k path is the same error 1024x the other way.",
			flags[0], want, unit)
	}
}

// TestParseDuTreeRejectsTheWrongUnit is the 1024x test, and it is the reason
// parseDuTree takes a unit at all.
//
// The measured hazard: `du -k` prints "14680064" for the same tree `du -h`
// prints "14G". A parser that falls through to strconv.ParseInt and calls the
// result BYTES turns 14 GiB into 14 MB — under-reporting, which is the single
// direction that makes a full box look healthy and is exactly what this payload
// exists to prevent. So -k rows on the -h path must be REFUSED, not returned
// 1024x short.
func TestParseDuTreeRejectsTheWrongUnit(t *testing.T) {
	const dir = "/var/lib/containerd"
	const wantTotal = int64(14) << 30

	t.Run("each unit read on its own path agrees, byte for byte", func(t *testing.T) {
		for _, c := range []struct {
			name string
			out  string
			unit duUnit
		}{
			{"human rows, human unit", duHumanTree, duUnitHuman},
			{"kib rows, kib unit", duKiBTree, duUnitKiB},
		} {
			t.Run(c.name, func(t *testing.T) {
				total, rows, degraded, err := parseDuTree(c.out, dir, c.unit)
				if err != nil {
					t.Fatalf("parseDuTree: %v", err)
				}
				if total != wantTotal {
					t.Errorf("total = %d, want %d — the two fixtures are the SAME TREE and must "+
						"produce the same bytes", total, wantTotal)
				}
				if len(rows) != 2 || rows[0].Bytes != int64(12)<<30 {
					t.Errorf("rows = %+v, want the overlayfs snapshotter at 12 GiB first", rows)
				}
				if degraded != nil {
					t.Errorf("degraded = %v, want nil — a clean walk names nothing", degraded)
				}
			})
		}
	})

	t.Run("kib rows on the HUMAN path are refused, not silently 1024x short", func(t *testing.T) {
		total, rows, degraded, err := parseDuTree(duKiBTree, dir, duUnitHuman)
		if err == nil {
			t.Fatalf("parseDuTree accepted `du -k` output on the -h path and returned total=%d "+
				"(%.1f MB) where the tree is %.1f GB. Silently under-reporting by 1024x is the "+
				"failure this axis exists to remove.",
				total, float64(total)/(1<<20), float64(wantTotal)/(1<<30))
		}
		if total != -1 || rows != nil || degraded != nil {
			t.Errorf("got (%d, %+v, %v), want (-1, nil, nil) — a rejected parse must land nothing",
				total, rows, degraded)
		}
		// The specific number the bug would have produced, named so a future
		// reader can see what "silently returned" would have meant.
		if total == 14680064 {
			t.Error("total is the raw 1024-block count read as bytes: 14 MB for a 14 GiB tree")
		}
	})

	t.Run("human rows on the KIB path are refused too", func(t *testing.T) {
		// The mirror image, and it over-reports by 1024x rather than under —
		// still a lie, and still caught by the same parameter.
		if total, _, _, err := parseDuTree(duHumanTree, dir, duUnitKiB); err == nil {
			t.Errorf("parseDuTree accepted `du -h` output on the -k path, total=%d", total)
		}
	})

	t.Run("the tripwire has a floor, and the floor is why the unit is a PARAMETER", func(t *testing.T) {
		// Measured on a real tree: `du -kx -d1` prints "300/100/400" where
		// `du -hx -d1` prints "300K/100K/400K". Below 1024 the two units are
		// indistinguishable from the output alone, so the -k rows for a small
		// tree DO parse on the -h path — as 400 bytes for a 400 KiB tree.
		//
		// This test exists so that limit is a STATED FACT rather than an
		// assumption a later reader makes on the tripwire's behalf and then
		// uses to justify dropping the duTreeArgs coupling. The parameter is
		// the defence; the >= 1024 check is a backstop for the magnitudes that
		// matter.
		small := "300\t/opt/barkpark/sites/a\n100\t/opt/barkpark/sites/b\n400\t/opt/barkpark/sites\n"
		total, _, _, err := parseDuTree(small, "/opt/barkpark/sites", duUnitHuman)
		if err != nil {
			t.Fatalf("parseDuTree: %v — sub-1024 bare values are legal `du -h` output", err)
		}
		if total != 400 {
			t.Fatalf("total = %d, want 400", total)
		}
		// Named for what it is: the same bytes read in the unit du was actually
		// asked for are 1024x larger, and only the caller knows which is right.
		if k, _, _, err := parseDuTree(small, "/opt/barkpark/sites", duUnitKiB); err != nil || k != 400*1024 {
			t.Fatalf("same bytes on the -k path = (%d, %v), want (%d, nil) — the ambiguity is real "+
				"and the unit parameter is the only thing that resolves it", k, err, 400*1024)
		}
	})

	t.Run("a bare sub-kilobyte size is still legal on the human path", func(t *testing.T) {
		// `du -h` humanizes at 1024, so it CAN print "0" or "512" and can never
		// print "14680064". The threshold is what makes the rejection exact
		// instead of a heuristic that discards real small rows.
		out := "512\t/var/lib/containerd/tiny\n0\t/var/lib/containerd/empty\n4.0K\t/var/lib/containerd\n"
		total, rows, _, err := parseDuTree(out, dir, duUnitHuman)
		if err != nil {
			t.Fatalf("parseDuTree rejected legal `du -h` output: %v", err)
		}
		if total != 4096 || len(rows) != 2 {
			t.Errorf("got total=%d rows=%+v, want 4096 and two rows", total, rows)
		}
	})
}

// --- the degraded axis -------------------------------------------------------

// duDegradedGNU and duDegradedBSD are the REAL CombinedOutput shape: runBounded
// uses CombinedOutput(), so du's stderr complaint arrives interleaved with its
// sizes. GNU coreutils 9.4 emits the diagnostic LAST (after the total row) and
// quotes the path; macOS/BSD emits it FIRST and does not quote. Any parser that
// assumes a position is a flake on one of the two, so both are pinned.
const (
	duDegradedGNU = "200\t/opt/barkpark/sites/ok\n" +
		"100\t/opt/barkpark/sites/ok2\n" +
		"300\t/opt/barkpark/sites\n" +
		"du: cannot read directory '/opt/barkpark/sites/locked': Permission denied\n"

	duDegradedBSD = "du: /opt/barkpark/sites/locked: Permission denied\n" +
		"200\t/opt/barkpark/sites/ok\n" +
		"100\t/opt/barkpark/sites/ok2\n" +
		"300\t/opt/barkpark/sites\n"
)

// TestParseDuTreeRoutesDuDiagnosticsToDegraded is the contained fix for the
// blocker: before it, one "du: ... Permission denied" line HARD-FAILED the
// whole parse — measured, `total=-1 rows=[]` against a stdout-only parse of
// `total=307200 rows=[{ok 204800} {ok2 102400}]`. A real measurement was thrown
// away along with the only bytes that could name the shortfall.
func TestParseDuTreeRoutesDuDiagnosticsToDegraded(t *testing.T) {
	for _, c := range []struct {
		name string
		out  string
	}{
		{"GNU: quoted path, diagnostic LAST", duDegradedGNU},
		{"BSD: bare path, diagnostic FIRST", duDegradedBSD},
	} {
		t.Run(c.name, func(t *testing.T) {
			total, rows, degraded, err := parseDuTree(c.out, "/opt/barkpark/sites", duUnitKiB)
			if err != nil {
				t.Fatalf("parseDuTree hard-failed on a du diagnostic: %v — the total was right "+
					"there in the same bytes", err)
			}
			if want := int64(300) * 1024; total != want {
				t.Errorf("total = %d, want %d", total, want)
			}
			if len(rows) != 2 {
				t.Errorf("rows = %+v, want the two readable children", rows)
			}
			want := []string{"/opt/barkpark/sites/locked"}
			if !reflect.DeepEqual(degraded, want) {
				t.Errorf("degraded = %v, want %v — the unreadable subtree must be named BY PATH, "+
					"which is what an operator can ls/chmod", degraded, want)
			}
		})
	}

	t.Run("GNU's curly quotes outside the C locale", func(t *testing.T) {
		out := "307200\t/opt/barkpark/sites\n" +
			"du: cannot read directory ‘/opt/barkpark/sites/locked’: Permission denied\n"
		_, _, degraded, err := parseDuTree(out, "/opt/barkpark/sites", duUnitKiB)
		if err != nil {
			t.Fatalf("parseDuTree: %v", err)
		}
		if len(degraded) != 1 || degraded[0] != "/opt/barkpark/sites/locked" {
			t.Errorf("degraded = %v, want the path out of U+2018/U+2019 quotes", degraded)
		}
	})

	t.Run("a directory whose NAME starts with du: is a row, not a diagnostic", func(t *testing.T) {
		// The discriminator has to be exact: a du OUTPUT row is size<TAB>path,
		// so a directory literally named "du: notes" arrives WITH a tab and
		// must be counted, not silently reclassified as a failure.
		out := "1024\t/opt/barkpark/sites/du: notes\n307200\t/opt/barkpark/sites\n"
		_, rows, degraded, err := parseDuTree(out, "/opt/barkpark/sites", duUnitKiB)
		if err != nil {
			t.Fatalf("parseDuTree: %v", err)
		}
		if len(rows) != 1 || degraded != nil {
			t.Errorf("rows=%+v degraded=%v, want one row and nothing degraded", rows, degraded)
		}
	})
}

// TestConsumerRootDegradedLandsTheFloorAndNamesTheShortfall is the end-to-end
// arm: a real permission-denied walk (rc=1, every row printed INCLUDING the
// total, one stderr line) reaches the payload as `degraded` with real bytes and
// the unreadable path named — never as `read` (the number is a floor, not a
// size) and never as `unmeasured` (we have a floor and can say what is missing
// from it).
func TestConsumerRootDegradedLandsTheFloorAndNamesTheShortfall(t *testing.T) {
	probe := newConsumerRootProbeWith(func(string, ...string) (string, error) {
		// Exactly what runBounded hands back: full combined output AND rc=1.
		return duDegradedGNU, errors.New("exit status 1")
	})
	s := gatherSpace(SpaceConfig{
		ConsumerRoots:      []string{"/opt/barkpark/sites"},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe: func(p string) (int64, []DirSize, []string, error) {
			return probe(p)
		},
	})

	got := s.ConsumerRoots[0]
	if got.Status != ConsumerRootDegraded {
		t.Fatalf("Status = %q, want %q — a walk that finished, printed its total and named what it "+
			"could not read is neither a clean read nor an unmeasured one", got.Status, ConsumerRootDegraded)
	}
	if want := int64(300) * 1024; got.Bytes != want {
		t.Errorf("Bytes = %d, want %d — the floor is real and must land", got.Bytes, want)
	}
	if got.Count != 2 {
		t.Errorf("Count = %d, want 2", got.Count)
	}
	if want := []string{"/opt/barkpark/sites/locked"}; !reflect.DeepEqual(got.Degraded, want) {
		t.Errorf("Degraded = %v, want %v — BY PATH, never by the daemon or unit that owns the tree",
			got.Degraded, want)
	}
	if got.DegradedCount != 1 {
		t.Errorf("DegradedCount = %d, want 1", got.DegradedCount)
	}

	// And it survives the wire under its own name.
	body, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, want := range []string{`"status":"degraded"`, `"degraded":["/opt/barkpark/sites/locked"]`, `"degraded_count":1`} {
		if !strings.Contains(string(body), want) {
			t.Errorf("payload missing %s; got %s", want, body)
		}
	}
}

// TestConsumerRootDegradedNamesAreCappedButCounted: the cap has to announce
// itself, the same lesson SitesCount paid for — a cap that eats its own
// denominator can never say when it binds.
func TestConsumerRootDegradedNamesAreCappedButCounted(t *testing.T) {
	var b strings.Builder
	b.WriteString("300\t/opt/barkpark/sites\n")
	const found = consumerDegradedLimit + 4
	for i := 0; i < found; i++ {
		fmt.Fprintf(&b, "du: cannot read directory '/opt/barkpark/sites/locked-%02d': Permission denied\n", i)
	}
	probe := newConsumerRootProbeWith(func(string, ...string) (string, error) {
		return b.String(), errors.New("exit status 1")
	})
	s := gatherSpace(SpaceConfig{
		ConsumerRoots:      []string{"/opt/barkpark/sites"},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe:  func(p string) (int64, []DirSize, []string, error) { return probe(p) },
	})
	got := s.ConsumerRoots[0]
	if len(got.Degraded) != consumerDegradedLimit {
		t.Errorf("Degraded carries %d names, want the %d cap", len(got.Degraded), consumerDegradedLimit)
	}
	if got.DegradedCount != found {
		t.Errorf("DegradedCount = %d, want %d — the count must be what the walk HIT, not what "+
			"survived the cap", got.DegradedCount, found)
	}
}

// TestConsumerRootDiscardsWhatWasCutShort is criterion 3's half of the rule,
// and it is the one that keeps land-on-degraded from becoming land-on-anything.
// D59 stands: a walk that was CUT SHORT is not a measurement, however parseable
// its prefix happens to be.
func TestConsumerRootDiscardsWhatWasCutShort(t *testing.T) {
	const dir = "/opt/barkpark/sites"
	partial := "200\t/opt/barkpark/sites/ok\n100\t/opt/barkpark/sites/ok2\n"

	for _, c := range []struct {
		name string
		out  string
		err  error
		why  string
	}{
		{
			name: "deadline kill, even with a total row AND a named diagnostic",
			out:  duDegradedGNU,
			err:  fmt.Errorf("%w after 60s: nice du", errProbeTimedOut),
			why:  "a killed du can print anything at all; the deadline is the fact, not the output shape",
		},
		{
			name: "non-zero exit, no total row",
			out:  partial,
			err:  errors.New("signal: killed"),
			why:  "du prints its root LAST, so output without it was cut short",
		},
		{
			name: "non-zero exit, total row, but nothing named",
			out:  partial + "300\t/opt/barkpark/sites\n",
			err:  errors.New("signal: killed"),
			why:  "an unexplained rc!=0 is not a permission shortfall; without a named path there is nothing to land",
		},
		{
			// BSD order deliberately: du has ALREADY named an unreadable subtree
			// by the time the unparseable row arrives, so the "was anything
			// named?" veto is satisfied and only the "did the parse succeed?"
			// veto can refuse this. Each veto has to be able to refuse ALONE, or
			// one of them is decoration.
			name: "non-zero exit, a named diagnostic ALREADY seen, but an unparseable row",
			out:  "du: /opt/barkpark/sites/locked: Permission denied\nnot-a-size\t/opt/barkpark/sites/x\n300\t/opt/barkpark/sites\n",
			err:  errors.New("exit status 1"),
			why:  "a row we could not read is a hole of unknown size, which is not a floor",
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			probe := newConsumerRootProbeWith(func(string, ...string) (string, error) { return c.out, c.err })
			total, children, degraded, err := probe(dir)
			if err == nil {
				t.Fatalf("probe returned nil error — %s", c.why)
			}
			if total != -1 || children != nil || degraded != nil {
				t.Fatalf("got (%d, %+v, %v), want (-1, nil, nil) — %s", total, children, degraded, c.why)
			}

			s := gatherSpace(SpaceConfig{
				ConsumerRoots:      []string{dir},
				ConsumerRootExists: func(string) bool { return true },
				ConsumerRootProbe:  func(p string) (int64, []DirSize, []string, error) { return probe(p) },
			})
			got := s.ConsumerRoots[0]
			if got.Status != ConsumerRootUnmeasured || got.Bytes != -1 || got.Degraded != nil || got.DegradedCount != -1 {
				t.Errorf("through gatherSpace: %+v, want unmeasured with every sentinel intact", got)
			}
		})
	}
}

// TestConsumerRootsReportEveryConfiguredRootByPath is criterion 1's shape, all
// four arms in one ordered payload: what was ATTEMPTED (every configured root
// has a row, in order), what was READ, what DEGRADED, and what was neither.
//
// Naming is BY PATH throughout. "containerd" is not a place; /var/lib/containerd
// is, and it is the string the operator's next command takes.
func TestConsumerRootsReportEveryConfiguredRootByPath(t *testing.T) {
	const (
		readRoot     = "/var/lib/containerd"
		degradedRoot = "/var/lib/barkpark-builder"
		absentRoot   = "/opt/barkpark/sites"
		failedRoot   = "/var/log/journal"
	)
	configured := []string{readRoot, degradedRoot, absentRoot, failedRoot}

	var attempted []string
	s := gatherSpace(SpaceConfig{
		ConsumerRoots:      configured,
		ConsumerRootExists: func(p string) bool { return p != absentRoot },
		ConsumerRootProbe: func(p string) (int64, []DirSize, []string, error) {
			attempted = append(attempted, p)
			switch p {
			case readRoot:
				return 14 << 30, []DirSize{{Name: "overlayfs", Bytes: 12 << 30}}, nil, nil
			case degradedRoot:
				return 11 << 30, []DirSize{{Name: "images", Bytes: 10 << 30}}, []string{degradedRoot + "/locked"}, nil
			}
			return -1, nil, nil, errors.New("du: boom")
		},
	})

	// ATTEMPTED, in the configured order: one row per root, absent included.
	var gotPaths []string
	for _, r := range s.ConsumerRoots {
		gotPaths = append(gotPaths, r.Path)
	}
	if !reflect.DeepEqual(gotPaths, configured) {
		t.Fatalf("payload paths = %v, want %v in configured order", gotPaths, configured)
	}
	// The absent root is answered by a stat, so it is deliberately NOT walked —
	// "attempted" is the row, and the row is there.
	if want := []string{readRoot, degradedRoot, failedRoot}; !reflect.DeepEqual(attempted, want) {
		t.Errorf("walked %v, want %v — the absent root is answered by a stat, not a du", attempted, want)
	}

	byPath := map[string]ConsumerRoot{}
	for _, r := range s.ConsumerRoots {
		byPath[r.Path] = r
	}
	for path, want := range map[string]string{
		readRoot:     ConsumerRootRead,
		degradedRoot: ConsumerRootDegraded,
		absentRoot:   ConsumerRootAbsent,
		failedRoot:   ConsumerRootUnmeasured,
	} {
		if got := byPath[path].Status; got != want {
			t.Errorf("%s Status = %q, want %q — the four states are four different operator actions",
				path, got, want)
		}
	}
	if d := byPath[degradedRoot]; d.Bytes != 11<<30 || len(d.Degraded) != 1 || d.Degraded[0] != degradedRoot+"/locked" {
		t.Errorf("degraded root = %+v, want a real floor and the unreadable path named", d)
	}
	if r := byPath[readRoot]; r.Degraded != nil || r.DegradedCount != -1 {
		t.Errorf("clean root = %+v, want nil/-1 — a root that read everything names nothing", r)
	}
}

// TestConsumerRootsBoundTOTALProbeTime is the bound criterion 4 asks for, and
// the distinction it draws is the whole point: duProbeTimeout is PER SHELL-OUT,
// so N roots buy N x 60s of worst case in ONE cycle. Nothing about the per-root
// bound stops six roots from becoming sixty.
//
// The SLICE is what bounds the total, so this measures the slice two ways —
// the number of walks actually performed, and the wall clock — and then pins
// the arithmetic against the cadence the beat has to fit inside.
func TestConsumerRootsBoundTOTALProbeTime(t *testing.T) {
	t.Run("the arithmetic worst case fits inside the space cadence", func(t *testing.T) {
		worst := time.Duration(consumerRootsLimit) * duProbeTimeout
		if worst >= DefaultSpaceInterval {
			t.Errorf("consumerRootsLimit(%d) x duProbeTimeout(%s) = %s, which is not shorter than the "+
				"%s space cadence: one slow cycle would still be walking when the next beat is due, and "+
				"beats would pile up. LOWER a bound — the per-root timeout is not the one that grows.",
				consumerRootsLimit, duProbeTimeout, worst, DefaultSpaceInterval)
		}
		t.Logf("worst case per cycle: %d roots x %s = %s (cadence %s)", consumerRootsLimit, duProbeTimeout, worst, DefaultSpaceInterval)
	})

	t.Run("a fat-fingered root list cannot buy more walls than the cap", func(t *testing.T) {
		const perRoot = 20 * time.Millisecond
		many := make([]string, consumerRootsLimit*5)
		for i := range many {
			many[i] = fmt.Sprintf("/root%d", i)
		}
		var calls int
		start := time.Now()
		s := gatherSpace(SpaceConfig{
			ConsumerRoots:      many,
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
				calls++
				time.Sleep(perRoot)
				return 1, nil, nil, nil
			},
		})
		elapsed := time.Since(start)

		if calls != consumerRootsLimit {
			t.Errorf("configured %d roots and the beat performed %d walks, want %d — the cap is the "+
				"only thing bounding TOTAL probe time, because the 60s deadline is per shell-out",
				len(many), calls, consumerRootsLimit)
		}
		if len(s.ConsumerRoots) != consumerRootsLimit {
			t.Errorf("payload carried %d roots, want %d", len(s.ConsumerRoots), consumerRootsLimit)
		}
		// Generous slack: this asserts the ORDER of magnitude the cap buys, not
		// the scheduler's precision.
		if ceiling := time.Duration(consumerRootsLimit)*perRoot + 2*time.Second; elapsed > ceiling {
			t.Errorf("the consumer axis took %s for %d configured roots, over the %s the %d-root cap "+
				"should have bought", elapsed, len(many), ceiling, consumerRootsLimit)
		}
		t.Logf("%d configured roots -> %d walks in %s", len(many), calls, elapsed)
	})
}

// TestBeatPreservesWindowS is the dr-w14-bl pin: a beat built from an instance
// body CARRYING window_s preserves it end to end — HTTP probe → gatherReport →
// the marshaled beat JSON — and an instance body WITHOUT the key (built before
// request_stats.ex shipped it) arrives as the -1 sentinel, never a confident
// 0-second window. Before this slice the decode struct had no WindowS field:
// three rates rode every beat with their measurement window discarded at the
// door — a rate without its denominator-of-time, the epic's signature defect.
func TestBeatPreservesWindowS(t *testing.T) {
	t.Run("window_s carried through to the outbound beat", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`{"req_per_s": 12.5, "p95_ms": 87, "err_5xx_per_s": 0.22, "window_s": 60}`))
		}))
		defer srv.Close()

		r := gatherReport(ReportConfig{ReqStatsProbe: NewReqStatsProbe(srv.URL, "", nil)})
		if r.WindowS != 60 {
			t.Fatalf("Report.WindowS = %d, want 60 — the window must survive the decode", r.WindowS)
		}
		beat, err := json.Marshal(r)
		if err != nil {
			t.Fatalf("marshal beat: %v", err)
		}
		if !strings.Contains(string(beat), `"window_s":60`) {
			t.Fatalf("outbound beat does not carry window_s:\n%s", beat)
		}
	})

	t.Run("absent window_s (old instance) → -1 sentinel, rates still land", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(`{"req_per_s": 12.5, "p95_ms": 87}`))
		}))
		defer srv.Close()

		r := gatherReport(ReportConfig{ReqStatsProbe: NewReqStatsProbe(srv.URL, "", nil)})
		if r.ReqPerS != 12.5 {
			t.Fatalf("ReqPerS = %v, want 12.5", r.ReqPerS)
		}
		if r.WindowS != -1 {
			t.Fatalf("Report.WindowS = %d, want -1 — an absent window is UNMEASURED, not zero seconds", r.WindowS)
		}
	})

	t.Run("unwired probe → -1", func(t *testing.T) {
		r := gatherReport(ReportConfig{})
		if r.WindowS != -1 {
			t.Fatalf("Report.WindowS = %d, want -1 with no probe", r.WindowS)
		}
	})
}

// --- the residual: what the reading did NOT measure ---------------------------
//
// The box these fixtures come from is the build plane at 91.98.139.58, read
// live on 2026-09-01. Its shape, from `df -P -k /`, `stat -c %d` and
// `du -kx -d1`:
//
//	/                                                 78408684 KiB total, 37560944 used, st_dev 2049
//	/var/lib/containerd                               13805152 KiB, st_dev 2049
//	/var/lib/barkpark-builder                         11304220 KiB, st_dev 2049
//	/var/log/journal                                   1925548 KiB, st_dev 2049
//	/var/lib/postgresql                                 157684 KiB, st_dev 2049
//	/var/lib/docker                                      13516 KiB, st_dev 2049
//	/var/lib/docker/rootfs/overlayfs/63036f65…         1506432 KiB, st_dev 44   <- A MOUNT
//
// The last row is the guard-2 hazard in one line: du -x reads the overlay in
// full when it is ROOTED there (1506432 KiB) and sees 8 KiB of it from
// /var/lib/docker's side, because -x will not cross INTO a mount. Those bytes
// are not on the root filesystem and must never be subtracted from its total.
const (
	jarlRootUsedBytes  = int64(37560944) * 1024 // 38,462,406,656
	jarlRootTotalBytes = int64(78408684) * 1024 // 80,290,492,416
	jarlPostgresBytes  = int64(157684) * 1024   //     161,468,416
	jarlOverlayBytes   = int64(1506432) * 1024  //   1,542,586,368
	jarlRootDev        = uint64(2049)
	jarlOverlayDev     = uint64(44)
)

// jarlDevices is the box's real st_dev map: everything on the root filesystem
// except the overlay.
func jarlDevices(overrides map[string]uint64) func(string) (uint64, bool) {
	return func(p string) (uint64, bool) {
		if d, ok := overrides[p]; ok {
			return d, true
		}
		return jarlRootDev, true
	}
}

// TestResidualNamesWhatWasNotMeasured is criterion 1. The reading must carry an
// explicit unaccounted figure, and it must be the SUBTRACTION — root used minus
// the measured roots — not a share of anything else.
//
// The failure it repairs is a confident subset. The shipped probe read one root
// that exists on one of six boxes and covers 14.9% of that one, and it said so
// in the same voice it would have used for the whole disk.
func TestResidualNamesWhatWasNotMeasured(t *testing.T) {
	s := gatherSpace(SpaceConfig{
		RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
		ConsumerRoots:      DefaultConsumerRoots,
		ConsumerRootExists: func(p string) bool { _, ok := realBuildPlaneDu[p]; return ok },
		ConsumerRootProbe:  newConsumerRootProbeWith(buildPlaneRunner(t)),
		DeviceProbe:        jarlDevices(nil),
	})

	r := s.Residual
	if r == nil {
		t.Fatal("Residual = nil — the reading must state what it did not measure, or refuse; " +
			"silence is the confident subset this field exists to end")
	}
	if r.Status != ResidualComputed {
		t.Fatalf("Status = %q reason %q, want %q — three disjoint roots on one device is the "+
			"computable case", r.Status, r.Reason, ResidualComputed)
	}

	measured := buildPlaneContainerdBytes + buildPlaneBuilderBytes + buildPlaneJournalBytes
	if r.MeasuredBytes != measured {
		t.Errorf("MeasuredBytes = %d, want %d (containerd + builder + journal, exact)", r.MeasuredBytes, measured)
	}
	if want := jarlRootUsedBytes - measured; r.Bytes != want {
		t.Errorf("Residual.Bytes = %d, want %d — RootUsedBytes minus the measured roots, "+
			"and nothing else", r.Bytes, want)
	}
	// The denominator travels WITH the value. A share whose whole is missing is
	// the number this axis replaced.
	if r.OfBytes != jarlRootUsedBytes {
		t.Errorf("OfBytes = %d, want %d — the denominator must ride beside the value so no "+
			"surface can render a percentage it cannot check", r.OfBytes, jarlRootUsedBytes)
	}
	if r.CountedRoots != 3 || r.ExcludedRoots != 0 {
		t.Errorf("counted/excluded = %d/%d, want 3/0", r.CountedRoots, r.ExcludedRoots)
	}
	if r.Reason != "" {
		t.Errorf("Reason = %q, want empty — a reason on a computed residual is a refusal that did not happen", r.Reason)
	}

	// Coverage on THIS box, from THIS payload: 71.98%, leaving 28.02%
	// unaccounted. That is the whole point — the roots name a bit under three
	// quarters of the used disk and the residual names the quarter nobody was
	// looking at, instead of the payload implying it had seen everything.
	if pct := float64(measured) / float64(jarlRootUsedBytes) * 100; pct < 71.5 || pct > 72.5 {
		t.Errorf("coverage = %.2f%%, want 71.98%% on the build-plane box's real numbers "+
			"(27683758080 measured of 38462406656 used)", pct)
	}

	body, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, want := range []string{`"residual":{`, `"status":"computed"`, `"of_bytes":38462406656`, `"pg_source":"none"`} {
		if !strings.Contains(string(body), want) {
			t.Errorf("payload missing %s; got %s", want, body)
		}
	}
}

// TestResidualDenominatorIsRootUsedNeverPercent is guard 4, and it is a test
// about a number that must NOT appear.
//
// `df`'s capacity column is ceil(used/(used+avail)) and excludes root-reserved
// blocks, so it is a share of a DIFFERENT WHOLE — not the same quantity in
// different units. On this box the two disagree by 1.7 points, and a residual
// built from the percent would invent bytes that do not exist.
func TestResidualDenominatorIsRootUsedNeverPercent(t *testing.T) {
	// The real df line from the box: 78408684 total, 37560944 used, 37602472
	// available, capacity 50%.
	const dfCapacityPercent = 50.0
	usedOfTotal := float64(jarlRootUsedBytes) / float64(jarlRootTotalBytes) * 100
	if math.Abs(usedOfTotal-dfCapacityPercent) < 0.5 {
		t.Fatalf("this test is vacuous: used-of-total (%.2f%%) and df capacity (%.0f%%) agree, so "+
			"nothing here can tell a residual built from one apart from the other", usedOfTotal, dfCapacityPercent)
	}

	const measured = int64(10) << 30
	s := gatherSpace(SpaceConfig{
		RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
		ConsumerRoots:      []string{"/var/lib/containerd"},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
			return measured, []DirSize{{Name: "images", Bytes: measured}}, nil, nil
		},
		DeviceProbe: jarlDevices(nil),
	})

	if want := jarlRootUsedBytes - measured; s.Residual.Bytes != want {
		t.Fatalf("Residual.Bytes = %d, want %d", s.Residual.Bytes, want)
	}
	// What the percent-derived answer WOULD have been. It is off by 636 MB on a
	// box that is only half full; on the 96%-vs-91.09% box that motivated this
	// guard it invents 1.83 GiB.
	fromPercent := int64(dfCapacityPercent/100*float64(jarlRootTotalBytes)) - measured
	if s.Residual.Bytes == fromPercent {
		t.Errorf("the residual equals the percent-derived figure (%d) — the denominator must be "+
			"RootUsedBytes, and df capacity is a share of a different whole", fromPercent)
	}
}

// TestResidualExcludesAndNamesACrossMountRoot is criterion 2's mount half, on
// the real overlay that makes it necessary.
//
// The overlay reads 1.44 GiB when du is rooted at it and 8 KiB from
// /var/lib/docker's side, because `du -x` will not cross INTO a mount. Both
// readings are correct; only one of them is bytes on the root filesystem.
// Summing the 1.44 GiB against a root-filesystem denominator subtracts bytes
// that are not in it — and that is the arithmetic that produced -1.29 GiB of
// phantom on this box when the fifth root was added.
func TestResidualExcludesAndNamesACrossMountRoot(t *testing.T) {
	const overlay = "/var/lib/docker/rootfs/overlayfs/63036f651e8bc20ff9c2d962d24dc1b881d503e793115c7bac15105bab6118d0"
	bytesFor := map[string]int64{
		"/var/lib/containerd": buildPlaneContainerdBytes,
		overlay:               jarlOverlayBytes,
	}
	s := gatherSpace(SpaceConfig{
		RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
		ConsumerRoots:      []string{"/var/lib/containerd", overlay},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe: func(p string) (int64, []DirSize, []string, error) {
			return bytesFor[p], []DirSize{{Name: "x", Bytes: bytesFor[p]}}, nil, nil
		},
		DeviceProbe: jarlDevices(map[string]uint64{overlay: jarlOverlayDev}),
	})

	// The root is still MEASURED — the reading is correct and stays on the wire.
	// What it is not is subtractable.
	var row *ConsumerRoot
	for i := range s.ConsumerRoots {
		if s.ConsumerRoots[i].Path == overlay {
			row = &s.ConsumerRoots[i]
		}
	}
	if row == nil {
		t.Fatal("no row for the overlay root — an excluded root must stay in the payload; " +
			"a row that vanishes is indistinguishable from a root nobody configured")
	}
	if row.Status != ConsumerRootRead || row.Bytes != jarlOverlayBytes {
		t.Errorf("overlay row = %+v, want a completed read of %d — exclusion is about the "+
			"SUBTRACTION, not about the measurement", row, jarlOverlayBytes)
	}
	if row.ExcludedReason != excludedCrossMount {
		t.Fatalf("overlay ExcludedReason = %q, want %q — a root held out of the sum must say so, "+
			"BY NAME, or the residual is a number with a silent asterisk", row.ExcludedReason, excludedCrossMount)
	}

	r := s.Residual
	if r.Status != ResidualComputed {
		t.Fatalf("Status = %q reason %q, want computed — excluding the overlay is what MAKES it computable", r.Status, r.Reason)
	}
	if r.MeasuredBytes != buildPlaneContainerdBytes {
		t.Errorf("MeasuredBytes = %d, want %d — only the same-device root", r.MeasuredBytes, buildPlaneContainerdBytes)
	}
	if r.CountedRoots != 1 || r.ExcludedRoots != 1 {
		t.Errorf("counted/excluded = %d/%d, want 1/1", r.CountedRoots, r.ExcludedRoots)
	}

	// The exclusion is not cosmetic: including it changes the answer by the
	// overlay's whole size, which is what this guard is worth.
	if got, without := r.Bytes, jarlRootUsedBytes-buildPlaneContainerdBytes-jarlOverlayBytes; got == without {
		t.Errorf("the residual (%d) equals the figure that INCLUDES the overlay — the guard did nothing", got)
	}
}

// TestResidualExcludesAndNamesAnOverlappingRoot is criterion 2's disjointness
// half. /var/lib's du total already contains /var/lib/containerd, so adding
// both subtracts containerd twice.
func TestResidualExcludesAndNamesAnOverlappingRoot(t *testing.T) {
	const parent, child = "/var/lib", "/var/lib/containerd"
	// A realistic pair: /var/lib as measured on this box contains containerd.
	bytesFor := map[string]int64{parent: int64(27) << 30, child: buildPlaneContainerdBytes}
	s := gatherSpace(SpaceConfig{
		RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
		ConsumerRoots:      []string{parent, child},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe: func(p string) (int64, []DirSize, []string, error) {
			return bytesFor[p], []DirSize{{Name: "x", Bytes: bytesFor[p]}}, nil, nil
		},
		DeviceProbe: jarlDevices(nil),
	})

	byPath := map[string]ConsumerRoot{}
	for _, r := range s.ConsumerRoots {
		byPath[r.Path] = r
	}
	if got := byPath[parent].ExcludedReason; got != "" {
		t.Errorf("%s ExcludedReason = %q, want empty — the CONTAINING root is the one that keeps "+
			"its bytes; excluding the parent would drop everything under it that has no root of its own", parent, got)
	}
	if want := excludedUnderPrefix + parent; byPath[child].ExcludedReason != want {
		t.Fatalf("%s ExcludedReason = %q, want %q — an exclusion must name WHAT covered it, or the "+
			"operator has to work out which pair collided", child, byPath[child].ExcludedReason, want)
	}
	if s.Residual.MeasuredBytes != bytesFor[parent] {
		t.Errorf("MeasuredBytes = %d, want %d — the child's bytes are already inside the parent's du total",
			s.Residual.MeasuredBytes, bytesFor[parent])
	}

	// A prefix match on strings alone is the bug this guard must not have:
	// /var/lib must not swallow /var/libvirt.
	t.Run("a shared prefix is not containment", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
			ConsumerRoots:      []string{"/var/lib", "/var/libvirt"},
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
				return int64(1) << 30, []DirSize{{Name: "x", Bytes: 1 << 30}}, nil, nil
			},
			DeviceProbe: jarlDevices(nil),
		})
		if s.Residual.ExcludedRoots != 0 || s.Residual.CountedRoots != 2 {
			t.Errorf("counted/excluded = %d/%d, want 2/0 — /var/libvirt is not under /var/lib, and a "+
				"bare strings.HasPrefix says it is", s.Residual.CountedRoots, s.Residual.ExcludedRoots)
		}
	})
}

// TestResidualCountsPostgresOnce is criterion 3. Postgres is the one consumer
// this payload can measure twice: `du -x -k -s /var/lib/postgresql` read
// 3,615,160 KiB on one box against sum(pg_database_size) 3,528,933 KiB — 97.6%
// the SAME bytes, 3.37 GiB and 12.5% of that box's used total. Adding both
// subtracts it twice, and the payload must say which one it used.
func TestResidualCountsPostgresOnce(t *testing.T) {
	const pgSize = int64(3528933) * 1024

	base := func(roots []string) SpaceConfig {
		return SpaceConfig{
			RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
			PGSizeProbe:        func() (int64, error) { return pgSize, nil },
			ConsumerRoots:      roots,
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe: func(p string) (int64, []DirSize, []string, error) {
				if p == DefaultPGDataDir {
					return jarlPostgresBytes, []DirSize{{Name: "14", Bytes: jarlPostgresBytes}}, nil, nil
				}
				return buildPlaneContainerdBytes, []DirSize{{Name: "x", Bytes: buildPlaneContainerdBytes}}, nil, nil
			},
			DeviceProbe: jarlDevices(nil),
			PGDataDir:   DefaultPGDataDir,
		}
	}

	t.Run("a du root over PGDATA wins, and pg_size_bytes is NOT added", func(t *testing.T) {
		s := gatherSpace(base([]string{"/var/lib/containerd", DefaultPGDataDir}))
		if s.Residual.PGSource != PGSourceDURoot {
			t.Fatalf("PGSource = %q, want %q — the payload must STATE which of the two "+
				"measurements it used", s.Residual.PGSource, PGSourceDURoot)
		}
		want := buildPlaneContainerdBytes + jarlPostgresBytes
		if s.Residual.MeasuredBytes != want {
			t.Errorf("MeasuredBytes = %d, want %d — pg counted ONCE, via the du root. %d would be "+
				"both", s.Residual.MeasuredBytes, want, want+pgSize)
		}
	})

	t.Run("no du root over PGDATA, so pg_size_bytes IS added", func(t *testing.T) {
		s := gatherSpace(base([]string{"/var/lib/containerd"}))
		if s.Residual.PGSource != PGSourceSizeBytes {
			t.Fatalf("PGSource = %q, want %q", s.Residual.PGSource, PGSourceSizeBytes)
		}
		if want := buildPlaneContainerdBytes + pgSize; s.Residual.MeasuredBytes != want {
			t.Errorf("MeasuredBytes = %d, want %d — with nothing walking PGDATA, the database's own "+
				"size is the only measurement of those bytes and dropping it hides them in the residual",
				s.Residual.MeasuredBytes, want)
		}
	})

	t.Run("a PARENT of PGDATA also covers it", func(t *testing.T) {
		s := gatherSpace(base([]string{"/var/lib"}))
		if s.Residual.PGSource != PGSourceDURoot {
			t.Errorf("PGSource = %q, want %q — /var/lib's walk already counted /var/lib/postgresql; "+
				"containment, not equality, is the test", s.Residual.PGSource, PGSourceDURoot)
		}
	})

	t.Run("no postgres on this box at all", func(t *testing.T) {
		cfg := base([]string{"/var/lib/containerd"})
		cfg.PGSizeProbe = nil
		s := gatherSpace(cfg)
		if s.Residual.PGSource != PGSourceNone {
			t.Errorf("PGSource = %q, want %q", s.Residual.PGSource, PGSourceNone)
		}
	})
}

// TestResidualNegativeIsRefusedNeverPrinted is criterion 4, and it is the guard
// that keeps this whole field from becoming a new dishonest number inside the
// fix for dishonest numbers.
//
// Disjoint trees on one device cannot sum past that device's used total, so a
// negative result is PROOF the root set is not what it claims. The honest
// output is a refusal that names the reason — never a negative gigabyte, and
// never a clamp to zero, because "0 B unaccounted" is the strongest claim this
// axis can make and reaching it by clamping would render the worst-measured box
// as the best-measured one.
func TestResidualNegativeIsRefusedNeverPrinted(t *testing.T) {
	// Two roots that each claim most of the disk. Whatever produced this — an
	// overlap the device check could not see, a du that followed a bind mount —
	// the arithmetic is impossible and the payload must say so.
	s := gatherSpace(SpaceConfig{
		RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
		ConsumerRoots:      []string{"/var", "/usr"},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
			return jarlRootUsedBytes - 1, []DirSize{{Name: "x", Bytes: 1}}, nil, nil
		},
		DeviceProbe: jarlDevices(nil),
	})

	r := s.Residual
	if r.Status != ResidualUndefined {
		t.Fatalf("Status = %q, want %q — a sum that exceeds its denominator is proof the root set "+
			"is wrong, and the only honest output is a refusal", r.Status, ResidualUndefined)
	}
	if r.Bytes >= 0 {
		t.Errorf("Bytes = %d, want the -1 sentinel. A NEGATIVE figure here is the phantom gigabyte "+
			"this guard exists to refuse, and a CLAMP to 0 is worse: it renders the least-measured "+
			"box as a box where everything was accounted for", r.Bytes)
	}
	if r.Reason != residualReasonOverlap {
		t.Errorf("Reason = %q, want %q — machine-readable, so a surface branches on it rather than "+
			"parsing prose", r.Reason, residualReasonOverlap)
	}
	// The evidence for the refusal travels with it: an operator who can see the
	// sum AND the denominator finds the overlapping root in one step.
	if r.MeasuredBytes <= r.OfBytes {
		t.Errorf("MeasuredBytes %d must exceed OfBytes %d and both must travel — a refusal without "+
			"its arithmetic is a shrug", r.MeasuredBytes, r.OfBytes)
	}

	// And nothing on the wire carries a minus sign in front of a byte count.
	body, err := json.Marshal(s.Residual)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(body), `"status":"undefined"`) || !strings.Contains(string(body), `"bytes":-1`) {
		t.Errorf("payload = %s, want an undefined status with the -1 sentinel", body)
	}
}

// TestResidualRefusesRatherThanGuessWhenItCannotVerify pins the two arms where
// the subtraction is not attempted at all. Both are refusals with a named
// reason, because "we could not check" is not "it checks out".
func TestResidualRefusesRatherThanGuessWhenItCannotVerify(t *testing.T) {
	measured := func() (int64, []DirSize, []string, error) {
		return buildPlaneContainerdBytes, []DirSize{{Name: "x", Bytes: 1}}, nil, nil
	}

	t.Run("no root-filesystem denominator", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			ConsumerRoots:      []string{"/var/lib/containerd"},
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe:  func(string) (int64, []DirSize, []string, error) { return measured() },
			DeviceProbe:        jarlDevices(nil),
		})
		if s.Residual.Status != ResidualUnmeasured || s.Residual.Reason != residualReasonRootUnmeasured {
			t.Errorf("residual = %+v, want unmeasured/%s — with no RootUsedBytes there is no whole to "+
				"subtract from, and disk_used_percent is NOT a substitute for it",
				s.Residual, residualReasonRootUnmeasured)
		}
		if s.Residual.Bytes != -1 {
			t.Errorf("Bytes = %d, want -1", s.Residual.Bytes)
		}
	})

	t.Run("no way to verify the roots' device", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
			ConsumerRoots:      []string{"/var/lib/containerd"},
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe:  func(string) (int64, []DirSize, []string, error) { return measured() },
			// DeviceProbe unwired.
		})
		if s.Residual.Status != ResidualUnmeasured || s.Residual.Reason != residualReasonDeviceUnverified {
			t.Errorf("residual = %+v, want unmeasured/%s — roots that cannot be placed on a device "+
				"cannot be subtracted from that device's total", s.Residual, residualReasonDeviceUnverified)
		}
	})

	t.Run("one root's device is unreadable — that root only", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			RootProbe:          func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
			ConsumerRoots:      []string{"/var/lib/containerd", "/var/lib/barkpark-builder"},
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe:  func(string) (int64, []DirSize, []string, error) { return measured() },
			DeviceProbe: func(p string) (uint64, bool) {
				if p == "/var/lib/barkpark-builder" {
					return 0, false
				}
				return jarlRootDev, true
			},
		})
		if s.Residual.Status != ResidualComputed || s.Residual.CountedRoots != 1 || s.Residual.ExcludedRoots != 1 {
			t.Errorf("residual = %+v, want computed with 1 counted and 1 excluded — one unreadable "+
				"root must not erase the one that WAS placed", s.Residual)
		}
		for _, r := range s.ConsumerRoots {
			if r.Path == "/var/lib/barkpark-builder" && r.ExcludedReason != excludedDeviceUnverified {
				t.Errorf("ExcludedReason = %q, want %q — unknown is not the same as same-device",
					r.ExcludedReason, excludedDeviceUnverified)
			}
		}
	})
}

// TestResidualCountsTheSitesTreeToo: the sites axis is a measured root like any
// other, and leaving it out of the sum would over-report the residual by the
// whole sites tree on every content box.
func TestResidualCountsTheSitesTreeToo(t *testing.T) {
	const sitesBytes = int64(4194304) * 1024
	s := gatherSpace(SpaceConfig{
		RootProbe: func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
		SitesDir:  "/opt/barkpark/sites",
		SitesProbe: func() (int64, []SiteSize, error) {
			return sitesBytes, []SiteSize{{Slug: "search-ember", Bytes: 643072 * 1024}}, nil
		},
		ConsumerRoots:      []string{"/var/lib/containerd"},
		ConsumerRootExists: func(string) bool { return true },
		ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
			return buildPlaneContainerdBytes, []DirSize{{Name: "x", Bytes: 1}}, nil, nil
		},
		DeviceProbe: jarlDevices(nil),
	})
	if want := buildPlaneContainerdBytes + sitesBytes; s.Residual.MeasuredBytes != want {
		t.Errorf("MeasuredBytes = %d, want %d — the sites tree is a measured root and must be "+
			"subtracted like one", s.Residual.MeasuredBytes, want)
	}
	if s.Residual.CountedRoots != 2 {
		t.Errorf("CountedRoots = %d, want 2 (the consumer root and the sites tree)", s.Residual.CountedRoots)
	}

	t.Run("a consumer root covering the sites dir counts it once", func(t *testing.T) {
		s := gatherSpace(SpaceConfig{
			RootProbe:  func() (int64, int64, error) { return jarlRootUsedBytes, jarlRootTotalBytes, nil },
			SitesDir:   "/opt/barkpark/sites",
			SitesProbe: func() (int64, []SiteSize, error) { return sitesBytes, nil, nil },
			ConsumerRoots:      []string{"/opt/barkpark"},
			ConsumerRootExists: func(string) bool { return true },
			ConsumerRootProbe: func(string) (int64, []DirSize, []string, error) {
				return sitesBytes + (1 << 20), []DirSize{{Name: "sites", Bytes: sitesBytes}}, nil, nil
			},
			DeviceProbe: jarlDevices(nil),
		})
		if s.Residual.CountedRoots != 1 || s.Residual.ExcludedRoots != 1 {
			t.Errorf("counted/excluded = %d/%d, want 1/1 — /opt/barkpark's walk already contains the "+
				"sites tree", s.Residual.CountedRoots, s.Residual.ExcludedRoots)
		}
	})
}

// TestResidualIsAbsentNotZeroWhenNothingIsWired: an agent with no space probes
// at all must not report "0 B unaccounted", which is the strongest possible
// claim on this axis.
func TestResidualIsAbsentNotZeroWhenNothingIsWired(t *testing.T) {
	s := gatherSpace(SpaceConfig{})
	if s.Residual == nil {
		t.Fatal("Residual = nil, want a stated refusal — nil is for an agent that computes no residual at all")
	}
	if s.Residual.Status != ResidualUnmeasured || s.Residual.Bytes != -1 || s.Residual.OfBytes != -1 {
		t.Errorf("residual = %+v, want unmeasured with both sentinels — 0 unaccounted is the claim "+
			"\"we saw everything\", made by an agent that measured nothing", s.Residual)
	}
}
