package taskboard

import (
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// The self-fence bug this slice fixes: in a raw cmux pane (CMUX_SURFACE_ID set,
// BARKPARK_WORKER_ID NOT exported — the exact tier-2 pane the `bp cmux` hook
// exists for) the `bp cmux` hook CLAIMS a task as cmux-<surface>, but the
// interactive board used to CLOSE via cmux-blind ResolveWorker() → tui-<host>,
// so the server fenced the pane's own close off (409 fenced_off). These tests
// pin that both the claim ('c') and close ('x') verbs now speak the pane id
// CmuxWorkerID() derives — and that outside cmux the historic tui-<host>
// convention is unchanged.
//
// CRITICAL: these tests set ONLY CMUX_SURFACE_ID and leave BARKPARK_WORKER_ID
// unset. With BARKPARK_WORKER_ID exported (as the other reducer tests do), every
// derivation agrees and the bug hides — the missing-override combination is the
// whole point.

// cmuxPaneEnv clears the worker override and cmux vars, then sets exactly
// CMUX_SURFACE_ID — the fence-prone tier-2 pane. t.Setenv restores all three.
func cmuxPaneEnv(t *testing.T, surface string) {
	t.Helper()
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("CMUX_SURFACE_ID", surface)
}

// c on a ready row inside a raw cmux pane claims as cmux-<surface>, matching the
// hook — NOT the cmux-blind tui-<host> that fenced the pane off.
func TestClaimInCmuxPaneUsesPaneWorkerID(t *testing.T) {
	cmuxPaneEnv(t, "srf_selffence")
	if got := CmuxWorkerID(); got != "cmux-srf_selffence" {
		t.Fatalf("precondition: CmuxWorkerID()=%q, want cmux-srf_selffence", got)
	}

	m := testModel(activeOrphans(readyTask("r1")))
	m.ui.Cursor = 1 // r1 (row 0 is the loose-bucket header)

	var gotWorker string
	m.doClaim = func(_ *apiclient.Client, docID, worker string) ActionResult {
		gotWorker = worker
		return ActionResult{OK: true, Message: "claimed"}
	}

	m, cmd := step(t, m, runes("c"))
	if cmd == nil {
		t.Fatal("c on a ready row did not fire a claim command")
	}
	cmd()
	if gotWorker != "cmux-srf_selffence" {
		t.Fatalf("board claimed as %q inside a cmux pane, want cmux-srf_selffence (the pane owns the task)", gotWorker)
	}
}

// x (double-press) on a claimed row inside a raw cmux pane closes as
// cmux-<surface> — the id that claimed it — so the CAS is same-worker and never
// self-fences.
func TestCloseInCmuxPaneUsesPaneWorkerID(t *testing.T) {
	cmuxPaneEnv(t, "srf_selffence")

	m := testModel(activeOrphans(claimedTask("c1", 7)))
	m.ui.Cursor = 1 // c1 (row 0 is the loose-bucket header)

	var gotWorker string
	var gotEpoch int
	m.doClose = func(_ *apiclient.Client, docID, worker string, epoch int, _ string) ActionResult {
		gotWorker, gotEpoch = worker, epoch
		return ActionResult{OK: true, Message: "closed"}
	}

	m, _ = step(t, m, runes("x"))    // arm
	m, cmd := step(t, m, runes("x")) // fire
	if cmd == nil {
		t.Fatal("the second x did not fire the close")
	}
	cmd()
	if gotWorker != "cmux-srf_selffence" {
		t.Fatalf("board closed as %q inside a cmux pane, want cmux-srf_selffence (must match the claiming id)", gotWorker)
	}
	if gotEpoch != 7 {
		t.Fatalf("close epoch = %d, want 7", gotEpoch)
	}
}

// Regression: outside cmux entirely (no CMUX_* env, no override) the board still
// claims and closes as tui-<hostname> — the historic convention is untouched.
func TestClaimCloseOutsideCmuxUnchanged(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")

	host, err := os.Hostname()
	wantPrefix := "tui-"
	if err == nil && host != "" {
		wantPrefix = "tui-" + host
	}

	// claim
	mc := testModel(activeOrphans(readyTask("r1")))
	mc.ui.Cursor = 1
	var claimWorker string
	mc.doClaim = func(_ *apiclient.Client, _, worker string) ActionResult {
		claimWorker = worker
		return ActionResult{OK: true}
	}
	_, cmd := step(t, mc, runes("c"))
	if cmd == nil {
		t.Fatal("c did not fire a claim outside cmux")
	}
	cmd()
	if !strings.HasPrefix(claimWorker, "tui-") || claimWorker != wantPrefix {
		t.Fatalf("claim worker outside cmux = %q, want %q", claimWorker, wantPrefix)
	}

	// close
	mx := testModel(activeOrphans(claimedTask("c1", 3)))
	mx.ui.Cursor = 1
	var closeWorker string
	mx.doClose = func(_ *apiclient.Client, _, worker string, _ int, _ string) ActionResult {
		closeWorker = worker
		return ActionResult{OK: true}
	}
	mx, _ = step(t, mx, runes("x"))
	_, cmd = step(t, mx, runes("x"))
	if cmd == nil {
		t.Fatal("second x did not fire a close outside cmux")
	}
	cmd()
	if closeWorker != wantPrefix {
		t.Fatalf("close worker outside cmux = %q, want %q", closeWorker, wantPrefix)
	}
}
