package cli

// Execute-level proofs for the close/pulse read-back: the STORE is the
// authority, driven through the real dispatch against a fake Barkpark.
//
// THE STATUS CODE CARRIES NO INFORMATION ABOUT WHETHER THE WRITE LANDED. This
// system has produced all three of these, and each is a mode below:
//
//	200 + LOST    the server answers a normal envelope and writes nothing
//	500 + LANDED  the transaction commits, then the RESPONSE fails
//	500 + LOST    the ordinary genuine failure
//
// Only the read-back can tell them apart, which is why a test that exercises
// only the happy path re-certifies the bug instead of catching it.

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// minimalClosePulseManifest carries ONLY `task close` and `task pulse`, so the
// Execute path can be driven without depending on the repo-wide fixture.
const minimalClosePulseManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "read",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.close", "noun": "task", "verb": "close", "summary": "close",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/close"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"},
        {"name": "observed_epoch", "required": true, "type": "int", "summary": "e"},
        {"name": "lifecycle_status", "required": false, "type": "string", "summary": "seal"},
        {"name": "reason", "required": false, "type": "string", "summary": "why"}
      ],
      "flags": [{"name": "set", "type": "string", "summary": "extra"}],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    },
    {
      "id": "task.pulse", "noun": "task", "verb": "pulse", "summary": "pulse",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/pulse"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"}
      ],
      "flags": [
        {"name": "now", "type": "string", "summary": "now-line"},
        {"name": "criterion", "type": "int", "summary": "idx"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// cpStoreMode decides what the fake Barkpark's STORE does with a write it
// answers. Only Honest and Store500Landed actually commit.
type cpStoreMode int

const (
	// cpHonest applies the write, so a second read finds it.
	cpHonest cpStoreMode = iota
	// cpDrops answers 200 with a normal envelope and writes NOTHING — the
	// 200 + LOST case, the silent non-landing this read-back exists for.
	cpDrops
	// cpUnreadable answers the POST 200 but fails the read-back: neither
	// verdict is available, so the verb must report UNCONFIRMED.
	cpUnreadable
	// cp500Landed answers the POST 500 but COMMITS — the 500 + LANDED case.
	cp500Landed
	// cp500Absent answers the POST 500 and writes nothing — 500 + LOST.
	cp500Absent
	// cp409StaleClaimLanded answers the close 409 `stale_claim` but COMMITS —
	// the shape measured on five real closes: the row stored, with its own
	// reason verbatim, while the CLI exited 6.
	cp409StaleClaimLanded
	// cp409StaleClaimAbsent answers 409 `stale_claim` and writes nothing — the
	// ordinary lost race, which must stay a failure.
	cp409StaleClaimAbsent
)

// cpDecodeBody reads the flat string map the CLI dispatch POSTs. Every value the
// manifest binds arrives here as a JSON string, so a fixture that reads the
// query string sees nothing and quietly falls back to its own defaults.
func cpDecodeBody(r *http.Request) map[string]string {
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		return nil
	}
	var body map[string]string
	if json.Unmarshal(raw, &body) != nil {
		return nil
	}
	return body
}

// cpStore is the fake server's state: exactly what a write actually put there.
type cpStore struct {
	mu        sync.Mutex
	lifecycle string
	worker    string
	epoch     int
	now       string
	// closedBy/closedAt are the CLOSE-OUT STAMP. The real server does not
	// delete the claim when it seals a row — Tasks.Close.apply_close_update/9
	// keeps `claim.worker` as the attribution and stamps these two onto the
	// same map in the same atomic write. Modelling the close as "the claim
	// disappears" is what let a receipt that refuses every sealed-and-named row
	// pass its own suite.
	closedBy string
	closedAt string
	// closeReason is `content.close_reason` — where the server puts the close's
	// `reason`. It is the only field that can identify WHOSE close a sealed row
	// holds, so a fixture without it cannot express "the row stored MY close".
	closeReason string
}

// cpTestServer wires a fake Barkpark that counts POSTs to the close/pulse
// routes, mutates its store only when the mode commits, and serves the task
// back on GET /v1/tasks/:id — the read-back the verbs now perform.
func cpTestServer(t *testing.T, mode cpStoreMode) (*cpStore, *int32) {
	t.Helper()
	// The ledger-write retry (tasks_write_retry.go) waits 0.5s/1.5s/4s between
	// attempts against a 5xx. This suite is about the READ-BACK, not the
	// schedule (ledger_write_retry_test.go owns that), so the waits are stubbed
	// out — otherwise every 500-mode case here would spend six real seconds.
	realSleep := ledgerSleep
	ledgerSleep = func(time.Duration) {}
	t.Cleanup(func() { ledgerSleep = realSleep })

	var hits int32
	// The row starts OPEN, claimed by "w", with no now-line: the state a task
	// is in before either verb runs.
	st := &cpStore{lifecycle: "open", worker: "w", epoch: 1}

	commits := mode == cpHonest || mode == cp500Landed || mode == cp409StaleClaimLanded
	fails := mode == cp500Landed || mode == cp500Absent
	staleClaims := mode == cp409StaleClaimLanded || mode == cp409StaleClaimAbsent

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/close"):
			atomic.AddInt32(&hits, 1)
			if commits {
				// The dispatch sends the close's args as a JSON BODY, not as
				// query params — reading them off the URL is how this fixture
				// silently defaulted its way to a green.
				body := cpDecodeBody(r)
				seal := body["lifecycle_status"]
				if seal == "" {
					seal = "done"
				}
				st.mu.Lock()
				st.lifecycle = seal
				// The claim map SURVIVES, exactly as the server leaves it: the
				// worker stays as the attribution and the close-out stamp is
				// added beside it.
				st.closedBy = body["worker_id"]
				st.closedAt = "2026-09-01T20:41:44.493753Z"
				st.closeReason = body["reason"]
				st.mu.Unlock()
			}
			if staleClaims {
				// The tasks controller's 409 shape: {"ok":false,"reason":…}.
				// It is answered AFTER the commit above, which is the whole
				// point — the status code says nothing about the write.
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"stale_claim","message":"epoch 1 is stale"}`))
				return
			}
			if fails {
				// The write (if this mode commits one) already happened above —
				// the transaction commits, THEN the response fails.
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":{"code":"internal_error","message":"boom"}}`))
				return
			}
			_, _ = w.Write([]byte(`{"ok":true}`))

		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/pulse"):
			atomic.AddInt32(&hits, 1)
			if commits {
				st.mu.Lock()
				st.now = r.URL.Query().Get("now")
				st.epoch++
				st.mu.Unlock()
			}
			if fails {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":{"code":"internal_error","message":"boom"}}`))
				return
			}
			_, _ = w.Write([]byte(`{"ok":true}`))

		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			if mode == cpUnreadable {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"store_unreachable"}`))
				return
			}
			st.mu.Lock()
			content := map[string]any{"acceptance_criteria": []any{}}
			if st.closeReason != "" {
				content["close_reason"] = st.closeReason
			}
			doc := map[string]any{
				"doc_id":           "bp-task-x",
				"status":           "published",
				"lifecycle_status": st.lifecycle,
				"content":          content,
			}
			// The claim rides the TOP LEVEL, exactly as render_doc emits it —
			// it is deleted out of content server-side.
			claim := map[string]any{"worker": st.worker, "epoch": st.epoch}
			if st.closedBy != "" {
				claim["closed_by"] = st.closedBy
				claim["closed_at"] = st.closedAt
			}
			if st.now != "" {
				claim["now"] = map[string]any{"text": st.now, "ts": "2026-08-24T10:00:00Z"}
			}
			doc["claim"] = claim
			st.mu.Unlock()
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
	return st, &hits
}

// --- close ---

// 200 + LOST. THE SPINE: a server that answers the close 200 with a normal
// envelope and writes NOTHING must NOT produce exit 0. Delete the read-back and
// this test goes green-with-exit-0 → red.
func TestTaskCloseExecute_DroppedWriteIsNotSuccess(t *testing.T) {
	_, hits := cpTestServer(t, cpDrops)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "done", "shipped it"})

	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("close POST fired %d times, want 1", n)
	}
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — a close the store never took is not a success; out:\n%s",
			code, exitConflict, out)
	}
	for _, want := range []string{"NOT confirmed", `"done"`, "lifecycle_status=open"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q; got:\n%s", want, out)
		}
	}
}

// The honest counterpart: a store that TOOK the write confirms it, exit 0.
func TestTaskCloseExecute_LandedWriteIsConfirmedByTheStore(t *testing.T) {
	cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "done", "shipped it"})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if !strings.Contains(out, "the store holds it") || !strings.Contains(out, "lifecycle_status=done") {
		t.Errorf("receipt should report the STORED seal; got:\n%s", out)
	}
}

// A read-back that cannot reach the store is UNCONFIRMED, never a success:
// "we could not ask" is not "it landed".
func TestTaskCloseExecute_UnreadableStoreIsUnconfirmedNotSuccess(t *testing.T) {
	cpTestServer(t, cpUnreadable)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "done", "shipped it"})

	if code == exitOK {
		t.Fatalf("exit = 0 on an unverifiable close — the verb reported success on an exit code alone; out:\n%s", out)
	}
	if !strings.Contains(out, "NOT confirmed") {
		t.Errorf("output should say the close is unconfirmed; got:\n%s", out)
	}
}

// 500 + LANDED. A 500 is NOT proof the write is absent: the transaction can
// commit and the response still fail. The read-back finds the seal and the verb
// exits 0. Delete the rc==exitServer arm and this goes red (rc stops at 8).
func TestTaskCloseExecute_ServerErrorThatLandedIsConfirmedSuccess(t *testing.T) {
	cpTestServer(t, cp500Landed)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "done", "shipped it"})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — the read-back confirmed the seal landed despite the 5xx; out:\n%s", code, out)
	}
	if !strings.Contains(out, "despite the POST answering a server error") {
		t.Errorf("receipt should name the surprising 5xx it survived; got:\n%s", out)
	}
}

// 500 + LOST. The ordinary genuine failure must still report failure — and now
// as a STORE-CONFIRMED absence, not a bare unconfirmed transport error.
func TestTaskCloseExecute_ServerErrorThatDidNotLandStaysAFailure(t *testing.T) {
	cpTestServer(t, cp500Absent)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "done", "shipped it"})

	if code == exitOK {
		t.Fatalf("a 500 whose write never landed exited 0; out:\n%s", out)
	}
	if !strings.Contains(out, "lifecycle_status=open") {
		t.Errorf("receipt should report the STORED (unchanged) seal; got:\n%s", out)
	}
}

// --- pulse ---

// 200 + LOST for the now-line.
func TestTaskPulseExecute_DroppedWriteIsNotSuccess(t *testing.T) {
	_, hits := cpTestServer(t, cpDrops)

	out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-x", "w", "--now", "warm-up pinned, rerunning"})

	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("pulse POST fired %d times, want 1", n)
	}
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — a now-line the board never got is not a success; out:\n%s",
			code, exitConflict, out)
	}
	for _, want := range []string{"NOT confirmed", "warm-up pinned", "now-line <none>"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q; got:\n%s", want, out)
		}
	}
}

func TestTaskPulseExecute_LandedWriteIsConfirmedByTheStore(t *testing.T) {
	cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-x", "w", "--now", "warm-up pinned, rerunning"})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if !strings.Contains(out, "the store holds it") || !strings.Contains(out, "warm-up pinned") {
		t.Errorf("receipt should report the STORED now-line; got:\n%s", out)
	}
}

func TestTaskPulseExecute_UnreadableStoreIsUnconfirmedNotSuccess(t *testing.T) {
	cpTestServer(t, cpUnreadable)

	out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-x", "w", "--now", "warm-up pinned, rerunning"})

	if code == exitOK {
		t.Fatalf("exit = 0 on an unverifiable pulse; out:\n%s", out)
	}
	if !strings.Contains(out, "NOT confirmed") {
		t.Errorf("output should say the pulse is unconfirmed; got:\n%s", out)
	}
}

// 500 + LANDED for the now-line.
func TestTaskPulseExecute_ServerErrorThatLandedIsConfirmedSuccess(t *testing.T) {
	cpTestServer(t, cp500Landed)

	out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-x", "w", "--now", "warm-up pinned, rerunning"})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — the read-back confirmed the now-line landed despite the 5xx; out:\n%s", code, out)
	}
	if !strings.Contains(out, "despite the POST answering a server error") {
		t.Errorf("receipt should name the surprising 5xx it survived; got:\n%s", out)
	}
}

// 500 + LOST for the now-line.
func TestTaskPulseExecute_ServerErrorThatDidNotLandStaysAFailure(t *testing.T) {
	cpTestServer(t, cp500Absent)

	out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-x", "w", "--now", "warm-up pinned, rerunning"})

	if code == exitOK {
		t.Fatalf("a 500 whose now-line never landed exited 0; out:\n%s", out)
	}
	if !strings.Contains(out, "now-line <none>") {
		t.Errorf("receipt should report the STORED (absent) now-line; got:\n%s", out)
	}
}
