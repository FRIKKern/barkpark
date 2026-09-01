package cli

// The CLAIM half of `bp task close`'s read-back.
//
// THE DEFECT THESE PIN. `close` refused every ordinary close of a claimed task
// with "the row is sealed but <worker> STILL HOLDS the claim — the close
// half-landed … close again", because it read a NAMED WORKER on the stored
// claim as a live lease. The server never releases the claim on a close: it
// keeps `claim.worker` as the attribution and stamps `closed_by` + `closed_at`
// beside it in the same atomic write as the seal. So the refusal fired on the
// normal post-close shape, and its own remedy ("close again") would 409 on an
// already-terminal row.
//
// Two properties are pinned here, and they pull in opposite directions on
// purpose — a fix for one that broke the other would be worse than the bug:
//
//   1. a sealed row carrying the close-out stamp is a LANDED close (exit 0),
//      confirmed on the FIRST read with no retry spent;
//   2. a sealed row whose claim carries NO stamp is still a half-landed close
//      and still exits non-zero — after one bounded re-read, never instead of
//      the refusal.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// cpClaimState is one claim shape the fake store hands back on a read-back.
type cpClaimState struct {
	worker   string
	closedBy string
}

// claimReadbackServer serves `task close` against a store whose GET answers walk
// `reads` in order, the last entry repeating forever. That is the only way to
// express a claim that is live on one read and gone on the next without a real
// race — the shape the CLI has to survive.
//
// It returns the count of READ-BACK GETs, so a test can prove both that the
// second look happened and that it was not spent when the first read already
// settled the question.
func claimReadbackServer(t *testing.T, reads []cpClaimState) *int32 {
	t.Helper()
	var gets int32

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/close"):
			_, _ = w.Write([]byte(`{"ok":true}`))

		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			n := int(atomic.AddInt32(&gets, 1)) - 1
			if n >= len(reads) {
				n = len(reads) - 1
			}
			state := reads[n]
			claim := map[string]any{"epoch": 9}
			if state.worker != "" {
				claim["worker"] = state.worker
			}
			if state.closedBy != "" {
				claim["closed_by"] = state.closedBy
				claim["closed_at"] = "2026-09-01T20:41:44.493753Z"
			}
			body, _ := json.Marshal(map[string]any{"ok": true, "doc": map[string]any{
				"doc_id":           "bp-task-x",
				"status":           "published",
				"lifecycle_status": "done",
				"content":          map[string]any{"acceptance_criteria": []any{}},
				"claim":            claim,
			}})
			_, _ = w.Write(body)

		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalClosePulseManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "cp-stub")
	// The second look is a real sleep in production. Zero it here so both arms
	// run at test speed — the BEHAVIOUR under test is the extra read, never the
	// wait in front of it.
	old := closeClaimRecheckDelay
	closeClaimRecheckDelay = 0
	t.Cleanup(func() { closeClaimRecheckDelay = old })
	return &gets
}

// THE REPORTED BUG, in its exact production shape: the store seals the row and
// KEEPS the claim, stamped closed_by/closed_at. That is a landed close and must
// print the receipt, on the FIRST read — spending a retry on a question the
// stamp already answered would be a slower way of not understanding it.
func TestTaskCloseExecute_SealedRowKeepingItsStampedClaimIsLanded(t *testing.T) {
	gets := claimReadbackServer(t, []cpClaimState{{worker: "w", closedBy: "w"}})

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "9", "done", "shipped it"})

	if code != exitOK {
		t.Fatalf("exit = %d, want 0 — a sealed row that kept its stamped claim IS a landed close; out:\n%s", code, out)
	}
	if strings.Contains(out, "STILL HOLDS the claim") || strings.Contains(out, "NOT confirmed") {
		t.Errorf("the receipt refused a landed close; got:\n%s", out)
	}
	if !strings.Contains(out, "the store holds it") {
		t.Errorf("the receipt does not print the close receipt; got:\n%s", out)
	}
	if n := atomic.LoadInt32(gets); n != 1 {
		t.Errorf("read-back GETs = %d, want 1 — the close-out stamp settles it on the first read", n)
	}
}

// The timing arm: a store whose FIRST read still shows the lease and whose
// SECOND shows it gone. One bounded re-read turns that into the receipt it is,
// instead of a refusal whose own remedy ("close again") 409s.
func TestTaskCloseExecute_ClaimGoneOnTheSecondReadIsNotHalfLanded(t *testing.T) {
	gets := claimReadbackServer(t, []cpClaimState{
		{worker: "w"}, // first read: sealed, lease still standing, no stamp
		{},            // second read: the lease is gone
	})

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "9", "done", "shipped it"})

	if code != exitOK {
		t.Fatalf("exit = %d, want 0 — the second read found the claim released; out:\n%s", code, out)
	}
	if strings.Contains(out, "half-landed") {
		t.Errorf("the receipt declared a half-landed close the store does not hold; got:\n%s", out)
	}
	if !strings.Contains(out, "the store holds it") {
		t.Errorf("the receipt does not print the close receipt; got:\n%s", out)
	}
	if n := atomic.LoadInt32(gets); n != 2 {
		t.Errorf("read-back GETs = %d, want 2 — exactly one second look", n)
	}
}

// THE COUNTERWEIGHT. A claim that is still standing, unstamped, after the second
// look is a GENUINE half-landed close and must still refuse, non-zero, naming
// the holder. The retry buys one more read; it must never buy a pass.
func TestTaskCloseExecute_ClaimStillLiveAfterTheRetryStillRefuses(t *testing.T) {
	gets := claimReadbackServer(t, []cpClaimState{{worker: "someone-else"}})

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "9", "done", "shipped it"})

	if code == exitOK {
		t.Fatalf("a sealed row whose lease never settled exited 0 — the retry laundered a real refusal; out:\n%s", out)
	}
	for _, want := range []string{"STILL HOLDS the claim", "someone-else"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q; got:\n%s", want, out)
		}
	}
	if n := atomic.LoadInt32(gets); n != 2 {
		t.Errorf("read-back GETs = %d, want 2 — the refusal is printed only after the second look", n)
	}
}

// A close-out stamp naming SOMEBODY ELSE settles nothing about this close: an
// older stamp left by a previous close-then-reopen cycle must not vouch for a
// lease this close failed to settle.
func TestTaskCloseExecute_ForeignCloseOutStampDoesNotSettleThisClaim(t *testing.T) {
	claimReadbackServer(t, []cpClaimState{{worker: "someone-else", closedBy: "an-older-closer"}})

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "9", "done", "shipped it"})

	if code == exitOK {
		t.Fatalf("a stamp naming another worker was read as this close's own; out:\n%s", out)
	}
	if !strings.Contains(out, "STILL HOLDS the claim") {
		t.Errorf("output missing the half-landed refusal; got:\n%s", out)
	}
}
