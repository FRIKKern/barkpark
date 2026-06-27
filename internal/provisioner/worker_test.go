package provisioner

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

// fakeControlPlane is an httptest-backed stand-in for the Elixir control plane's
// internal provision-jobs endpoints. It serves one queued job on claim (then 204
// once drained), and records the succeed/fail report — all without a live
// Phoenix server. It mirrors the FIXED CONTRACT exactly so the worker test
// double-checks the wire shape the Elixir side must match.
type fakeControlPlane struct {
	mu sync.Mutex

	wantToken string
	job       *JobSpec // served on the next claim; nil → 204

	claimAuth   string
	claimCount  int
	succeededID string
	succeededIP string
	succeedAuth string
	failedID    string
	failedError string
	failAuth    string
}

func (f *fakeControlPlane) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/internal/provision-jobs/claim", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.claimCount++
		f.claimAuth = r.Header.Get("Authorization")
		if f.job == nil {
			w.WriteHeader(http.StatusNoContent) // 204 — nothing pending
			return
		}
		// 200 {job_id, name, slug, region, server_type}
		_ = json.NewEncoder(w).Encode(f.job)
		f.job = nil // serve it once; subsequent claims are 204
	})

	// /v1/internal/provision-jobs/:id/succeed and /fail — net/http's mux can't
	// pattern-match the :id segment on go1.21-style routes generically, so route
	// on the trailing verb.
	mux.HandleFunc("/v1/internal/provision-jobs/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		id, verb := parseJobPath(r.URL.Path)
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		_ = json.Unmarshal(body, &payload)

		switch verb {
		case "succeed":
			f.succeededID = id
			f.succeededIP = payload["ip"]
			f.succeedAuth = r.Header.Get("Authorization")
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "fail":
			f.failedID = id
			f.failedError = payload["error"]
			f.failAuth = r.Header.Get("Authorization")
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	})

	return mux
}

// parseJobPath splits /v1/internal/provision-jobs/<id>/<verb> into (id, verb).
func parseJobPath(p string) (id, verb string) {
	const prefix = "/v1/internal/provision-jobs/"
	rest := p[len(prefix):]
	for i := 0; i < len(rest); i++ {
		if rest[i] == '/' {
			return rest[:i], rest[i+1:]
		}
	}
	return rest, ""
}

const testToken = "worker-shared-secret"

// TestRunOnceClaimsProvisionsAndSucceeds is the happy path: the control plane
// hands back a job → the worker provisions via a FAKE provision → POSTs succeed
// with the right ip + Bearer WORKER_TOKEN. Asserts body AND auth on every hop.
func TestRunOnceClaimsProvisionsAndSucceeds(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-1", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var gotSpec JobSpec
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(_ context.Context, spec JobSpec) (string, error) {
			gotSpec = spec
			return "203.0.113.7", nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if !claimed {
		t.Fatal("RunOnce claimed=false, want true (a job was queued)")
	}

	// ── the job reached Provision intact ──
	if gotSpec.JobID != "job-1" || gotSpec.Name != "acme" || gotSpec.Slug != "acme" ||
		gotSpec.Region != "nbg1" || gotSpec.ServerType != "cax11" {
		t.Errorf("Provision got %+v, want the queued job", gotSpec)
	}

	// ── claim carried the Bearer WORKER_TOKEN ──
	if cp.claimAuth != "Bearer "+testToken {
		t.Errorf("claim Authorization = %q, want Bearer %s", cp.claimAuth, testToken)
	}

	// ── succeed reported the right ip + auth; fail was NOT called ──
	if cp.succeededID != "job-1" {
		t.Errorf("succeed job id = %q, want job-1", cp.succeededID)
	}
	if cp.succeededIP != "203.0.113.7" {
		t.Errorf("succeed ip = %q, want 203.0.113.7", cp.succeededIP)
	}
	if cp.succeedAuth != "Bearer "+testToken {
		t.Errorf("succeed Authorization = %q, want Bearer %s", cp.succeedAuth, testToken)
	}
	if cp.failedID != "" {
		t.Errorf("fail was called (id=%q) on the happy path, want none", cp.failedID)
	}
}

// TestRunOnceEmptyQueueNoProvision proves a 204 claim is a clean no-op: no
// provision runs, no succeed/fail is posted, claimed=false, no error.
func TestRunOnceEmptyQueueNoProvision(t *testing.T) {
	cp := &fakeControlPlane{wantToken: testToken, job: nil} // 204 on claim
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	provisionCalls := 0
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(context.Context, JobSpec) (string, error) {
			provisionCalls++
			return "", nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if claimed {
		t.Error("RunOnce claimed=true on a 204, want false")
	}
	if provisionCalls != 0 {
		t.Errorf("Provision ran %d times on an empty queue, want 0", provisionCalls)
	}
	if cp.succeededID != "" || cp.failedID != "" {
		t.Errorf("a report was posted on an empty queue: succeed=%q fail=%q", cp.succeededID, cp.failedID)
	}
}

// TestRunOnceProvisionErrorReportsFail proves a provision FAILURE is reported to
// /fail with the error message (not /succeed), the cycle still counts as a
// handled claim, and RunOnce does NOT return that as an error (the job was
// handled; it stays provisioning for retry).
func TestRunOnceProvisionErrorReportsFail(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-2", Name: "boom", Slug: "boom", Region: "nbg1", ServerType: "cax11"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(context.Context, JobSpec) (string, error) {
			return "", errBoom
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce returned an error for a provision failure, want nil (failure is reported, not propagated): %v", err)
	}
	if !claimed {
		t.Error("RunOnce claimed=false, want true (a job was drained even though it failed)")
	}

	if cp.failedID != "job-2" {
		t.Errorf("fail job id = %q, want job-2", cp.failedID)
	}
	if cp.failedError != errBoom.Error() {
		t.Errorf("fail error = %q, want %q", cp.failedError, errBoom.Error())
	}
	if cp.failAuth != "Bearer "+testToken {
		t.Errorf("fail Authorization = %q, want Bearer %s", cp.failAuth, testToken)
	}
	if cp.succeededID != "" {
		t.Errorf("succeed was called (id=%q) on a provision failure, want none", cp.succeededID)
	}
}

// TestRunOnceNilProvisionErrors proves a misconfigured worker (no Provision)
// fails fast rather than silently no-op'ing.
func TestRunOnceNilProvisionErrors(t *testing.T) {
	w := &Worker{ControlURL: "http://unused", Token: testToken}
	if _, err := w.RunOnce(context.Background()); err == nil {
		t.Fatal("RunOnce with nil Provision returned nil, want a config error")
	}
}

// TestRunOnceClaimNon2xxErrors proves a non-2xx, non-204 claim is a transport
// error (the worker doesn't blindly proceed).
func TestRunOnceClaimNon2xxErrors(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/internal/provision-jobs/claim", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	provisionCalls := 0
	w := &Worker{
		ControlURL: srv.URL,
		Token:      "bad",
		HTTPClient: srv.Client(),
		Provision: func(context.Context, JobSpec) (string, error) {
			provisionCalls++
			return "", nil
		},
	}
	if _, err := w.RunOnce(context.Background()); err == nil {
		t.Fatal("RunOnce returned nil on a 401 claim, want an error")
	}
	if provisionCalls != 0 {
		t.Errorf("Provision ran after a failed claim (%d times), want 0", provisionCalls)
	}
}

// TestRunLoopsUntilContextDone proves Run drains queued jobs then idles on the
// interval, looping until ctx is cancelled and returning ctx.Err().
func TestRunLoopsUntilContextDone(t *testing.T) {
	cp := &fakeControlPlane{wantToken: testToken} // 204 every claim (empty queue)
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		Interval:   5 * time.Millisecond,
		HTTPClient: srv.Client(),
		Provision:  func(context.Context, JobSpec) (string, error) { return "", nil },
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()

	var cycles int
	err := w.RunWith(ctx, func(bool, error) { cycles++ })
	if err == nil {
		t.Fatal("Run returned nil, want ctx error")
	}
	if cycles < 2 {
		t.Errorf("cycles = %d, want >= 2 (immediate + ticks)", cycles)
	}
	cp.mu.Lock()
	cc := cp.claimCount
	cp.mu.Unlock()
	if cc < 2 {
		t.Errorf("claimCount = %d, want >= 2", cc)
	}
}

// TestRunOnceProvisionTimeoutReleasesJob proves the per-job timeout: a Provision
// that blocks until its ctx is cancelled is bounded by ProvisionTimeout — RunOnce
// returns (does NOT hang), the job is reported to /fail (released for retry), and
// the cycle still counts as a handled claim.
func TestRunOnceProvisionTimeoutReleasesJob(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-slow", Name: "slow", Slug: "slow", Region: "nbg1", ServerType: "cax11"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	provStarted := make(chan struct{})
	w := &Worker{
		ControlURL:       srv.URL,
		Token:            testToken,
		HTTPClient:       srv.Client(),
		ProvisionTimeout: 20 * time.Millisecond, // short deadline for the test
		Provision: func(ctx context.Context, _ JobSpec) (string, error) {
			close(provStarted)
			<-ctx.Done() // block until the per-job timeout cancels us
			return "", ctx.Err()
		},
	}

	done := make(chan error, 1)
	go func() {
		_, err := w.RunOnce(context.Background())
		done <- err
	}()

	<-provStarted
	select {
	case err := <-done:
		// RunOnce must NOT hang and must NOT return the provision error (it is
		// reported to /fail, not propagated).
		if err != nil {
			t.Fatalf("RunOnce returned an error for a timed-out provision, want nil (reported to /fail): %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("RunOnce did not return after the provision timeout fired — the worker hung")
	}

	if cp.failedID != "job-slow" {
		t.Errorf("timed-out job not released via /fail: failedID=%q, want job-slow", cp.failedID)
	}
	if cp.succeededID != "" {
		t.Errorf("succeed was called on a timed-out provision, want none (id=%q)", cp.succeededID)
	}
}

// errBoom is the deterministic provision failure the fail-path test asserts on.
var errBoom = errString("provision blew up: warm pool empty")

type errString string

func (e errString) Error() string { return string(e) }
