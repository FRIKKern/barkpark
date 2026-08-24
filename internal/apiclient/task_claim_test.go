package apiclient

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TaskClaim must return the claim's fencing epoch — the token TaskClose echoes
// back as observed_epoch. Epochs start at 1, so a malformed ok-envelope that
// carries no epoch (0) is NOT a real claim: proceeding with epoch 0 silently
// defeats the CAS-on-epoch fencing the whole bp task workflow depends on.
func TestTaskClaimRejectsMissingEpoch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/claim") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		// An ok envelope with an empty doc — no fencing epoch.
		_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	epoch, err := c.TaskClaim("task-7", "worker-a")
	if err == nil {
		t.Fatalf("expected an error for a claim with no fencing epoch, got nil (epoch=%d)", epoch)
	}
	if epoch != 0 {
		t.Errorf("epoch = %d, want 0 on failure", epoch)
	}
}

func TestTaskClaimReturnsEpoch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/claim") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":2}}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	epoch, err := c.TaskClaim("task-7", "worker-a")
	if err != nil {
		t.Fatalf("TaskClaim: %v", err)
	}
	if epoch != 2 {
		t.Errorf("epoch = %d, want 2", epoch)
	}
}

// TaskRelabel POSTs {"add":…,"remove":…} to /v1/tasks/:doc_id/labels. This
// asserts the exact request the server contract expects: the labels path with
// the doc id percent-escaped (like TaskClaim), and the add/remove lists in the
// body. A single-add relabel (the board's `t` verb) sends add=[tag], remove=[].
func TestTaskRelabelSendsAddRemoveBody(t *testing.T) {
	var gotPath string
	var gotBody struct {
		Add    []string `json:"add"`
		Remove []string `json:"remove"`
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.EscapedPath() // the on-the-wire (percent-escaped) form
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	// A doc id with a slash must be escaped in the path (TaskClaim discipline).
	if err := c.TaskRelabel("drafts/task 9", []string{"proj:sheets-parity"}, nil); err != nil {
		t.Fatalf("TaskRelabel: %v", err)
	}
	if gotPath != "/v1/tasks/drafts%2Ftask%209/labels" {
		t.Errorf("path = %q, want the escaped /labels path", gotPath)
	}
	if len(gotBody.Add) != 1 || gotBody.Add[0] != "proj:sheets-parity" {
		t.Errorf("add = %v, want [proj:sheets-parity]", gotBody.Add)
	}
	if len(gotBody.Remove) != 0 {
		t.Errorf("remove = %v, want empty", gotBody.Remove)
	}
}

// A relabel the server refuses (advisory-lock loss / CAS-on-rev conflict on a
// 409) comes back as an ok:false envelope; taskPost surfaces the reason string
// VERBATIM as the error — never swallowed, never a retry loop.
func TestTaskRelabelSurfacesConflictReason(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/labels") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"ok":false,"reason":"stale_rev"}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	err := c.TaskRelabel("task-7", []string{"area:tui"}, nil)
	if err == nil {
		t.Fatal("expected an error on a 409 conflict, got nil")
	}
	if err.Error() != "stale_rev" {
		t.Errorf("error = %q, want the verbatim reason %q", err.Error(), "stale_rev")
	}
}

// TaskClaimResources declares the task's file scope in the claim body so the
// server's check_resources_free fence can run. This asserts the outgoing body
// carries worker_id AND the sorted resources, and that a won claim returns the
// fencing epoch on the outcome.
func TestTaskClaimResourcesSendsResourcesBody(t *testing.T) {
	var gotBody struct {
		WorkerID  string   `json:"worker_id"`
		Resources []string `json:"resources"`
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/claim") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":3}}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	res := []string{"internal/cli/cli.go", "internal/cli/cmux_dispatch.go"}
	outcome, err := c.TaskClaimResources("task-7", "worker-a", res)
	if err != nil {
		t.Fatalf("TaskClaimResources: %v", err)
	}
	if !outcome.OK || outcome.Epoch != 3 {
		t.Errorf("outcome = %+v, want OK epoch 3", outcome)
	}
	if gotBody.WorkerID != "worker-a" {
		t.Errorf("worker_id = %q, want worker-a", gotBody.WorkerID)
	}
	if len(gotBody.Resources) != 2 || gotBody.Resources[0] != "internal/cli/cli.go" {
		t.Errorf("resources = %v, want the two declared files", gotBody.Resources)
	}
}

// An empty file scope sends NO resources key — byte-identical to a bare claim —
// so the server fence stays inert unless a task actually declares files.
func TestTaskClaimResourcesEmptyOmitsResourcesKey(t *testing.T) {
	var raw []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":1}}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	if _, err := c.TaskClaimResources("task-7", "worker-a", nil); err != nil {
		t.Fatalf("TaskClaimResources: %v", err)
	}
	if strings.Contains(string(raw), "resources") {
		t.Errorf("empty scope must not send a resources key; body = %s", raw)
	}
}

// A 409 resource_conflict rides an ok:false envelope with a conflicts array. The
// outcome must surface reason + the named holders WITHOUT collapsing into an
// error (the frontier loop needs to branch on it and skip to the next pick).
//
// THE FIXTURE BELOW IS THE WIRE SHAPE, CAPTURED FROM guerrilla — the holder key
// is `doc_id`. This test previously spelled it `"task"`, which no emitter in the
// API sends (api/lib/barkpark/tasks/claim.ex builds `%{doc_id: …}`), so it was
// green against a body the server does not produce while TaskConflict.Task was
// empty on every real response. Read the holder through HolderID.
func TestTaskClaimResourcesDecodesConflicts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"ok":false,"reason":"resource_conflict","conflicts":[{"worker":"worker-2","doc_id":"task-b","resources":["internal/cli/cli.go"]}]}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	outcome, err := c.TaskClaimResources("task-7", "worker-a", []string{"internal/cli/cli.go"})
	if err != nil {
		t.Fatalf("resource_conflict must not be an error, got %v", err)
	}
	if outcome.OK || outcome.Reason != "resource_conflict" {
		t.Errorf("outcome = %+v, want ok=false reason=resource_conflict", outcome)
	}
	if len(outcome.Conflicts) != 1 || outcome.Conflicts[0].HolderID() != "task-b" || outcome.Conflicts[0].Worker != "worker-2" {
		t.Errorf("conflicts = %+v, want the named holder task-b/worker-2", outcome.Conflicts)
	}
}

// TestTaskConflictHolderIDReadsTheWireKey is the guard the fixture above cannot
// be: it asserts the SERVER's spelling decodes, that the legacy `task` spelling
// still decodes (so a hand-written fixture or an older emitter is not broken by
// the fix), and — the row that actually matters — that reading `.Task` on a real
// response yields NOTHING. That last assertion is what made every holder line
// render with a leading blank where the row id belongs.
func TestTaskConflictHolderIDReadsTheWireKey(t *testing.T) {
	// Captured verbatim from guerrilla.barkpark.cloud.
	const wire = `{"worker":"build-lane-j","doc_id":"task-4b338a4dbe90d44d","resources":["internal/cli/run.go"]}`
	var c TaskConflict
	if err := json.Unmarshal([]byte(wire), &c); err != nil {
		t.Fatalf("decoding the live wire body: %v", err)
	}
	if c.HolderID() != "task-4b338a4dbe90d44d" {
		t.Errorf("HolderID() = %q, want the doc_id the server sent", c.HolderID())
	}
	if c.Task != "" {
		t.Errorf("Task = %q — the server does not send a `task` key; this test would stop measuring the bug", c.Task)
	}

	var legacy TaskConflict
	if err := json.Unmarshal([]byte(`{"task":"task-b","worker":"w"}`), &legacy); err != nil {
		t.Fatalf("decoding the legacy spelling: %v", err)
	}
	if legacy.HolderID() != "task-b" {
		t.Errorf("HolderID() = %q on the legacy `task` spelling, want task-b", legacy.HolderID())
	}

	var none TaskConflict
	if none.HolderID() != "" {
		t.Errorf("HolderID() = %q on an empty conflict, want empty", none.HolderID())
	}
}

// A lost race is reason not_ready on an ok:false envelope — surfaced (not an
// error) so the frontier loop skips to the next pick.
func TestTaskClaimResourcesSurfacesNotReady(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"ok":false,"reason":"not_ready"}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	outcome, err := c.TaskClaimResources("task-7", "worker-a", nil)
	if err != nil {
		t.Fatalf("not_ready must not be an error, got %v", err)
	}
	if outcome.OK || outcome.Reason != "not_ready" {
		t.Errorf("outcome = %+v, want ok=false reason=not_ready", outcome)
	}
}

// A won claim (ok:true) that carries no positive epoch stays a HARD error —
// proceeding with epoch 0 defeats the CAS fencing (TaskClaimN's discipline).
func TestTaskClaimResourcesRejectsMissingEpoch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	outcome, err := c.TaskClaimResources("task-7", "worker-a", nil)
	if err == nil {
		t.Fatalf("expected a hard error for a claim with no fencing epoch, got %+v", outcome)
	}
	if outcome.OK {
		t.Errorf("outcome.OK = true, want false on the epoch failure")
	}
}
