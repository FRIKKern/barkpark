package apiclient

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
)

// WHY THIS FILE EXISTS — DO NOT DELETE AS REDUNDANT COVERAGE.
//
// The server's autostamp_merge_gate/6 (api/lib/barkpark/tasks/close.ex:344-370)
// synthesises met:true stamps for every unmet merge_gate criterion on a task.
// Its ONLY entry condition is the close payload's "landed" key:
//
//	when is_map(landed) and map_size(landed) > 0 and is_list(criteria)
//
// The cmux Stop hook (internal/cli/cmux_hook.go hookStopClose) closes a task
// automatically the moment every acceptance criterion reads met. The single
// thing that stops that AUTOMATED close from also auto-stamping a merge-gated
// criterion — "PR merged", which no builder may stamp for itself — is that
// TaskCloseN/TaskCloseRevN send neither a "criteria" nor a "landed" key, so
// autostamp_merge_gate is structurally unreachable from a Stop event.
//
// That safety is TRUE BY CONSTRUCTION, and construction is exactly what an
// innocent edit changes. The fake servers in internal/cli/cmux_hook_test.go
// decode only worker_id/observed_epoch/observed_rev out of the close body, so
// adding "landed" to either payload would compile and pass every other test in
// the tree while silently making a false merge-gate close reachable from an
// automated hook.
//
// So these tests assert the FULL KEY SET as a whitelist, not merely the absence
// of "criteria" and "landed" — a whitelist fails on the next unexpected key too,
// a blacklist only ever catches the two keys someone already thought of. If you
// are adding a key here on purpose, prove first that it cannot reach
// autostamp_merge_gate from hookStopClose.

// captureCloseBody stands up an httptest server that records the decoded JSON
// body of the single /close POST it serves, and replies with a minimal ok
// envelope so the client's normal success path runs.
func captureCloseBody(t *testing.T, call func(c *Client) error) map[string]interface{} {
	t.Helper()

	var got map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/close") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read close body: %v", err)
		}
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Errorf("decode close body %q: %v", raw, err)
		}
		_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	if err := call(c); err != nil {
		t.Fatalf("close call: %v", err)
	}
	if got == nil {
		t.Fatal("server never received a close request body")
	}
	return got
}

// assertExactKeys fails when the body's key set differs from want in EITHER
// direction — an extra key (the autostamp hazard) or a missing one (a payload
// regression the server would reject).
func assertExactKeys(t *testing.T, body map[string]interface{}, want ...string) {
	t.Helper()

	got := make([]string, 0, len(body))
	for k := range body {
		got = append(got, k)
	}
	sort.Strings(got)
	sort.Strings(want)

	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("close payload keys = %v, want exactly %v\n"+
			"an EXTRA key here can reach autostamp_merge_gate "+
			"(api/lib/barkpark/tasks/close.ex:344-370) from an automated Stop close",
			got, want)
	}
}

// TaskCloseN is the payload the cmux Stop hook sends. Exactly three keys.
func TestTaskCloseNSendsExactKeySet(t *testing.T) {
	body := captureCloseBody(t, func(c *Client) error {
		_, _, err := c.TaskCloseN("task-7", "worker-a", 3)
		return err
	})

	assertExactKeys(t, body, "worker_id", "observed_epoch", "lifecycle_status")

	if body["worker_id"] != "worker-a" {
		t.Errorf("worker_id = %v, want worker-a", body["worker_id"])
	}
	if body["observed_epoch"] != float64(3) {
		t.Errorf("observed_epoch = %v, want 3", body["observed_epoch"])
	}
	if body["lifecycle_status"] != "done" {
		t.Errorf("lifecycle_status = %v, want done", body["lifecycle_status"])
	}
}

// TaskCloseRevN adds the observed_rev strict-CAS guard and NOTHING else.
func TestTaskCloseRevNSendsExactKeySet(t *testing.T) {
	body := captureCloseBody(t, func(c *Client) error {
		_, _, err := c.TaskCloseRevN("task-7", "worker-a", 3, "rev-abc")
		return err
	})

	assertExactKeys(t, body, "worker_id", "observed_epoch", "observed_rev", "lifecycle_status")

	if body["observed_rev"] != "rev-abc" {
		t.Errorf("observed_rev = %v, want rev-abc", body["observed_rev"])
	}
	if body["lifecycle_status"] != "done" {
		t.Errorf("lifecycle_status = %v, want done", body["lifecycle_status"])
	}
}
