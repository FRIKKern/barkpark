package cli

// cmux_breadcrumb_test.go — the last-error breadcrumb the fail-safe hook leaves
// so a dead bridge is diagnosable (task cb-hook-breadcrumb). These assert the
// WRITE side: a swallowed failure drops a breadcrumb; an unwritable state dir
// still exits 0 with empty stdout; a healthy action clears a stale breadcrumb.

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// setHookEnv wires the hook env + a caller-owned config dir (so the test can read
// back the breadcrumb the hook drops). Clears ambient CMUX_* so a real pane
// can't leak into the derived worker id.
func setHookEnv(t *testing.T, dir, task, surface string) {
	t.Helper()
	t.Setenv("BARKPARK_TASK", task)
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", surface)
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BP_CMUX_DEBUG", "")
	hookStdin = strings.NewReader(`{}`)
	userConfigDir = func() (string, error) { return dir, nil }
}

// claimFailServer 500s on every claim so DoClaim fails → the hook swallows it →
// a breadcrumb is dropped. Everything else 404s.
func claimFailServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/claim") {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"ok":false,"error":"boom"}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// A swallowed SessionStart claim failure leaves a full breadcrumb, and the hook
// still exits 0 with empty stdout.
func TestHookBreadcrumbOnClaimFailure(t *testing.T) {
	srv := claimFailServer(t)
	dir := t.TempDir()
	setHookEnv(t, dir, "task-x", "SRF1")
	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxHook(w, globals{}, ctx, []string{"SessionStart"}); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if so.Len() != 0 {
		t.Errorf("stdout = %q, want empty on the hook path", so.String())
	}

	bc, ok := readHookBreadcrumb("cmux-SRF1")
	if !ok {
		t.Fatal("no breadcrumb written for the swallowed claim failure")
	}
	if bc.Event != "SessionStart" {
		t.Errorf("breadcrumb event = %q, want SessionStart", bc.Event)
	}
	if bc.Worker != "cmux-SRF1" || bc.Task != "task-x" {
		t.Errorf("breadcrumb worker/task = %q/%q, want cmux-SRF1/task-x", bc.Worker, bc.Task)
	}
	if bc.Error == "" {
		t.Error("breadcrumb error is empty — nothing to diagnose")
	}
	if bc.Unix == 0 {
		t.Error("breadcrumb unix ts is zero")
	}
}

// The fail-safe contract holds even when the breadcrumb itself can't be written:
// an unwritable state dir → exit 0, empty stdout, no crash.
func TestHookBreadcrumbUnwritableDirStaysFailSafe(t *testing.T) {
	srv := claimFailServer(t)

	// Point the config dir at a FILE so MkdirAll under it fails → the breadcrumb
	// write is impossible.
	tmp := t.TempDir()
	file := filepath.Join(tmp, "not-a-dir")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	setHookEnv(t, file, "task-x", "SRF2")
	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxHook(w, globals{}, ctx, []string{"SessionStart"}); code != exitOK {
		t.Fatalf("exit = %d, want 0 despite an unwritable breadcrumb dir", code)
	}
	if so.Len() != 0 {
		t.Errorf("stdout = %q, want empty", so.String())
	}
	if _, ok := readHookBreadcrumb("cmux-SRF2"); ok {
		t.Error("breadcrumb unexpectedly readable under an unwritable dir")
	}
}

// A healthy claim clears a stale breadcrumb, so status reflects CURRENT health
// (present iff the most recent hook action failed).
func TestHookBreadcrumbClearedOnHealthyClaim(t *testing.T) {
	dir := t.TempDir()
	setHookEnv(t, dir, "task-ok", "SRF3")
	writeHookBreadcrumb("PreToolUse", "cmux-SRF3", "task-ok", "old failure")
	if _, ok := readHookBreadcrumb("cmux-SRF3"); !ok {
		t.Fatal("seed breadcrumb not written")
	}

	srv, _ := newHookServer(t, []bool{false}, 1) // claim succeeds
	setHookEnv(t, dir, "task-ok", "SRF3")        // re-point config dir at the shared dir
	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxHook(w, globals{}, ctx, []string{"SessionStart"}); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if _, ok := readHookBreadcrumb("cmux-SRF3"); ok {
		t.Error("healthy claim did not clear the stale breadcrumb")
	}
}

// readHookBreadcrumb reports ok=false when there is nothing to show.
func TestReadHookBreadcrumbAbsent(t *testing.T) {
	dir := t.TempDir()
	userConfigDir = func() (string, error) { return dir, nil }
	if _, ok := readHookBreadcrumb("cmux-none"); ok {
		t.Error("readHookBreadcrumb reported ok for a missing breadcrumb")
	}
}
