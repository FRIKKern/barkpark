package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// --- claimVerdict: the pure decision table -------------------------------

func TestClaimVerdict_GenuinelyNotReady(t *testing.T) {
	got := claimVerdict("me", "blocked", apiclient.ClaimInfo{}, queueGate{}, "")
	if !strings.Contains(got, "genuinely not ready") || !strings.Contains(got, `"blocked"`) {
		t.Errorf("verdict = %q, want a genuinely-not-ready verdict naming lifecycle_status", got)
	}
}

func TestClaimVerdict_NoHolderButOpen_NamesThePredicateDefect(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{}, queueGate{}, "")
	if !strings.Contains(got, "task-eb2b6170e19f1611") {
		t.Errorf("verdict = %q, want it to point at the known predicate defect", got)
	}
}

func TestClaimVerdict_AlreadyYours(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{Present: true, Worker: "me"}, queueGate{}, "")
	if !strings.Contains(got, "YOU (me)") {
		t.Errorf("verdict = %q, want it to say the store already lists the caller", got)
	}
}

func TestClaimVerdict_HeldLiveBySomeoneElse(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{Present: true, Worker: "other"}, queueGate{}, "")
	if !strings.Contains(got, "held live by other") {
		t.Errorf("verdict = %q, want a held-live-by verdict naming the holder", got)
	}
}

func TestClaimVerdict_StaleReleasedWorkerField(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{
		Present: true, Worker: "other", ReleasedAt: "2026-08-20T17:32:26Z",
	}, queueGate{}, "")
	if !strings.Contains(got, "RELEASED but claim.worker is still stale-set to other") ||
		!strings.Contains(got, "WRONG WORKER") {
		t.Errorf("verdict = %q, want the stale-released verdict naming the wrong-worker cause", got)
	}
}

func TestClaimVerdict_ExpiredCountsAsNotLive(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{
		Present: true, Worker: "other", ExpiredAt: "2026-08-20T17:32:26Z",
	}, queueGate{}, "")
	if !strings.Contains(got, "stale-set") {
		t.Errorf("verdict = %q, want an expired-but-still-named claim treated as stale, not live", got)
	}
}

// --- claimRequestOf: resolves the same target the dispatch used ----------

func TestClaimRequestOf_ResolvesDocAndWorker(t *testing.T) {
	cmd := claimCommandFixture(t)
	req, ok := claimRequestOf(cmd, []string{"task-abc", "worker-1"})
	if !ok {
		t.Fatal("claimRequestOf returned ok=false on a valid claim invocation")
	}
	if req.docID != "task-abc" || req.workerID != "worker-1" {
		t.Errorf("req = %+v, want docID=task-abc workerID=worker-1", req)
	}
}

func TestClaimRequestOf_MissingArgsIsNotOK(t *testing.T) {
	cmd := claimCommandFixture(t)
	if _, ok := claimRequestOf(cmd, []string{"task-abc"}); ok {
		t.Error("claimRequestOf should refuse a claim invocation missing worker_id")
	}
}

func claimCommandFixture(t *testing.T) manifest.Command {
	t.Helper()
	m, err := manifest.Parse([]byte(minimalClaimManifest))
	if err != nil {
		t.Fatalf("parse minimal claim manifest: %v", err)
	}
	for _, c := range m.Commands {
		if c.Noun == "task" && c.Verb == "claim" {
			return c
		}
	}
	t.Fatal("task claim missing from fixture manifest")
	return manifest.Command{}
}

const minimalClaimManifest = `{
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
    }
  ]
}`

// --- integration: Execute("task","claim",…) through a fake server --------

// claimTestServer wires a fake Barkpark: POST /v1/tasks/:id/claim always
// refuses not_ready (409), and GET /v1/data/doc/:dataset/task/:id (the
// diagnosis read-back) answers with docState. Returns the POST hit counter.
func claimTestServer(t *testing.T, docState map[string]any) *int32 {
	t.Helper()
	var hits int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/claim"):
			atomic.AddInt32(&hits, 1)
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"ok":false,"reason":"not_ready"}`))
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/"):
			body, _ := json.Marshal(map[string]any{"result": docState})
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalClaimManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "claim-stub")
	return &hits
}

func TestTaskClaimExecute_NotReadyDiagnosesHeldBySomeoneElse(t *testing.T) {
	hits := claimTestServer(t, map[string]any{
		"_id": "task-x", "lifecycle_status": "open",
		"claim": map[string]any{"worker": "other-worker", "epoch": 3},
	})
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("claim POST fired %d times, want 1", n)
	}
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d); out:\n%s", code, exitConflict, out)
	}
	for _, want := range []string{"diagnosis:", "claim.worker=other-worker", "held live by other-worker"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q; got:\n%s", want, out)
		}
	}
}

func TestTaskClaimExecute_NotReadyDiagnosesStaleReleasedWorker(t *testing.T) {
	claimTestServer(t, map[string]any{
		"_id": "task-x", "lifecycle_status": "open",
		"claim": map[string]any{"worker": "other-worker", "epoch": 5, "released_at": "2026-08-20T17:32:26Z"},
	})
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, out)
	}
	if !strings.Contains(out, "stale-set to other-worker") || !strings.Contains(out, "WRONG WORKER") {
		t.Errorf("output should diagnose the stale released-worker cause; got:\n%s", out)
	}
}

func TestTaskClaimExecute_NotReadyDiagnosesGenuinelyBlocked(t *testing.T) {
	claimTestServer(t, map[string]any{
		"_id": "task-x", "lifecycle_status": "blocked", "claim": nil,
	})
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, out)
	}
	if !strings.Contains(out, `genuinely not ready: lifecycle_status is "blocked"`) {
		t.Errorf("output should diagnose the genuinely-not-ready cause; got:\n%s", out)
	}
}

// A read-back that did not land must say so and assert NOTHING about the
// claim. The message now also names WHICH failure it was: reporting a flat
// 403 as "the store may simply be unreachable" sent operators to debug the
// network for an answer the server had already given in full.
func TestTaskClaimExecute_ReadBackFailureSaysSoAndNothingMore(t *testing.T) {
	cases := []struct {
		name       string
		readStatus int
		want       string // the substring that names this failure class
		forbidden  []string
	}{
		{
			name:       "server error",
			readStatus: http.StatusInternalServerError,
			want:       "the store errored reading task-x back",
			forbidden:  []string{"refused the read"},
		},
		{
			name:       "forbidden",
			readStatus: http.StatusForbidden,
			want:       "the store refused the read-back of task-x",
			// The old copy for this case. A refusal is not an unreachable store.
			forbidden: []string{"may simply be unreachable", "unreachable"},
		},
		{
			name:       "unauthenticated",
			readStatus: http.StatusUnauthorized,
			want:       "the store refused the read-back of task-x",
			forbidden:  []string{"may simply be unreachable", "unreachable"},
		},
		{
			name:       "other non-2xx",
			readStatus: http.StatusTooManyRequests,
			want:       "could not read task-x back",
			forbidden:  nil,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var hits int32
			backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/claim"):
					atomic.AddInt32(&hits, 1)
					w.WriteHeader(http.StatusConflict)
					_, _ = w.Write([]byte(`{"ok":false,"reason":"not_ready"}`))
				default:
					w.WriteHeader(c.readStatus)
				}
			}))
			t.Cleanup(backend.Close)
			mf := filepath.Join(t.TempDir(), "manifest.json")
			if err := os.WriteFile(mf, []byte(minimalClaimManifest), 0o600); err != nil {
				t.Fatalf("write manifest: %v", err)
			}
			t.Setenv("BARKPARK_MANIFEST", mf)
			t.Setenv("BARKPARK_API_URL", backend.URL)
			t.Setenv("BARKPARK_API_TOKEN", "claim-stub")

			out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
			if code != exitConflict {
				t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, out)
			}
			if !strings.Contains(out, c.want) {
				t.Errorf("output should name this read-back failure (%q); got:\n%s", c.want, out)
			}
			for _, bad := range c.forbidden {
				if strings.Contains(out, bad) {
					t.Errorf("output misdescribes the failure (contains %q); got:\n%s", bad, out)
				}
			}
			// Unchanged invariant: a read-back that did not land supports no
			// verdict about the claim, and must never fall through to the
			// read-back line and report a ZERO document as if it were read.
			if strings.Contains(out, "genuinely not ready") || strings.Contains(out, "held live by") {
				t.Errorf("a failed read-back must not assert a cause it cannot support; got:\n%s", out)
			}
			if strings.Contains(out, "read-back of task-x — lifecycle_status=") {
				t.Errorf("a failed read-back printed the empty document as a read-back; got:\n%s", out)
			}
		})
	}
}

// --- the queue gate: never "not legitimate" before checking legitimacy ---

// speculativeSentence is the ONE assertion in this CLI that a refusal is
// illegitimate. It is named once, here, so the absence assertions and the
// positive control below cannot drift apart (an absence assertion that has
// quietly stopped matching passes on every input).
const speculativeSentence = "not a legitimate refusal"

// liveHumanGatedClaimBody is the 409 guerrilla.barkpark.cloud sends for a
// claim against a row its AUTHOR gated, captured from the shape
// tasks_controller.not_ready_arm/2 emits: reason "not_ready", the arm named,
// and the gate's own sentence as the message.
const liveHumanGatedClaimBody = `{"ok":false,"reason":"not_ready","arm":"queue_gated",` +
	`"execution_class":"human_gated","gate_reason":"needs an OPERATOR. Do not claim this row to build.",` +
	`"message":"queue_gate state is \"human_gated\" — this row is gated by its AUTHOR, not by readiness, and no retry will change that. Read content.queue_gate.reason for what it is waiting on."}`

// unexplainedClaimBody is the case the speculation was WRITTEN for: a bare
// not_ready with no arm, over a row the read-back shows open and unheld.
const unexplainedClaimBody = `{"ok":false,"reason":"not_ready"}`

// gatedClaimServer refuses the POST with the given body and answers the
// read-back with the given content fields, exactly as the live store holds them.
func gatedClaimServer(t *testing.T, refusal string, readBack map[string]any) {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/claim"):
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(refusal))
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/"):
			body, _ := json.Marshal(map[string]any{"result": readBack})
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalClaimManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "claim-stub")
}

// TestTaskClaimExecute_HumanGatedNamesTheGateAndDoesNotSpeculate is the
// first-response pin (task-3011aa665010a615 c3).
//
// Measured live before the fix, one bp invocation, both halves on stderr:
//
//	bp: queue_gate state is "human_gated" — this row is gated by its AUTHOR …
//	diagnosis: read-back of task-ed7ae8110c7c8b41 — lifecycle_status=open claim.worker=(none) …
//	  the store shows NO holder and an apparently-open row — this does not match
//	  a real conflict; likely the server-side predicate defect … not a legitimate refusal
//
// The refusal was legitimate. A diagnostic that calls an author's gate a known
// server bug recommends an override of the gate — the cost here is a SAFETY
// MECHANISM, not a confusing sentence.
func TestTaskClaimExecute_HumanGatedNamesTheGateAndDoesNotSpeculate(t *testing.T) {
	gatedClaimServer(t, liveHumanGatedClaimBody, map[string]any{
		"_id": "task-x", "lifecycle_status": "open", "claim": nil,
		"queue_gate": map[string]any{
			"state": "human_gated", "version": 1,
			"reason": "needs an OPERATOR. Do not claim this row to build.",
		},
	})
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d); out:\n%s", code, exitConflict, out)
	}
	// PRESENT: the gate is named in this, the FIRST response.
	for _, want := range []string{"human_gated", "gated by its AUTHOR", "Do not claim this row to build."} {
		if !strings.Contains(out, want) {
			t.Errorf("first response does not name the gate (%q missing):\n%s", want, out)
		}
	}
	// ABSENT: no assertion that the refusal is illegitimate.
	for _, banned := range []string{speculativeSentence, "does not match a real conflict", "task-eb2b6170e19f1611"} {
		if strings.Contains(out, banned) {
			t.Errorf("first response still speculates (%q) over a legitimate gate:\n%s", banned, out)
		}
	}
}

// TestTaskClaimExecute_UnexplainedRefusalKeepsTheSpeculation is the POSITIVE
// CONTROL for the absence half above. The absence assertion is only worth
// something if it CAN see the sentence; this proves the same assertion, run
// against the branch that still emits it, fails to find nothing.
//
// It is also c1's second branch: the speculation is not deleted, it is confined
// to the case it was written for — a refusal with no explanation anywhere.
func TestTaskClaimExecute_UnexplainedRefusalKeepsTheSpeculation(t *testing.T) {
	gatedClaimServer(t, unexplainedClaimBody, map[string]any{
		"_id": "task-x", "lifecycle_status": "open", "claim": nil,
	})
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d); out:\n%s", code, exitConflict, out)
	}
	if !strings.Contains(out, speculativeSentence) {
		t.Fatalf("the unexplained-refusal branch LOST the speculation — the absence assertion "+
			"in the gated test can no longer see it and passes vacuously:\n%s", out)
	}
}

// TestClaimVerdict_QueueGateOutranksTheSpeculation pins the pure decision: an
// open, unheld row that carries an author gate must NEVER reach the
// speculative arm, whatever the arm field says.
func TestClaimVerdict_QueueGateOutranksTheSpeculation(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{},
		queueGate{State: "human_gated", Reason: "waiting on an operator"}, "")
	if strings.Contains(got, speculativeSentence) {
		t.Errorf("verdict speculates over an author gate: %q", got)
	}
	for _, want := range []string{"human_gated", "gated by its AUTHOR", "waiting on an operator"} {
		if !strings.Contains(got, want) {
			t.Errorf("verdict = %q, want it to name %q", got, want)
		}
	}
}

// An UNKNOWN gate state must silence the speculation too. The failure being
// closed is a local guess overruling a server answer; a state this build cannot
// classify is the last place to start guessing again.
func TestClaimVerdict_UnknownGateStateStillSilencesTheSpeculation(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{}, queueGate{State: "some_future_state"}, "")
	if strings.Contains(got, speculativeSentence) {
		t.Errorf("verdict speculates over an unrecognised gate state: %q", got)
	}
}

// "executable" is the one persisted state that is NOT a reason for a refusal,
// so it must leave the speculation reachable — otherwise the gate check would
// suppress the diagnosis on every gated row in the store.
func TestClaimVerdict_ExecutableGateIsNotAReason(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{}, queueGate{State: "executable"}, "")
	if !strings.Contains(got, speculativeSentence) {
		t.Errorf("verdict = %q, want an executable gate to leave the unexplained-refusal arm reachable", got)
	}
}

// A named arm, with no gate on the read-back, is still a positive reason the
// server stated: report it, never contradict it.
func TestClaimVerdict_NamedArmSuppressesTheSpeculation(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{}, queueGate{}, "held_by_other")
	if strings.Contains(got, speculativeSentence) {
		t.Errorf("verdict contradicts a server-named arm: %q", got)
	}
	if !strings.Contains(got, "held_by_other") {
		t.Errorf("verdict = %q, want it to report the arm the server named", got)
	}
}

// arm "unknown" is the server saying it could not name a cause either — the
// exact input the speculation exists for.
func TestClaimVerdict_UnknownArmKeepsTheSpeculation(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{}, queueGate{}, "unknown")
	if !strings.Contains(got, speculativeSentence) {
		t.Errorf("verdict = %q, want arm=unknown to reach the unexplained-refusal arm", got)
	}
}

// classifyError must carry the arm off the wire, or every suppression above is
// keyed on a field that is always "".
func TestClassifyErrorCarriesTheNotReadyArm(t *testing.T) {
	ae := classifyError(http.StatusConflict, []byte(liveHumanGatedClaimBody))
	if ae.code != "not_ready" || ae.exit != exitConflict {
		t.Fatalf("code/exit = %q/%d, want not_ready/%d", ae.code, ae.exit, exitConflict)
	}
	if ae.arm != "queue_gated" {
		t.Errorf("arm = %q, want queue_gated — the server's own name for which gate fired", ae.arm)
	}
	if bare := classifyError(http.StatusConflict, []byte(unexplainedClaimBody)); bare.arm != "" {
		t.Errorf("arm = %q on a body that carried none, want \"\"", bare.arm)
	}
}

// queueGateOf must be as tolerant as ClaimInfo: one odd field costs the gate
// line, never the diagnosis.
func TestQueueGateOfIsShapeTolerant(t *testing.T) {
	for _, c := range []struct {
		name string
		raw  string
		want queueGate
	}{
		{"absent", ``, queueGate{}},
		{"null", `null`, queueGate{}},
		{"string instead of object", `"human_gated"`, queueGate{}},
		{"gated", `{"state":"human_gated","reason":"  hold  "}`, queueGate{State: "human_gated", Reason: "hold"}},
		{"executable", `{"state":"executable"}`, queueGate{State: "executable"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			d := apiclient.Doc{}
			if c.raw != "" {
				d.Extra = map[string]json.RawMessage{"queue_gate": json.RawMessage(c.raw)}
			}
			if got := queueGateOf(d); got != c.want {
				t.Errorf("queueGateOf(%s) = %+v, want %+v", c.raw, got, c.want)
			}
		})
	}
}
