package agent

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// fakeControlPlane is an httptest-backed stand-in for the cloud-9 control plane.
// It records the report it received, serves a queued command list, and records
// the results — all without a live Phoenix server or real agent-token DB.
type fakeControlPlane struct {
	mu sync.Mutex

	wantToken string
	queue     []Command

	gotReport     *Report
	gotReportAuth string
	gotResults    []CommandResult
	reportCount   int
}

func (f *fakeControlPlane) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/agent/report", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.reportCount++
		f.gotReportAuth = r.Header.Get("Authorization")
		var rep Report
		if err := json.NewDecoder(r.Body).Decode(&rep); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		f.gotReport = &rep
		w.WriteHeader(http.StatusOK)
	})

	mux.HandleFunc("/v1/agent/commands", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		_ = json.NewEncoder(w).Encode(f.queue)
	})

	mux.HandleFunc("/v1/agent/results", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &f.gotResults)
		w.WriteHeader(http.StatusOK)
	})

	return mux
}

// TestRunOnceFullCycle is the end-to-end test: against an httptest control plane,
// RunOnce posts a report (with the expected fields + Bearer token), fetches the
// command queue, runs the allowlisted ones via a fake runner, and posts results.
// No live control plane; the fake runner never shells out.
func TestRunOnceFullCycle(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: "agent-secret-token",
		queue: []Command{
			{ID: "cmd-1", Name: "restart"},
			{ID: "cmd-2", Name: "logs"},
			{ID: "cmd-3", Name: "rm -rf"}, // must be rejected, not run
		},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	runner := &fakeRunner{output: "done"}
	git := &gitFakeRunner{head: "deadbeef", status: ""}

	a := &Agent{
		ControlURL: srv.URL,
		Token:      "agent-secret-token",
		HTTPClient: srv.Client(),
		Runner:     runner,
		ReportProbes: ReportConfig{
			Runner:    git,
			DiskProbe: func() (int, error) { return 17, nil },
		},
	}

	if err := a.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// --- report assertions ---
	if cp.gotReport == nil {
		t.Fatal("control plane received no report")
	}
	if cp.gotReportAuth != "Bearer agent-secret-token" {
		t.Errorf("report Authorization = %q, want Bearer agent-secret-token", cp.gotReportAuth)
	}
	if cp.gotReport.AgentStatus != "online" {
		t.Errorf("report AgentStatus = %q, want online", cp.gotReport.AgentStatus)
	}
	if cp.gotReport.Version != Version {
		t.Errorf("report Version = %q, want %q", cp.gotReport.Version, Version)
	}
	if cp.gotReport.GitCommit != "deadbeef" {
		t.Errorf("report GitCommit = %q, want deadbeef", cp.gotReport.GitCommit)
	}
	if cp.gotReport.DirtyTree {
		t.Error("report DirtyTree = true, want false (clean porcelain)")
	}
	if cp.gotReport.DiskUsedPercent != 17 {
		t.Errorf("report DiskUsedPercent = %d, want 17", cp.gotReport.DiskUsedPercent)
	}

	// --- command execution assertions ---
	// Only the two allowlisted commands ran; "rm -rf" was rejected.
	if len(runner.calls) != 2 {
		t.Fatalf("runner ran %d commands, want 2 (restart, logs); calls=%v", len(runner.calls), runner.calls)
	}
	if got := runner.calls[0]; got[0] != "systemctl" || got[1] != "restart" {
		t.Errorf("first command argv = %v, want systemctl restart …", got)
	}
	if got := runner.calls[1]; got[0] != "journalctl" {
		t.Errorf("second command argv = %v, want journalctl …", got)
	}

	// --- results assertions ---
	if len(cp.gotResults) != 3 {
		t.Fatalf("control plane got %d results, want 3 (incl. the rejection)", len(cp.gotResults))
	}
	byID := map[string]CommandResult{}
	for _, res := range cp.gotResults {
		byID[res.ID] = res
	}
	if !byID["cmd-1"].Approved || byID["cmd-1"].Output != "done" {
		t.Errorf("cmd-1 (restart) result = %+v, want approved+ran", byID["cmd-1"])
	}
	if !byID["cmd-2"].Approved {
		t.Errorf("cmd-2 (logs) result = %+v, want approved", byID["cmd-2"])
	}
	if byID["cmd-3"].Approved {
		t.Errorf("cmd-3 (rm -rf) approved = true, want REJECTED")
	}
	if byID["cmd-3"].Err == "" {
		t.Error("cmd-3 (rm -rf) Err empty, want a rejection message")
	}
}

// TestRunOnceNoCommands proves an empty queue is a clean no-op: report posts,
// no command runs, and (since there are no results) the cycle still succeeds.
func TestRunOnceNoCommands(t *testing.T) {
	cp := &fakeControlPlane{queue: nil}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	runner := &fakeRunner{}
	a := &Agent{
		ControlURL: srv.URL,
		Token:      "tok",
		HTTPClient: srv.Client(),
		Runner:     runner,
		// Separate runner for the report's git probe so the command runner's
		// call count isolates command EXECUTION (none expected here).
		ReportProbes: ReportConfig{Runner: &gitFakeRunner{head: "x"}},
	}

	if err := a.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if cp.gotReport == nil {
		t.Fatal("no report posted")
	}
	if len(runner.calls) != 0 {
		t.Errorf("runner ran %d commands on empty queue, want 0", len(runner.calls))
	}
	if cp.gotResults != nil {
		t.Errorf("results posted on empty queue: %v", cp.gotResults)
	}
}

// TestRunOnceReportErrorAborts proves a non-2xx on /report aborts the cycle
// before any command runs — the agent does not blindly drain the queue when the
// control plane rejected its report.
func TestRunOnceReportErrorAborts(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/agent/report", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	})
	commandsHit := false
	mux.HandleFunc("/v1/agent/commands", func(w http.ResponseWriter, r *http.Request) {
		commandsHit = true
		_ = json.NewEncoder(w).Encode([]Command{})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	a := &Agent{ControlURL: srv.URL, Token: "bad", HTTPClient: srv.Client()}
	if err := a.RunOnce(context.Background()); err == nil {
		t.Fatal("RunOnce returned nil, want error on 401 report")
	}
	if commandsHit {
		t.Error("commands endpoint was polled after report failed; want abort")
	}
}

// TestRunLoopsUntilContextDone proves Run fires immediately and keeps cycling on
// the interval until ctx is cancelled, returning ctx.Err().
func TestRunLoopsUntilContextDone(t *testing.T) {
	cp := &fakeControlPlane{}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	a := &Agent{
		ControlURL: srv.URL,
		Token:      "tok",
		Interval:   5 * time.Millisecond,
		HTTPClient: srv.Client(),
		Runner:     &fakeRunner{},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()

	var cycles int
	err := a.RunWith(ctx, func(error) { cycles++ })
	if err == nil {
		t.Fatal("Run returned nil, want ctx error")
	}
	// Immediate fire + several ticks inside 60ms at a 5ms interval.
	if cycles < 2 {
		t.Errorf("cycles = %d, want >= 2 (immediate + ticks)", cycles)
	}
	cp.mu.Lock()
	rc := cp.reportCount
	cp.mu.Unlock()
	if rc < 2 {
		t.Errorf("reportCount = %d, want >= 2", rc)
	}
}
