package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// hookRec records what a hook fired at the fake server.
type hookRec struct {
	claims  int
	closes  int
	gets    int
	lastWkr string // worker_id on the last claim/close body
	lastEp  int    // observed_epoch on the last close body
	lastRev string // observed_rev on the last close body (digest-fence bypass, D82)
}

// newHookServer serves the three endpoints the hook touches: the drafts task
// read (GET …/task/<id>) with the given acceptance-criteria met-states, the
// claim (returns a fixed fencing epoch), and the close. It records each call.
func newHookServer(t *testing.T, met []bool, claimEpoch int) (*httptest.Server, *hookRec) {
	t.Helper()
	rec := &hookRec{}
	crit := make([]map[string]any, len(met))
	for i, m := range met {
		crit[i] = map[string]any{"criterion": "c", "met": m}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			rec.claims++
			var body struct {
				Worker string `json:"worker_id"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			rec.lastWkr = body.Worker
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":` + itoaT(claimEpoch) + `}}}`))
		case strings.HasSuffix(p, "/close"):
			rec.closes++
			var body struct {
				Worker string `json:"worker_id"`
				Epoch  int    `json:"observed_epoch"`
				Rev    string `json:"observed_rev"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			rec.lastWkr = body.Worker
			rec.lastEp = body.Epoch
			rec.lastRev = body.Rev
			_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
		case strings.Contains(p, "/v1/data/doc/") && strings.Contains(p, "/task/"):
			rec.gets++
			env := map[string]any{"result": map[string]any{
				"_id":                 "task-x",
				"rev":                 "r-fresh-1",
				"lifecycle_status":    "in_progress",
				"acceptance_criteria": crit,
			}}
			_ = json.NewEncoder(w).Encode(env)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, p)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, rec
}

func itoaT(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// hookHarness wires the package test seams + env for one hook invocation and
// returns the writer's stdout/stderr. It clears CMUX_* so an ambient real cmux
// pane can't leak into the worker id.
func hookHarness(t *testing.T, server, task, surface, stdin string) *manifest.Context {
	t.Helper()
	t.Setenv("BARKPARK_TASK", task)
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", surface)
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BP_CMUX_DEBUG", "") // default: silent
	hookStdin = strings.NewReader(stdin)
	userConfigDir = func() (string, error) { return t.TempDir(), nil }
	ctx := &manifest.Context{Server: server, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	return ctx
}

func runHook(t *testing.T, ctx *manifest.Context, g globals, event string) (stdout, stderr string, code int) {
	t.Helper()
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code = runCmuxHook(w, g, *ctx, []string{event})
	return so.String(), se.String(), code
}

// SessionStart claims the pane's task as the derived worker id (design §2).
func TestHookSessionStartClaims(t *testing.T) {
	srv, rec := newHookServer(t, []bool{false}, 3)
	ctx := hookHarness(t, srv.URL, "task-abc", "SRF1", `{"session_id":"s"}`)
	so, _, code := runHook(t, ctx, globals{}, "SessionStart")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if so != "" {
		t.Errorf("hook wrote to stdout: %q (must be empty)", so)
	}
	if rec.claims != 1 {
		t.Fatalf("claims = %d, want 1", rec.claims)
	}
	if rec.lastWkr != "cmux-SRF1" {
		t.Errorf("claim worker = %q, want cmux-SRF1", rec.lastWkr)
	}
}

// Stop closes ONLY when every criterion is met; else zero mutation (design §2a).
func TestHookStopClosesOnlyWhenAllMet(t *testing.T) {
	t.Run("all met → re-claim then close with the live epoch", func(t *testing.T) {
		srv, rec := newHookServer(t, []bool{true, true}, 7)
		ctx := hookHarness(t, srv.URL, "task-done", "S", `{}`)
		so, _, code := runHook(t, ctx, globals{}, "Stop")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
		}
		if so != "" {
			t.Errorf("close-path wrote to stdout: %q (must be empty)", so)
		}
		if rec.gets != 1 {
			// ONE read, to prove acceptance. The fresh-rev read is paid only when
			// the server's work-digest fence actually refuses the close
			// (pds-bl-hook-observed-rev-defeats-fence) — an undrifted close never
			// needs a rev, so it never reads one.
			t.Errorf("gets = %d, want 1 (acceptance read only — the fresh-rev read is drift-only)", rec.gets)
		}
		if rec.claims != 1 {
			t.Errorf("claims = %d, want 1 (re-claim for the live epoch)", rec.claims)
		}
		if rec.closes != 1 {
			t.Fatalf("closes = %d, want 1", rec.closes)
		}
		if rec.lastEp != 7 {
			t.Errorf("close observed_epoch = %d, want the re-claimed 7", rec.lastEp)
		}
		// The fence is ARMED on the first attempt: no observed_rev on the wire
		// when nothing needs bypassing. D82's bypass is not gone — it is now
		// drift-TRIGGERED, and cmux_hook_fence_test.go pins both halves (the
		// fenced 409 is reported, then the strict-rev retry lands the close).
		// A non-empty rev here is the regression the row named: the unattended
		// closer becomes the one closer the work-digest fence never protects.
		if rec.lastRev != "" {
			t.Errorf("close observed_rev = %q, want \"\" — the fence must be armed first, not bypassed pre-emptively", rec.lastRev)
		}
	})

	t.Run("one unmet → no mutation, leave for resume", func(t *testing.T) {
		srv, rec := newHookServer(t, []bool{true, false}, 7)
		ctx := hookHarness(t, srv.URL, "task-wip", "S", `{}`)
		so, _, code := runHook(t, ctx, globals{}, "Stop")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
		}
		if so != "" {
			t.Errorf("unmet-criteria path wrote to stdout: %q (must be empty)", so)
		}
		if rec.closes != 0 || rec.claims != 0 {
			t.Errorf("unmet criteria mutated: claims=%d closes=%d, want 0/0", rec.claims, rec.closes)
		}
	})

	t.Run("no criteria at all → cannot prove doneness, no mutation", func(t *testing.T) {
		srv, rec := newHookServer(t, nil, 7)
		ctx := hookHarness(t, srv.URL, "task-thin", "S", `{}`)
		so, _, code := runHook(t, ctx, globals{}, "Stop")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
		}
		if so != "" {
			t.Errorf("criteria-less path wrote to stdout: %q (must be empty)", so)
		}
		if rec.closes != 0 || rec.claims != 0 {
			t.Errorf("criteria-less task mutated: claims=%d closes=%d, want 0/0", rec.claims, rec.closes)
		}
	})
}

// PreToolUse renew is throttled: a second fire inside the window makes no
// request; the first (no stamp yet) renews (design §2c).
func TestHookPreToolUseThrottle(t *testing.T) {
	srv, rec := newHookServer(t, []bool{false}, 2)
	// Shared temp dir across BOTH fires so the stamp written by the first is seen
	// by the second (hookHarness would hand a fresh TempDir each call).
	dir := t.TempDir()
	t.Setenv("BARKPARK_TASK", "task-p")
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "S")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BP_CMUX_DEBUG", "")
	hookStdin = strings.NewReader(`{}`)
	userConfigDir = func() (string, error) { return dir, nil }
	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}

	// First fire: no stamp → renews. Real buffers (not io.Discard) so the
	// fail-safe "empty stdout" invariant is actually asserted on the renew path.
	var so1, se1 bytes.Buffer
	if code := runCmuxHook(&writer{stdout: &so1, stderr: &se1, output: "table"}, globals{}, ctx, []string{"PreToolUse"}); code != exitOK {
		t.Fatalf("first PreToolUse exit = %d", code)
	}
	if so1.Len() != 0 {
		t.Errorf("first PreToolUse wrote to stdout: %q (must be empty)", so1.String())
	}
	if rec.claims != 1 {
		t.Fatalf("first PreToolUse claims = %d, want 1 (renew)", rec.claims)
	}
	// Second fire immediately: within the throttle window → no request.
	var so2, se2 bytes.Buffer
	if code := runCmuxHook(&writer{stdout: &so2, stderr: &se2, output: "table"}, globals{}, ctx, []string{"PreToolUse"}); code != exitOK {
		t.Fatalf("second PreToolUse exit = %d", code)
	}
	if so2.Len() != 0 {
		t.Errorf("second PreToolUse wrote to stdout: %q (must be empty)", so2.String())
	}
	if rec.claims != 1 {
		t.Errorf("second PreToolUse claims = %d, want still 1 (throttled)", rec.claims)
	}
}

// The dry-run flag mutates nothing but still reads to decide (design §7 rule 5).
func TestHookDryRunNoMutation(t *testing.T) {
	srv, rec := newHookServer(t, []bool{true}, 5)
	ctx := hookHarness(t, srv.URL, "task-dry", "S", `{}`)
	so, se, code := runHook(t, ctx, globals{dryRun: true}, "Stop")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if so != "" {
		t.Errorf("dry-run wrote to stdout: %q (must be empty)", so)
	}
	if rec.claims != 0 || rec.closes != 0 {
		t.Errorf("dry-run mutated: claims=%d closes=%d, want 0/0", rec.claims, rec.closes)
	}
	if !strings.Contains(se, "would re-claim") {
		t.Errorf("dry-run stderr = %q, want a 'would re-claim' plan line", se)
	}
}

// The fail-safe exit-0 matrix: every abnormal input exits 0 with empty stdout.
func TestHookFailSafeExitZero(t *testing.T) {
	// A server that hangs longer than the (shortened) hook timeout.
	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
	}))
	t.Cleanup(hang.Close)

	cases := []struct {
		name   string
		task   string
		event  string
		server string
		stdin  string
	}{
		{"missing BARKPARK_TASK", "", "SessionStart", "http://127.0.0.1:1", `{}`},
		{"unknown event", "task-x", "Frobnicate", "http://127.0.0.1:1", `{}`},
		{"unreachable server", "task-x", "SessionStart", "http://127.0.0.1:1", `{}`},
		{"malformed stdin", "task-x", "SessionStart", "http://127.0.0.1:1", `{not json at all`},
		{"hung server within timeout", "task-x", "SessionStart", hang.URL, `{}`},
		// PreToolUse is the renew path (re-claim, throttled). Its failure surface
		// must be just as inert as SessionStart's.
		{"PreToolUse unreachable server", "task-x", "PreToolUse", "http://127.0.0.1:1", `{}`},
		{"PreToolUse hung server", "task-x", "PreToolUse", hang.URL, `{}`},
		// Oversized stdin (> the 1 MiB io.LimitReader at cmux_hook.go:257): the
		// drain must stay bounded — read a bounded prefix and no-op, never hang.
		{"oversized stdin bounded", "task-x", "SessionStart", "http://127.0.0.1:1", strings.Repeat("a", 1<<20+4096)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Shorten the hook network timeout so the hung-server cases are quick.
			old := hookTimeout
			hookTimeout = 150 * time.Millisecond
			defer func() { hookTimeout = old }()

			ctx := hookHarness(t, tc.server, tc.task, "S", tc.stdin)
			var so, se bytes.Buffer
			w := &writer{stdout: &so, stderr: &se, output: "table"}
			start := time.Now()
			code := runCmuxHook(w, globals{}, *ctx, []string{tc.event})
			if code != exitOK {
				t.Errorf("exit = %d, want 0", code)
			}
			if so.Len() != 0 {
				t.Errorf("stdout = %q, want empty on the hook path", so.String())
			}
			// EVERY row must return promptly: a hung server is bounded by the
			// (shortened) network timeout, an oversized stdin by the LimitReader,
			// a refused connection is immediate. None may stall the agent's turn.
			if elapsed := time.Since(start); elapsed > time.Second {
				t.Errorf("hook took %v — a fail-safe path must never stall the turn", elapsed)
			}
		})
	}
}

// A forced panic inside the hook still exits 0 (the top-level recover). We
// trigger it by making a seam panic.
func TestHookPanicRecovers(t *testing.T) {
	old := userConfigDir
	defer func() { userConfigDir = old }()
	// SessionStart's writeRenewStamp calls userConfigDir; make it panic.
	userConfigDir = func() (string, error) { panic("boom") }
	srv, _ := newHookServer(t, []bool{false}, 1)
	ctx := hookHarness(t, srv.URL, "task-x", "S", `{}`)
	// hookHarness reset userConfigDir — re-install the panicking one AFTER it.
	userConfigDir = func() (string, error) { panic("boom") }
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxHook(w, globals{}, *ctx, []string{"SessionStart"}); code != exitOK {
		t.Errorf("exit = %d, want 0 after a recovered panic", code)
	}
	if so.Len() != 0 {
		t.Errorf("stdout = %q, want empty", so.String())
	}
}

// hookFailCfg configures the Stop-path matrix server to fail at a chosen step so
// each of hookStopClose's up-to-four sequential calls (acceptance GET → re-claim
// POST → fresh-rev GET → close POST) can be broken in isolation.
type hookFailCfg struct {
	met         []bool // acceptance states (all true reaches the mutation path)
	claimEpoch  int
	claimStatus int // non-zero → /claim answers this HTTP status (e.g. 409 fence)
	closeStatus int // non-zero → /close answers this HTTP status (e.g. 409 fence)
	getFailAt   int // >0 → the Nth GET (1-based) answers 500 (2 = fresh-rev fails)
}

// newHookMatrixServer is newHookServer with per-endpoint fault injection. It
// records calls into the same hookRec so a subtest can assert both the exit/
// stdout invariant AND that the failing step was actually reached.
func newHookMatrixServer(t *testing.T, cfg hookFailCfg) (*httptest.Server, *hookRec) {
	t.Helper()
	rec := &hookRec{}
	crit := make([]map[string]any, len(cfg.met))
	for i, m := range cfg.met {
		crit[i] = map[string]any{"criterion": "c", "met": m}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			rec.claims++
			if cfg.claimStatus != 0 {
				w.WriteHeader(cfg.claimStatus)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"fenced_off"}`))
				return
			}
			var body struct {
				Worker string `json:"worker_id"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			rec.lastWkr = body.Worker
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":` + itoaT(cfg.claimEpoch) + `}}}`))
		case strings.HasSuffix(p, "/close"):
			rec.closes++
			if cfg.closeStatus != 0 {
				w.WriteHeader(cfg.closeStatus)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"fenced_off"}`))
				return
			}
			var body struct {
				Worker string `json:"worker_id"`
				Epoch  int    `json:"observed_epoch"`
				Rev    string `json:"observed_rev"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			rec.lastWkr = body.Worker
			rec.lastEp = body.Epoch
			rec.lastRev = body.Rev
			_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
		case strings.Contains(p, "/v1/data/doc/") && strings.Contains(p, "/task/"):
			rec.gets++
			if cfg.getFailAt != 0 && rec.gets == cfg.getFailAt {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			env := map[string]any{"result": map[string]any{
				"_id":                 "task-x",
				"rev":                 "r-fresh-1",
				"lifecycle_status":    "in_progress",
				"acceptance_criteria": crit,
			}}
			_ = json.NewEncoder(w).Encode(env)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, p)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, rec
}

// TestHookStopFailSafeExitZero is the Stop-path (close) failure matrix — the
// branch-heaviest hook path (acceptance GET → re-claim → fresh-rev GET → close).
// EVERY server fault must still exit 0 with EMPTY stdout, and each row also
// asserts the failing step was reached (anti-vacuous: a green here must mean the
// path was exercised, not skipped).
func TestHookStopFailSafeExitZero(t *testing.T) {
	// A server that hangs past the (shortened) hook timeout on every request.
	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
	}))
	t.Cleanup(hang.Close)

	t.Run("unreadable task (dead server)", func(t *testing.T) {
		old := hookTimeout
		hookTimeout = 150 * time.Millisecond
		defer func() { hookTimeout = old }()
		ctx := hookHarness(t, "http://127.0.0.1:1", "task-x", "S", `{}`)
		var so, se bytes.Buffer
		code := runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"Stop"})
		assertHookInert(t, code, so.String())
	})

	t.Run("re-claim for epoch fails (409 on /claim)", func(t *testing.T) {
		srv, rec := newHookMatrixServer(t, hookFailCfg{met: []bool{true, true}, claimStatus: 409})
		ctx := hookHarness(t, srv.URL, "task-x", "S", `{}`)
		var so, se bytes.Buffer
		code := runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"Stop"})
		assertHookInert(t, code, so.String())
		if rec.claims != 1 {
			t.Errorf("claims = %d, want 1 (the re-claim was attempted)", rec.claims)
		}
		if rec.closes != 0 {
			t.Errorf("closes = %d, want 0 (a fenced re-claim must not close — no theft)", rec.closes)
		}
	})

	t.Run("close rejected/fenced (409 on /close)", func(t *testing.T) {
		srv, rec := newHookMatrixServer(t, hookFailCfg{met: []bool{true, true}, claimEpoch: 7, closeStatus: 409})
		ctx := hookHarness(t, srv.URL, "task-x", "S", `{}`)
		var so, se bytes.Buffer
		code := runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"Stop"})
		assertHookInert(t, code, so.String())
		if rec.closes != 1 {
			t.Errorf("closes = %d, want 1 (the close was attempted and rejected)", rec.closes)
		}
	})

	t.Run("acceptance GET succeeds, close lands rev-less (fence armed)", func(t *testing.T) {
		// getFailAt=2 used to model "the post-claim fresh-rev GET 500s → fall back
		// to a rev-less close". There IS no post-claim fresh-rev GET on an
		// undrifted close any more — the fence is armed first and the rev is read
		// only when the server refuses (pds-bl-hook-observed-rev-defeats-fence).
		// The fault therefore never fires; what this row still pins is that the
		// undrifted close is rev-less and carries the re-claimed epoch. The
		// drift-side failure (fence refuses AND the fresh rev is unreadable →
		// NO close) is pinned in cmux_hook_fence_test.go, where the fake server
		// can express the rev-less refusal.
		srv, rec := newHookMatrixServer(t, hookFailCfg{met: []bool{true, true}, claimEpoch: 9, getFailAt: 2})
		ctx := hookHarness(t, srv.URL, "task-x", "S", `{}`)
		var so, se bytes.Buffer
		code := runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"Stop"})
		assertHookInert(t, code, so.String())
		if rec.closes != 1 {
			t.Fatalf("closes = %d, want 1", rec.closes)
		}
		if rec.lastRev != "" {
			t.Errorf("close observed_rev = %q, want empty (the fence is armed on the first attempt)", rec.lastRev)
		}
		if rec.lastEp != 9 {
			t.Errorf("close observed_epoch = %d, want the re-claimed 9", rec.lastEp)
		}
	})

	t.Run("hung server", func(t *testing.T) {
		old := hookTimeout
		hookTimeout = 150 * time.Millisecond
		defer func() { hookTimeout = old }()
		ctx := hookHarness(t, hang.URL, "task-x", "S", `{}`)
		var so, se bytes.Buffer
		start := time.Now()
		code := runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"Stop"})
		assertHookInert(t, code, so.String())
		if elapsed := time.Since(start); elapsed > time.Second {
			t.Errorf("Stop took %v against a hung server — network timeout not honored", elapsed)
		}
	})
}

// TestHookRenewStampWriteFailSafe proves the on-disk renew-stamp write
// (writeRenewStamp, cmux_hook.go:305-318) failing does not break the hook: the
// claim still succeeds and the hook exits 0 with empty stdout. We make MkdirAll
// fail by pointing the config dir at a regular FILE, so joining barkpark/cmux/…
// beneath it cannot be created.
func TestHookRenewStampWriteFailSafe(t *testing.T) {
	srv, rec := newHookServer(t, []bool{false}, 3)
	ctx := hookHarness(t, srv.URL, "task-x", "S", `{}`)
	// hookHarness set userConfigDir to a temp dir; override it AFTER to a file
	// path so writeRenewStamp's MkdirAll fails.
	f := t.TempDir() + "/not-a-dir"
	if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
		t.Fatalf("seed file: %v", err)
	}
	userConfigDir = func() (string, error) { return f, nil }
	var so, se bytes.Buffer
	code := runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"SessionStart"})
	assertHookInert(t, code, so.String())
	if rec.claims != 1 {
		t.Errorf("claims = %d, want 1 (claim succeeds; only the stamp write fails)", rec.claims)
	}
}

// assertHookInert is the shared fail-safe assertion: exit 0 AND empty stdout.
func assertHookInert(t *testing.T, code int, stdout string) {
	t.Helper()
	if code != exitOK {
		t.Errorf("exit = %d, want 0 (a hook must never break the agent)", code)
	}
	if stdout != "" {
		t.Errorf("stdout = %q, want empty on every hook path", stdout)
	}
}

// acceptanceAllMet decodes the criteria tolerance contract correctly.
func TestAcceptanceAllMet(t *testing.T) {
	mk := func(mets ...bool) map[string]json.RawMessage {
		arr := make([]map[string]any, len(mets))
		for i, m := range mets {
			arr[i] = map[string]any{"met": m}
		}
		raw, _ := json.Marshal(arr)
		return map[string]json.RawMessage{"acceptance_criteria": raw}
	}
	type tc struct {
		name      string
		extra     map[string]json.RawMessage
		wantTotal int
		wantAll   bool
	}
	cases := []tc{
		{"all met", mk(true, true), 2, true},
		{"one unmet", mk(true, false), 2, false},
		{"none met", mk(false), 1, false},
		{"empty array", map[string]json.RawMessage{"acceptance_criteria": json.RawMessage(`[]`)}, 0, false},
		{"absent key", map[string]json.RawMessage{}, 0, false},
		{"garbage value", map[string]json.RawMessage{"acceptance_criteria": json.RawMessage(`"nope"`)}, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			total, all := acceptanceAllMet(apiclient.Doc{Extra: c.extra})
			if total != c.wantTotal || all != c.wantAll {
				t.Errorf("acceptanceAllMet = (%d,%v), want (%d,%v)", total, all, c.wantTotal, c.wantAll)
			}
		})
	}
}
