package cli

// tasks_close_receipt_readback_test.go — the receipt of `bp task close` is
// rendered from a READ, never from the request.
//
// THE FILING. A close was reported to print
//
//	✓ the store holds it — lifecycle_status=cancelled
//
// for a close that did not persist, the sentence rendered from the REQUEST.
// Measured on origin/main 912136444 before this change, that half is already
// closed: renderCloseVerdict is pure over the row FetchSeal handed back, and a
// fake that answers 2xx to the POST while its store still reads `open` already
// exits non-zero naming the stored value. Arms 1 and 2 here PIN that — they are
// the regression fence for the sentence the filing named, and they are green
// on main by construction.
//
// WHAT WAS STILL OPEN, and what arms 3 and 4 drive: the case where the store
// does not answer AT ALL. `bp task stamp` had one bounded second look and, when
// both reads failed, said "✗ NOT confirmed". `bp task close` had NEITHER: one
// unlucky GET and it printed "the seal may or may not have landed" — the exact
// hedge this verb exists to remove — and it never asked twice. Both arms below
// are RED on origin/main:
//
//	--- FAIL: TestTaskCloseReceipt_UnreadableStoreSaysUnverifiedNotMaybe
//	    the receipt hedges with "may or may not have landed"
//	--- FAIL: TestTaskCloseReceipt_OneLostReadIsRetriedNotHedged
//	    exit = 1, want 0 … read-back GETs = 1, want 2

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

// closeReceiptServer is a fake Barkpark whose POST /close ALWAYS answers 2xx —
// the accepted-but-not-persisted world — while its GET is driven independently.
//
// failReads is how many read-backs answer 500 before the store starts
// answering; storedSeal is the lifecycle_status the store actually holds (empty
// = the row names no lifecycle_status at all, i.e. the write persisted
// nothing). It returns the read-back GET count so a test can prove how many
// looks were spent.
func closeReceiptServer(t *testing.T, failReads int, storedSeal string) *int32 {
	t.Helper()
	var gets int32

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/close"):
			// ACCEPTED. The transport says yes to every close, always.
			_, _ = w.Write([]byte(`{"ok":true}`))

		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			if int(atomic.AddInt32(&gets, 1)) <= failReads {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"ok":false,"error":"read replica unavailable"}`))
				return
			}
			doc := map[string]any{
				"doc_id":  "bp-task-x",
				"status":  "published",
				"content": map[string]any{"acceptance_criteria": []any{}},
				"claim":   map[string]any{"epoch": 9, "worker": "w", "closed_by": "w", "closed_at": "2026-09-01T20:41:44Z"},
			}
			if storedSeal != "" {
				doc["lifecycle_status"] = storedSeal
			}
			body, _ := json.Marshal(map[string]any{"ok": true, "doc": doc})
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
	// Both second looks are real sleeps in production. Zero them: the BEHAVIOUR
	// under test is the extra read, never the wait in front of it.
	oldClaim, oldRead := closeClaimRecheckDelay, closeReadbackRetryDelay
	closeClaimRecheckDelay, closeReadbackRetryDelay = 0, 0
	t.Cleanup(func() { closeClaimRecheckDelay, closeReadbackRetryDelay = oldClaim, oldRead })
	return &gets
}

func closeCancelledArgs() []string {
	return []string{"task", "close", "bp-task-x", "w", "9", "cancelled", "not doing it"}
}

// ARM 1 — the filing's own sentence, in its own words. The POST is accepted and
// the store persists a DIFFERENT lifecycle. The receipt must not say the store
// holds a `cancelled` it does not hold, and it must name what the row actually
// reads.
func TestTaskCloseReceipt_AcceptedButPersistedADifferentLifecycleRefuses(t *testing.T) {
	closeReceiptServer(t, 0, "in_progress")

	out, code := captureExecuteCode(t, closeCancelledArgs())

	if code == exitOK {
		t.Fatalf("exit = 0 on a close the store did not persist — the receipt is rendered from the request; out:\n%s", out)
	}
	if strings.Contains(out, "the store holds it — lifecycle_status=cancelled") {
		t.Errorf("THE FILED SENTENCE: the receipt claims a seal the store does not hold; out:\n%s", out)
	}
	// The observed lifecycle has to be IN the message — a refusal that does not
	// say what the row reads sends the operator back for another round trip.
	if !strings.Contains(out, "in_progress") {
		t.Errorf("the refusal does not name the lifecycle the store actually holds; out:\n%s", out)
	}
	if !strings.Contains(out, `expected lifecycle_status: "cancelled"`) {
		t.Errorf("the refusal does not name what was asked for; out:\n%s", out)
	}
}

// ARM 2 — accepted and persisted NOTHING: the row names no lifecycle_status at
// all. The receipt must still refuse, and must not paper the empty value over
// with the requested one.
func TestTaskCloseReceipt_AcceptedButPersistedNothingRefuses(t *testing.T) {
	closeReceiptServer(t, 0, "")

	out, code := captureExecuteCode(t, closeCancelledArgs())

	if code == exitOK {
		t.Fatalf("exit = 0 on a close that persisted nothing; out:\n%s", out)
	}
	if strings.Contains(out, "the store holds it — lifecycle_status=cancelled") {
		t.Errorf("the receipt claims a seal off the request; out:\n%s", out)
	}
	if !strings.Contains(out, "the server named no lifecycle_status") {
		t.Errorf("the refusal does not say the stored row carries no lifecycle_status; out:\n%s", out)
	}
}

// ARM 3 — RED ON origin/main. The store never answers. Two reads, both 500.
// "UNVERIFIED" is the only honest word: no row was read, so the receipt makes
// no claim in EITHER direction — and it must not tell the operator to close
// again, because a second close of a sealed row 409s `not_ready`.
func TestTaskCloseReceipt_UnreadableStoreSaysUnverifiedNotMaybe(t *testing.T) {
	gets := closeReceiptServer(t, 99, "cancelled")

	out, code := captureExecuteCode(t, closeCancelledArgs())

	if code == exitOK {
		t.Fatalf("exit = 0 with no read at all; out:\n%s", out)
	}
	if strings.Contains(out, "✓") {
		t.Errorf("a ✓ was printed for a close nothing confirmed; out:\n%s", out)
	}
	if !strings.Contains(out, "UNVERIFIED") {
		t.Errorf("the receipt does not say UNVERIFIED; out:\n%s", out)
	}
	if strings.Contains(out, "may or may not have landed") {
		t.Errorf("the receipt hedges with \"may or may not have landed\" — the exact ambiguity the read-back exists to remove; out:\n%s", out)
	}
	if !strings.Contains(out, "not_ready") {
		t.Errorf("the receipt does not warn that closing again 409s `not_ready`; out:\n%s", out)
	}
	if n := atomic.LoadInt32(gets); n != 2 {
		t.Errorf("read-back GETs = %d, want 2 — exactly one bounded second look", n)
	}
}

// ARM 4 — RED ON origin/main, the counterweight to arm 3. ONE lost read is a
// race, not an unanswerable store. The second look finds the seal and the close
// is confirmed, from that read.
func TestTaskCloseReceipt_OneLostReadIsRetriedNotHedged(t *testing.T) {
	gets := closeReceiptServer(t, 1, "cancelled")

	out, code := captureExecuteCode(t, closeCancelledArgs())

	if code != exitOK {
		t.Fatalf("exit = %d, want 0 — the second read found the seal; out:\n%s", code, out)
	}
	if strings.Contains(out, "UNVERIFIED") {
		t.Errorf("one lost read was reported as an unreadable store; out:\n%s", out)
	}
	if !strings.Contains(out, "the store holds it — lifecycle_status=cancelled") {
		t.Errorf("the confirmed receipt is missing; out:\n%s", out)
	}
	if n := atomic.LoadInt32(gets); n != 2 {
		t.Errorf("read-back GETs = %d, want 2", n)
	}
}

// ARM 5 — the same shape on `bp task stamp`, in its HUMAN output. The row named
// stamp as a suspect ("the store holds it — met=true" over a later met=false).
// It is NOT: confirmStampLanded reads the criterion back and renderStampVerdict
// prints from that row. Pinned here so the pair cannot drift apart — the fake
// answers 200 to the POST and writes nothing (applyStamp:false).
func TestTaskStampReceipt_AcceptedButNotPersistedRefusesInHumanOutput(t *testing.T) {
	s := &stampReceiptServer{criteria: plainRow(), applyStamp: false}
	s.start(t)

	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-r", "w", "1",
		"--criterion", "0", "--met", "--evidence", "run output",
		"--criterion-text", "the suite is green",
	})

	if code == exitOK {
		t.Fatalf("exit = 0 on a stamp the store dropped; out:\n%s", out)
	}
	if strings.Contains(out, "✓ the store holds it") {
		t.Errorf("the stamp receipt claims a met the store does not hold; out:\n%s", out)
	}
	if !strings.Contains(out, "NOT stored") {
		t.Errorf("the refusal does not say the stamp is not stored; out:\n%s", out)
	}
}

// ARM 6 — RED ON origin/main. THE ONE GENUINE accepted-but-not-persisted 2xx
// this server still produces, reproduced against the api code that makes it.
//
// `Tasks.Close.close_with_receipt/3` answers `{:already_closed, doc}` — a 200
// that writes NOTHING — whenever the row is terminal and `idempotent_replay?/3`
// (api/lib/barkpark/tasks/close.ex:565) says yes. That predicate compares
// `claim.closed_by == worker` and `lifecycle_status == new_status`, and NOTHING
// ELSE: the reason is absent from it. So a same-worker replay to the same seal
// carrying a DIFFERENT reason is accepted and the store keeps the FIRST close's
// reason verbatim.
//
// The fake below IS that server: 200 on the POST, and a store already sealed by
// the same worker holding somebody else's sentence. The seal is real, so this
// must NOT refuse — a re-close would 409 `not_ready`. But the receipt must say
// the reason is not the caller's, or the caller reads their own words back out
// of a row that never took them.
func TestTaskCloseReceipt_IdempotentReplayNamesTheReasonThatDidNotLand(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/close"):
			// The `:already_closed` receipt: 200, no write.
			_, _ = w.Write([]byte(`{"ok":true,"already_closed":true}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			body, _ := json.Marshal(map[string]any{"ok": true, "doc": map[string]any{
				"doc_id":           "bp-task-x",
				"status":           "published",
				"lifecycle_status": "cancelled",
				"content": map[string]any{
					"acceptance_criteria": []any{},
					"close_reason":        "superseded by the earlier attempt",
				},
				"claim": map[string]any{"epoch": 9, "worker": "w", "closed_by": "w", "closed_at": "2026-09-01T20:41:44Z"},
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
	oldClaim, oldRead := closeClaimRecheckDelay, closeReadbackRetryDelay
	closeClaimRecheckDelay, closeReadbackRetryDelay = 0, 0
	t.Cleanup(func() { closeClaimRecheckDelay, closeReadbackRetryDelay = oldClaim, oldRead })

	out, code := captureExecuteCode(t, closeCancelledArgs())

	// The seal IS on the ledger — refusing would send the operator into a
	// re-close that 409s `not_ready`.
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 — the seal genuinely landed; a refusal here manufactures a `not_ready` retry; out:\n%s", code, out)
	}
	if !strings.Contains(out, "YOUR REASON DID NOT") {
		t.Errorf("the receipt does not say the caller's reason never landed; out:\n%s", out)
	}
	if !strings.Contains(out, "superseded by the earlier attempt") {
		t.Errorf("the receipt does not quote the reason the store ACTUALLY holds; out:\n%s", out)
	}
	if !strings.Contains(out, "not_ready") {
		t.Errorf("the receipt does not warn against re-closing; out:\n%s", out)
	}
}

// ARM 7 — the counterweight to arm 6. A close whose reason DID land says
// nothing extra. The divergence line must fire on divergence, not on every
// close with a reason.
func TestTaskCloseReceipt_MatchingReasonPrintsNoDivergenceLine(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/close"):
			_, _ = w.Write([]byte(`{"ok":true}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			body, _ := json.Marshal(map[string]any{"ok": true, "doc": map[string]any{
				"doc_id":           "bp-task-x",
				"status":           "published",
				"lifecycle_status": "cancelled",
				"content": map[string]any{
					"acceptance_criteria": []any{},
					"close_reason":        "not doing it",
				},
				"claim": map[string]any{"epoch": 9, "worker": "w", "closed_by": "w", "closed_at": "2026-09-01T20:41:44Z"},
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
	oldClaim, oldRead := closeClaimRecheckDelay, closeReadbackRetryDelay
	closeClaimRecheckDelay, closeReadbackRetryDelay = 0, 0
	t.Cleanup(func() { closeClaimRecheckDelay, closeReadbackRetryDelay = oldClaim, oldRead })

	out, code := captureExecuteCode(t, closeCancelledArgs())

	if code != exitOK {
		t.Fatalf("exit = %d, want 0; out:\n%s", code, out)
	}
	if strings.Contains(out, "YOUR REASON DID NOT") {
		t.Errorf("the divergence line fired on a close whose reason DID land; out:\n%s", out)
	}
}
