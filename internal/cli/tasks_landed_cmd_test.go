package cli

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// `bp task landed` is a PURELY MANIFEST-DRIVEN verb — there is no
// tasks_landed_cmd.go, and that is the claim these tests defend. Its two
// siblings on this ledger earned hand-written wrappers for reasons `landed`
// does not have: `stamp` translates a 0-vs-1 base and re-reads the row it
// flipped; `close` and `pulse` re-read because an exit code alone had already
// been watched lying about a write. `landed` adds no client-side ergonomics and
// adjudicates nothing client-side — every guard it has is a server guard on the
// STORED row (merge-shaped, already-met, index-in-range), and a CLI that
// second-guessed any of them from the flags it was typed would be exactly the
// mistake `stamp`'s own comment records as measured-refuted.
//
// So what a Go test can actually prove here is that DECLARING the verb is the
// whole CLI change: given a manifest that carries `task.landed`, the generic
// dispatch reaches the right method and path and carries every flag on the
// wire. A regression that added a `noun == "task" && verb == "landed"` branch
// which swallowed a flag, or a manifest whose path_template drifted from the
// route, reds here.
const minimalLandedManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "write",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.landed", "noun": "task", "verb": "landed", "summary": "landing mark",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/landed"},
      "auth_tier": "write",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"}
      ],
      "flags": [
        {"name": "commit", "type": "string", "summary": "sha"},
        {"name": "pr", "type": "string", "summary": "pr"},
        {"name": "note", "type": "string", "summary": "sentence"},
        {"name": "criterion", "type": "int", "summary": "idx"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// landedTestServer stands up a fake Barkpark that records the method, path and
// query of the landing POST it answers.
type landedCapture struct {
	mu     sync.Mutex
	method string
	path   string
	query  string
	hits   int32
}

func landedTestServer(t *testing.T) *landedCapture {
	t.Helper()
	cap := &landedCapture{}

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/landed") {
			atomic.AddInt32(&cap.hits, 1)
			cap.mu.Lock()
			cap.method, cap.path, cap.query = r.Method, r.URL.Path, r.URL.RawQuery
			cap.mu.Unlock()
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"bp-task-x"}}`))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalLandedManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "landed-stub")
	return cap
}

// THE ADDITIVE-MANIFEST CLAIM: declaring `task.landed` on the server is the
// entire CLI change. `bp task landed <id> --commit --pr --note --criterion`
// must reach POST /v1/tasks/<id>/landed with all four values on the wire, with
// no Go command file backing it.
func TestTaskLandedExecute_DispatchesThroughTheManifest(t *testing.T) {
	cap := landedTestServer(t)

	out, code := captureExecuteCode(t, []string{
		"task", "landed", "bp-task-x",
		"--commit", "a1b2c3d", "--pr", "14993",
		"--note", "PR #14993 merged to main", "--criterion", "6",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d); out:\n%s", code, exitOK, out)
	}
	if n := atomic.LoadInt32(&cap.hits); n != 1 {
		t.Fatalf("landed POST fired %d times, want 1; out:\n%s", n, out)
	}

	cap.mu.Lock()
	method, path, query := cap.method, cap.path, cap.query
	cap.mu.Unlock()

	if method != http.MethodPost {
		t.Errorf("method = %s, want POST", method)
	}
	if path != "/v1/tasks/bp-task-x/landed" {
		t.Errorf("path = %q, want /v1/tasks/bp-task-x/landed", path)
	}
	for _, want := range []string{"commit=a1b2c3d", "pr=14993", "criterion=6"} {
		if !strings.Contains(query, want) {
			t.Errorf("query %q is missing %q — a flag was dropped on the way to the wire", query, want)
		}
	}
	if !strings.Contains(query, "note=") {
		t.Errorf("query %q carries no note — the note IS the criterion's evidence", query)
	}
}

// NO worker_id, NO observed_epoch — the absence is the feature, and it is
// declared, not merely tolerated. `landed` takes exactly ONE positional arg, so
// a caller who types the stamp/close shape (`<id> <worker> <epoch>`) is a usage
// error that SENDS NOTHING, rather than a POST that quietly drops two values.
// A manifest that grew the holder args back would red here.
func TestTaskLandedExecute_TakesNoWorkerOrEpoch(t *testing.T) {
	cap := landedTestServer(t)

	out, code := captureExecuteCode(t, []string{
		"task", "landed", "bp-task-x", "some-worker", "3", "--note", "merged to main",
	})
	if code == exitOK {
		t.Fatalf("the stamp/close positional shape must NOT be accepted; exit = %d, out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(&cap.hits); n != 0 {
		t.Fatalf("landed POST fired %d times on a usage error; want 0 (nothing sent)", n)
	}
}
