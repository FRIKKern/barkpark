package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// railDispatchServer serves two ready tasks that SHARE ONE PARENT RAIL
// (epic-1) — the shape a dispatch batch actually has when it fans an epic's
// children into panes. It records each claim's observed_rail_rev and replays a
// rail_rev per task, and it fires the server's own rail_changed advisory under
// exactly the server's rule: only when the claim SUPPLIED observed_rail_rev and
// that value differs from the rail's current rev
// (api/lib/barkpark_web/controllers/tasks_controller.ex add_rail_changed_notice/5).
func railDispatchServer(t *testing.T, observed *[]string) *httptest.Server {
	t.Helper()
	list := `{"docs":[
		{"doc_id":"task-a","title":"Task A","lifecycle_status":"open","kind":"task","priority":1,"parent_id":"epic-1","labels":["proj:alpha","files:internal/cli/cli.go"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"},
		{"doc_id":"task-b","title":"Task B","lifecycle_status":"open","kind":"task","priority":1,"parent_id":"epic-1","labels":["proj:beta","files:internal/cli/cmux_dispatch.go"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"}
	]}`
	prime := `{"counts":{"open":2},"recent_events":[],"ready":[{"doc_id":"task-a"},{"doc_id":"task-b"}]}`
	// The rail moved between the two claims (a concurrent sibling edited it):
	// task-a's claim leaves the rail at rev-1, task-b's claim finds rev-2.
	revs := map[string]string{"task-a": "rev-1", "task-b": "rev-2"}
	epoch := map[string]int{"task-a": 5, "task-b": 6}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			id := strings.TrimSuffix(strings.TrimPrefix(p, "/v1/tasks/"), "/claim")
			var body struct {
				ObservedRailRev string `json:"observed_rail_rev"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			*observed = append(*observed, body.ObservedRailRev)

			env := map[string]any{
				"ok":       true,
				"doc":      map[string]any{"claim": map[string]any{"epoch": epoch[id]}},
				"rail_rev": revs[id],
			}
			// The server's rule, verbatim: supplied AND different.
			if body.ObservedRailRev != "" && body.ObservedRailRev != revs[id] {
				env["notices"] = []map[string]any{
					{"type": "rail_changed", "parent_id": "epic-1", "rail_rev": revs[id]},
				}
			}
			out, _ := json.Marshal(env)
			_, _ = w.Write(out)
		case p == "/v1/tasks":
			_, _ = w.Write([]byte(list))
		case p == "/v1/tasks/prime":
			_, _ = w.Write([]byte(prime))
		case strings.HasPrefix(p, "/v1/graph/"):
			w.WriteHeader(http.StatusNotFound)
		default:
			t.Errorf("unexpected path %s", p)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// THE LOUD ARM (wb-bl-go-railrev-claim-plumbing). Dispatch must carry the rail
// baseline forward: the FIRST claim in a rail has none (the client has no
// source yet), the SECOND observes against the rev the first claim's envelope
// handed back — and because a sibling moved the rail in between, the server's
// rail_changed advisory fires and renders through the existing
// emitTaskNoticeLines path (cmux_dispatch.go) as "notice: rail_changed".
//
// Revert either half of the change — the railBaselines write after a won claim,
// or the TaskClaimResourcesObserved read before the next claim — and this test
// fails: claim #2 sends "" , the server stays silent, and stderr has no notice.
func TestDispatchCarriesRailBaselineAndRendersRailChanged(t *testing.T) {
	var observed []string
	srv := railDispatchServer(t, &observed)
	withCmuxSeams(t, true, func(id, cwd, cmd string) error { return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxDispatch(w, globals{}, dispatchCtx(srv.URL), []string{"--claim"}); code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s%s", code, so.String(), se.String())
	}
	if len(observed) != 2 {
		t.Fatalf("recorded %d claims, want 2 (both picks share epic-1): %v", len(observed), observed)
	}
	if observed[0] != "" {
		t.Errorf("first claim in the rail sent observed_rail_rev=%q, want \"\" — the client has no baseline yet", observed[0])
	}
	if observed[1] != "rev-1" {
		t.Fatalf("second claim sent observed_rail_rev=%q, want \"rev-1\" (the rev the first claim's envelope returned)", observed[1])
	}
	if !strings.Contains(se.String(), "notice: rail_changed parent=epic-1 rail_rev=rev-2") {
		t.Errorf("the rail_changed advisory did not render through the dispatch notice path:\n%s", se.String())
	}
}

// THE QUIET ARM. Picks with NO parent have no rail, so dispatch must neither
// read nor write the baseline cache: every claim goes out with no
// observed_rail_rev, the server (by its own rule) emits nothing, and stderr
// carries no rail notice. This is the test that reds if the fix ever starts
// sending a baseline it does not have — e.g. keying the cache on "" and letting
// one parentless task's rev leak onto the next.
func TestDispatchParentlessPicksSendNoRailBaseline(t *testing.T) {
	var observed []string
	srv := railDispatchServerParentless(t, &observed)
	withCmuxSeams(t, true, func(id, cwd, cmd string) error { return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxDispatch(w, globals{}, dispatchCtx(srv.URL), []string{"--claim"}); code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s%s", code, so.String(), se.String())
	}
	if len(observed) != 2 {
		t.Fatalf("recorded %d claims, want 2: %v", len(observed), observed)
	}
	for i, o := range observed {
		if o != "" {
			t.Errorf("parentless claim %d sent observed_rail_rev=%q, want \"\"", i, o)
		}
	}
	if strings.Contains(se.String(), "rail_changed") {
		t.Errorf("a parentless dispatch must raise no rail notice:\n%s", se.String())
	}
}

// Same server, minus parent_id — the control that isolates "shares a rail" as
// the only difference between the two arms.
func railDispatchServerParentless(t *testing.T, observed *[]string) *httptest.Server {
	t.Helper()
	list := `{"docs":[
		{"doc_id":"task-a","title":"Task A","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:alpha","files:internal/cli/cli.go"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"},
		{"doc_id":"task-b","title":"Task B","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:beta","files:internal/cli/cmux_dispatch.go"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"}
	]}`
	prime := `{"counts":{"open":2},"recent_events":[],"ready":[{"doc_id":"task-a"},{"doc_id":"task-b"}]}`
	epoch := map[string]int{"task-a": 5, "task-b": 6}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			id := strings.TrimSuffix(strings.TrimPrefix(p, "/v1/tasks/"), "/claim")
			var body struct {
				ObservedRailRev string `json:"observed_rail_rev"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			*observed = append(*observed, body.ObservedRailRev)
			// A parentless task gets NO rail_rev field — exactly what
			// with_rail_extras/5 does when task_parent_id is nil.
			out, _ := json.Marshal(map[string]any{
				"ok":  true,
				"doc": map[string]any{"claim": map[string]any{"epoch": epoch[id]}},
			})
			_, _ = w.Write(out)
		case p == "/v1/tasks":
			_, _ = w.Write([]byte(list))
		case p == "/v1/tasks/prime":
			_, _ = w.Write([]byte(prime))
		case strings.HasPrefix(p, "/v1/graph/"):
			w.WriteHeader(http.StatusNotFound)
		default:
			t.Errorf("unexpected path %s", p)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}
