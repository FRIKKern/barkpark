package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// install --print emits a valid JSON hook block naming all four events + the
// guarded worker-id shell line, and NEVER writes settings.json.
func TestCmuxInstallPrint(t *testing.T) {
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxInstall(w, globals{}, []string{"--print"}); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	out := so.String()

	// The embedded hook block must be valid JSON.
	var parsed any
	if err := json.Unmarshal([]byte(cmuxHooksBlock), &parsed); err != nil {
		t.Fatalf("hook block is not valid JSON: %v", err)
	}
	if !hooksBlockValid() {
		t.Error("hook block does not name bp cmux hook for all four events")
	}
	for _, ev := range []string{"SessionStart", "PreToolUse", "Stop", "SessionEnd"} {
		if !strings.Contains(out, "bp cmux hook "+ev) {
			t.Errorf("output missing hook wiring for %s", ev)
		}
	}
	if !strings.Contains(out, `BARKPARK_WORKER_ID="cmux-$CMUX_SURFACE_ID"`) {
		t.Error("output missing the guarded worker-id shell line")
	}
	// Names both files + the alongside-cmux caveat.
	if !strings.Contains(out, "~/.claude/settings.json") || !strings.Contains(out, "shell profile") {
		t.Error("output should name both ~/.claude/settings.json and the shell profile")
	}
	if !strings.Contains(strings.ToLower(out), "alongside") {
		t.Error("output should say the hooks run ALONGSIDE cmux's own")
	}
}

// The PreToolUse hook block uses a catch-all matcher; the session/stop events
// take none (design §5a).
func TestCmuxInstallMatcherShape(t *testing.T) {
	var block struct {
		Hooks map[string][]struct {
			Matcher string `json:"matcher"`
			Hooks   []struct {
				Type    string `json:"type"`
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal([]byte(cmuxHooksBlock), &block); err != nil {
		t.Fatalf("decode block: %v", err)
	}
	if got := block.Hooks["PreToolUse"][0].Matcher; got != "*" {
		t.Errorf("PreToolUse matcher = %q, want \"*\"", got)
	}
	if got := block.Hooks["SessionStart"][0].Matcher; got != "" {
		t.Errorf("SessionStart matcher = %q, want empty", got)
	}
	if got := block.Hooks["Stop"][0].Hooks[0].Command; got != "bp cmux hook Stop" {
		t.Errorf("Stop command = %q", got)
	}
}

// status shows worker + task + the live claim on a claimed task (design §6).
func TestCmuxStatusShowsClaim(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		env := map[string]any{"result": map[string]any{
			"_id":              "task-live",
			"lifecycle_status": "in_progress",
			"claim": map[string]any{
				"worker":     "cmux-SRF9",
				"epoch":      4,
				"ts_iso":     "2026-07-06T15:12:03Z",
				"expired_at": "2999-01-01T00:00:00Z",
			},
		}}
		_ = json.NewEncoder(w).Encode(env)
	}))
	t.Cleanup(srv.Close)

	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "SRF9")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "task-live")

	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	out := so.String()
	for _, want := range []string{"cmux-SRF9", "task-live", "epoch 4", "in_progress", "left)"} {
		if !strings.Contains(out, want) {
			t.Errorf("status output missing %q:\n%s", want, out)
		}
	}
}

// status degrades honestly with no task and outside cmux.
func TestCmuxStatusDegrades(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "")

	ctx := manifest.Context{Server: "http://127.0.0.1:1", Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	out := so.String()
	if !strings.Contains(out, "not in a cmux pane") {
		t.Errorf("want the not-in-cmux degradation line:\n%s", out)
	}
	if !strings.Contains(out, "owns no task") {
		t.Errorf("want the no-task degradation line:\n%s", out)
	}
}

// status -o json emits a stable shape and never mutates (it only GETs).
func TestCmuxStatusJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("status made a %s request — must be read-only", r.Method)
		}
		env := map[string]any{"result": map[string]any{"_id": "task-j", "lifecycle_status": "open"}}
		_ = json.NewEncoder(w).Encode(env)
	}))
	t.Cleanup(srv.Close)

	t.Setenv("BARKPARK_WORKER_ID", "hand")
	t.Setenv("CMUX_SURFACE_ID", "SRFJ")
	t.Setenv("BARKPARK_TASK", "task-j")

	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var got map[string]any
	if err := json.Unmarshal(so.Bytes(), &got); err != nil {
		t.Fatalf("status -o json not valid JSON: %v\n%s", err, so.String())
	}
	if got["worker"] != "hand" || got["task"] != "task-j" {
		t.Errorf("json worker/task = %v/%v, want hand/task-j", got["worker"], got["task"])
	}
}

// The verb router: unknown verb is a usage error; --help is exit 0.
func TestCmuxVerbRouting(t *testing.T) {
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmux(w, globals{}, manifest.Context{}, []string{"bogus"}); code != exitUsage {
		t.Errorf("unknown verb exit = %d, want exitUsage", code)
	}
	so.Reset()
	se.Reset()
	if code := runCmux(w, globals{}, manifest.Context{}, []string{"--help"}); code != exitOK {
		t.Errorf("--help exit = %d, want 0", code)
	}
}
