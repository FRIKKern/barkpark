package cli

// Execute-level proofs for the WIRE half of the flight recorder
// (task-a42dccec2fe4a406, criterion 2), driven through the real dispatch
// against a fake Barkpark that DECODES THE REQUEST BODY.
//
// THE QUESTION THESE ANSWER is not "did the CLI print something" — it is "what
// bytes reached the server". A manifest that is written locally and sent in some
// OTHER shape is two records, and the epic exists because one record was already
// too few. So the fake server keeps what it was posted, and the assertions
// compare it against the file on disk.
//
// The negative direction is the load-bearing one and is ASSERTED, not assumed:
// a claim with no priming dir must put NO priming_start key on the wire — not an
// empty object, not a null.

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// minimalFlightManifest carries ONLY `task claim` and `task close`, in the
// shape api/lib/barkpark/plugins/tasks.ex declares them — `--set` and all, since
// `--set` is the body door both recorder keys ride.
const minimalFlightManifest = `{
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
      "flags": [{"name": "set", "type": "string", "repeatable": true, "summary": "extra"}],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    },
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
      "flags": [{"name": "set", "type": "string", "repeatable": true, "summary": "extra"}],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// frCapture is what the fake server was actually POSTed.
type frCapture struct {
	mu     sync.Mutex
	bodies []map[string]any
	paths  []string
}

func (c *frCapture) add(path string, body map[string]any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.paths = append(c.paths, path)
	c.bodies = append(c.bodies, body)
}

func (c *frCapture) last() map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.bodies) == 0 {
		return nil
	}
	return c.bodies[len(c.bodies)-1]
}

// frServer stands up the fake Barkpark and points the dispatch at it. The GET
// arm exists because `bp task close` re-reads the row after the POST; it answers
// a sealed row so the read-back confirms and the verb exits 0.
func frServer(t *testing.T) *frCapture {
	t.Helper()
	cap := &frCapture{}

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost:
			raw, _ := io.ReadAll(r.Body)
			var body map[string]any
			_ = json.Unmarshal(raw, &body)
			cap.add(r.URL.Path, body)
			_, _ = w.Write([]byte(`{"ok":true}`))

		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"task-fr","status":"published",` +
				`"lifecycle_status":"done","content":{"acceptance_criteria":[],"close_reason":"shipped"},` +
				`"claim":{"worker":"w","epoch":1,"closed_by":"w","closed_at":"2026-09-18T09:00:00Z"}}}`))

		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalFlightManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "fr-stub")
	return cap
}

// THE CRITERION, in one test: with BARKPARK_PRIMING_DIR set, the claim sends the
// SAME manifest it writes locally. "Same" is measured by DIGEST, which is a
// content checksum over the whole record with the digest field blanked — so two
// manifests that agree on it agree on every field, including ClaimedAt, which is
// exactly what a second build would have changed.
func TestClaimSendsTheSameManifestItWritesLocally(t *testing.T) {
	cap := frServer(t)
	dir := t.TempDir()
	t.Setenv("BARKPARK_PRIMING_DIR", dir)
	t.Setenv("BARKPARK_AGENT_MODEL", "opus-5")
	t.Setenv("BARKPARK_AGENT_EFFORT", "medium")

	out, code := captureExecuteCode(t, []string{"task", "claim", "task-fr", "w"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; out:\n%s", code, out)
	}

	body := cap.last()
	if body == nil {
		t.Fatalf("the fake server captured no POST body; out:\n%s", out)
	}
	sent, ok := body[primingBodyKey].(map[string]any)
	if !ok {
		t.Fatalf("no %q object on the wire; body was %#v\nout:\n%s", primingBodyKey, body, out)
	}

	// It is the schema=1 shape, not some second spelling.
	if sent["schema"] != float64(primingSchema) {
		t.Errorf("wire manifest schema = %v, want %d", sent["schema"], primingSchema)
	}

	// AND IT IS THE SAME RECORD AS THE FILE. Read the local manifest back and
	// compare digests: one build, two destinations.
	raw, err := os.ReadFile(primingManifestPath(dir, "task-fr"))
	if err != nil {
		t.Fatalf("local manifest not written: %v", err)
	}
	var onDisk PrimingManifest
	if err := json.Unmarshal(raw, &onDisk); err != nil {
		t.Fatalf("local manifest does not parse: %v", err)
	}
	if sent["digest"] != onDisk.Digest {
		t.Fatalf("wire digest %v != local digest %q — the ledger and the directory hold DIFFERENT records",
			sent["digest"], onDisk.Digest)
	}
	if sent["claimed_at"] != onDisk.ClaimedAt {
		t.Errorf("wire claimed_at %v != local %q — two builds, not one", sent["claimed_at"], onDisk.ClaimedAt)
	}

	// The digest must still describe the bytes that were SENT, not merely match
	// a string the builder also wrote into the file. Re-derive it from the wire
	// object by decoding it back into the typed shape.
	var roundTrip PrimingManifest
	wireBytes, _ := json.Marshal(sent)
	if err := json.Unmarshal(wireBytes, &roundTrip); err != nil {
		t.Fatalf("the wire object does not decode as a PrimingManifest: %v", err)
	}
	if got := primingDigest(roundTrip); got != roundTrip.Digest {
		t.Errorf("the manifest on the wire carries digest %q but its own content hashes to %q",
			roundTrip.Digest, got)
	}
}

// THE CONTROL, ASSERTED RATHER THAN ASSUMED: no priming dir, no key. Not an
// empty object, not a null — the key itself absent, which is what lets the
// server's three-state law mean anything.
func TestClaimWithNoLocalManifestSendsNoManifestKey(t *testing.T) {
	cap := frServer(t)
	t.Setenv("BARKPARK_PRIMING_DIR", "")

	out, code := captureExecuteCode(t, []string{"task", "claim", "task-fr", "w"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; out:\n%s", code, out)
	}
	body := cap.last()
	if body == nil {
		t.Fatalf("no POST captured; out:\n%s", out)
	}
	if _, present := body[primingBodyKey]; present {
		t.Fatalf("a claim with no priming dir put %q on the wire (value %#v) — absent must mean ABSENT",
			primingBodyKey, body[primingBodyKey])
	}
}

// `bp task close --context-compact <file>` sends the FILE'S CONTENTS under
// context_compact, and the client-side flag itself never reaches the server.
func TestCloseSendsTheContextCompactFromAFile(t *testing.T) {
	cap := frServer(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "compact.md")
	compact := "read claim.ex + close.ex.\nthe seam is do_claim_resolved/8.\nbound is byte_size, not String.length.\n"
	if err := os.WriteFile(path, []byte(compact), 0o600); err != nil {
		t.Fatalf("write compact: %v", err)
	}

	out, code := captureExecuteCode(t, []string{
		"task", "close", "task-fr", "w", "1", "done", "landed #19114 @ 90d237d368",
		contextCompactFlag, path,
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; out:\n%s", code, out)
	}
	body := cap.last()
	if body == nil {
		t.Fatalf("no POST captured; out:\n%s", out)
	}
	if got := body[contextCompactBodyKey]; got != compact {
		t.Fatalf("wire %s = %q, want the file's contents %q", contextCompactBodyKey, got, compact)
	}
	// The client-side flag is CONSUMED: no server declares it, so a spelling of
	// it reaching the wire would be an unknown-flag refusal on the next server.
	for k := range body {
		if strings.Contains(k, "context-compact") {
			t.Errorf("the client-side flag spelling %q reached the wire", k)
		}
	}
}

// A close with no --context-compact sends no key — the same control, at the
// other door.
func TestCloseWithoutTheFlagSendsNoCompactKey(t *testing.T) {
	cap := frServer(t)

	out, code := captureExecuteCode(t, []string{
		"task", "close", "task-fr", "w", "1", "done", "landed #19114 @ 90d237d368",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; out:\n%s", code, out)
	}
	if _, present := cap.last()[contextCompactBodyKey]; present {
		t.Fatalf("a close with no --context-compact put %q on the wire", contextCompactBodyKey)
	}
}

// THE THREE LOCAL REFUSALS, each measured by what did NOT happen: no POST at
// all. A close that sealed the row while dropping the record the agent asked to
// attach is the exact silence this epic exists to end, so the refusal comes
// BEFORE the request.
func TestCloseRefusesAnUnusableCompactBeforeThePost(t *testing.T) {
	over := filepath.Join(t.TempDir(), "over.md")
	if err := os.WriteFile(over, []byte(strings.Repeat("x", flightRecorderMaxBytes+1)), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	cases := []struct {
		name string
		args []string
		want string
	}{
		{"missing path", []string{contextCompactFlag}, "needs a file path"},
		{"unreadable file", []string{contextCompactFlag, "/nope/not/here.md"}, "could not read"},
		{"over the bound", []string{contextCompactFlag, over}, "context_compact_too_large"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cap := frServer(t)
			args := append([]string{"task", "close", "task-fr", "w", "1", "done", "landed #19114 @ 90d237d368"}, tc.args...)
			out, code := captureExecuteCode(t, args)

			if code == exitOK {
				t.Fatalf("exit = 0 on an unusable compact; out:\n%s", out)
			}
			if !strings.Contains(out, tc.want) {
				t.Errorf("output missing %q; got:\n%s", tc.want, out)
			}
			// THE MEASUREMENT: nothing was sent. Asserting only the exit code
			// would pass just as happily on a refusal issued AFTER the seal.
			if n := len(cap.paths); n != 0 {
				t.Errorf("%d request(s) reached the server on a refused close: %v", n, cap.paths)
			}
		})
	}
}
