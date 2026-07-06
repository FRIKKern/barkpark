package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
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
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			rec.lastWkr = body.Worker
			rec.lastEp = body.Epoch
			_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
		case strings.Contains(p, "/v1/data/doc/") && strings.Contains(p, "/task/"):
			rec.gets++
			env := map[string]any{"result": map[string]any{
				"_id":                 "task-x",
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
		_, _, code := runHook(t, ctx, globals{}, "Stop")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
		}
		if rec.gets != 1 {
			t.Errorf("gets = %d, want 1 (read to prove acceptance)", rec.gets)
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
	})

	t.Run("one unmet → no mutation, leave for resume", func(t *testing.T) {
		srv, rec := newHookServer(t, []bool{true, false}, 7)
		ctx := hookHarness(t, srv.URL, "task-wip", "S", `{}`)
		_, _, code := runHook(t, ctx, globals{}, "Stop")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
		}
		if rec.closes != 0 || rec.claims != 0 {
			t.Errorf("unmet criteria mutated: claims=%d closes=%d, want 0/0", rec.claims, rec.closes)
		}
	})

	t.Run("no criteria at all → cannot prove doneness, no mutation", func(t *testing.T) {
		srv, rec := newHookServer(t, nil, 7)
		ctx := hookHarness(t, srv.URL, "task-thin", "S", `{}`)
		_, _, code := runHook(t, ctx, globals{}, "Stop")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
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

	// First fire: no stamp → renews.
	if code := runCmuxHook(&writer{stdout: io.Discard, stderr: io.Discard, output: "table"}, globals{}, ctx, []string{"PreToolUse"}); code != exitOK {
		t.Fatalf("first PreToolUse exit = %d", code)
	}
	if rec.claims != 1 {
		t.Fatalf("first PreToolUse claims = %d, want 1 (renew)", rec.claims)
	}
	// Second fire immediately: within the throttle window → no request.
	if code := runCmuxHook(&writer{stdout: io.Discard, stderr: io.Discard, output: "table"}, globals{}, ctx, []string{"PreToolUse"}); code != exitOK {
		t.Fatalf("second PreToolUse exit = %d", code)
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
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Shorten the hook network timeout so the hung-server case is quick.
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
			if tc.name == "hung server within timeout" && time.Since(start) > time.Second {
				t.Errorf("hook took %v — network timeout not honored", time.Since(start))
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
