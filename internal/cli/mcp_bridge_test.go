package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// newBridgeSession registers the bridge tools on a real mcp.Server and connects
// a client over the SDK's in-memory transport (StdioTransport hardcodes
// os.Stdout), returning the live client session. Cleanup is automatic.
func newBridgeSession(t *testing.T, g globals, ctx manifest.Context, m *manifest.Manifest) *mcp.ClientSession {
	t.Helper()
	srv := mcp.NewServer(&mcp.Implementation{Name: "bridge-test", Version: "0"}, nil)
	if err := registerBridgeTools(srv, g, ctx, m); err != nil {
		t.Fatalf("registerBridgeTools: %v", err)
	}
	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "bridge-test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// listAllTools drains tools/list across pagination cursors (the fixture
// manifest generates far more tools than one page may carry).
func listAllTools(t *testing.T, cs *mcp.ClientSession) map[string]*mcp.Tool {
	t.Helper()
	bg := context.Background()
	tools := map[string]*mcp.Tool{}
	var cursor string
	for {
		res, err := cs.ListTools(bg, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			t.Fatalf("ListTools: %v", err)
		}
		for _, tool := range res.Tools {
			tools[tool.Name] = tool
		}
		if res.NextCursor == "" {
			return tools
		}
		cursor = res.NextCursor
	}
}

func toolNames(tools map[string]*mcp.Tool) []string {
	out := make([]string, 0, len(tools))
	for n := range tools {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// loadFixtureManifest parses the shipped full-manifest fixture the charter names
// as the schema-derivation corpus.
func loadFixtureManifest(t *testing.T) *manifest.Manifest {
	t.Helper()
	raw, err := os.ReadFile("../../docs/cli/fixtures/full-manifest.json")
	if err != nil {
		t.Fatalf("read fixture manifest: %v", err)
	}
	m, err := manifest.Parse(raw)
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	return m
}

func TestBridgeToolName(t *testing.T) {
	cases := []struct {
		noun, verb, want string
	}{
		{"task", "get", "bp_task_get"},
		{"doc", "create", "bp_doc_create"},
		{"task", "claim", "bp_task_claim"},
		{"ticket-key", "mint", "bp_ticket_key_mint"}, // hyphen folded to underscore
	}
	for _, tc := range cases {
		got := bridgeToolName(manifest.Command{Noun: tc.noun, Verb: tc.verb})
		if got != tc.want {
			t.Errorf("bridgeToolName(%s,%s) = %q, want %q", tc.noun, tc.verb, got, tc.want)
		}
	}
}

// TestBridgeInputSchema_Derivation checks the 2020-12 schema derived for
// task.close: required is exactly the required ARGS (flags never required),
// int→integer, string→string, and a repeatable flag becomes an array of strings
// — all with summaries as descriptions.
func TestBridgeInputSchema_Derivation(t *testing.T) {
	m := loadFixtureManifest(t)
	cmd := findCommand(t, m, "task.close")

	schema := bridgeInputSchema(cmd)

	if schema["$schema"] != "https://json-schema.org/draft/2020-12/schema" {
		t.Errorf("missing 2020-12 $schema, got %v", schema["$schema"])
	}
	if schema["type"] != "object" {
		t.Errorf("schema type = %v, want object", schema["type"])
	}

	props, _ := schema["properties"].(map[string]any)
	if props == nil {
		t.Fatalf("properties missing or wrong type: %v", schema["properties"])
	}

	// observed_epoch is a manifest int → JSON integer.
	epoch, _ := props["observed_epoch"].(map[string]any)
	if epoch == nil || epoch["type"] != "integer" {
		t.Errorf("observed_epoch property = %v, want type integer", props["observed_epoch"])
	}
	if epoch["description"] == "" || epoch["description"] == nil {
		t.Errorf("observed_epoch missing description (summary)")
	}

	// doc_id is a string.
	docID, _ := props["doc_id"].(map[string]any)
	if docID == nil || docID["type"] != "string" {
		t.Errorf("doc_id property = %v, want type string", props["doc_id"])
	}

	// set is a repeatable flag → array of strings.
	setProp, _ := props["set"].(map[string]any)
	if setProp == nil || setProp["type"] != "array" {
		t.Fatalf("set property = %v, want type array", props["set"])
	}
	items, _ := setProp["items"].(map[string]any)
	if items == nil || items["type"] != "string" {
		t.Errorf("set items = %v, want type string", setProp["items"])
	}

	// required is exactly the three required args, no flags.
	got := toStringSlice(schema["required"])
	sort.Strings(got)
	want := []string{"doc_id", "observed_epoch", "worker_id"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("required = %v, want %v (flags must never be required)", got, want)
	}
	if _, present := indexOf(got, "set"); present {
		t.Errorf("repeatable flag 'set' must not be in required")
	}
	if _, present := indexOf(got, "reason"); present {
		t.Errorf("optional arg 'reason' must not be in required")
	}
}

// TestBridgeShadowing proves the four curated-twin IDs are shadowed while the
// distinct by-id claim and a non-covered doc verb still generate — over a real
// MCP session's tools/list. doc.create is synthesised (the fixture carries only
// doc.get/ls/query/mutate) so the test asserts the shadow set is scoped to
// EXACTLY the four twins and never over-shadows a sibling verb.
func TestBridgeShadowing(t *testing.T) {
	m := loadFixtureManifest(t)
	// Synthesize doc.create so we can assert it generates (not covered by the
	// curated five, must NOT be shadowed).
	m.Commands = append(m.Commands, manifest.Command{
		ID:     "doc.create",
		Noun:   "doc",
		Verb:   "create",
		Writes: true,
		HTTP:   manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:   []manifest.Arg{{Name: "type", Required: true, Type: "string", Summary: "doc type"}},
	})

	cs := newBridgeSession(t, globals{}, manifest.Context{Server: "http://x"}, m)
	tools := listAllTools(t, cs)

	absent := []string{"bp_task_ready", "bp_task_next", "bp_task_get", "bp_task_close"}
	for _, name := range absent {
		if _, ok := tools[name]; ok {
			t.Errorf("shadowed tool %q should be absent (curated twin covers it)", name)
		}
	}

	present := []string{"bp_task_claim", "bp_task_ls", "bp_doc_create"}
	for _, name := range present {
		if _, ok := tools[name]; !ok {
			t.Errorf("tool %q should generate; have %v", name, toolNames(tools))
		}
	}
}

// capturedRequest records what an httptest server received so the bridge
// round-trip and a direct CLI dispatch can be compared byte-for-byte.
type capturedRequest struct {
	method string
	path   string
	query  string
	body   map[string]any
}

// TestBridgeRoundTrip_ArgPlacement is the core proof: an arg lands in the PATH,
// a body arg in the BODY, and a flag in the QUERY string — and the bridge tool,
// called over a real MCP session, produces the EXACT same HTTP request a direct
// CLI dispatch of the same command does. A POST command with a :id path
// placeholder, a body arg, and a query-bound flag exercises all three
// placements through one call.
func TestBridgeRoundTrip_ArgPlacement(t *testing.T) {
	var got capturedRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.method = r.Method
		got.path = r.URL.Path
		got.query = r.URL.Query().Encode()
		body, _ := io.ReadAll(r.Body)
		got.body = map[string]any{}
		if len(body) > 0 {
			_ = json.Unmarshal(body, &got.body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"result":{"ok":true}}`))
	}))
	defer srv.Close()

	// A write command: :id → path, name → body (write, no placeholder), and a
	// non-file/non-bool string flag `tag` → query.
	cmd := manifest.Command{
		ID:     "thing.create",
		Noun:   "thing",
		Verb:   "create",
		Writes: true,
		HTTP:   manifest.HTTP{Method: "POST", PathTemplate: "/v1/thing/:id"},
		Args: []manifest.Arg{
			{Name: "id", Required: true, Type: "string", Summary: "thing id"},
			{Name: "name", Required: true, Type: "string", Summary: "display name"},
		},
		Flags: []manifest.Flag{
			{Name: "tag", Type: "string", Summary: "a label"},
		},
	}
	m := &manifest.Manifest{ManifestVersion: "1", Commands: []manifest.Command{cmd}}
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}
	g := globals{yes: true}

	// (1) Bridge dispatch over a live MCP session.
	cs := newBridgeSession(t, g, ctx, m)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "bp_thing_create",
		Arguments: map[string]any{"id": "abc", "name": "widget", "tag": "blue"},
	})
	if err != nil {
		t.Fatalf("CallTool bp_thing_create: %v", err)
	}
	if res.IsError {
		t.Fatalf("bridge call unexpectedly IsError: %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), `"ok":true`) {
		t.Fatalf("bridge result = %q, want the raw response body", mcpContentText(res))
	}
	bridgeReq := got

	// (2) Direct CLI dispatch of the SAME command with the equivalent tail.
	got = capturedRequest{}
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g2 := g
	g2.output = "json"
	g2.outputSet = true
	out.applyGlobals(g2)
	if code := runCommand(out, g2, ctx, m, cmd, []string{"abc", "widget", "--tag", "blue"}); code != exitOK {
		t.Fatalf("CLI dispatch exit %d, stderr=%s", code, stderr.String())
	}
	cliReq := got

	// The two must be identical: same method, path, query, body.
	if bridgeReq.method != cliReq.method || bridgeReq.method != "POST" {
		t.Errorf("method: bridge=%q cli=%q", bridgeReq.method, cliReq.method)
	}
	if bridgeReq.path != "/v1/thing/abc" {
		t.Errorf("path arg did not land in URL path: %q", bridgeReq.path)
	}
	if bridgeReq.path != cliReq.path {
		t.Errorf("path mismatch: bridge=%q cli=%q", bridgeReq.path, cliReq.path)
	}
	if bridgeReq.query != "tag=blue" {
		t.Errorf("flag did not land in query: %q", bridgeReq.query)
	}
	if bridgeReq.query != cliReq.query {
		t.Errorf("query mismatch: bridge=%q cli=%q", bridgeReq.query, cliReq.query)
	}
	if bridgeReq.body["name"] != "widget" {
		t.Errorf("body arg did not land in body: %v", bridgeReq.body)
	}
	if _, leaked := bridgeReq.body["id"]; leaked {
		t.Errorf("path arg leaked into body: %v", bridgeReq.body)
	}
	if _, leaked := bridgeReq.body["tag"]; leaked {
		t.Errorf("query flag leaked into body: %v", bridgeReq.body)
	}
	if !reflect.DeepEqual(bridgeReq.body, cliReq.body) {
		t.Errorf("body mismatch: bridge=%v cli=%v", bridgeReq.body, cliReq.body)
	}
}

// TestBuildCommandTail checks the tail reconstruction: a non-string scalar is
// stringified, a repeatable flag repeats, and a bool flag emits a bare --name
// when truthy.
func TestBuildCommandTail(t *testing.T) {
	cmd := manifest.Command{
		Noun: "task", Verb: "close",
		Args: []manifest.Arg{
			{Name: "doc_id", Required: true, Type: "string"},
			{Name: "worker_id", Required: true, Type: "string"},
			{Name: "observed_epoch", Required: true, Type: "int"},
		},
		Flags: []manifest.Flag{
			{Name: "set", Type: "string", Repeatable: true},
			{Name: "force", Type: "bool"},
		},
	}
	tail := buildCommandTail(cmd, map[string]any{
		"doc_id":         "t1",
		"worker_id":      "w1",
		"observed_epoch": float64(7), // JSON numbers decode to float64
		"set":            []any{"a=1", "b=2"},
		"force":          true,
	})

	// Positionals first, in Args order; epoch stringified from float64 without a
	// trailing ".000000".
	wantPrefix := []string{"t1", "w1", "7"}
	for i, w := range wantPrefix {
		if tail[i] != w {
			t.Errorf("tail[%d] = %q, want %q (full=%v)", i, tail[i], w, tail)
		}
	}
	joined := strings.Join(tail, " ")
	if !strings.Contains(joined, "--set a=1") || !strings.Contains(joined, "--set b=2") {
		t.Errorf("repeatable --set not repeated: %v", tail)
	}
	if !strings.Contains(joined, "--force") {
		t.Errorf("bool flag --force missing: %v", tail)
	}
	// A bare bool must NOT carry a value.
	for i, tok := range tail {
		if tok == "--force" && i+1 < len(tail) && tail[i+1] == "true" {
			t.Errorf("bool flag --force must not be followed by a value: %v", tail)
		}
	}

	// A falsy bool omits the flag entirely.
	tail2 := buildCommandTail(cmd, map[string]any{"doc_id": "t1", "worker_id": "w1", "observed_epoch": 1, "force": false})
	if strings.Contains(strings.Join(tail2, " "), "--force") {
		t.Errorf("falsy bool must omit --force: %v", tail2)
	}
}

// ── small test helpers ───────────────────────────────────────────────────────

func findCommand(t *testing.T, m *manifest.Manifest, id string) manifest.Command {
	t.Helper()
	for _, c := range m.Commands {
		if c.ID == id {
			return c
		}
	}
	t.Fatalf("command %q not in fixture", id)
	return manifest.Command{}
}

func toStringSlice(v any) []string {
	arr, ok := v.([]string)
	if ok {
		return arr
	}
	anyArr, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(anyArr))
	for _, e := range anyArr {
		if s, ok := e.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func indexOf(ss []string, target string) (int, bool) {
	for i, s := range ss {
		if s == target {
			return i, true
		}
	}
	return 0, false
}
