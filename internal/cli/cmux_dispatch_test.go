package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// dispatchServer serves the two task endpoints with two ready tasks in DISTINCT
// neighborhoods (proj:alpha / proj:beta) so taskboard.Frontier admits both.
func dispatchServer(t *testing.T) *httptest.Server {
	t.Helper()
	list := `{"docs":[
		{"doc_id":"task-a","title":"Task A","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:alpha"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"},
		{"doc_id":"task-b","title":"Task B","lifecycle_status":"open","kind":"task","priority":1,"labels":["proj:beta"],"inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"}
	]}`
	prime := `{"counts":{"open":2},"recent_events":[],"ready":[{"doc_id":"task-a"},{"doc_id":"task-b"}]}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/tasks":
			_, _ = w.Write([]byte(list))
		case "/v1/tasks/prime":
			_, _ = w.Write([]byte(prime))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func dispatchCtx(server string) manifest.Context {
	return manifest.Context{Server: server, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
}

// withCmuxSeams installs test seams for cmux presence + spawn and restores them.
func withCmuxSeams(t *testing.T, present bool, spawn func(id, cwd, cmd string) error) {
	t.Helper()
	oldLook, oldSpawn := cmuxLookPath, cmuxSpawn
	cmuxLookPath = func() (string, bool) { return "/fake/cmux", present }
	cmuxSpawn = spawn
	t.Cleanup(func() { cmuxLookPath, cmuxSpawn = oldLook, oldSpawn })
}

// --dry-run prints exactly one cmux invocation per Frontier pick and spawns
// nothing (design §4 safety spine).
func TestDispatchDryRunPrintsPerPick(t *testing.T) {
	srv := dispatchServer(t)
	spawns := 0
	withCmuxSeams(t, true, func(id, cwd, cmd string) error { spawns++; return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runCmuxDispatch(w, globals{dryRun: true}, dispatchCtx(srv.URL), nil)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if spawns != 0 {
		t.Errorf("spawned %d panes under --dry-run, want 0", spawns)
	}
	n := strings.Count(so.String(), "cmux new-workspace")
	if n != 2 {
		t.Fatalf("printed %d invocations, want 2 (one per pick)\n%s", n, so.String())
	}
	if !strings.Contains(so.String(), "BARKPARK_TASK=task-a") || !strings.Contains(so.String(), "BARKPARK_TASK=task-b") {
		t.Errorf("invocations missing BARKPARK_TASK env:\n%s", so.String())
	}
	if !strings.Contains(so.String(), "dry-run") {
		t.Errorf("header did not mark dry-run mode:\n%s", so.String())
	}
}

// Absent cmux FORCES dry-run even without the flag (you cannot spawn what isn't
// installed).
func TestDispatchAbsentCmuxForcesDryRun(t *testing.T) {
	srv := dispatchServer(t)
	spawns := 0
	withCmuxSeams(t, false, func(id, cwd, cmd string) error { spawns++; return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runCmuxDispatch(w, globals{}, dispatchCtx(srv.URL), nil)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if spawns != 0 {
		t.Errorf("spawned %d panes with cmux absent, want 0 (forced dry-run)", spawns)
	}
	if !strings.Contains(so.String(), "cmux not on PATH") {
		t.Errorf("header did not explain the forced dry-run:\n%s", so.String())
	}
}

// With cmux present and --dry-run off, dispatch spawns one pane per pick; a
// spawn failure on one pick continues the batch (design §7).
func TestDispatchSpawnsAndContinuesOnFailure(t *testing.T) {
	srv := dispatchServer(t)
	var got []string
	withCmuxSeams(t, true, func(id, cwd, cmd string) error {
		got = append(got, id)
		if id == "task-a" {
			return os.ErrPermission // one bad surface
		}
		return nil
	})

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runCmuxDispatch(w, globals{}, dispatchCtx(srv.URL), nil)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if len(got) != 2 {
		t.Fatalf("spawn attempts = %v, want both picks attempted despite the failure", got)
	}
	if !strings.Contains(so.String(), "dispatched 1 pane(s)") || !strings.Contains(so.String(), "1 failed") {
		t.Errorf("summary did not honestly report 1 spawned / 1 failed:\n%s", so.String())
	}
}

// --max reaches FrontierOpts (caps the emitted picks).
func TestDispatchMaxReachesFrontierOpts(t *testing.T) {
	srv := dispatchServer(t)
	withCmuxSeams(t, true, func(id, cwd, cmd string) error { return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runCmuxDispatch(w, globals{dryRun: true}, dispatchCtx(srv.URL), []string{"--max", "1"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if n := strings.Count(so.String(), "cmux new-workspace"); n != 1 {
		t.Errorf("--max 1 emitted %d invocations, want 1:\n%s", n, so.String())
	}
}

// Guard: dispatch reads the SHARED taskboard.Frontier — never a second
// interference model. This tripwire fails if a future edit inlines its own
// candidate/interference loop instead of importing the wave-13 function.
func TestDispatchUsesSharedFrontier(t *testing.T) {
	src, err := os.ReadFile("cmux_dispatch.go")
	if err != nil {
		t.Fatalf("read source: %v", err)
	}
	if !strings.Contains(string(src), "taskboard.Frontier(") {
		t.Error("cmux_dispatch.go must call taskboard.Frontier — the one shared interference model")
	}
	for _, banned := range []string{"func interferes", "greedy MWIS", "neighborhoodKey("} {
		if strings.Contains(string(src), banned) {
			t.Errorf("cmux_dispatch.go reimplements frontier logic (%q) — import taskboard.Frontier instead", banned)
		}
	}
}

// --claim claims each pick (declaring its file scope) BEFORE spawning: the
// winner is spawned with its lease (worker + epoch) in the pane env, and a pick
// lost to a file-scope conflict is skipped with its holder named — never spawned.
func TestDispatchClaimSpawnsOnlyWinners(t *testing.T) {
	captured := map[string]*capturedClaim{}
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {body: `{"ok":true,"doc":{"claim":{"epoch":5}}}`},
		"task-b": {status: http.StatusConflict, body: `{"ok":false,"reason":"resource_conflict","conflicts":[{"doc_id":"task-z","worker":"worker-9","resources":["internal/cli/cmux_dispatch.go"]}]}`},
	}, captured)

	var got []string
	withCmuxSeams(t, true, func(id, cwd, cmd string) error { got = append(got, cmd); return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runCmuxDispatch(w, globals{}, dispatchCtx(srv.URL), []string{"--claim"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	if len(got) != 1 {
		t.Fatalf("spawned %d panes, want only the 1 winner:\n%v", len(got), got)
	}
	// The winner's pane env carries the observed lease and the claimed task.
	if !strings.Contains(got[0], "BARKPARK_TASK=task-a") ||
		!strings.Contains(got[0], "BARKPARK_TASK_EPOCH=5") ||
		!strings.Contains(got[0], "BARKPARK_WORKER_ID=") {
		t.Errorf("winner pane env missing the lease (worker+epoch+task):\n%s", got[0])
	}
	// The claim body declared the pick's file scope.
	if c := captured["task-a"]; c == nil || len(c.resources) != 1 || c.resources[0] != "internal/cli/cli.go" {
		t.Errorf("winner claim did not carry the declared resources: %+v", captured["task-a"])
	}
	// The loser is named with its holder and NOT spawned.
	out := so.String()
	if !strings.Contains(out, "skipped task-b") || !strings.Contains(out, "task-z") || !strings.Contains(out, "worker-9") {
		t.Errorf("loser skip did not name the holder task-z/worker-9:\n%s", out)
	}
	if strings.Contains(got[0], "task-b") {
		t.Errorf("task-b must not be spawned — it lost the file fence:\n%v", got)
	}
}

// TestDispatchClaimRendersHelpAndNotices pins charter D18 on the cmux --claim
// path (which BYPASSES runCommand): on a won claim the server's help[] templates
// and rail-awareness notices are surfaced to stderr, one line each, instead of
// being silently dropped. stdout keeps the clean spawn receipt.
func TestDispatchClaimRendersHelpAndNotices(t *testing.T) {
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {body: `{"ok":true,"doc":{"claim":{"epoch":5}},` +
			`"help":["bp task pulse task-a w --now \"...\""],` +
			`"notices":[{"type":"rail_changed","parent_id":"epic-1","rail_rev":"r3"}]}`},
		"task-b": {body: `{"ok":true,"doc":{"claim":{"epoch":6}}}`},
	}, nil)
	withCmuxSeams(t, true, func(id, cwd, cmd string) error { return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runCmuxDispatch(w, globals{}, dispatchCtx(srv.URL), []string{"--claim"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	if !strings.Contains(se.String(), "help: bp task pulse task-a w") {
		t.Errorf("dispatch --claim dropped the server help template:\n%s", se.String())
	}
	if !strings.Contains(se.String(), "notice: rail_changed parent=epic-1 rail_rev=r3") {
		t.Errorf("dispatch --claim dropped the rail-awareness notice:\n%s", se.String())
	}
	// The spawn receipt (stdout) stays clean — advisories are stderr-only.
	if strings.Contains(so.String(), "help:") || strings.Contains(so.String(), "notice:") {
		t.Errorf("advisories leaked onto stdout (must be stderr):\n%s", so.String())
	}
}

// Default dispatch (no --claim) claims NOTHING — the pane derives and claims its
// own lease at SessionStart. This asserts the byte-unchanged default path never
// hits the /claim endpoint.
func TestDispatchDefaultNeverClaims(t *testing.T) {
	captured := map[string]*capturedClaim{}
	srv := nextFrontierServer(t, map[string]claimReply{}, captured)

	withCmuxSeams(t, true, func(id, cwd, cmd string) error { return nil })

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := runCmuxDispatch(w, globals{}, dispatchCtx(srv.URL), nil)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr=%s", code, se.String())
	}
	if len(captured) != 0 {
		t.Errorf("default dispatch claimed %d task(s), want 0 (pane self-claims):\n%v", len(captured), captured)
	}
}

// TestDispatchFetchFailureEmitsJSONEnvelope pins the fetchSnapshotErr fix
// (wbqs-go-board-fetch-error-envelope): before the fix, a failed
// taskboard.FetchSnapshotFull hit `out.userErr(...); return exitGeneric` with
// no machineOut() check, so `bp cmux dispatch -o json | jq` on a broken board
// fetch got EMPTY stdout. It must now emit a parseable
// {"ok":false,"error":{"code":...,"message":...}} envelope on stdout.
func TestDispatchFetchFailureEmitsJSONEnvelope(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runCmuxDispatch(w, globals{dryRun: true}, dispatchCtx(srv.URL), nil)
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

// shellSingleQuote escapes embedded single quotes so a title with an apostrophe
// stays one safe shell token.
func TestShellSingleQuote(t *testing.T) {
	got := shellSingleQuote("it's a 'test'")
	want := `'it'\''s a '\''test'\'''`
	if got != want {
		t.Errorf("shellSingleQuote = %q, want %q", got, want)
	}
}
