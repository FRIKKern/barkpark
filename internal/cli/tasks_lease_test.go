package cli

// Proofs for the lease receipt and the epoch-staleness explanation
// (tasks_lease.go), driven through the real dispatch against a fake Barkpark.
//
// The defect these guard is an instrument that WITHHOLDS a number and
// DOCUMENTS one that decays: `bp task claim` printed the fencing epoch and said
// nothing about when the lease lapses, and stamp/close called that epoch "the
// one returned at claim time" when every pulse advances it. Both halves are
// asserted on the OUTPUT a lead actually reads, not on the helpers.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const minimalLeaseManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "read",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.claim", "noun": "task", "verb": "claim", "summary": "claim",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/claim"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"}
      ],
      "flags": [],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    },
    {
      "id": "task.next", "noun": "task", "verb": "next", "summary": "next",
      "http": {"method": "POST", "path_template": "/v1/tasks/claim"},
      "auth_tier": "read",
      "args": [
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"}
      ],
      "flags": [],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// leaseTestServer answers every claim POST 200 with `body` verbatim.
func leaseTestServer(t *testing.T, body string) {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.Contains(r.URL.Path, "claim") {
			_, _ = w.Write([]byte(body))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalLeaseManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "lease-stub")
}

// leaseEnvelope is the shape BarkparkWeb.TasksController now returns on a
// claim/next/pulse 2xx: the doc, the server's help templates, and the ADDITIVE
// top-level `lease` object.
func leaseEnvelope(epoch int) string {
	body, _ := json.Marshal(map[string]any{
		"ok": true,
		"doc": map[string]any{
			"doc_id": "bp-task-x",
			"claim":  map[string]any{"worker": "w", "epoch": epoch},
		},
		"help": []string{"bp task pulse bp-task-x w --now \"…\""},
		"lease": map[string]any{
			"granted_at": "2026-09-02T05:05:01Z",
			"expires_at": "2026-09-02T05:50:01Z",
			"seconds":    2700,
			"minutes":    45,
		},
	})
	return string(body)
}

// --- the pure receipt ------------------------------------------------------

// The three facts ride ONE line, together. A lease printed on its own line
// below the epoch is separable from the fence it belongs to, and a dispatcher
// scanning four claim receipts reads the first line of each.
func TestLeaseLine_CarriesEpochExpiryAndMinutesTogether(t *testing.T) {
	got := leaseLine(claimLease{ExpiresAt: "2026-09-02T05:50:01Z", Minutes: 45, Seconds: 2700, Epoch: 2})
	for _, want := range []string{"epoch=2", "expires_at=2026-09-02T05:50:01Z", "lease=45min"} {
		if !strings.Contains(got, want) {
			t.Errorf("lease line %q missing %q", got, want)
		}
	}
	if strings.Contains(strings.TrimSpace(got), "\n") {
		t.Errorf("the lease receipt must be ONE line; got:\n%s", got)
	}
}

// A server too old to send `lease` must produce NO lease line. Inventing an
// expiry from a TTL the client guessed would be the same defect wearing a
// fix's clothes.
func TestLeaseFromEnvelope_SilentWithoutALease(t *testing.T) {
	if _, ok := leaseFromEnvelope([]byte(`{"ok":true,"doc":{"claim":{"epoch":2}}}`)); ok {
		t.Error("leaseFromEnvelope reported a lease on an envelope that carried none")
	}
	if _, ok := leaseFromEnvelope([]byte(`{"ok":true,"lease":{"seconds":2700,"minutes":45}}`)); ok {
		t.Error("leaseFromEnvelope reported a lease with no expires_at — the one field the receipt exists to carry")
	}
}

// --- Execute-level: what the lead actually reads ---------------------------

// THE SPINE. `bp task claim <id> <worker>` must print the lease expiry as an
// absolute UTC timestamp AND the length in minutes, on the same line as the
// epoch. Drop the emitClaimLease call in runCommand and this goes red.
func TestTaskClaimExecute_PrintsTheLeaseOnTheEpochLine(t *testing.T) {
	leaseTestServer(t, leaseEnvelope(2))
	out, code := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w"})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	assertLeaseLine(t, out)
}

// The queue claim is the SAME contract: a lead that takes work with
// `bp task next` is dispatching on the same lease.
func TestTaskNextExecute_PrintsTheLeaseOnTheEpochLine(t *testing.T) {
	leaseTestServer(t, leaseEnvelope(2))
	out, code := captureExecuteCode(t, []string{"task", "next", "w"})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	assertLeaseLine(t, out)
}

// A claim against a server that sends no `lease` prints no lease line — and
// still succeeds. The receipt degrades to what it was, never to a guess.
func TestTaskClaimExecute_OldServerPrintsNoLeaseLine(t *testing.T) {
	leaseTestServer(t, `{"ok":true,"doc":{"doc_id":"bp-task-x","claim":{"worker":"w","epoch":2}}}`)
	out, code := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w"})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if strings.Contains(out, "lease:") || strings.Contains(out, "expires_at=") {
		t.Errorf("a server that sent no lease must produce no lease line; got:\n%s", out)
	}
}

// assertLeaseLine is the shared assertion: ONE printed line carrying the epoch,
// the absolute UTC expiry and the minutes together.
func assertLeaseLine(t *testing.T, out string) {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "lease:") {
			continue
		}
		for _, want := range []string{"epoch=2", "expires_at=2026-09-02T05:50:01Z", "lease=45min"} {
			if !strings.Contains(line, want) {
				t.Errorf("lease line %q missing %q", line, want)
			}
		}
		return
	}
	t.Errorf("no lease line in the claim receipt — the lead is still guessing when the claim lapses; got:\n%s", out)
}

// --- pulse names the NEW epoch --------------------------------------------

// A pulse ADVANCES the claim epoch, and the number the next stamp/close must
// pass is the one the pulse produced. Saying so is the half that stops the
// bare 409.
func TestTaskPulseExecute_NamesTheEpochItAdvancedTo(t *testing.T) {
	// cpTestServer's row starts at epoch 1 and the pulse commits epoch++.
	cpTestServer(t, cpHonest)
	out, code := captureExecuteCode(t, []string{
		"task", "pulse", "bp-task-x", "w", "--now", "warm-up pinned, rerunning",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if !strings.Contains(out, "ADVANCED the claim epoch to 2") {
		t.Errorf("the pulse receipt must name the NEW epoch outright; got:\n%s", out)
	}
}

// --- a stale-epoch 409 names the epoch that is current now -----------------

// `bp task close` refused fenced_off used to be a bare CAS conflict. It is
// almost always the caller's OWN pulse having moved the epoch, and the CLI can
// read that number back and say so.
func TestTaskCloseExecute_FencedOffNamesTheCurrentEpoch(t *testing.T) {
	fencedOffServer(t, "w", 9)
	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "done"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, out)
	}
	if !strings.Contains(out, "epoch advanced by pulse to 9") {
		t.Errorf("a fenced_off refusal must name the epoch the store holds now; got:\n%s", out)
	}
}

// The honest limit: when the store shows a DIFFERENT holder, the refusal is
// about ownership and handing the caller an epoch would only refuse them again.
func TestTaskCloseExecute_FencedOffUnderAForeignHolderSaysSo(t *testing.T) {
	fencedOffServer(t, "someone-else", 9)
	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "done"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, out)
	}
	if strings.Contains(out, "epoch advanced by pulse") {
		t.Errorf("a foreign-holder refusal must NOT be explained as a stale epoch; got:\n%s", out)
	}
	if !strings.Contains(out, "held by someone-else") {
		t.Errorf("output should name the holder the store shows; got:\n%s", out)
	}
}

// fencedOffServer refuses every close 409 fenced_off and serves the row back
// with the given holder + epoch.
func fencedOffServer(t *testing.T, holder string, epoch int) {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/close"):
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"ok":false,"reason":"fenced_off"}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			body, _ := json.Marshal(map[string]any{"ok": true, "doc": map[string]any{
				"doc_id":           "bp-task-x",
				"status":           "published",
				"lifecycle_status": "in_progress",
				"content":          map[string]any{"acceptance_criteria": []any{}},
				"claim":            map[string]any{"worker": holder, "epoch": epoch},
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
	t.Setenv("BARKPARK_API_TOKEN", "lease-stub")
}

// --- the stamp's 5xx receipt is never ambiguous ----------------------------

// task-6b1f073e83fba78d: three stamps during a load spike printed the SAME
// message shape for two different outcomes — one had landed and one had not.
// The read-back's own failure path was the ambiguous one ("the write may or
// may not have landed"), and it is now a bounded second look plus a definite
// verdict. Whatever the store does, the receipt must never hedge.
func TestTaskStampExecute_ReceiptIsNeverAmbiguous(t *testing.T) {
	realDelay := stampReadbackRetryDelay
	stampReadbackRetryDelay = 0
	t.Cleanup(func() { stampReadbackRetryDelay = realDelay })

	cases := []struct {
		name string
		mode stampStoreMode
		want string
	}{
		{"5xx that committed", stampStore500Landed, "the store holds it"},
		{"5xx that did not", stampStore500Absent, "✗ NOT stored — stamp again"},
		{"read-back unreachable", stampStore500Unreadable, "treat this stamp as NOT stored and stamp again"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stampTestServerMode(t, c.mode)
			out, _ := captureExecuteCode(t, []string{
				"task", "stamp", "bp-task-x", "w", "1",
				"--criterion", "2", "--met", "--evidence", "gate green",
				"--criterion-text", "a normal row",
			})
			if !strings.Contains(out, c.want) {
				t.Errorf("receipt missing %q; got:\n%s", c.want, out)
			}
			if strings.Contains(out, "may or may not have landed") {
				t.Errorf("the stamp receipt hedged — the same words for landed and not-landed is the whole defect; got:\n%s", out)
			}
		})
	}
}
