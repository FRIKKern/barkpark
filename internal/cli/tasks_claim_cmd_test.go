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
	got := claimVerdict("me", "blocked", apiclient.ClaimInfo{})
	if !strings.Contains(got, "genuinely not ready") || !strings.Contains(got, `"blocked"`) {
		t.Errorf("verdict = %q, want a genuinely-not-ready verdict naming lifecycle_status", got)
	}
}

func TestClaimVerdict_NoHolderButOpen_NamesThePredicateDefect(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{})
	if !strings.Contains(got, "task-eb2b6170e19f1611") {
		t.Errorf("verdict = %q, want it to point at the known predicate defect", got)
	}
}

func TestClaimVerdict_AlreadyYours(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{Present: true, Worker: "me"})
	if !strings.Contains(got, "YOU (me)") {
		t.Errorf("verdict = %q, want it to say the store already lists the caller", got)
	}
}

func TestClaimVerdict_HeldLiveBySomeoneElse(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{Present: true, Worker: "other"})
	if !strings.Contains(got, "held live by other") {
		t.Errorf("verdict = %q, want a held-live-by verdict naming the holder", got)
	}
}

func TestClaimVerdict_StaleReleasedWorkerField(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{
		Present: true, Worker: "other", ReleasedAt: "2026-08-20T17:32:26Z",
	})
	if !strings.Contains(got, "RELEASED but claim.worker is still stale-set to other") ||
		!strings.Contains(got, "WRONG WORKER") {
		t.Errorf("verdict = %q, want the stale-released verdict naming the wrong-worker cause", got)
	}
}

func TestClaimVerdict_ExpiredCountsAsNotLive(t *testing.T) {
	got := claimVerdict("me", "open", apiclient.ClaimInfo{
		Present: true, Worker: "other", ExpiredAt: "2026-08-20T17:32:26Z",
	})
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
