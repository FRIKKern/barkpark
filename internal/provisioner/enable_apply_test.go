package provisioner

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
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

	// ── exactly three steps, in order: env flag, go.mod churn restore, restart ──
	if len(runner.steps) != 3 {
		t.Fatalf("runner ran %d steps, want 3 (env flag + churn restore + restart): %+v", len(runner.steps), runner.steps)
	}
	if !strings.Contains(runner.steps[0].Title, "BARKPARK_SELF_UPDATE_APPLY") {
		t.Errorf("step[0] = %q, want the env-flag step first", runner.steps[0].Title)
	}
	if !strings.Contains(runner.steps[1].Title, "go.mod/go.sum") {
		t.Errorf("step[1] = %q, want the go.mod/go.sum restore second", runner.steps[1].Title)
	}
	if !strings.Contains(runner.steps[2].Title, "restart Barkpark") {
		t.Errorf("step[2] = %q, want the app restart last", runner.steps[2].Title)
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

	steps := enableApplySteps(envFile, dir)
	if len(steps) != 3 {
		t.Fatalf("enableApplySteps returned %d steps, want 3 (env flag + churn restore + restart)", len(steps))
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

// TestSetShapeCloudStepReplacesAndIsIdempotent EXECUTES the shape step (real
// bash, temp file) over an env that already says solo (deploy.sh's default on
// a warm-baked image): the result is exactly one BARKPARK_SHAPE=cloud line,
// unchanged by a re-run, with unrelated keys untouched.
func TestSetShapeCloudStepReplacesAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "app.env")
	if err := os.WriteFile(envFile, []byte("PHX_HOST=acme.barkpark.cloud\nBARKPARK_SHAPE=solo\nPHX_SCHEME=https\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	step := setShapeCloudStep(envFile)
	runAttachScript(t, step)
	runAttachScript(t, step)

	env, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(env), "BARKPARK_SHAPE="); got != 1 {
		t.Errorf("BARKPARK_SHAPE= appears %d times, want exactly 1:\n%s", got, env)
	}
	if !strings.Contains(string(env), "BARKPARK_SHAPE=cloud\n") || strings.Contains(string(env), "BARKPARK_SHAPE=solo") {
		t.Errorf("shape was not replaced with cloud:\n%s", env)
	}
	if !strings.Contains(string(env), "PHX_HOST=acme.barkpark.cloud") || !strings.Contains(string(env), "PHX_SCHEME=https") {
		t.Errorf("unrelated env keys were disturbed:\n%s", env)
	}
	info, err := os.Stat(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("env file mode = %v, want 0600 kept (the step rewrites in place)", info.Mode().Perm())
	}
}

// churnRepo builds a real git checkout shaped like a jammed box: go.mod/go.sum
// committed, then optionally rewritten (the `go mod tidy` churn) and optionally
// another tracked file edited.
func churnRepo(t *testing.T, tidyChurn bool, otherEdit bool) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("init", "-q")
	write("go.mod", "module x\n\ngo 1.25\n")
	write("go.sum", "a v1 h1:x\n")
	write("README", "readme\n")
	run("add", "-A")
	run("commit", "-qm", "base")
	if tidyChurn {
		write("go.mod", "module x\n\ngo 1.25.0\n")
		write("go.sum", "a v1 h1:x\nb v2 h1:y\n")
	}
	if otherEdit {
		write("README", "someone's local edit\n")
	}
	// An untracked file is never a reason to refuse.
	write(".bp-self-update-runs", "untracked\n")
	return dir
}

func gitStatus(t *testing.T, dir string) string {
	t.Helper()
	cmd := exec.Command("git", "status", "--porcelain", "--untracked-files=no")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(out))
}

// TestRestoreGoModChurnStep EXECUTES the rendered step (real bash, real git)
// against the three box shapes: tidy churn only → restored and clean (and a
// re-run is a no-op); a clean tree → no-op; churn PLUS another tracked edit →
// the step FAILS, names the file, and touches nothing.
func TestRestoreGoModChurnStep(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}

	t.Run("tidy churn only: restored, clean, re-run is a no-op", func(t *testing.T) {
		dir := churnRepo(t, true, false)
		step := restoreGoModChurnStep(dir)
		runAttachScript(t, step)
		if got := gitStatus(t, dir); got != "" {
			t.Fatalf("tree still dirty after restore: %q", got)
		}
		runAttachScript(t, step)
		if _, err := os.Stat(filepath.Join(dir, ".bp-self-update-runs")); err != nil {
			t.Errorf("an untracked file was removed: %v", err)
		}
	})

	t.Run("clean tree: no-op", func(t *testing.T) {
		dir := churnRepo(t, false, false)
		runAttachScript(t, restoreGoModChurnStep(dir))
		if got := gitStatus(t, dir); got != "" {
			t.Fatalf("clean tree changed: %q", got)
		}
	})

	t.Run("another tracked edit: refuses loudly and changes nothing", func(t *testing.T) {
		dir := churnRepo(t, true, true)
		step := restoreGoModChurnStep(dir)
		out, err := exec.Command(step.Argv[0], step.Argv[1:]...).CombinedOutput()
		if err == nil {
			t.Fatalf("step succeeded with a foreign tracked edit present, want a failure:\n%s", out)
		}
		if !strings.Contains(string(out), "README") || !strings.Contains(string(out), "REFUSING") {
			t.Errorf("refusal does not name the blocking file:\n%s", out)
		}
		status := gitStatus(t, dir)
		for _, f := range []string{"go.mod", "go.sum", "README"} {
			if !strings.Contains(status, f) {
				t.Errorf("%s was touched (status now %q) — a refusal must change nothing", f, status)
			}
		}
	})
}
