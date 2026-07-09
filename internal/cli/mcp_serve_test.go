package cli

import (
	"bytes"
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
    {"id":"task.ready","noun":"task","verb":"ready","summary":"ready","http":{"method":"GET","path_template":"/v1/tasks/ready"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"task.get","noun":"task","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"task.next","noun":"task","verb":"next","summary":"next","http":{"method":"POST","path_template":"/v1/tasks/claim"},"auth_tier":"read","args":[{"name":"worker_id","required":true,"type":"string","summary":"w"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.close","noun":"task","verb":"close","summary":"close","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/close"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"},{"name":"observed_epoch","required":true,"type":"int","summary":"e"},{"name":"lifecycle_status","required":false,"type":"string","summary":"s"},{"name":"reason","required":false,"type":"string","summary":"r"}],"flags":[{"name":"set","repeatable":true,"type":"string","summary":"extra close-body fields"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"}
  ]
}`

// TestMCPServeToolsLiveOverInMemory drives the MCP server the way a real client
// would — initialize handshake, tools/list, tools/call — over an in-memory
// transport (the SDK's StdioTransport hardcodes os.Stdout, so a stdio test would
// fight the real stdout; NewInMemoryTransports is the SDK's own test seam). It
// asserts the curated five tools are advertised, that a call returns the backing
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

	// A stand-in Barkpark API. Routes by path so one server backs every tool call.
	// closeBody captures what the task_close handler actually POSTed, so the
	// test can prove the MCP→tail→seam translation placed every field in the
	// request body exactly as `bp task close … --set criteria:=[…]` would.
	var closeBody []byte
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		switch {
		case req.URL.Path == "/v1/tasks/ready":
			io.WriteString(rw, `{"result":{"tasks":[{"doc_id":"t1"}]}}`)
		case req.URL.Path == "/v1/tasks/t1":
			io.WriteString(rw, `{"result":{"doc_id":"t1","title":"first"}}`)
		case req.URL.Path == "/v1/tasks/claim":
			// Empty queue: 200 with ok:false — a valid outcome, not an error.
			io.WriteString(rw, `{"ok":false,"reason":"no_ready"}`)
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

	// tools/list — exactly the curated five, by name.
	lt, err := cs.ListTools(bg, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	got := make([]string, 0, len(lt.Tools))
	for _, tool := range lt.Tools {
		got = append(got, tool.Name)
	}
	sort.Strings(got)
	want := []string{"task_close", "task_create", "task_next", "task_ready", "task_show"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("tools = %v, want %v", got, want)
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

	// task_next on an empty queue: 200 {ok:false,reason:no_ready} is NOT an error.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{
		Name:      "task_next",
		Arguments: map[string]any{"worker_id": "cursor-test"},
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

	// Tear the sessions down, then assert bp wrote nothing to os.Stdout.
	cs.Close()
	ss.Close()
	w.Close()
	restore()
	var buf bytes.Buffer
	io.Copy(&buf, r)
	if buf.Len() != 0 {
		t.Fatalf("bp MCP code wrote %d bytes to os.Stdout (corrupts a real stdio protocol stream): %q", buf.Len(), buf.String())
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

// TestParseMCPServeArgs covers the --tools selector parsing.
func TestParseMCPServeArgs(t *testing.T) {
	cases := []struct {
		in      []string
		want    string
		wantErr bool
	}{
		{nil, "tasks", false},
		{[]string{"--tools", "tasks"}, "tasks", false},
		{[]string{"--tools", "all"}, "all", false},
		{[]string{"--tools=all"}, "all", false},
		{[]string{"--tools", "bogus"}, "", true},
		{[]string{"--tools"}, "", true},
		{[]string{"--nope"}, "", true},
		{[]string{"stray"}, "", true},
	}
	for _, c := range cases {
		got, err := parseMCPServeArgs(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("parseMCPServeArgs(%v) = %q, want error", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseMCPServeArgs(%v) unexpected error: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("parseMCPServeArgs(%v) = %q, want %q", c.in, got, c.want)
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

// ensure json import used (guards against a refactor dropping the receipt path).
var _ = json.Marshal
