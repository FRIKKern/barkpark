package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// claimReply is the scripted response for one task's /claim endpoint.
type claimReply struct {
	status int
	body   string
}

// capturedClaim records what a claim POST carried, so a test can assert the
// declared resources travelled in the body.
type capturedClaim struct {
	worker    string
	resources []string
}

// nextFrontierServer serves the board snapshot (two ready tasks in DISTINCT
// neighborhoods so BOTH are frontier picks) plus a scripted /claim per task id.
// It records each claim body so tests can assert the resources travelled. A graph
// fetch (best-effort cross-edge enrichment) is answered 404 so it degrades
// silently instead of tripping the unexpected-path guard.
func nextFrontierServer(t *testing.T, replies map[string]claimReply, captured map[string]*capturedClaim) *httptest.Server {
	t.Helper()
	list := `{"docs":[
		{"doc_id":"task-a","title":"Task A","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:alpha","files:internal/cli/cli.go"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"},
		{"doc_id":"task-b","title":"Task B","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:beta","files:internal/cli/cmux_dispatch.go"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"}
	]}`
	prime := `{"counts":{"open":2},"recent_events":[],"ready":[{"doc_id":"task-a"},{"doc_id":"task-b"}]}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			id := strings.TrimSuffix(strings.TrimPrefix(p, "/v1/tasks/"), "/claim")
			if captured != nil {
				var body struct {
					WorkerID  string   `json:"worker_id"`
					Resources []string `json:"resources"`
				}
				raw, _ := io.ReadAll(r.Body)
				_ = json.Unmarshal(raw, &body)
				captured[id] = &capturedClaim{worker: body.WorkerID, resources: body.Resources}
			}
			rep, ok := replies[id]
			if !ok {
				t.Errorf("no scripted claim reply for %q", id)
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			if rep.status != 0 {
				w.WriteHeader(rep.status)
			}
			_, _ = w.Write([]byte(rep.body))
		case p == "/v1/tasks":
			_, _ = w.Write([]byte(list))
		case p == "/v1/tasks/prime":
			_, _ = w.Write([]byte(prime))
		case strings.HasPrefix(p, "/v1/graph/"):
			w.WriteHeader(http.StatusNotFound) // best-effort cross-edge fetch degrades
		default:
			t.Errorf("unexpected path %s", p)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// Happy path: the top pick is claimed and its id + worker + epoch are printed.
func TestNextFrontierClaimsTopPick(t *testing.T) {
	captured := map[string]*capturedClaim{}
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {body: `{"ok":true,"doc":{"claim":{"epoch":7}}}`},
	}, captured)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runTaskNextFrontierArgs(w, dispatchCtx(srv.URL), []string{"worker-1", "--frontier"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	out := so.String()
	if !strings.Contains(out, "claimed task-a") || !strings.Contains(out, "worker=worker-1") || !strings.Contains(out, "epoch=7") {
		t.Fatalf("output missing claim receipt:\n%s", out)
	}
	// The claim body must carry the task's declared file scope as resources.
	c := captured["task-a"]
	if c == nil || len(c.resources) != 1 || c.resources[0] != "internal/cli/cli.go" {
		t.Fatalf("claim body did not carry the declared resources: %+v", c)
	}
}

// Deny-path (a): the top pick is lost (409 not_ready) → the loop claims the NEXT
// non-colliding pick instead of aborting.
func TestNextFrontierLostRaceSkipsToNext(t *testing.T) {
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {status: http.StatusConflict, body: `{"ok":false,"reason":"not_ready"}`},
		"task-b": {body: `{"ok":true,"doc":{"claim":{"epoch":4}}}`},
	}, nil)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runTaskNextFrontierArgs(w, dispatchCtx(srv.URL), []string{"worker-1", "--frontier"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	out := so.String()
	if !strings.Contains(out, "skipped task-a") || !strings.Contains(out, "not_ready") {
		t.Errorf("expected a not_ready skip line for task-a:\n%s", out)
	}
	if !strings.Contains(out, "claimed task-b") || !strings.Contains(out, "epoch=4") {
		t.Errorf("expected task-b to be claimed after the lost race:\n%s", out)
	}
}

// Deny-path (b): a 409 resource_conflict names the holder task + worker on the
// skip line, then the loop claims the next pick.
func TestNextFrontierResourceConflictNamesHolder(t *testing.T) {
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {status: http.StatusConflict, body: `{"ok":false,"reason":"resource_conflict","conflicts":[{"task":"task-z","worker":"worker-9","resources":["internal/cli/cli.go"]}]}`},
		"task-b": {body: `{"ok":true,"doc":{"claim":{"epoch":2}}}`},
	}, nil)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runTaskNextFrontierArgs(w, dispatchCtx(srv.URL), []string{"worker-1", "--frontier"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	out := so.String()
	if !strings.Contains(out, "resource_conflict") || !strings.Contains(out, "task-z") || !strings.Contains(out, "worker-9") {
		t.Errorf("resource_conflict skip did not name the holder task-z/worker-9:\n%s", out)
	}
	if !strings.Contains(out, "claimed task-b") {
		t.Errorf("expected task-b claimed after the conflict:\n%s", out)
	}
}

// Deny-path (c): a won claim with epoch 0/absent is a HARD failure — nothing is
// claimed and the exit is non-zero.
func TestNextFrontierMissingEpochHardFails(t *testing.T) {
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {body: `{"ok":true,"doc":{}}`}, // ok but no fencing epoch
	}, nil)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runTaskNextFrontierArgs(w, dispatchCtx(srv.URL), []string{"worker-1", "--frontier"})
	if code == exitOK {
		t.Fatalf("exit = %d, want non-zero on a missing-epoch claim", code)
	}
	if strings.Contains(so.String(), "claimed") {
		t.Errorf("nothing must be claimed on the epoch failure:\n%s", so.String())
	}
}

// The `bp task ready` capacity header names the frontier size from the SAME
// taskboard.Frontier the `frontier` verb reads (two distinct-neighborhood ready
// tasks → 2 independent). A fetch error would drop the header silently.
func TestReadyFrontierHeader(t *testing.T) {
	srv := nextFrontierServer(t, map[string]claimReply{}, nil)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	printReadyFrontierHeader(w, dispatchCtx(srv.URL))
	if !strings.Contains(so.String(), "FRONTIER · 2 independent") {
		t.Fatalf("ready header missing the capacity line:\n%s", so.String())
	}
}

// runTaskNextFrontierArgs is the test entry point: parse the `next` tail exactly
// as cli.go does, then run the frontier claim. It keeps the tests honest about
// the real arg-parsing path (worker positional + --frontier marker).
func runTaskNextFrontierArgs(w *writer, ctx manifest.Context, tail []string) int {
	worker, opts, err := parseNextFrontierArgs(tail)
	if err != nil {
		w.userErr("%v", err)
		return exitUsage
	}
	return runTaskNextFrontier(w, globals{}, ctx, worker, opts)
}
