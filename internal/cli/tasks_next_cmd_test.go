package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
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
		"task-a": {status: http.StatusConflict, body: `{"ok":false,"reason":"resource_conflict","conflicts":[{"doc_id":"task-z","worker":"worker-9","resources":["internal/cli/cli.go"]}]}`},
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

// Deny-path (d): when EVERY pick is lost in EVERY round, the loop stops after
// frontierClaimRounds bounded rounds and reports an honest "frontier exhausted"
// — it never spins forever against a hot claim race. The skip-line count pins
// the bound: 2 picks × frontierClaimRounds rounds, then stop.
func TestNextFrontierExhaustedAfterBoundedRounds(t *testing.T) {
	lost := claimReply{status: http.StatusConflict, body: `{"ok":false,"reason":"not_ready"}`}
	srv := nextFrontierServer(t, map[string]claimReply{"task-a": lost, "task-b": lost}, nil)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runTaskNextFrontierArgs(w, dispatchCtx(srv.URL), []string{"worker-1", "--frontier"})
	if code == exitOK {
		t.Fatalf("exit = %d, want non-zero when the frontier is exhausted", code)
	}
	if !strings.Contains(se.String(), "frontier exhausted") {
		t.Errorf("expected an honest frontier-exhausted message, got:\n%s", se.String())
	}
	if got, want := strings.Count(so.String(), "skipped"), 2*frontierClaimRounds; got != want {
		t.Errorf("skip lines = %d, want %d (2 picks × %d bounded rounds — the loop must stop)",
			got, want, frontierClaimRounds)
	}
}

// TestNextFrontierClaimRendersHelpAndNotices pins charter D18: the frontier
// claim BYPASSES runCommand, so the server's help[] next-command templates and
// rail-awareness notices — decoded on the claim outcome but silently dropped
// before this slice — must be surfaced explicitly. Human mode routes them to
// stderr (the emitHelpHints / emitNotices house pattern), leaving stdout the
// clean claim receipt.
func TestNextFrontierClaimRendersHelpAndNotices(t *testing.T) {
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {body: `{"ok":true,"doc":{"claim":{"epoch":7}},` +
			`"help":["bp task pulse task-a worker-1 --now \"...\"","bp task close task-a worker-1 7 done \"...\""],` +
			`"notices":[{"type":"blocked_while_claimed","task_id":"task-q","blockers":["dep-1"]}]}`},
	}, nil)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runTaskNextFrontierArgs(w, dispatchCtx(srv.URL), []string{"worker-1", "--frontier"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	// The claim receipt stays on stdout, clean.
	if !strings.Contains(so.String(), "claimed task-a") {
		t.Fatalf("stdout missing the claim receipt:\n%s", so.String())
	}
	// help[] + notices ride stderr, one line each.
	if !strings.Contains(se.String(), "help: bp task pulse task-a worker-1") {
		t.Errorf("stderr missing the server help template:\n%s", se.String())
	}
	if !strings.Contains(se.String(), "help: bp task close task-a worker-1 7 done") {
		t.Errorf("stderr missing the second help template:\n%s", se.String())
	}
	if !strings.Contains(se.String(), "notice: blocked_while_claimed task=task-q blockers=dep-1") {
		t.Errorf("stderr missing the rail-awareness notice:\n%s", se.String())
	}
	// The advisories must NOT leak onto stdout — it stays one parseable receipt.
	if strings.Contains(so.String(), "help:") || strings.Contains(so.String(), "notice:") {
		t.Errorf("advisories leaked onto stdout (must be stderr):\n%s", so.String())
	}
}

// TestNextFrontierClaimJSONCarriesHelpAndNotices: in machine mode the frontier
// claim's hand-built JSON must ALSO carry help/notices as fields (the frontier
// bypasses renderSuccess, which would otherwise echo them from the raw body), so
// a piped agent reads them off stdout — parity with every runCommand verb.
func TestNextFrontierClaimJSONCarriesHelpAndNotices(t *testing.T) {
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {body: `{"ok":true,"doc":{"claim":{"epoch":7}},"help":["do X next"],` +
			`"notices":[{"type":"rail_changed","parent_id":"epic-1","rail_rev":"r9"}]}`},
	}, nil)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runTaskNextFrontier(w, globals{}, dispatchCtx(srv.URL), "worker-1", taskboard.FrontierOpts{})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	var env struct {
		OK      bool     `json:"ok"`
		Help    []string `json:"help"`
		Notices []struct {
			Type string `json:"type"`
		} `json:"notices"`
		Claimed struct {
			ID     string `json:"id"`
			Worker string `json:"worker"`
			Epoch  *int   `json:"epoch"`
		} `json:"claimed"`
	}
	if err := json.Unmarshal(so.Bytes(), &env); err != nil {
		t.Fatalf("json stdout not parseable: %v\n%s", err, so.String())
	}
	// The claim receipt must carry the GRANTED epoch. It is the CAS token
	// `bp task close <id> <worker> <epoch>` requires and the one the tasks rules
	// promise `bp task next` returns — yet deleting `"epoch": epoch` from
	// emitFrontierClaim reddened NOTHING repo-wide (go test ./... rc=0, 29 ok
	// packages) before this assertion existed: the human line prints the epoch
	// separately, and no JSON test decoded `claimed`. A pointer, not an int, so
	// an ABSENT key fails here rather than reading as the zero epoch.
	if env.Claimed.Epoch == nil {
		t.Fatalf("claim receipt carried no claimed.epoch — the close CAS token is missing:\n%s", so.String())
	}
	if *env.Claimed.Epoch != 7 {
		t.Errorf("claimed.epoch = %d, want 7 (the epoch the server granted):\n%s", *env.Claimed.Epoch, so.String())
	}
	if env.Claimed.ID != "task-a" || env.Claimed.Worker != "worker-1" {
		t.Errorf("claimed id/worker drifted from the granted claim:\n%s", so.String())
	}
	if !env.OK || len(env.Help) != 1 || env.Help[0] != "do X next" {
		t.Errorf("json payload missing help[]:\n%s", so.String())
	}
	if len(env.Notices) != 1 || env.Notices[0].Type != "rail_changed" {
		t.Errorf("json payload missing notices[]:\n%s", so.String())
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

// TestReadyFrontierHeaderZeroGraphCalls — D12/D4 deny-path: the ready header
// must compute its capacity with ZERO graph calls, so a graph endpoint that
// BLOCKS FOREVER cannot stall `bp task ready`. The snapshot deliberately spans
// two epic roots (task-a and task-b are parentless) — exactly the
// ReadyRootSpan>=2 state that used to arm the sequential per-root fan-out and
// stall the interactive path for minutes on a live board.
func TestReadyFrontierHeaderZeroGraphCalls(t *testing.T) {
	var graphHits atomic.Int32
	list := `{"docs":[
		{"doc_id":"task-a","title":"Task A","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:alpha"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"},
		{"doc_id":"task-b","title":"Task B","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:beta"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"}
	]}`
	prime := `{"counts":{"open":2},"recent_events":[],"ready":[{"doc_id":"task-a"},{"doc_id":"task-b"}]}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/tasks":
			_, _ = w.Write([]byte(list))
		case r.URL.Path == "/v1/tasks/prime":
			_, _ = w.Write([]byte(prime))
		case strings.HasPrefix(r.URL.Path, "/v1/graph/"):
			graphHits.Add(1)
			<-r.Context().Done() // block "forever" — released only when the caller gives up
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	start := time.Now()
	printReadyFrontierHeader(w, dispatchCtx(srv.URL))
	elapsed := time.Since(start)

	if got := graphHits.Load(); got != 0 {
		t.Fatalf("graph endpoint hit %d time(s), want 0 — the ready header must not fan out", got)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("ready header took %v — it must answer instantly", elapsed)
	}
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

// TestNextFrontierFetchFailureEmitsJSONEnvelope pins the fetchSnapshotErr fix
// (wbqs-go-board-fetch-error-envelope): before the fix, a failed
// taskboard.FetchSnapshotFull hit `out.userErr(...); return exitGeneric` with
// no machineOut() check, so `bp task next <worker> --frontier -o json | jq` on
// a broken board fetch got EMPTY stdout. It must now emit a parseable
// {"ok":false,"error":{"code":...,"message":...}} envelope on stdout.
func TestNextFrontierFetchFailureEmitsJSONEnvelope(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runTaskNextFrontier(w, globals{}, dispatchCtx(srv.URL), "worker-1", taskboard.FrontierOpts{})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric (%d)", code, exitGeneric)
	}
	if se.Len() != 0 {
		t.Errorf("json mode must not also leak the human stderr line:\n%s", se.String())
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(so.Bytes(), &env); err != nil {
		t.Fatalf("json stdout not parseable (empty stdout is exactly the pre-fix bug): %v\n%s", err, so.String())
	}
	if env.OK || env.Error.Code == "" || env.Error.Message == "" {
		t.Errorf("bad fetch-failure envelope:\n%s", so.String())
	}
}
