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
