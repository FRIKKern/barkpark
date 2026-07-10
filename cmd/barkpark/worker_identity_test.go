package main

import (
	"os"
	"testing"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// workerIdentity() delegates to taskboard.CmuxWorkerID() — the single
// honored-everywhere derivation. The desk TUI must claim/close a task with the
// SAME id the interactive board and the `bp cmux` hook use, or a raw cmux pane
// self-fences (hook claims cmux-<surface>, desk closes tui-<host> → 409).
//
// CRITICAL: BARKPARK_WORKER_ID is left unset here. With it exported the old
// hand-copied clone and CmuxWorkerID() agree and the bug hides — the
// missing-override cmux pane is the whole regression.

// Inside a raw cmux pane (CMUX_SURFACE_ID set, BARKPARK_WORKER_ID unset) the
// desk id is cmux-<surface>, matching the hook — the old clone returned
// tui-<host> here.
func TestWorkerIdentityInCmuxPane(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "srf_desk")

	if got := workerIdentity(); got != "cmux-srf_desk" {
		t.Fatalf("workerIdentity() in a cmux pane = %q, want cmux-srf_desk", got)
	}
	if workerIdentity() != taskboard.CmuxWorkerID() {
		t.Fatalf("workerIdentity()=%q diverged from taskboard.CmuxWorkerID()=%q", workerIdentity(), taskboard.CmuxWorkerID())
	}
}

// Outside cmux entirely, the historic tui-<hostname> convention is unchanged.
func TestWorkerIdentityOutsideCmuxUnchanged(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")

	host, err := os.Hostname()
	want := "tui-"
	if err == nil && host != "" {
		want = "tui-" + host
	}
	if got := workerIdentity(); got != want {
		t.Fatalf("workerIdentity() outside cmux = %q, want %q", got, want)
	}
}
