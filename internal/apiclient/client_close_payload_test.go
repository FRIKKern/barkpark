package apiclient

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
)

// WHY THIS FILE EXISTS — DO NOT DELETE AS REDUNDANT COVERAGE.
//
// The server's autostamp_merge_gate/6 (grep the SYMBOL in
// api/lib/barkpark/tasks/close.ex — never a line number; the previous citation
// here said :344-370 for a function that had drifted ~340 lines away)
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
//
// EVERY exported closer on Client is pinned — TaskCloseN, TaskCloseRevN, and the
// error-only TaskClose wrapper — because "the hook only calls two of them" is a
// fact about today's call graph, not about the payloads. A future caller
// switching hookStopClose to the third one must not be able to widen the body on
// the way. The pin is only ever EXTENDED; relaxing it hands every automated hook
// close the power to stamp its own merge gate.
//
// A guard that cannot fail is not a guard, so closePayloadKeyMismatch (the pure
// comparison assertExactKeys is built on) is itself exercised in BOTH failing
// directions — an extra key AND a missing one — by
// TestClosePayloadWhitelistFailsInBothDirections below.

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

// closePayloadKeyMismatch is the whitelist itself, as a PURE function: it
// returns "" when the body's key set equals want, and the failure message
// otherwise. It differs in EITHER direction — an extra key (the autostamp
// hazard) or a missing one (a payload regression the server would reject).
// Pure so the guard can be proven able to FAIL (see the both-directions test);
// a whitelist nobody has watched refuse is a whitelist nobody knows is wired.
func closePayloadKeyMismatch(body map[string]interface{}, want []string) string {
	got := make([]string, 0, len(body))
	for k := range body {
		got = append(got, k)
	}
	sort.Strings(got)

	wantSorted := append([]string(nil), want...)
	sort.Strings(wantSorted)

	if strings.Join(got, ",") == strings.Join(wantSorted, ",") {
		return ""
	}
	return fmt.Sprintf("close payload keys = %v, want exactly %v\n"+
		"an EXTRA key here can reach autostamp_merge_gate "+
		"(grep the SYMBOL in api/lib/barkpark/tasks/close.ex) from an automated Stop close",
		got, wantSorted)
}

// assertExactKeys fails when the body's key set differs from want in EITHER
// direction.
func assertExactKeys(t *testing.T, body map[string]interface{}, want ...string) {
	t.Helper()

	if msg := closePayloadKeyMismatch(body, want); msg != "" {
		t.Error(msg)
	}
}

// The guard proven able to lose. An extra key and a missing key must BOTH be
// reported — a whitelist that only catches additions is a blacklist wearing a
// whitelist's name.
func TestClosePayloadWhitelistFailsInBothDirections(t *testing.T) {
	want := []string{"worker_id", "observed_epoch", "lifecycle_status"}

	exact := map[string]interface{}{
		"worker_id": "w", "observed_epoch": 1, "lifecycle_status": "done",
	}
	if msg := closePayloadKeyMismatch(exact, want); msg != "" {
		t.Fatalf("exact key set must pass, got mismatch: %s", msg)
	}

	// EXTRA — the autostamp hazard itself.
	extra := map[string]interface{}{
		"worker_id": "w", "observed_epoch": 1, "lifecycle_status": "done",
		"landed": map[string]interface{}{"prs": []interface{}{11435}},
	}
	msg := closePayloadKeyMismatch(extra, want)
	if msg == "" {
		t.Error("an EXTRA \"landed\" key must be refused — that key alone reaches autostamp_merge_gate")
	}
	if !strings.Contains(msg, "landed") {
		t.Errorf("the failure must NAME the offending key, got: %s", msg)
	}

	// MISSING — a payload regression the server would reject.
	missing := map[string]interface{}{"worker_id": "w", "observed_epoch": 1}
	if closePayloadKeyMismatch(missing, want) == "" {
		t.Error("a MISSING key must be refused too — the pin is a whitelist, not a blacklist")
	}
}

// TaskCloseN is the payload the cmux Stop hook sends. Exactly three keys.
func TestClosePayloadTaskCloseNExactKeySet(t *testing.T) {
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
func TestClosePayloadTaskCloseRevNExactKeySet(t *testing.T) {
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

// THE THIRD PINNED KEY-SET. TaskClose is the error-only wrapper — today it
// delegates to TaskCloseN, so its body is that body, and this test says so in a
// way a delegation change cannot quietly outlive. It is pinned for the same
// reason the other two are: the safety is TRUE BY CONSTRUCTION, and the
// construction here is "the third exported closer sends no landed key either".
// A future hook that reaches for the simplest closer must find it already
// fenced.
func TestClosePayloadTaskCloseExactKeySet(t *testing.T) {
	body := captureCloseBody(t, func(c *Client) error {
		return c.TaskClose("task-7", "worker-a", 3)
	})

	assertExactKeys(t, body, "worker_id", "observed_epoch", "lifecycle_status")

	if _, hasLanded := body["landed"]; hasLanded {
		t.Error("TaskClose sent a \"landed\" key — that key alone reaches autostamp_merge_gate")
	}
	if _, hasCriteria := body["criteria"]; hasCriteria {
		t.Error("TaskClose sent a \"criteria\" key — an automated close must not stamp criteria")
	}
}
