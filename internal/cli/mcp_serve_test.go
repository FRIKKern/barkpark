package cli

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpTestManifest is a minimal capabilities manifest carrying exactly the task
// verbs the curated tools map onto — the same HTTP shapes the live manifest and
// the docs/cli/fixtures manifests declare. Kept inline so the test does not
// depend on a fixture file path.
const mcpTestManifest = `{
  "manifest_version": "1",
  "server": {"name": "test", "version": "0", "base_url": "http://x"},
  "auth_tier": "admin",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {"id":"task.ready","noun":"task","verb":"ready","summary":"ready","http":{"method":"GET","path_template":"/v1/tasks/ready"},"auth_tier":"read","args":[],"flags":[{"name":"order","type":"string","summary":"o"}],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"task.prime","noun":"task","verb":"prime","summary":"prime","http":{"method":"GET","path_template":"/v1/tasks/prime"},"auth_tier":"read","args":[],"flags":[{"name":"worker","type":"string","summary":"w"},{"name":"limit","type":"int","summary":"l"},{"name":"order","type":"string","summary":"o"}],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"json"},
    {"id":"task.get","noun":"task","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"task.next","noun":"task","verb":"next","summary":"next","http":{"method":"POST","path_template":"/v1/tasks/claim"},"auth_tier":"read","args":[{"name":"worker_id","required":true,"type":"string","summary":"w"}],"flags":[{"name":"order","type":"string","summary":"o"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.close","noun":"task","verb":"close","summary":"close","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/close"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"},{"name":"observed_epoch","required":true,"type":"int","summary":"e"},{"name":"lifecycle_status","required":false,"type":"string","summary":"s"},{"name":"reason","required":false,"type":"string","summary":"r"}],"flags":[{"name":"set","repeatable":true,"type":"string","summary":"extra close-body fields"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.stamp","noun":"task","verb":"stamp","summary":"stamp","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/stamp"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"},{"name":"observed_epoch","required":true,"type":"int","summary":"e"}],"flags":[{"name":"criterion","type":"int","summary":"idx"},{"name":"met","type":"bool","summary":"m"},{"name":"evidence","type":"string","summary":"ev"},{"name":"miss","type":"bool","summary":"x"},{"name":"note","type":"string","summary":"n"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.pulse","noun":"task","verb":"pulse","summary":"pulse","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/pulse"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"}],"flags":[{"name":"now","type":"string","summary":"nowline"},{"name":"criterion","type":"int","summary":"idx"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"}
  ]
}`

// TestMCPServeToolsLiveOverInMemory drives the MCP server the way a real client
// would — initialize handshake, tools/list, tools/call — over an in-memory
// transport (the SDK's StdioTransport hardcodes os.Stdout, so a stdio test would
// fight the real stdout; NewInMemoryTransports is the SDK's own test seam). It
// asserts the curated eight tools are advertised, that a call returns the backing
// HTTP response as content, that the empty-queue 200 is NOT flagged an error,
// that an HTTP >= 400 IS, and that bp's server code writes ZERO bytes to
// os.Stdout (the invariant that keeps a real stdio session's protocol stream
// uncorrupted).
func TestMCPServeToolsLiveOverInMemory(t *testing.T) {
	// Capture os.Stdout for the whole test: any stray write from bp's MCP code is
	// a protocol-corruption bug under a real stdio transport.
	origStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	restore := func() { os.Stdout = origStdout }
	defer restore()
	// Drain the pipe concurrently. A darwin pipe's buffer starts at 512 bytes
	// (Linux gives 64 KiB), so a reader that only runs after the code under test
	// returns turns the very failure this asserts on — a stray write to
	// os.Stdout — into a deadlock instead of an assertion.
	stdoutCh := make(chan []byte, 1)
	go func() { b, _ := io.ReadAll(r); stdoutCh <- b }()

	// A stand-in Barkpark API. Routes by path so one server backs every tool call.
	// closeBody captures what the task_close handler actually POSTed, so the
	// test can prove the MCP→tail→seam translation placed every field in the
	// request body exactly as `bp task close … --set criteria:=[…]` would.
	var closeBody []byte
	var primeQuery, readyQuery, showQuery, nextQuery string
	// stamp/pulse capture: body proves the positionals landed in the JSON body,
	// query proves the flags rode as query params — the whole tail→seam translation.
	var stampBody, pulseBody []byte
	var stampQuery, pulseQuery string
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		switch {
		case req.URL.Path == "/v1/tasks/prime":
			// Capture the query so the test can prove worker/limit rode as query
			// params (task.prime declares them as flags → query via inference).
			primeQuery = req.URL.RawQuery
			io.WriteString(rw, `{"result":{"primed":true}}`)
		case req.URL.Path == "/v1/tasks/ready":
			readyQuery = req.URL.RawQuery
			io.WriteString(rw, `{"result":{"tasks":[{"doc_id":"t1"}]}}`)
		case req.URL.Path == "/v1/tasks/t1":
			showQuery = req.URL.RawQuery
			io.WriteString(rw, `{"result":{"doc_id":"t1","title":"first"}}`)
		case req.URL.Path == "/v1/tasks/claim":
			nextQuery = req.URL.RawQuery
			// Empty queue: 200 with ok:false — a valid outcome, not an error.
			io.WriteString(rw, `{"ok":false,"reason":"no_ready"}`)
		case strings.HasSuffix(req.URL.Path, "/stamp"):
			stampBody, _ = io.ReadAll(req.Body)
			stampQuery = req.URL.RawQuery
			io.WriteString(rw, `{"ok":true,"doc":{"doc_id":"t1"}}`)
		case strings.HasSuffix(req.URL.Path, "/pulse"):
			pulseBody, _ = io.ReadAll(req.Body)
			pulseQuery = req.URL.RawQuery
			io.WriteString(rw, `{"ok":true,"doc":{"doc_id":"t1"}}`)
		case strings.HasSuffix(req.URL.Path, "/close"):
			closeBody, _ = io.ReadAll(req.Body)
			// A stale-epoch conflict: HTTP 409 must surface as IsError.
			rw.WriteHeader(http.StatusConflict)
			io.WriteString(rw, `{"error":{"code":"doc_changed_since_claim"}}`)
		default:
			rw.WriteHeader(http.StatusNotFound)
			io.WriteString(rw, `{"error":{"code":"not_found"}}`)
		}
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	ctx := manifest.Context{Server: ts.URL, Token: "tok"}

	srv := mcp.NewServer(&mcp.Implementation{Name: "barkpark-tasks", Version: "test"}, nil)
	if err := registerTaskTools(srv, globals{yes: true}, ctx, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()

	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil) // performs the initialize handshake
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	// tools/list — exactly the curated eight, by name.
	lt, err := cs.ListTools(bg, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	got := make([]string, 0, len(lt.Tools))
	for _, tool := range lt.Tools {
		got = append(got, tool.Name)
	}
	sort.Strings(got)
	want := []string{"task_close", "task_create", "task_next", "task_prime", "task_pulse", "task_ready", "task_show", "task_stamp"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("tools = %v, want %v", got, want)
	}

	// Annotations must be honest: the three reads carry readOnlyHint:true and no
	// destructiveHint; the three writers carry readOnlyHint:false + destructiveHint:true.
	byName := map[string]*mcp.Tool{}
	for _, tool := range lt.Tools {
		byName[tool.Name] = tool
	}
	for _, name := range []string{"task_ready", "task_show", "task_prime"} {
		a := byName[name].Annotations
		if a == nil || a.ReadOnlyHint != true || a.DestructiveHint != nil {
			t.Errorf("%s annotations = %+v, want ReadOnlyHint:true, no DestructiveHint", name, a)
		}
	}
	for _, name := range []string{"task_next", "task_close", "task_create"} {
		a := byName[name].Annotations
		if a == nil || a.ReadOnlyHint != false || a.DestructiveHint == nil || *a.DestructiveHint != true {
			t.Errorf("%s annotations = %+v, want ReadOnlyHint:false + DestructiveHint:true", name, a)
		}
	}
	// task_stamp/task_pulse are the middle group: they DO write (ReadOnlyHint:false)
	// but carry DestructiveHint EXPLICITLY false — additive, holder-gated heartbeats
	// a client should not gate behind a destructive-confirm.
	for _, name := range []string{"task_stamp", "task_pulse"} {
		a := byName[name].Annotations
		if a == nil || a.ReadOnlyHint != false || a.DestructiveHint == nil || *a.DestructiveHint != false {
			t.Errorf("%s annotations = %+v, want ReadOnlyHint:false + DestructiveHint:false", name, a)
		}
	}

	// task_prime — the rehydration read rides task.prime with worker/limit on the
	// query; the backing response comes straight back as content, no error.
	res0, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_prime",
		Arguments: map[string]any{"worker_id": "cursor-test", "limit": 5, "order": "closure_nearest"},
	})
	if err != nil {
		t.Fatalf("CallTool task_prime: %v", err)
	}
	if res0.IsError {
		t.Fatalf("task_prime unexpectedly IsError: %s", mcpContentText(res0))
	}
	if !strings.Contains(mcpContentText(res0), `"primed":true`) {
		t.Fatalf("task_prime content = %q, want the prime body", mcpContentText(res0))
	}
	if !strings.Contains(primeQuery, "worker=cursor-test") || !strings.Contains(primeQuery, "limit=5") || !strings.Contains(primeQuery, "order=closure_nearest") {
		t.Fatalf("task_prime query = %q, want worker+limit+closure order as query params", primeQuery)
	}

	readyResult, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_ready",
		Arguments: map[string]any{"limit": 3, "order": "closure_nearest"},
	})
	if err != nil || readyResult.IsError {
		t.Fatalf("task_ready closure order failed: err=%v result=%s", err, mcpContentText(readyResult))
	}
	if !strings.Contains(readyQuery, "view=brief") || !strings.Contains(readyQuery, "limit=3") || !strings.Contains(readyQuery, "order=closure_nearest") {
		t.Fatalf("task_ready query = %q, want brief view + limit + closure order", readyQuery)
	}
	// An MCP consumer is an agent: prime requests the brief view (AXI R1).
	if !strings.Contains(primeQuery, "view=brief") {
		t.Fatalf("task_prime query = %q, want view=brief", primeQuery)
	}

	// tools/call task_show — the backing response body rides back as content.
	res, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_show",
		Arguments: map[string]any{"doc_id": "t1"},
	})
	if err != nil {
		t.Fatalf("CallTool task_show: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_show unexpectedly IsError: %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), `"title":"first"`) {
		t.Fatalf("task_show content = %q, want the task body", mcpContentText(res))
	}
	// task_show is the full-detail escape hatch: it must NEVER send a view param.
	if strings.Contains(showQuery, "view=") {
		t.Fatalf("task_show query = %q, want NO view param (full-only escape hatch)", showQuery)
	}

	// task_next on an empty queue: 200 {ok:false,reason:no_ready} is NOT an error.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_next",
		Arguments: map[string]any{"worker_id": "cursor-test", "order": "closure_nearest"},
	})
	if err != nil {
		t.Fatalf("CallTool task_next: %v", err)
	}
	if res.IsError {
		t.Fatalf("empty-queue task_next must not be IsError; got %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), "no_ready") {
		t.Fatalf("task_next content = %q, want no_ready", mcpContentText(res))
	}
	if !strings.Contains(nextQuery, "order=closure_nearest") {
		t.Fatalf("task_next query = %q, want closure order", nextQuery)
	}

	// task_close hitting a 409: HTTP >= 400 must set IsError. Criteria ride the
	// same call so the captured body proves the whole tail→seam translation.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_close",
		Arguments: map[string]any{
			"doc_id": "t1", "worker_id": "cursor-test", "observed_epoch": 1,
			"criteria": []any{map[string]any{"index": 0, "met": true, "evidence": "test"}},
		},
	})
	if err != nil {
		t.Fatalf("CallTool task_close: %v", err)
	}
	if !res.IsError {
		t.Fatalf("409 close must be IsError; got %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), "doc_changed_since_claim") {
		t.Fatalf("task_close content = %q, want the 409 envelope", mcpContentText(res))
	}
	// The POSTed close body must carry every field the CLI form would: worker_id
	// + observed_epoch (server-coerced string, like the CLI) as bound positionals,
	// the defaulted lifecycle_status, and the criteria array TYPED via --set :=.
	var sent map[string]any
	if err := json.Unmarshal(closeBody, &sent); err != nil {
		t.Fatalf("close body did not parse: %v (%q)", err, closeBody)
	}
	if sent["worker_id"] != "cursor-test" || sent["observed_epoch"] != "1" || sent["lifecycle_status"] != "done" {
		t.Fatalf("close body fields wrong: %q", closeBody)
	}
	crit, ok := sent["criteria"].([]any)
	if !ok || len(crit) != 1 {
		t.Fatalf("close body criteria not a typed 1-element array: %q", closeBody)
	}
	if c0, _ := crit[0].(map[string]any); c0 == nil || c0["met"] != true || c0["evidence"] != "test" {
		t.Fatalf("close body criteria[0] wrong: %q", closeBody)
	}

	// task_close with a missing epoch: an arg error before any request.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_close",
		Arguments: map[string]any{"doc_id": "t1", "worker_id": "cursor-test"},
	})
	if err != nil {
		t.Fatalf("CallTool task_close (bad args): %v", err)
	}
	if !res.IsError || !strings.Contains(mcpContentText(res), "observed_epoch") {
		t.Fatalf("missing-epoch close must IsError naming observed_epoch; got IsError=%v %q", res.IsError, mcpContentText(res))
	}

	// task_stamp --met: the positionals (worker_id + observed_epoch) land in the
	// POST body; criterion + met + evidence ride as query params (declared flags).
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_stamp",
		Arguments: map[string]any{
			"doc_id": "t1", "worker_id": "cursor-test", "observed_epoch": 2,
			"criterion": 1, "met": true, "evidence": "gate green",
		},
	})
	if err != nil {
		t.Fatalf("CallTool task_stamp: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_stamp unexpectedly IsError: %s", mcpContentText(res))
	}
	var stampSent map[string]any
	if err := json.Unmarshal(stampBody, &stampSent); err != nil {
		t.Fatalf("stamp body did not parse: %v (%q)", err, stampBody)
	}
	// worker_id + observed_epoch (server-coerced string, like close) in the body.
	if stampSent["worker_id"] != "cursor-test" || stampSent["observed_epoch"] != "2" {
		t.Fatalf("stamp body positionals wrong: %q", stampBody)
	}
	// criterion/met/evidence rode as query flags — and never as body.
	if !strings.Contains(stampQuery, "criterion=1") || !strings.Contains(stampQuery, "met=true") || !strings.Contains(stampQuery, "evidence=gate+green") {
		t.Fatalf("stamp query = %q, want criterion+met+evidence", stampQuery)
	}
	if _, ok := stampSent["criterion"]; ok {
		t.Fatalf("stamp flags must not leak into the body: %q", stampBody)
	}

	// task_stamp --miss: records a note WITHOUT met; miss+note ride the query.
	stampQuery = ""
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_stamp",
		Arguments: map[string]any{
			"doc_id": "t1", "worker_id": "cursor-test", "observed_epoch": 2,
			"criterion": 0, "miss": true, "note": "flaky, rerunning",
		},
	})
	if err != nil {
		t.Fatalf("CallTool task_stamp miss: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_stamp miss unexpectedly IsError: %s", mcpContentText(res))
	}
	if !strings.Contains(stampQuery, "miss=true") || !strings.Contains(stampQuery, "note=flaky") || strings.Contains(stampQuery, "met=true") {
		t.Fatalf("stamp miss query = %q, want miss+note and no met", stampQuery)
	}

	// task_stamp arg errors, caught client-side before any request:
	//   missing criterion; both met and miss; met without evidence.
	for _, bad := range []map[string]any{
		{"doc_id": "t1", "worker_id": "cursor-test", "observed_epoch": 2, "met": true, "evidence": "x"},                                            // no criterion
		{"doc_id": "t1", "worker_id": "cursor-test", "observed_epoch": 2, "criterion": 0},                                                          // neither met nor miss
		{"doc_id": "t1", "worker_id": "cursor-test", "observed_epoch": 2, "criterion": 0, "met": true, "miss": true, "evidence": "x", "note": "y"}, // both
		{"doc_id": "t1", "worker_id": "cursor-test", "observed_epoch": 2, "criterion": 0, "met": true},                                             // met, no evidence
		{"doc_id": "t1", "worker_id": "cursor-test", "criterion": 0, "met": true, "evidence": "x"},                                                 // no observed_epoch
	} {
		res, err = cs.CallTool(bg, &mcp.CallToolParams{Name: "task_stamp", Arguments: bad})
		if err != nil {
			t.Fatalf("CallTool task_stamp (bad args %v): %v", bad, err)
		}
		if !res.IsError {
			t.Fatalf("task_stamp with bad args %v must IsError; got %q", bad, mcpContentText(res))
		}
	}

	// task_pulse: worker_id lands in the body; now + criterion ride the query; and
	// there is NO observed_epoch anywhere (pulse carries no epoch arg).
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_pulse",
		Arguments: map[string]any{
			"doc_id": "t1", "worker_id": "cursor-test", "now": "gating now", "criterion": 2,
		},
	})
	if err != nil {
		t.Fatalf("CallTool task_pulse: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_pulse unexpectedly IsError: %s", mcpContentText(res))
	}
	var pulseSent map[string]any
	if err := json.Unmarshal(pulseBody, &pulseSent); err != nil {
		t.Fatalf("pulse body did not parse: %v (%q)", err, pulseBody)
	}
	if pulseSent["worker_id"] != "cursor-test" {
		t.Fatalf("pulse body worker_id wrong: %q", pulseBody)
	}
	if _, ok := pulseSent["observed_epoch"]; ok {
		t.Fatalf("pulse must carry NO observed_epoch; body = %q", pulseBody)
	}
	if strings.Contains(pulseQuery, "observed_epoch") {
		t.Fatalf("pulse must carry NO observed_epoch; query = %q", pulseQuery)
	}
	if !strings.Contains(pulseQuery, "now=gating+now") || !strings.Contains(pulseQuery, "criterion=2") {
		t.Fatalf("pulse query = %q, want now+criterion", pulseQuery)
	}

	// task_pulse with an empty now: an arg error before any request.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_pulse",
		Arguments: map[string]any{"doc_id": "t1", "worker_id": "cursor-test"},
	})
	if err != nil {
		t.Fatalf("CallTool task_pulse (bad args): %v", err)
	}
	if !res.IsError || !strings.Contains(mcpContentText(res), "now") {
		t.Fatalf("missing-now pulse must IsError naming now; got IsError=%v %q", res.IsError, mcpContentText(res))
	}

	// Tear the sessions down, then assert bp wrote nothing to os.Stdout.
	cs.Close()
	ss.Close()
	w.Close()
	restore()
	buf := <-stdoutCh
	if len(buf) != 0 {
		t.Fatalf("bp MCP code wrote %d bytes to os.Stdout (corrupts a real stdio protocol stream): %q", len(buf), buf)
	}
}

// TestMCPTaskCreateWeightedTags proves the task_create tool's new `tags` property
// survives the MCP→body→mutate translation as a weighted-object array. It stands
// up a fake /v1/data/mutate server, calls task_create over a real in-memory MCP
// session with three weighted tags (publish:false so the single create mutation is
// the whole exchange), and asserts the captured create body carries tags as
// {tag,strength,rationale} objects with the strengths intact — the coverage the
// name-only tools/list assertions never provided.
func TestMCPTaskCreateWeightedTags(t *testing.T) {
	var createBody []byte
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/mutate") {
			createBody, _ = io.ReadAll(req.Body)
			io.WriteString(rw, `{"results":[{"id":"drafts.task-1"}]}`)
			return
		}
		rw.WriteHeader(http.StatusNotFound)
		io.WriteString(rw, `{"error":{"code":"not_found"}}`)
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	ctx := manifest.Context{Server: ts.URL, Token: "tok"}

	srv := mcp.NewServer(&mcp.Implementation{Name: "barkpark-tasks", Version: "test"}, nil)
	if err := registerTaskTools(srv, globals{yes: true}, ctx, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	res, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_create",
		Arguments: map[string]any{
			"title":   "weighted task",
			"publish": false, // keep the exchange to the single create mutation
			"tags": []any{
				map[string]any{"tag": "auth", "strength": 90, "rationale": "core to the seam"},
				map[string]any{"tag": "cli", "strength": 40, "rationale": "surfaced in bp"},
				map[string]any{"tag": "docs", "strength": 10, "rationale": "card touched"},
			},
		},
	})
	if err != nil {
		t.Fatalf("CallTool task_create: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_create unexpectedly IsError: %s", mcpContentText(res))
	}

	// The create mutation body must carry tags as a weighted-object array under the
	// create op — {mutations:[{create:{_type:task, tags:[{tag,strength,rationale}…]}}]}.
	var sent struct {
		Mutations []struct {
			Create map[string]any `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(createBody, &sent); err != nil {
		t.Fatalf("create body did not parse: %v (%q)", err, createBody)
	}
	if len(sent.Mutations) != 1 || sent.Mutations[0].Create == nil {
		t.Fatalf("expected one create mutation; got %q", createBody)
	}
	create := sent.Mutations[0].Create
	if create["_type"] != "task" || create["title"] != "weighted task" {
		t.Fatalf("create op missing task defaults: %q", createBody)
	}
	tags, ok := create["tags"].([]any)
	if !ok || len(tags) != 3 {
		t.Fatalf("create tags not a 3-element array: %q", createBody)
	}
	// Strengths land as numbers (distinct, unique max) and the labels/rationales survive.
	want := []struct {
		tag       string
		strength  float64
		rationale string
	}{
		{"auth", 90, "core to the seam"},
		{"cli", 40, "surfaced in bp"},
		{"docs", 10, "card touched"},
	}
	for i, w := range want {
		obj, _ := tags[i].(map[string]any)
		if obj == nil {
			t.Fatalf("tags[%d] not an object: %q", i, createBody)
		}
		if obj["tag"] != w.tag || obj["rationale"] != w.rationale {
			t.Fatalf("tags[%d] tag/rationale wrong: %v (%q)", i, obj, createBody)
		}
		s, isNum := obj["strength"].(float64)
		if !isNum || s != w.strength {
			t.Fatalf("tags[%d] strength = %v (%T), want %v as a number: %q", i, obj["strength"], obj["strength"], w.strength, createBody)
		}
	}
}

// TestMCPTaskCreateSurfacesWarnings proves the task_create receipt folds the
// authoring wall's advisories from the create/publish success envelope (ae-w1)
// instead of dropping the response body on the floor (D24). It stands up a fake
// /v1/data/mutate server that returns a {code,severity,message} warning on the
// PUBLISH step, runs create+publish over a real in-memory MCP session, and asserts
// the receipt carries {id, status:"published", warnings:[…]} with the advisory
// intact — the publish body's warnings preferred over the create body's.
func TestMCPTaskCreateSurfacesWarnings(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/mutate") {
			b, _ := io.ReadAll(req.Body)
			if strings.Contains(string(b), `"publish"`) {
				io.WriteString(rw, `{"results":[{"id":"task-1"}],"warnings":[`+
					`{"code":"label_norm","severity":"advisory","message":"tags: advisory norm is 2–4"}]}`)
				return
			}
			io.WriteString(rw, `{"results":[{"id":"drafts.task-1"}]}`)
			return
		}
		rw.WriteHeader(http.StatusNotFound)
		io.WriteString(rw, `{"error":{"code":"not_found"}}`)
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	ctx := manifest.Context{Server: ts.URL, Token: "tok"}

	srv := mcp.NewServer(&mcp.Implementation{Name: "barkpark-tasks", Version: "test"}, nil)
	if err := registerTaskTools(srv, globals{yes: true}, ctx, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	res, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_create",
		Arguments: map[string]any{
			"title": "warned task",
			// A wall-passing body: task_create now runs the same client-side
			// publish-wall pre-flight the CLI does, so a bare title + publish:true
			// is a REFUSAL, not a create.
			"description": wallPassingDescription,
			"tags": []any{
				map[string]any{"tag": "cli", "strength": 80, "rationale": "the tool under test is the bp CLI's MCP task surface"},
			},
			"publish": true, // exercise the create + publish exchange
		},
	})
	if err != nil {
		t.Fatalf("CallTool task_create: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_create unexpectedly IsError: %s", mcpContentText(res))
	}

	var receipt struct {
		ID              string           `json:"id"`
		Draft           string           `json:"draft"`
		Status          string           `json:"status"`
		LifecycleStatus string           `json:"lifecycle_status"`
		Warnings        []map[string]any `json:"warnings"`
	}
	if err := json.Unmarshal([]byte(mcpContentText(res)), &receipt); err != nil {
		t.Fatalf("receipt did not parse: %v (%q)", err, mcpContentText(res))
	}
	if receipt.ID != "task-1" || receipt.Status != "published" {
		t.Fatalf("receipt id/status wrong: %+v", receipt)
	}
	// tlv-s6: the receipt echoes the born lifecycle_status — the MCP create
	// path injects "open", and the receipt must say so instead of assuming it.
	if receipt.LifecycleStatus != "open" {
		t.Fatalf("receipt.lifecycle_status = %q, want the born \"open\" echoed", receipt.LifecycleStatus)
	}
	if len(receipt.Warnings) != 1 {
		t.Fatalf("receipt.warnings = %v, want the publish-step advisory folded in", receipt.Warnings)
	}
	if receipt.Warnings[0]["code"] != "label_norm" || receipt.Warnings[0]["message"] != "tags: advisory norm is 2–4" {
		t.Fatalf("receipt.warnings[0] = %v, want the {label_norm, …} advisory intact", receipt.Warnings[0])
	}
	// task-ee33b6f088b35bdb — the publish CONSUMED drafts.task-1, so a receipt
	// that still names it points at a document that does not exist. The CLI
	// twin (renderTaskCreated) is locked by
	// TestTaskCreateJSONReceiptNamesADraftOnlyWhenOneExists; this is the MCP
	// side of the same mirror.
	if receipt.Draft != "" {
		t.Fatalf("a SUCCESSFUL publish receipt still carries draft = %q; publishing consumes the draft, so that id resolves to nothing", receipt.Draft)
	}
}

// TestMCPTaskCreateDraftReceiptNamesTheDraft is the other arm of the mirror
// above: WITHOUT publish the draft is the only document there is, and its id is
// the caller's sole handle for publish_command / discard. Asserted separately so
// the publish arm cannot go green by dropping the key everywhere.
func TestMCPTaskCreateDraftReceiptNamesTheDraft(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/mutate") {
			io.WriteString(rw, `{"results":[{"id":"drafts.task-7"}]}`)
			return
		}
		rw.WriteHeader(http.StatusNotFound)
		io.WriteString(rw, `{"error":{"code":"not_found"}}`)
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	ctx := manifest.Context{Server: ts.URL, Token: "tok"}
	srv := mcp.NewServer(&mcp.Implementation{Name: "barkpark-tasks", Version: "test"}, nil)
	if err := registerTaskTools(srv, globals{yes: true}, ctx, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}
	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	res, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_create",
		Arguments: map[string]any{"title": "a draft task", "publish": false},
	})
	if err != nil {
		t.Fatalf("CallTool task_create: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_create unexpectedly IsError: %s", mcpContentText(res))
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(mcpContentText(res)), &raw); err != nil {
		t.Fatalf("receipt did not parse: %v (%q)", err, mcpContentText(res))
	}
	if raw["status"] != "draft" {
		t.Fatalf("receipt.status = %v, want draft — this arm must be the no-publish path", raw["status"])
	}
	if raw["draft"] != "drafts.task-7" {
		t.Fatalf("draft receipt draft = %v (present=%v), want drafts.task-7 — the draft exists and the receipt must name it", raw["draft"], raw["draft"] != nil)
	}
}

// mcpContentText concatenates the text of a result's content blocks.
func mcpContentText(res *mcp.CallToolResult) string {
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String()
}

// TestParseMCPServeArgs covers the --tools selector (tasks|all AND the D129
// comma-noun subset) and the --http transport parsing. Validation of a noun
// subset stays SYNTACTIC: tasks/all are reserved words, an empty comma token is
// rejected, but a noun's EXISTENCE is never checked here (the manifest loads only
// after parse; an absent noun degrades to zero tools, not a usage error).
func TestParseMCPServeArgs(t *testing.T) {
	cases := []struct {
		in        []string
		want      string
		wantNouns []string
		wantHTTP  string
		wantErr   bool
	}{
		{nil, "tasks", nil, "", false},
		{[]string{"--tools", "tasks"}, "tasks", nil, "", false},
		{[]string{"--tools", "all"}, "all", nil, "", false},
		{[]string{"--tools=all"}, "all", nil, "", false},
		{[]string{"--http", "127.0.0.1:4010"}, "tasks", nil, "127.0.0.1:4010", false},
		{[]string{"--http=127.0.0.1:4010"}, "tasks", nil, "127.0.0.1:4010", false},
		{[]string{"--tools", "all", "--http", ":4010"}, "all", nil, ":4010", false},
		// D129 noun subsets — a single noun, a two-noun list, the inline form.
		{[]string{"--tools", "github"}, "subset", []string{"github"}, "", false},
		{[]string{"--tools", "github,linear"}, "subset", []string{"github", "linear"}, "", false},
		{[]string{"--tools=github,linear"}, "subset", []string{"github", "linear"}, "", false},
		// A subset composes with --http exactly like tasks|all.
		{[]string{"--tools", "github,linear", "--http", ":4010"}, "subset", []string{"github", "linear"}, ":4010", false},
		// An absent noun is NOT a parse error — it parses fine and degrades to
		// zero tools once the manifest loads (proven in the session test).
		{[]string{"--tools", "nosuchnoun"}, "subset", []string{"nosuchnoun"}, "", false},
		// Reserved words may not be MIXED into a noun list.
		{[]string{"--tools", "github,tasks"}, "", nil, "", true},
		{[]string{"--tools", "all,github"}, "", nil, "", true},
		// Empty comma tokens are rejected.
		{[]string{"--tools", "github,"}, "", nil, "", true},
		{[]string{"--tools", ",linear"}, "", nil, "", true},
		{[]string{"--tools", "github,,linear"}, "", nil, "", true},
		{[]string{"--http"}, "", nil, "", true},   // missing addr
		{[]string{"--http="}, "", nil, "", true},  // empty addr
		{[]string{"--tools="}, "", nil, "", true}, // empty --tools value
		{[]string{"--tools"}, "", nil, "", true},
		{[]string{"--nope"}, "", nil, "", true},
		{[]string{"stray"}, "", nil, "", true},
	}
	for _, c := range cases {
		got, gotNouns, gotHTTP, err := parseMCPServeArgs(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("parseMCPServeArgs(%v) = %q,%v,%q, want error", c.in, got, gotNouns, gotHTTP)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseMCPServeArgs(%v) unexpected error: %v", c.in, err)
			continue
		}
		if got != c.want || gotHTTP != c.wantHTTP {
			t.Errorf("parseMCPServeArgs(%v) = %q,%q, want %q,%q", c.in, got, gotHTTP, c.want, c.wantHTTP)
		}
		if strings.Join(gotNouns, ",") != strings.Join(c.wantNouns, ",") {
			t.Errorf("parseMCPServeArgs(%v) nouns = %v, want %v", c.in, gotNouns, c.wantNouns)
		}
	}
}

// TestRegisterTaskToolsMissingVerb asserts the server refuses to come up if a
// required task verb is absent from the manifest — better a clear startup error
// than a tool that 404s every call.
func TestRegisterTaskToolsMissingVerb(t *testing.T) {
	const noReady = `{
      "manifest_version":"1",
      "server":{"name":"t","version":"0","base_url":"http://x"},
      "auth_tier":"admin","generated_at":"n","etag":"e",
      "nouns":[{"name":"task","summary":"t"}],
      "commands":[{"id":"task.get","noun":"task","verb":"get","summary":"g","http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"i"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}]
    }`
	m, err := manifest.Parse([]byte(noReady))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	srv := mcp.NewServer(&mcp.Implementation{Name: "x", Version: "0"}, nil)
	if err := registerTaskTools(srv, globals{}, manifest.Context{Server: "http://x"}, m); err == nil {
		t.Fatal("expected error for manifest missing task.ready")
	}
}

// TestTasksLessManifestGracefulUnderAll proves the --tools all graceful path: a
// manifest with NO task verbs makes registerTaskTools fail fast (so the default
// --tools tasks correctly refuses to start), but the bridge still serves whatever
// the manifest DOES carry — so runMCPServe warns and continues bridge-only rather
// than dying. The bridge is registered over a real in-memory MCP session and its
// tool is confirmed present.
func TestTasksLessManifestGracefulUnderAll(t *testing.T) {
	const tasksLess = `{
      "manifest_version":"1",
      "server":{"name":"t","version":"0","base_url":"http://x"},
      "auth_tier":"admin","generated_at":"n","etag":"e",
      "nouns":[{"name":"doc","summary":"documents"}],
      "commands":[{"id":"doc.get","noun":"doc","verb":"get","summary":"fetch a document","http":{"method":"GET","path_template":"/v1/data/query/:dataset/:doc_id"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}]
    }`
	m, err := manifest.Parse([]byte(tasksLess))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	// The curated tools cannot register — this is what makes --tools tasks fail
	// fast, and what runMCPServe tolerates (warns + continues) only under --tools all.
	srv := mcp.NewServer(&mcp.Implementation{Name: "x", Version: "0"}, nil)
	if err := registerTaskTools(srv, globals{}, manifest.Context{Server: "http://x"}, m); err == nil {
		t.Fatal("expected registerTaskTools to fail on a tasks-less manifest")
	}

	// The bridge still exposes the manifest's own verbs — bridge-only service.
	cs := newBridgeSession(t, globals{}, manifest.Context{Server: "http://x"}, m)
	tools := listAllTools(t, cs)
	if _, ok := tools["bp_doc_get"]; !ok {
		t.Fatalf("bridge should serve bp_doc_get on a tasks-less manifest; have %v", toolNames(tools))
	}
	// And it read-annotates the non-writing verb.
	if a := tools["bp_doc_get"].Annotations; a == nil || a.ReadOnlyHint != true {
		t.Errorf("bp_doc_get annotations = %+v, want ReadOnlyHint:true", tools["bp_doc_get"].Annotations)
	}
}

// ensure json import used (guards against a refactor dropping the receipt path).
var _ = json.Marshal
