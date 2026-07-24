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

// newBridgeSession registers the full bridge (no noun filter — the `--tools all`
// surface) on a real mcp.Server and connects a client over the SDK's in-memory
// transport (StdioTransport hardcodes os.Stdout), returning the live client
// session. Cleanup is automatic.
func newBridgeSession(t *testing.T, g globals, ctx manifest.Context, m *manifest.Manifest) *mcp.ClientSession {
	t.Helper()
	return newBridgeSessionForNouns(t, g, ctx, m, nil)
}

// newBridgeSessionForNouns is newBridgeSession with an optional noun allowlist —
// the `--tools <noun,noun>` subset surface. nil nouns = the full bridge; a
// non-empty subset filters to those nouns (registerBridgeToolsFiltered).
func newBridgeSessionForNouns(t *testing.T, g globals, ctx manifest.Context, m *manifest.Manifest, nouns []string) *mcp.ClientSession {
	t.Helper()
	srv := mcp.NewServer(&mcp.Implementation{Name: "bridge-test", Version: "0"}, nil)
	if err := registerBridgeToolsFiltered(srv, g, ctx, m, nouns); err != nil {
		t.Fatalf("registerBridgeToolsFiltered: %v", err)
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

// TestBridgeShadowing proves the curated-twin IDs are shadowed while the
// distinct by-id claim and a non-covered doc verb still generate — over a real
// MCP session's tools/list. doc.create and the chat.* verbs are synthesised
// (herd charter D75h). The 2026-07-24 fixture regen (ctx-s1-brief-manifest)
// captured an ADMIN-tier manifest that now carries doc.create and chat.*
// natively, so the synthesised appends duplicate live entries — harmless
// (AddTool replaces on same name) and kept so the test stays self-contained
// against an older or write-tier fixture too.
// The test asserts the shadow set is scoped to EXACTLY the curated twins and
// never over-shadows a sibling verb — and, on a combined curated+bridge server
// (the shape `--tools all` actually assembles), that each shadowed chat verb's
// capability is present under its curated name, never twice.
func TestBridgeShadowing(t *testing.T) {
	m := loadFixtureManifest(t)
	// Synthesize doc.create so we can assert it generates (not covered by the
	// curated eight, must NOT be shadowed).
	m.Commands = append(m.Commands, manifest.Command{
		ID:     "doc.create",
		Noun:   "doc",
		Verb:   "create",
		Writes: true,
		HTTP:   manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:   []manifest.Arg{{Name: "type", Required: true, Type: "string", Summary: "doc type"}},
	})
	// Synthesize the three chat verbs the curated chat tools cover (D75h): a
	// future manifest that carries them (admin-tier projection / the D36 remap)
	// must NOT generate bp_chat_* twins. chat.interrupt is synthesised as the
	// control: a chat verb with NO curated twin must still generate.
	m.Commands = append(m.Commands,
		manifest.Command{
			ID: "chat.create_session", Noun: "chat", Verb: "create_session", Writes: true,
			HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/chat/sessions"},
		},
		manifest.Command{
			ID: "chat.send_message", Noun: "chat", Verb: "send_message", Writes: true,
			HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/chat/sessions/:id/messages"},
			Args: []manifest.Arg{{Name: "id", Required: true, Type: "string", Summary: "session id"}},
		},
		manifest.Command{
			ID: "chat.get_session", Noun: "chat", Verb: "get_session",
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/chat/sessions/:id"},
			Args: []manifest.Arg{{Name: "id", Required: true, Type: "string", Summary: "session id"}},
		},
		manifest.Command{
			ID: "chat.interrupt", Noun: "chat", Verb: "interrupt", Writes: true,
			HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/chat/sessions/:id/interrupt"},
			Args: []manifest.Arg{{Name: "id", Required: true, Type: "string", Summary: "session id"}},
		},
	)

	cs := newBridgeSession(t, globals{}, manifest.Context{Server: "http://x"}, m)
	tools := listAllTools(t, cs)

	absent := []string{
		"bp_task_ready", "bp_task_next", "bp_task_get", "bp_task_close", "bp_task_prime", "bp_task_stamp", "bp_task_pulse",
		"bp_chat_create_session", "bp_chat_send_message", "bp_chat_get_session",
	}
	for _, name := range absent {
		if _, ok := tools[name]; ok {
			t.Errorf("shadowed tool %q should be absent (curated twin covers it)", name)
		}
	}

	present := []string{"bp_task_claim", "bp_task_ls", "bp_doc_create", "bp_chat_interrupt"}
	for _, name := range present {
		if _, ok := tools[name]; !ok {
			t.Errorf("tool %q should generate; have %v", name, toolNames(tools))
		}
	}

	// Combined curated+bridge server (what `--tools all` assembles): the chat
	// capabilities exist ONCE, under the curated names — never as bp_chat_* twins.
	combined := mcp.NewServer(&mcp.Implementation{Name: "combined-test", Version: "0"}, nil)
	registerChatTools(combined, manifest.Context{Server: "http://x"})
	if err := registerBridgeToolsFiltered(combined, globals{}, manifest.Context{Server: "http://x"}, m, nil); err != nil {
		t.Fatalf("registerBridgeToolsFiltered: %v", err)
	}
	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := combined.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "combined-test-client", Version: "0"}, nil)
	ccs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { ccs.Close() })
	combinedTools := listAllTools(t, ccs)
	for _, name := range []string{"chat_spawn_session", "chat_send", "chat_read_tail", "chat_wait_for_state"} {
		if _, ok := combinedTools[name]; !ok {
			t.Errorf("curated chat tool %q missing from the combined surface; have %v", name, toolNames(combinedTools))
		}
	}
	for _, name := range []string{"bp_chat_create_session", "bp_chat_send_message", "bp_chat_get_session"} {
		if _, ok := combinedTools[name]; ok {
			t.Errorf("bridge twin %q must be shadowed on the combined surface (never-double-expose)", name)
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

// TestBridgeAnnotations proves the Writes bit drives the MCP behaviour hints: a
// read command is ReadOnlyHint:true with no DestructiveHint; a write command is
// ReadOnlyHint:false + DestructiveHint:true (conservative — the manifest can't
// tell additive from destructive). Idempotent/OpenWorld stay unset.
func TestBridgeAnnotations(t *testing.T) {
	read := bridgeAnnotations(manifest.Command{Noun: "task", Verb: "get", Writes: false})
	if read == nil || read.ReadOnlyHint != true || read.DestructiveHint != nil {
		t.Errorf("read annotations = %+v, want ReadOnlyHint:true, no DestructiveHint", read)
	}
	if read.OpenWorldHint != nil || read.IdempotentHint != false {
		t.Errorf("read annotations leaked Idempotent/OpenWorld hints: %+v", read)
	}
	write := bridgeAnnotations(manifest.Command{Noun: "doc", Verb: "create", Writes: true})
	if write == nil || write.ReadOnlyHint != false || write.DestructiveHint == nil || *write.DestructiveHint != true {
		t.Errorf("write annotations = %+v, want ReadOnlyHint:false + DestructiveHint:true", write)
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

// accessCommands mirrors the six CORE `access` verbs defined in
// api/lib/barkpark/plugins/capabilities.ex (access.grant/ls/show/revoke/claim/
// mine) — the airdrop-grants grant-lifecycle surface. The fixture manifest
// predates the access noun, so the parity proof synthesizes the commands the
// same way TestBridgeShadowing synthesizes doc.create: the bridge is pure over
// the manifest, so a manifest carrying these six MUST generate their tools.
func accessCommands() []manifest.Command {
	return []manifest.Command{
		{
			ID: "access.grant", Noun: "access", Verb: "grant", Writes: true,
			HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/access"},
			Args: []manifest.Arg{
				{Name: "grantee_email", Required: true, Type: "string", Summary: "Who the link is FOR."},
				{Name: "workspace_id", Required: true, Type: "string", Summary: "Workspace scope top."},
				{Name: "capabilities", Required: true, Type: "string", Summary: "read|write|admin."},
			},
			Flags: []manifest.Flag{
				{Name: "project_id", Type: "string", Summary: "Narrow to a project."},
				{Name: "expires_at", Type: "string", Summary: "ISO-8601 expiry."},
				{Name: "single_use", Type: "boolean", Summary: "Spend on first claim."},
			},
		},
		{
			ID: "access.ls", Noun: "access", Verb: "ls",
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/access"},
			Flags: []manifest.Flag{
				{Name: "workspace_id", Type: "string", Summary: "Workspace whose grants to list."},
			},
		},
		{
			ID: "access.show", Noun: "access", Verb: "show",
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/access/:id"},
			Args: []manifest.Arg{{Name: "id", Required: true, Type: "string", Summary: "Grant id."}},
		},
		{
			ID: "access.revoke", Noun: "access", Verb: "revoke", Writes: true,
			HTTP: manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/access/:id"},
			Args: []manifest.Arg{{Name: "id", Required: true, Type: "string", Summary: "Grant id."}},
		},
		{
			ID: "access.claim", Noun: "access", Verb: "claim", Writes: true,
			HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/access/claim"},
			Args: []manifest.Arg{{Name: "token", Required: true, Type: "string", Summary: "Raw airdrop token."}},
		},
		{
			ID: "access.mine", Noun: "access", Verb: "mine",
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/access/mine"},
		},
	}
}

// TestBridgeAccessParity is the airdrop-grants parity guard (Task:
// ag-access-mcp-parity-proof). It pins two facts so a future shadow-set edit or
// verb rename turns into a red test:
//
//  1. No access.* id is ever in bridgeShadowedIDs — the curated overlay covers
//     only the five task queue/read/close verbs, never an access verb, so the
//     bridge must be free to generate all six.
//  2. registerBridgeTools over a manifest carrying the six access commands
//     yields bp_access_grant/ls/show/revoke/claim/mine over a real MCP session's
//     tools/list — full grant-lifecycle parity under `--tools all`.
func TestBridgeAccessParity(t *testing.T) {
	access := accessCommands()

	// (1) The shadow set must never swallow an access verb.
	for _, cmd := range access {
		if bridgeShadowedIDs[cmd.ID] {
			t.Errorf("access verb %q is in bridgeShadowedIDs — the curated overlay must never shadow an access verb (it covers only the 7 task twins)", cmd.ID)
		}
	}
	// Belt-and-suspenders: no shadowed id is under the access noun at all.
	for id := range bridgeShadowedIDs {
		if strings.HasPrefix(id, "access.") {
			t.Errorf("bridgeShadowedIDs contains %q — access verbs must never be shadowed", id)
		}
	}

	// (2) A manifest carrying the six access commands generates all six tools.
	m := loadFixtureManifest(t)
	m.Commands = append(m.Commands, access...)

	cs := newBridgeSession(t, globals{}, manifest.Context{Server: "http://x"}, m)
	tools := listAllTools(t, cs)

	want := []string{
		"bp_access_grant",
		"bp_access_ls",
		"bp_access_show",
		"bp_access_revoke",
		"bp_access_claim",
		"bp_access_mine",
	}
	for _, name := range want {
		if _, ok := tools[name]; !ok {
			t.Errorf("access tool %q must generate under --tools all; have %v", name, toolNames(tools))
		}
	}
}

// syntheticConnectorManifest builds a manifest with two connector-style nouns
// (github, linear — each two commands) and a task noun whose two commands are
// BOTH in bridgeShadowedIDs. The shipped fixture carries NO github/linear noun
// (grep=0), because github/linear are Catalog connector providers, not bp
// manifest nouns — so, exactly as accessCommands()/TestBridgeAccessParity
// synthesize their commands, this test declares its own nouns. The task noun is
// present so the "shadowed noun → zero" leg is exercised over a real noun whose
// every verb the curated overlay covers.
func syntheticConnectorManifest() *manifest.Manifest {
	return &manifest.Manifest{
		ManifestVersion: "1",
		Commands: []manifest.Command{
			{
				ID: "github.status", Noun: "github", Verb: "status",
				HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/github/status"},
				Args: []manifest.Arg{{Name: "repo", Required: true, Type: "string", Summary: "owner/name"}},
			},
			{
				ID: "github.sync", Noun: "github", Verb: "sync", Writes: true,
				HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/github/sync"},
				Args: []manifest.Arg{{Name: "repo", Required: true, Type: "string", Summary: "owner/name"}},
			},
			{
				ID: "linear.issues", Noun: "linear", Verb: "issues",
				HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/linear/issues"},
			},
			{
				ID: "linear.create", Noun: "linear", Verb: "create", Writes: true,
				HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/linear/issues"},
				Args: []manifest.Arg{{Name: "title", Required: true, Type: "string", Summary: "issue title"}},
			},
			// task.* — both are in bridgeShadowedIDs, so a `--tools task` subset
			// yields zero (the curated overlay covers them).
			{
				ID: "task.ready", Noun: "task", Verb: "ready",
				HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/ready"},
			},
			{
				ID: "task.close", Noun: "task", Verb: "close", Writes: true,
				HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/tasks/:doc_id/close"},
				Args: []manifest.Arg{{Name: "doc_id", Required: true, Type: "string", Summary: "id"}},
			},
		},
	}
}

// TestBridgeNounSubset is the D129 (D24 knob-3, Go half) proof: a bridge filtered
// to a noun subset exposes EXACTLY that subset's non-shadowed commands as
// bp_<noun>_<verb> tools — and nothing else. It drives four legs over a real
// in-memory MCP session against the synthetic connector manifest:
//
//   - full subset (github,linear) → exactly the four connector tools;
//   - single noun (github)        → exactly the two github tools;
//   - absent noun (nosuchnoun)    → zero tools (honest 0-install degrade);
//   - shadowed noun (task)        → zero tools (both verbs are curated twins).
//
// This slice filters bp MANIFEST nouns; it is NOT the transport by which a cloud
// claude reaches GitHub/Linear (that is the in-sandbox MCP wiring, a separate
// slice) — the noun names here are synthetic test fixtures, not a claim otherwise.
func TestBridgeNounSubset(t *testing.T) {
	m := syntheticConnectorManifest()
	ctx := manifest.Context{Server: "http://x"}
	g := globals{}

	cases := []struct {
		name  string
		nouns []string
		want  []string
	}{
		{
			name:  "full subset",
			nouns: []string{"github", "linear"},
			want:  []string{"bp_github_status", "bp_github_sync", "bp_linear_create", "bp_linear_issues"},
		},
		{
			name:  "single noun",
			nouns: []string{"github"},
			want:  []string{"bp_github_status", "bp_github_sync"},
		},
		{
			name:  "absent noun degrades to zero",
			nouns: []string{"nosuchnoun"},
			want:  []string{},
		},
		{
			name:  "shadowed noun yields zero",
			nouns: []string{"task"},
			want:  []string{},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cs := newBridgeSessionForNouns(t, g, ctx, m, c.nouns)
			tools := listAllTools(t, cs)
			got := toolNames(tools)
			// want is already sorted; toolNames sorts too.
			if strings.Join(got, ",") != strings.Join(c.want, ",") {
				t.Errorf("--tools %v exposed %v, want EXACTLY %v", c.nouns, got, c.want)
			}
		})
	}
}

// TestBridgeFullSurfaceUnfiltered pins that a nil noun set is the unfiltered
// full-bridge surface (the `--tools all` semantics registerBridgeTools keeps):
// every non-shadowed command generates, across BOTH connector nouns and the task
// noun's non-shadowed verbs. Here the task noun's verbs ARE all shadowed, so the
// full surface is exactly the four connector tools — proving the nil path is a
// superset of any subset and never over-filters.
func TestBridgeFullSurfaceUnfiltered(t *testing.T) {
	m := syntheticConnectorManifest()
	cs := newBridgeSessionForNouns(t, globals{}, manifest.Context{Server: "http://x"}, m, nil)
	tools := listAllTools(t, cs)
	got := toolNames(tools)
	want := []string{"bp_github_status", "bp_github_sync", "bp_linear_create", "bp_linear_issues"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("unfiltered bridge exposed %v, want %v (task verbs shadowed)", got, want)
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
