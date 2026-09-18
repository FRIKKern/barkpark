package apiclient

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// claimBodyRecorder serves one scripted claim reply and records the EXACT bytes
// of every claim request body — the byte-identity arm needs the raw body, not a
// decoded map, because the whole omission contract is about which keys are on
// the wire.
func claimBodyRecorder(t *testing.T, reply string, bodies *[]string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/claim") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		*bodies = append(*bodies, string(raw))
		_, _ = w.Write([]byte(reply))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// THE LOUD ARM. A non-empty observedRailRev must reach the wire as
// `observed_rail_rev` — the key the server's add_rail_changed_notice/5 guard
// requires before it will emit the rail_changed advisory at all. Reverting the
// `if observedRailRev != ""` branch in claimPayload to never set the key fails
// BOTH of these.
func TestClaimSendsObservedRailRevWhenNonEmpty(t *testing.T) {
	var bodies []string
	srv := claimBodyRecorder(t, `{"ok":true,"doc":{"claim":{"epoch":3}},"rail_rev":"aaaabbbbccccdddd"}`, &bodies)
	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})

	if _, _, _, rev, err := c.TaskClaimObservedN("task-7", "worker-a", "1111222233334444"); err != nil {
		t.Fatalf("TaskClaimObservedN: %v", err)
	} else if rev != "aaaabbbbccccdddd" {
		t.Errorf("rail_rev = %q, want the envelope's aaaabbbbccccdddd (the next claim's baseline)", rev)
	}
	out, err := c.TaskClaimResourcesObserved("task-7", "worker-a", []string{"a.go"}, "1111222233334444")
	if err != nil {
		t.Fatalf("TaskClaimResourcesObserved: %v", err)
	}
	if out.RailRev != "aaaabbbbccccdddd" {
		t.Errorf("outcome.RailRev = %q, want aaaabbbbccccdddd", out.RailRev)
	}
	if len(bodies) != 2 {
		t.Fatalf("recorded %d claim bodies, want 2", len(bodies))
	}
	for i, b := range bodies {
		if !strings.Contains(b, `"observed_rail_rev":"1111222233334444"`) {
			t.Errorf("claim body %d omitted observed_rail_rev: %s", i, b)
		}
	}
}

// THE QUIET ARM. An EMPTY observedRailRev must keep the request byte-identical
// to the claim every caller sent before this change: exactly {"worker_id":…}
// for the bare claim and worker_id+resources for the resources claim. No
// `"observed_rail_rev":""`, no key at all. A client with no rail baseline yet
// must not start sending an empty key to every unrelated consumer.
func TestClaimWithoutBaselineIsByteIdenticalToTheOldRequest(t *testing.T) {
	var bodies []string
	srv := claimBodyRecorder(t, `{"ok":true,"doc":{"claim":{"epoch":3}}}`, &bodies)
	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})

	if _, err := c.TaskClaim("task-7", "worker-a"); err != nil {
		t.Fatalf("TaskClaim: %v", err)
	}
	if _, _, _, err := c.TaskClaimN("task-7", "worker-a"); err != nil {
		t.Fatalf("TaskClaimN: %v", err)
	}
	if _, _, _, _, err := c.TaskClaimObservedN("task-7", "worker-a", ""); err != nil {
		t.Fatalf("TaskClaimObservedN(\"\"): %v", err)
	}
	if _, err := c.TaskClaimResources("task-7", "worker-a", nil); err != nil {
		t.Fatalf("TaskClaimResources: %v", err)
	}
	for i, b := range bodies {
		if b != `{"worker_id":"worker-a"}` {
			t.Errorf("claim body %d = %s, want the byte-identical {\"worker_id\":\"worker-a\"}", i, b)
		}
	}

	bodies = nil
	if _, err := c.TaskClaimResourcesObserved("task-7", "worker-a", []string{"a.go"}, ""); err != nil {
		t.Fatalf("TaskClaimResourcesObserved(\"\"): %v", err)
	}
	if len(bodies) != 1 || bodies[0] != `{"resources":["a.go"],"worker_id":"worker-a"}` {
		t.Fatalf("resources claim with no baseline = %v, want the unchanged worker_id+resources body", bodies)
	}
}
