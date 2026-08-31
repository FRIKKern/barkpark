package provisioner

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// enableApplyFakeSeams wires DefaultEnableApply entirely from the recording
// runner fake (reused from the attach-domain tests) — no real box.
func enableApplyFakeSeams() (Seams, *recordingAttachRunner) {
	runner := &recordingAttachRunner{}
	seams := Seams{
		RunnerFor: func(string) cloud.StepRunner { return runner },
	}
	return seams, runner
}

// validEnableApplySpec is the pinned-contract claim payload the tests drive.
func validEnableApplySpec() EnableApplySpec {
	return EnableApplySpec{
		JobID: "eajob-1",
		IP:    "203.0.113.9",
	}
}

// fakeEnableApplyControlPlane is an httptest-backed stand-in for the Elixir
// control plane's internal ENABLE-APPLY-jobs endpoints — the enable-apply twin
// of fakeAttachDomainControlPlane. It serves one queued spec on claim (then 204
// once drained) and records the succeed/fail report.
type fakeEnableApplyControlPlane struct {
	mu sync.Mutex

	spec *EnableApplySpec // served on the next claim; nil → 204

	claimCount  int
	claimAuth   string
	succeededID string
	succeedAuth string
	failedID    string
	failedError string
	failAuth    string
}

func (f *fakeEnableApplyControlPlane) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/internal/enable-apply-jobs/claim", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.claimCount++
		f.claimAuth = r.Header.Get("Authorization")
		if f.spec == nil {
			w.WriteHeader(http.StatusNoContent) // 204 — nothing pending
			return
		}
		// 200 {job_id, claim_token, ip}
		_ = json.NewEncoder(w).Encode(f.spec)
		f.spec = nil // serve it once; subsequent claims are 204
	})

	// /v1/internal/enable-apply-jobs/:id/succeed and /fail — route on the trailing verb.
	mux.HandleFunc("/v1/internal/enable-apply-jobs/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		id, verb := parseEnableApplyJobPath(r.URL.Path)
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		_ = json.Unmarshal(body, &payload)

		switch verb {
		case "succeed":
			f.succeededID = id
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

// parseEnableApplyJobPath splits /v1/internal/enable-apply-jobs/<id>/<verb>.
func parseEnableApplyJobPath(p string) (id, verb string) {
	const prefix = "/v1/internal/enable-apply-jobs/"
	rest := p[len(prefix):]
	for i := 0; i < len(rest); i++ {
		if rest[i] == '/' {
			return rest[:i], rest[i+1:]
		}
	}
	return rest, ""
}

// TestRunOnceEnableApplyHappyPath is the full happy path through the worker:
// the control plane hands back an enable-apply spec → the executor runs the two
// SSH steps in order (env flag append → app restart) → the worker POSTs succeed
// with the Bearer WORKER_TOKEN.
func TestRunOnceEnableApplyHappyPath(t *testing.T) {
	spec := validEnableApplySpec()
	cp := &fakeEnableApplyControlPlane{spec: &spec}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	seams, runner := enableApplyFakeSeams()
	w := &Worker{
		ControlURL:  srv.URL,
		Token:       testToken,
		HTTPClient:  srv.Client(),
		EnableApply: DefaultEnableApply(seams),
	}

	claimed, err := w.RunOnceEnableApply(context.Background())
	if err != nil {
		t.Fatalf("RunOnceEnableApply: %v", err)
	}
	if !claimed {
		t.Fatal("RunOnceEnableApply claimed=false, want true (an enable-apply job was queued)")
	}

	// ── exactly two steps, in order: env flag append, then app restart ──
	if len(runner.steps) != 2 {
		t.Fatalf("runner ran %d steps, want 2 (env flag + restart): %+v", len(runner.steps), runner.steps)
	}
	if !strings.Contains(runner.steps[0].Title, "BARKPARK_SELF_UPDATE_APPLY") {
		t.Errorf("step[0] = %q, want the env-flag step first", runner.steps[0].Title)
	}
	if !strings.Contains(runner.steps[1].Title, "restart Barkpark") {
		t.Errorf("step[1] = %q, want the app restart second", runner.steps[1].Title)
	}

	// ── the rendered env step carries the pinned flag + env file ──
	envScript := runner.steps[0].Argv[2]
	if !strings.Contains(envScript, "BARKPARK_SELF_UPDATE_APPLY=1") || !strings.Contains(envScript, attachEnvFile) {
		t.Errorf("env-flag script missing the guarded append: %q", envScript)
	}

	// ── claim + succeed carried the Bearer WORKER_TOKEN; fail was NOT called ──
	if cp.claimAuth != "Bearer "+testToken {
		t.Errorf("claim Authorization = %q, want Bearer %s", cp.claimAuth, testToken)
	}
	if cp.succeededID != "eajob-1" {
		t.Errorf("succeed job id = %q, want eajob-1", cp.succeededID)
	}
	if cp.succeedAuth != "Bearer "+testToken {
		t.Errorf("succeed Authorization = %q, want Bearer %s", cp.succeedAuth, testToken)
	}
	if cp.failedID != "" {
		t.Errorf("fail was called (id=%q) on the happy path, want none", cp.failedID)
	}
}

// TestEnableApplyHostileIPAborts is the fail-closed gate: a hostile/empty ip
// (the worker NEVER trusts the control plane; ip reaches the SSH argv) must
// abort with NO remote command.
func TestEnableApplyHostileIPAborts(t *testing.T) {
	cases := []struct {
		name string
		ip   string
	}{
		{"shell metachars in ip", "203.0.113.9; reboot"},
		{"hostname not an ip", "evil.example.com"},
		{"empty ip", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			seams, runner := enableApplyFakeSeams()
			spec := validEnableApplySpec()
			spec.IP = tc.ip

			err := DefaultEnableApply(seams)(context.Background(), spec)
			if err == nil {
				t.Fatalf("DefaultEnableApply accepted a hostile spec %+v, want an error", spec)
			}
			if len(runner.steps) != 0 {
				t.Errorf("the runner ran %d step(s) for a hostile spec, want NO side effects", len(runner.steps))
			}
		})
	}
}

// TestRunOnceEnableApplyHostileSpecReportsFail proves the worker loop reports a
// validation abort to /fail (the job is failed, not silently dropped) with zero
// runner calls, and never POSTs succeed.
func TestRunOnceEnableApplyHostileSpecReportsFail(t *testing.T) {
	spec := validEnableApplySpec()
	spec.JobID = "eajob-evil"
	spec.IP = "203.0.113.9; reboot"
	cp := &fakeEnableApplyControlPlane{spec: &spec}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	seams, runner := enableApplyFakeSeams()
	w := &Worker{
		ControlURL:  srv.URL,
		Token:       testToken,
		HTTPClient:  srv.Client(),
		EnableApply: DefaultEnableApply(seams),
	}

	claimed, err := w.RunOnceEnableApply(context.Background())
	if err != nil {
		t.Fatalf("RunOnceEnableApply returned an error for a validation abort, want nil (reported to /fail): %v", err)
	}
	if !claimed {
		t.Error("RunOnceEnableApply claimed=false, want true (the job was drained even though it failed)")
	}
	if cp.failedID != "eajob-evil" {
		t.Errorf("fail job id = %q, want eajob-evil", cp.failedID)
	}
	if !strings.Contains(cp.failedError, "ip") {
		t.Errorf("fail error = %q, want the validation message", cp.failedError)
	}
	if cp.succeededID != "" {
		t.Errorf("succeed was called (id=%q) for a hostile spec, want none", cp.succeededID)
	}
	if len(runner.steps) != 0 {
		t.Errorf("side effects ran for a hostile spec: steps=%d", len(runner.steps))
	}
}

// TestEnableApplyStepIdempotent proves the mutating box step is idempotent by
// EXECUTING its rendered script (real bash, temp file) twice: the flag line is
// appended exactly once and unrelated keys are untouched.
func TestEnableApplyStepIdempotent(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "app.env")

	// Seed the file the way a provisioned box looks: the PHX_* pair.
	if err := os.WriteFile(envFile, []byte("PHX_HOST=acme.barkpark.cloud\nPHX_SCHEME=https\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	steps := enableApplySteps(envFile)
	if len(steps) != 2 {
		t.Fatalf("enableApplySteps returned %d steps, want 2 (env flag + restart)", len(steps))
	}

	// Run the env-flag step TWICE — the re-run must change nothing.
	runAttachScript(t, steps[0])
	runAttachScript(t, steps[0])

	env, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(env), "BARKPARK_SELF_UPDATE_APPLY=1"); got != 1 {
		t.Errorf("BARKPARK_SELF_UPDATE_APPLY=1 appears %d times after a re-run, want exactly 1:\n%s", got, env)
	}
	if !strings.Contains(string(env), "PHX_HOST=acme.barkpark.cloud") || !strings.Contains(string(env), "PHX_SCHEME=https") {
		t.Errorf("unrelated env keys were disturbed:\n%s", env)
	}
}

// TestRunOnceEnableApplyEmptyQueueNoCall proves a 204 claim is a clean no-op.
func TestRunOnceEnableApplyEmptyQueueNoCall(t *testing.T) {
	cp := &fakeEnableApplyControlPlane{spec: nil} // 204 on claim
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	calls := 0
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		EnableApply: func(context.Context, EnableApplySpec) error {
			calls++
			return nil
		},
	}

	claimed, err := w.RunOnceEnableApply(context.Background())
	if err != nil {
		t.Fatalf("RunOnceEnableApply: %v", err)
	}
	if claimed {
		t.Error("RunOnceEnableApply claimed=true on a 204, want false")
	}
	if calls != 0 {
		t.Errorf("EnableApply ran %d times on an empty queue, want 0", calls)
	}
	if cp.succeededID != "" || cp.failedID != "" {
		t.Errorf("a report was posted on an empty queue: succeed=%q fail=%q", cp.succeededID, cp.failedID)
	}
}

// TestRunOnceEnableApplyNilFuncIsNoOp mirrors the attach-domain contract: a
// worker without the EnableApply seam quietly skips the queue.
func TestRunOnceEnableApplyNilFuncIsNoOp(t *testing.T) {
	w := &Worker{ControlURL: "http://127.0.0.1:1", Token: testToken}
	claimed, err := w.RunOnceEnableApply(context.Background())
	if err != nil {
		t.Fatalf("RunOnceEnableApply with a nil func: %v", err)
	}
	if claimed {
		t.Error("claimed=true with a nil EnableApply, want false")
	}
}
