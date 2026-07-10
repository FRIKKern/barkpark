package cli

// cmux_status_health_test.go — `bp cmux status` as the one-command bridge
// diagnosis (task cb-hook-breadcrumb). Asserts: the breadcrumb is surfaced (text
// + json) and silent when absent; not-found is disambiguated from unreachable
// (the server-unreachable degradation line is asserted here — completes
// cb-status-verb criterion 2); live lease health comes from claim.ts_iso + the
// TTL default, no longer the post-mortem expired_at.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// status surfaces the last-error breadcrumb even when this pane owns no task
// (a claim that never landed still left one).
func TestCmuxStatusSurfacesBreadcrumb(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "SRFB")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "")
	userConfigDir = func() (string, error) { return dir, nil }
	writeHookBreadcrumb("SessionStart", "cmux-SRFB", "task-z", "claim rejected: stale epoch")

	ctx := manifest.Context{Server: "http://127.0.0.1:1", Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	out := so.String()
	for _, want := range []string{"last-err", "claim rejected: stale epoch", "ago)"} {
		if !strings.Contains(out, want) {
			t.Errorf("status missing %q:\n%s", want, out)
		}
	}
}

// status -o json carries the breadcrumb as a last_error object.
func TestCmuxStatusBreadcrumbJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("BARKPARK_WORKER_ID", "wk")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "")
	userConfigDir = func() (string, error) { return dir, nil }
	writeHookBreadcrumb("PreToolUse", "wk", "task-q", "renew failed: timeout")

	ctx := manifest.Context{Server: "http://127.0.0.1:1", Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var got map[string]any
	if err := json.Unmarshal(so.Bytes(), &got); err != nil {
		t.Fatalf("status -o json not valid JSON: %v\n%s", err, so.String())
	}
	le, ok := got["last_error"].(map[string]any)
	if !ok {
		t.Fatalf("last_error missing in json:\n%s", so.String())
	}
	if le["error"] != "renew failed: timeout" || le["event"] != "PreToolUse" || le["task"] != "task-q" {
		t.Errorf("last_error = %v", le)
	}
}

// No breadcrumb → the status stays silent about hook errors (text + json).
func TestCmuxStatusSilentWithoutBreadcrumb(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("BARKPARK_WORKER_ID", "wk2")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "")
	userConfigDir = func() (string, error) { return dir, nil }

	ctx := manifest.Context{Server: "http://127.0.0.1:1", Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if strings.Contains(so.String(), "last-err") {
		t.Errorf("status showed a hook error with no breadcrumb:\n%s", so.String())
	}

	so.Reset()
	se.Reset()
	wj := &writer{stdout: &so, stderr: &se, output: "json"}
	if code := runCmuxStatus(wj, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var got map[string]any
	_ = json.Unmarshal(so.Bytes(), &got)
	if _, present := got["last_error"]; present {
		t.Errorf("json carried last_error with no breadcrumb:\n%s", so.String())
	}
}

// An unreachable server reads as unreachable, NOT not-found (text + json).
func TestCmuxStatusServerUnreachable(t *testing.T) {
	dir := t.TempDir()
	userConfigDir = func() (string, error) { return dir, nil }
	t.Setenv("BARKPARK_WORKER_ID", "wk3")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "task-unreach")

	// A closed port refuses the connection → transport error → unreachable.
	ctx := manifest.Context{Server: "http://127.0.0.1:1", Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	out := so.String()
	if !strings.Contains(out, "server unreachable") {
		t.Errorf("want the server-unreachable degradation line:\n%s", out)
	}
	if strings.Contains(out, "task not found") {
		t.Errorf("unreachable must NOT read as not-found:\n%s", out)
	}

	so.Reset()
	se.Reset()
	wj := &writer{stdout: &so, stderr: &se, output: "json"}
	if code := runCmuxStatus(wj, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var got map[string]any
	_ = json.Unmarshal(so.Bytes(), &got)
	if got["server_unreachable"] != true {
		t.Errorf("server_unreachable = %v, want true", got["server_unreachable"])
	}
	if got["task_not_found"] != false {
		t.Errorf("task_not_found = %v, want false", got["task_not_found"])
	}
}

// A 404 on the task read reads as not-found, NOT unreachable.
func TestCmuxStatusTaskNotFound(t *testing.T) {
	dir := t.TempDir()
	userConfigDir = func() (string, error) { return dir, nil }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"not found"}`))
	}))
	t.Cleanup(srv.Close)

	t.Setenv("BARKPARK_WORKER_ID", "wk4")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "task-ghost")

	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	out := so.String()
	if !strings.Contains(out, "task not found") {
		t.Errorf("want the not-found degradation line:\n%s", out)
	}
	if strings.Contains(out, "server unreachable") {
		t.Errorf("not-found must NOT read as unreachable:\n%s", out)
	}
}

// Live lease health is derived from claim.ts_iso + the TTL (approximate), not the
// post-mortem expired_at.
func TestCmuxStatusLeaseHealthFromTsIso(t *testing.T) {
	dir := t.TempDir()
	userConfigDir = func() (string, error) { return dir, nil }
	claimed := time.Now().Add(-10 * time.Minute).UTC().Format(time.RFC3339)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		env := map[string]any{"result": map[string]any{
			"_id":              "task-h",
			"lifecycle_status": "in_progress",
			"claim":            map[string]any{"worker": "cmux-SH", "epoch": 2, "ts_iso": claimed},
		}}
		_ = json.NewEncoder(w).Encode(env)
	}))
	t.Cleanup(srv.Close)

	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "SH")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BARKPARK_TASK", "task-h")
	t.Setenv("BARKPARK_TASK_LEASE_TTL_SECONDS", "1800") // 30m override

	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxStatus(w, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	out := so.String()
	// 10m into a 30m TTL → live, ~20m left, explicitly approximate.
	for _, want := range []string{"claimed 10m", "ago", "left", "approx", "30m0s"} {
		if !strings.Contains(out, want) {
			t.Errorf("lease line missing %q:\n%s", want, out)
		}
	}
	// The old expired_at-keyed absolute expiry must be gone.
	if strings.Contains(out, "expires") {
		t.Errorf("lease line still shows an expired_at-keyed expiry:\n%s", out)
	}

	so.Reset()
	se.Reset()
	wj := &writer{stdout: &so, stderr: &se, output: "json"}
	if code := runCmuxStatus(wj, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var got map[string]any
	_ = json.Unmarshal(so.Bytes(), &got)
	if got["lease_ttl_seconds"] != float64(1800) {
		t.Errorf("lease_ttl_seconds = %v, want 1800", got["lease_ttl_seconds"])
	}
	if _, ok := got["approx_remaining_seconds"]; !ok {
		t.Errorf("approx_remaining_seconds missing:\n%s", so.String())
	}
	if _, ok := got["claimed_age_seconds"]; !ok {
		t.Errorf("claimed_age_seconds missing:\n%s", so.String())
	}
}
