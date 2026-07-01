package provisioner

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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

	// failSucceed / failFail make the matching report endpoint answer a non-2xx —
	// a control-plane response the worker classifies (5xx transient → retry, 4xx
	// terminal → stop). When the status field is 0 the legacy default of 500 is
	// used. Used by the succeed/fail money-edge tests.
	failSucceed bool
	failFail    bool

	// succeedStatus overrides the status the succeed endpoint returns when
	// failSucceed is set (0 → 500). Lets a test drive a 4xx (409, terminal) vs a
	// 5xx (500/503, transient) without new handler branches.
	succeedStatus int

	// succeedFailFirstN makes the succeed endpoint answer a transient 503 for the
	// first N calls, then a normal 200 — the "deploy restart lands mid-report, then
	// the CP comes back" pattern. Independent of failSucceed.
	succeedFailFirstN int

	claimAuth           string
	claimCount          int
	succeededID         string
	succeededIP         string
	succeededAdminToken string
	succeededRawBody    []byte // the full succeed JSON — bootstrap tests decode the nested payload
	succeedAuth         string
	succeedCalls        int
	failedID            string
	failedError         string
	failAuth            string
	failCalls           int
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
		// A struct decode, NOT map[string]string: the succeed body may carry a
		// NESTED `bootstrap` object (dwb-4), which a map[string]string unmarshal
		// would reject wholesale, silently blanking ip/admin_token.
		var payload struct {
			IP         string `json:"ip"`
			AdminToken string `json:"admin_token"`
			Error      string `json:"error"`
		}
		_ = json.Unmarshal(body, &payload)

		switch verb {
		case "succeed":
			f.succeedCalls++
			f.succeededID = id
			f.succeededIP = payload.IP
			f.succeededAdminToken = payload.AdminToken
			f.succeededRawBody = body
			f.succeedAuth = r.Header.Get("Authorization")
			// Transient pattern: the first N calls 503 (deploy restart), then 200.
			if f.succeedCalls <= f.succeedFailFirstN {
				http.Error(w, "service unavailable (restarting)", http.StatusServiceUnavailable)
				return
			}
			if f.failSucceed {
				status := f.succeedStatus
				if status == 0 {
					status = http.StatusInternalServerError
				}
				http.Error(w, "boom", status)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "fail":
			f.failCalls++
			f.failedID = id
			f.failedError = payload.Error
			f.failAuth = r.Header.Get("Authorization")
			if f.failFail {
				http.Error(w, "boom", http.StatusInternalServerError)
				return
			}
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

const testToken = "worker-shared-test-fixture"

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
		Provision: func(_ context.Context, spec JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			gotSpec = spec
			return "203.0.113.7", "", nil, func(context.Context) error { return nil }, nil
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
	// instance-admin-token: this fake returned an empty token, so the succeed body
	// carries NO admin_token — the ip-only contract is unchanged.
	if cp.succeededAdminToken != "" {
		t.Errorf("succeed admin_token = %q, want empty (the fake reported no token)", cp.succeededAdminToken)
	}
	if cp.succeedAuth != "Bearer "+testToken {
		t.Errorf("succeed Authorization = %q, want Bearer %s", cp.succeedAuth, testToken)
	}
	if cp.failedID != "" {
		t.Errorf("fail was called (id=%q) on the happy path, want none", cp.failedID)
	}
}

// TestRunOnceForwardsAdminToken proves the instance-admin-token report path: when
// the provision chain surfaces a minted admin token, the worker forwards it in the
// succeed POST body as admin_token (alongside ip) so the control plane can store it
// encrypted for the owner. The token is the SECOND Provision return value.
func TestRunOnceForwardsAdminToken(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-tok", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	const minted = "bp_admin_secret-instance-bearer"
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "203.0.113.8", minted, nil, func(context.Context) error { return nil }, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if !claimed {
		t.Fatal("RunOnce claimed=false, want true")
	}
	if cp.succeededIP != "203.0.113.8" {
		t.Errorf("succeed ip = %q, want 203.0.113.8", cp.succeededIP)
	}
	if cp.succeededAdminToken != minted {
		t.Errorf("succeed admin_token = %q, want %q (the minted token must be forwarded)", cp.succeededAdminToken, minted)
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
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			provisionCalls++
			return "", "", nil, nil, nil
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
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "", "", nil, nil, errBoom
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
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			provisionCalls++
			return "", "", nil, nil, nil
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
		Provision:  func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) { return "", "", nil, nil, nil },
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
		Provision: func(ctx context.Context, _ JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			close(provStarted)
			<-ctx.Done() // block until the per-job timeout cancels us
			return "", "", nil, nil, ctx.Err()
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

// TestRunOnceSucceedReportPersistent5xxRetriesThenTearsDown is the FIX money edge,
// FLIPPED from the old behavior. Provision SUCCEEDS (a paid box is live) but every
// succeed-report 5xxs — a control plane that is DOWN (e.g. a deploy `systemctl
// restart` that never came back in the window). A 5xx is TRANSIENT, so the worker
// must RETRY (first attempt + reportRetries = 4 POSTs reach the server) before
// concluding the CP is unreachable; only THEN does it (a) tear the live box down
// (no box the control plane is blind to) and (b) NOT consume the job
// (claimed=false) so the reaper re-claims it once the CP is back. RunOnce returns
// an error so the outage is observable.
//
// Before the fix this test asserted teardown on the FIRST 5xx with NO retry — that
// locked in the bug where a deploy-window 502/503 tore down a healthy billed box.
func TestRunOnceSucceedReportPersistent5xxRetriesThenTearsDown(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken:   testToken,
		job:         &JobSpec{JobID: "job-orphan", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
		failSucceed: true, // every succeed POST 5xxs — the CP is down for the whole window
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var teardownCalls int
	w := &Worker{
		ControlURL:         srv.URL,
		Token:              testToken,
		HTTPClient:         srv.Client(),
		ReportRetryBackoff: time.Millisecond, // run the widened retry loop fast
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			// A live box came up; hand back the teardown the worker must invoke ONLY
			// after the retries are exhausted.
			return "203.0.113.9", "", nil, func(context.Context) error {
				teardownCalls++
				return nil
			}, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())

	// ── a 5xx is transient: the worker retried before giving up ──
	if cp.succeedCalls != reportRetries+1 {
		t.Errorf("succeed reached the server %d times, want %d (first attempt + %d retries) — a 5xx must be retried, not torn down on the first blip", cp.succeedCalls, reportRetries+1, reportRetries)
	}
	// ── only after retries are exhausted is the orphan box torn down ──
	if teardownCalls != 1 {
		t.Errorf("teardown called %d times, want exactly 1 (the orphan box must be deleted after retries fail)", teardownCalls)
	}
	// ── the job was NOT cleanly consumed — left for the reaper to retry ──
	if claimed {
		t.Error("RunOnce claimed=true after a persistent succeed-report failure, want false (the job must stay re-claimable)")
	}
	if err == nil {
		t.Error("RunOnce returned nil after a persistent succeed-report failure, want an error (the outage must be observable)")
	}
	// ── the worker did attempt the succeed report (it just never landed) ──
	if cp.succeededID != "job-orphan" {
		t.Errorf("succeed was not attempted (id=%q), want job-orphan", cp.succeededID)
	}
}

// TestRunOnceSucceedReportTransient5xxThenSucceeds is the deploy-window self-heal:
// the succeed POST 503s the first time (Caddy answering while barkpark.service
// restarts) and then 200s. A 5xx is transient, so the worker retries; the second
// attempt lands. The box must be KEPT (NO teardown) and the job cleanly consumed
// (claimed=true). This is the exact case the old code broke — it tore the healthy
// billed box down on that first 503.
func TestRunOnceSucceedReportTransient5xxThenSucceeds(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken:         testToken,
		job:               &JobSpec{JobID: "job-deploy", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
		succeedFailFirstN: 1, // first succeed POST 503s (restart), then 200
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var teardownCalls int
	w := &Worker{
		ControlURL:         srv.URL,
		Token:              testToken,
		HTTPClient:         srv.Client(),
		ReportRetryBackoff: time.Millisecond, // run the widened retry loop fast
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "203.0.113.12", "", nil, func(context.Context) error { teardownCalls++; return nil }, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce returned an error after a transient 5xx that recovered, want nil: %v", err)
	}
	if !claimed {
		t.Error("RunOnce claimed=false after a recovered succeed report, want true (cleanly consumed)")
	}
	if teardownCalls != 0 {
		t.Errorf("teardown ran %d times on a recovered 503, want 0 (the healthy billed box must be kept)", teardownCalls)
	}
	// First call 503'd, retry 200'd → exactly 2 calls reached the server.
	if cp.succeedCalls != 2 {
		t.Errorf("server recorded %d succeed calls, want exactly 2 (one 503 + one 200)", cp.succeedCalls)
	}
	if cp.succeededIP != "203.0.113.12" {
		t.Errorf("succeed ip = %q, want 203.0.113.12", cp.succeededIP)
	}
}

// TestRunOnceSucceedReport4xxStopsImmediatelyAndTearsDown proves a 4xx is TERMINAL:
// the control plane returns 409 (the job was already reaped/failed at the attempts
// cap — succeed_job is status-guarded). Retrying cannot change a 4xx, so the worker
// must stop on the FIRST attempt (no retries), tear the orphan box down, and leave
// the job un-consumed (claimed=false). Contrast the persistent-5xx test, which
// retries reportRetries+1 times before tearing down.
func TestRunOnceSucceedReport4xxStopsImmediatelyAndTearsDown(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken:     testToken,
		job:           &JobSpec{JobID: "job-409", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
		failSucceed:   true,
		succeedStatus: http.StatusConflict, // 409 — terminal rejection
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var teardownCalls int
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "203.0.113.13", "", nil, func(context.Context) error { teardownCalls++; return nil }, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())

	// ── a 4xx is terminal: exactly ONE attempt, no retries ──
	if cp.succeedCalls != 1 {
		t.Errorf("succeed reached the server %d times, want exactly 1 (a 4xx must NOT be retried)", cp.succeedCalls)
	}
	// ── the orphan box was torn down ──
	if teardownCalls != 1 {
		t.Errorf("teardown called %d times, want exactly 1 (a 4xx-rejected attempt must not leave an orphan)", teardownCalls)
	}
	if claimed {
		t.Error("RunOnce claimed=true after a 4xx succeed-report, want false (the job must stay re-claimable)")
	}
	if err == nil {
		t.Error("RunOnce returned nil after a 4xx succeed-report, want an error (the rejection must be observable)")
	}
}

// TestRunOnceSucceedReportIdempotent200KeepsBox proves the lost-response self-heal:
// the worker thinks the succeed might be a retry, the control plane has ALREADY
// recorded this job as succeeded, and its idempotent succeed_job returns 200 with
// no double side-effects. A 200 — fresh OR idempotent — is success: the box is
// KEPT (NO teardown), the job is cleanly consumed (claimed=true). (Here the very
// first POST 200s, modelling the CP committing then returning 200 on the worker's
// re-POST after a dropped response.)
func TestRunOnceSucceedReportIdempotent200KeepsBox(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-idem", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
		// failSucceed=false, succeedFailFirstN=0 → the endpoint 200s — exactly what an
		// idempotent re-POST of an already-succeeded job returns.
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var teardownCalls int
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "203.0.113.14", "", nil, func(context.Context) error { teardownCalls++; return nil }, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce returned an error on an idempotent 200, want nil: %v", err)
	}
	if !claimed {
		t.Error("RunOnce claimed=false on an idempotent 200, want true (a 200 is success)")
	}
	if teardownCalls != 0 {
		t.Errorf("teardown ran %d times on a 200, want 0 (a 200 keeps the box)", teardownCalls)
	}
	if cp.succeedCalls != 1 {
		t.Errorf("server recorded %d succeed calls, want exactly 1 (the 200 landed first try)", cp.succeedCalls)
	}
}

// TestRunOnceSucceedReportRetriesTransientThenSucceeds proves the blip-tolerance:
// a succeed POST that fails as a TRANSPORT error the first time and then succeeds
// is NOT escalated to teardown — the box stays live, the job is cleanly consumed,
// and no teardown runs. (A transport failure is simulated by a transport that errs
// once then delegates to the real client.)
func TestRunOnceSucceedReportRetriesTransientThenSucceeds(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-blip", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	// Wrap the real client's transport so the FIRST succeed POST returns a transport
	// error (connection reset), then every later request goes through normally.
	base := srv.Client().Transport
	flaky := &flakyTransport{base: base, failFirstPathSubstr: "/succeed"}

	var teardownCalls int
	w := &Worker{
		ControlURL:         srv.URL,
		Token:              testToken,
		HTTPClient:         &http.Client{Transport: flaky},
		ProvisionTimeout:   time.Minute,
		ReportRetryBackoff: time.Millisecond, // run the widened retry loop fast
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "203.0.113.10", "", nil, func(context.Context) error { teardownCalls++; return nil }, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce returned an error after a transient succeed blip that recovered: %v", err)
	}
	if !claimed {
		t.Error("RunOnce claimed=false after a recovered succeed report, want true (cleanly consumed)")
	}
	if teardownCalls != 0 {
		t.Errorf("teardown ran %d times on a recovered blip, want 0 (the live box must be kept)", teardownCalls)
	}
	// The first succeed POST failed at the transport (never reached the server); the
	// retry reached it. So the transport saw >= 2 succeed attempts while the server
	// recorded exactly 1.
	if flaky.matchAttempts < 2 {
		t.Errorf("succeed was attempted %d times at the transport, want >= 2 (one failed blip + one retry)", flaky.matchAttempts)
	}
	if cp.succeedCalls != 1 {
		t.Errorf("server recorded %d succeed calls, want exactly 1 (only the retry reached it)", cp.succeedCalls)
	}
}

// TestRunOnceSucceedReportFailsAndTeardownFails surfaces the worst case: the
// succeed report fails AND the orphan teardown fails. The job must still be left
// for retry (claimed=false) and the error must name BOTH failures so the billed
// orphan is visible in the worker journal.
func TestRunOnceSucceedReportFailsAndTeardownFails(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken:   testToken,
		job:         &JobSpec{JobID: "job-worst", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
		failSucceed: true,
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL:         srv.URL,
		Token:              testToken,
		HTTPClient:         srv.Client(),
		ReportRetryBackoff: time.Millisecond, // run the widened retry loop fast
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "203.0.113.11", "", nil, func(context.Context) error {
				return errString("delete server bp-acme-xyz (BILLED ORPHAN): provider unreachable")
			}, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if claimed {
		t.Error("RunOnce claimed=true when both succeed-report and teardown failed, want false")
	}
	if err == nil {
		t.Fatal("RunOnce returned nil when both succeed-report and teardown failed, want an error naming both")
	}
	if !strings.Contains(err.Error(), "BILLED ORPHAN") {
		t.Errorf("error %q does not surface the failed teardown (billed orphan), want it visible", err)
	}
}

// TestRunOnceFailReportFailsLeavesJobForRetry is the FIX-1 fail-report case:
// provision FAILS (its half-built box already torn down by the provision path),
// and the fail-report ALSO fails to land. There is no box to clean up, but the job
// must NOT be silently consumed — claimed=false so the reaper re-claims it and the
// failure is eventually recorded (bounded by the attempts cap). RunOnce returns an
// error so the dropped report is observable.
func TestRunOnceFailReportFailsLeavesJobForRetry(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-failreport", Name: "boom", Slug: "boom", Region: "nbg1", ServerType: "cax11"},
		failFail:  true, // the fail POST 500s — report does not get through
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var teardownCalls int
	w := &Worker{
		ControlURL:         srv.URL,
		Token:              testToken,
		HTTPClient:         srv.Client(),
		ReportRetryBackoff: time.Millisecond, // run the widened retry loop fast
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			// Provision failed: nil teardown (the box was already cleaned up), error set.
			return "", "", nil, func(context.Context) error { teardownCalls++; return nil }, errBoom
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if claimed {
		t.Error("RunOnce claimed=true after a failed fail-report, want false (job must stay re-claimable)")
	}
	if err == nil {
		t.Error("RunOnce returned nil after a failed fail-report, want an error (the dropped report must be observable)")
	}
	// ── the worker did NOT call succeed and did NOT try to tear anything down (the
	// provision failure path owns the box) ──
	if cp.succeededID != "" {
		t.Errorf("succeed was called (id=%q) on a provision failure, want none", cp.succeededID)
	}
	if cp.failedID != "job-failreport" {
		t.Errorf("fail was not attempted (id=%q), want job-failreport", cp.failedID)
	}
	if teardownCalls != 0 {
		t.Errorf("teardown ran %d times on a provision failure (box already cleaned up), want 0", teardownCalls)
	}
}

// TestSweepOnce_RunsInjectedSweep proves the worker's startup-sweep seam: SweepOnce
// invokes the injected Sweep and returns its count. main() calls this BEFORE the
// claim loop so a prior run's leaked orphan is recovered on the next process start.
func TestSweepOnce_RunsInjectedSweep(t *testing.T) {
	var sweepCalls int
	w := &Worker{
		Sweep: func(context.Context) (int, error) { sweepCalls++; return 3, nil },
	}
	swept, err := w.SweepOnce(context.Background())
	if err != nil {
		t.Fatalf("SweepOnce: %v", err)
	}
	if swept != 3 {
		t.Errorf("SweepOnce swept = %d, want 3 (the injected count)", swept)
	}
	if sweepCalls != 1 {
		t.Errorf("Sweep invoked %d times, want 1", sweepCalls)
	}
}

// TestSweepOnce_NilSweepIsNoop proves a worker without the Sweep seam still runs:
// SweepOnce is a clean (0, nil) no-op rather than a panic.
func TestSweepOnce_NilSweepIsNoop(t *testing.T) {
	w := &Worker{} // no Sweep
	if swept, err := w.SweepOnce(context.Background()); err != nil || swept != 0 {
		t.Errorf("SweepOnce with nil Sweep = (%d, %v), want (0, nil)", swept, err)
	}
}

// TestRunWith_PeriodicSweep proves the periodic sweep fires every SweepEvery
// cycles within Run, in addition to the startup sweep main() drives. With
// SweepEvery=1 the sweep runs after each cycle, so a few cycles trigger several
// sweeps before ctx cancels.
func TestRunWith_PeriodicSweep(t *testing.T) {
	cp := &fakeControlPlane{wantToken: testToken} // 204 every claim (idle)
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var sweepCalls int
	var mu sync.Mutex
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		Interval:   2 * time.Millisecond,
		HTTPClient: srv.Client(),
		Provision:  func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) { return "", "", nil, nil, nil },
		SweepEvery: 1,
		Sweep: func(context.Context) (int, error) {
			mu.Lock()
			sweepCalls++
			mu.Unlock()
			return 0, nil
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	_ = w.RunWith(ctx, func(bool, error) {})

	mu.Lock()
	calls := sweepCalls
	mu.Unlock()
	if calls < 2 {
		t.Errorf("periodic sweep ran %d times, want >= 2 (SweepEvery=1 over several cycles)", calls)
	}
}

// flakyTransport fails the FIRST request whose URL path contains failFirstPathSubstr
// with a transport-style error (no HTTP response), then delegates every subsequent
// request to base. It simulates a momentary network blip so the succeed-report
// retry path can be exercised without a real network.
type flakyTransport struct {
	base                http.RoundTripper
	failFirstPathSubstr string
	failed              bool
	matchAttempts       int // requests whose path matched the substr (failed + retried)
	mu                  sync.Mutex
}

func (t *flakyTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	t.mu.Lock()
	match := strings.Contains(r.URL.Path, t.failFirstPathSubstr)
	shouldFail := match && !t.failed
	if match {
		t.matchAttempts++
	}
	if shouldFail {
		t.failed = true
	}
	t.mu.Unlock()
	if shouldFail {
		return nil, errString("simulated transport blip: connection reset by peer")
	}
	return t.base.RoundTrip(r)
}

// errBoom is the deterministic provision failure the fail-path test asserts on.
var errBoom = errString("provision blew up: warm pool empty")

type errString string

func (e errString) Error() string { return string(e) }
