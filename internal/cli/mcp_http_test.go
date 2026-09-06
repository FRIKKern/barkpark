package cli

// mcp_http_test.go — the Streamable-HTTP transport of `bp mcp serve --http` and
// its FORWARD-THROUGH bearer design (viable-everywhere charter D18). These tests
// drive a REAL MCP client over real HTTP against the production handler
// (newMCPHTTPHandler), backed by a stub Barkpark API that gates every route on
// one good bearer — mirroring how downstream Auth.verify_token/1 is the single
// choke point in production.
//
// The three proof obligations (hard merge gates, task ve-w2-remote-mcp-bearer):
//
//  1. FORWARD-THROUGH: the credential a request carries is the credential the
//     downstream API sees — verbatim, per request.
//  2. FAIL CLOSED, NO AMBIENT TOKEN: a missing or bogus bearer yields the
//     downstream 401 envelope as an isError tool result, with no side effects;
//     the process's own token (base context AND environment) is NEVER sent on a
//     remote caller's behalf.
//  3. TEMPLATE-ONLY PAPERS: HTTP mode registers the barkpark://papers/{id} read
//     template only — the per-request server build must never fire the
//     resources/list enumeration GET (doc.ls) that stdio startup runs once.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpHTTPTestManifest carries the five task verbs registerTaskTools requires
// PLUS both doc verbs — doc.ls deliberately present so the template-only test
// proves HTTP mode does not enumerate even when the manifest would allow it.
const mcpHTTPTestManifest = `{
  "manifest_version": "1",
  "server": {"name": "test", "version": "0", "base_url": "http://x"},
  "auth_tier": "admin",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "task", "summary": "tasks"}, {"name": "doc", "summary": "docs"}],
  "commands": [
    {"id":"task.ready","noun":"task","verb":"ready","summary":"ready","http":{"method":"GET","path_template":"/v1/tasks/ready"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"task.prime","noun":"task","verb":"prime","summary":"prime","http":{"method":"GET","path_template":"/v1/tasks/prime"},"auth_tier":"read","args":[],"flags":[{"name":"worker","type":"string","summary":"w"},{"name":"limit","type":"int","summary":"l"}],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"json"},
    {"id":"task.get","noun":"task","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"task.next","noun":"task","verb":"next","summary":"next","http":{"method":"POST","path_template":"/v1/tasks/claim"},"auth_tier":"read","args":[{"name":"worker_id","required":true,"type":"string","summary":"w"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.stamp","noun":"task","verb":"stamp","summary":"stamp","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/stamp"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"},{"name":"observed_epoch","required":true,"type":"int","summary":"e"}],"flags":[{"name":"criterion","type":"int","summary":"c"},{"name":"met","type":"bool","summary":"m"},{"name":"evidence","type":"string","summary":"ev"},{"name":"miss","type":"bool","summary":"x"},{"name":"note","type":"string","summary":"n"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.pulse","noun":"task","verb":"pulse","summary":"pulse","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/pulse"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"}],"flags":[{"name":"now","type":"string","summary":"t"},{"name":"criterion","type":"int","summary":"c"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.close","noun":"task","verb":"close","summary":"close","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/close"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"},{"name":"observed_epoch","required":true,"type":"int","summary":"e"},{"name":"lifecycle_status","required":false,"type":"string","summary":"s"},{"name":"reason","required":false,"type":"string","summary":"r"}],"flags":[{"name":"set","repeatable":true,"type":"string","summary":"x"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"list","http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},"auth_tier":"read","args":[{"name":"type","required":true,"type":"string","summary":"t"}],"flags":[{"name":"limit","type":"int","default":50,"summary":"l"}],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"doc.get","noun":"doc","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},"auth_tier":"read","args":[{"name":"type","required":true,"type":"string","summary":"t"},{"name":"doc_id","required":true,"type":"string","summary":"i"}],"flags":[{"name":"perspective","type":"string","default":"published","summary":"p"}],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

const (
	mcpHTTPGoodToken    = "good-token"
	mcpHTTPAmbientToken = "AMBIENT-TOKEN-MUST-NEVER-BE-SENT"
)

// mcpHTTPSeen is one downstream request the stub API observed: which path, and
// with exactly which Authorization header (empty string = header absent).
type mcpHTTPSeen struct {
	Path string
	Auth string
}

// mcpHTTPBackend is the stub Barkpark API. Like the real server, auth is the
// FIRST gate on every route: anything but the one good bearer answers the 401
// unauthorized envelope before any handler logic runs — so writes (the claim
// counter) can only ever move on an authorized request. It records every
// request's path + Authorization header for the forward-through/no-ambient
// assertions.
type mcpHTTPBackend struct {
	mu     sync.Mutex
	seen   []mcpHTTPSeen
	lsHits int // GET /v1/data/query/… (paper enumeration) — must stay 0 in HTTP mode
	claims int // successful (authorized) task claims — must stay 0 on deny paths
}

func (b *mcpHTTPBackend) record(req *http.Request) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.seen = append(b.seen, mcpHTTPSeen{Path: req.URL.Path, Auth: req.Header.Get("Authorization")})
}

func (b *mcpHTTPBackend) snapshot() ([]mcpHTTPSeen, int, int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]mcpHTTPSeen(nil), b.seen...), b.lsHits, b.claims
}

func (b *mcpHTTPBackend) handler() http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		b.record(req)

		// Auth gate FIRST, like the production API: bad/missing bearer never
		// reaches route logic, so it can have no side effects.
		if req.Header.Get("Authorization") != "Bearer "+mcpHTTPGoodToken {
			rw.WriteHeader(http.StatusUnauthorized)
			io.WriteString(rw, `{"error":{"code":"unauthorized","message":"invalid or missing bearer token"}}`)
			return
		}

		switch {
		case req.URL.Path == "/v1/tasks/t1":
			io.WriteString(rw, `{"result":{"doc_id":"t1","title":"first"}}`)
		case req.URL.Path == "/v1/tasks/claim":
			b.mu.Lock()
			b.claims++
			b.mu.Unlock()
			io.WriteString(rw, `{"ok":true,"doc":{"doc_id":"t1"}}`)
		case strings.HasPrefix(req.URL.Path, "/v1/data/query/"):
			b.mu.Lock()
			b.lsHits++
			b.mu.Unlock()
			io.WriteString(rw, `{"result":{"documents":[]}}`)
		case req.URL.Path == "/v1/data/doc/production/paper/p1":
			io.WriteString(rw, mcpPaperGetP1Body)
		default:
			rw.WriteHeader(http.StatusNotFound)
			io.WriteString(rw, `{"error":{"code":"not_found"}}`)
		}
	})
}

// newMCPHTTPStack stands up the full production stack under test: stub API ←
// newMCPHTTPHandler (the real `--http` handler, base context deliberately
// carrying an ambient token that must never surface) ← httptest front server a
// real MCP client dials. It also plants an ambient token in the environment so
// a request-time env fallback would be caught too.
func newMCPHTTPStack(t *testing.T, toolset string) (*mcpHTTPBackend, string) {
	t.Helper()

	// Ambient credentials on BOTH channels a leak could ride: the resolved base
	// context and the process environment. Neither may ever reach the backend.
	t.Setenv("BARKPARK_API_TOKEN", mcpHTTPAmbientToken)

	backend := &mcpHTTPBackend{}
	api := httptest.NewServer(backend.handler())
	t.Cleanup(api.Close)

	m, err := manifest.Parse([]byte(mcpHTTPTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	base := manifest.Context{Server: api.URL, Token: mcpHTTPAmbientToken, Dataset: "production"}

	handler, err := newMCPHTTPHandler(newWriter(io.Discard, io.Discard), globals{}, base, m, toolset, nil)
	if err != nil {
		t.Fatalf("newMCPHTTPHandler: %v", err)
	}
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)
	return backend, front.URL
}

// mcpBearerTransport injects `Authorization: Bearer <token>` on every request —
// exactly what a remote MCP client (Claude.ai/ChatGPT-class connector config)
// does. An empty token sends NO Authorization header (the missing-bearer path).
type mcpBearerTransport struct {
	token string
	base  http.RoundTripper
}

func (t mcpBearerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	r := req.Clone(req.Context())
	if t.token != "" {
		r.Header.Set("Authorization", "Bearer "+t.token)
	}
	return t.base.RoundTrip(r)
}

// connectMCPHTTPClient dials the front server with a real MCP client over the
// SDK's Streamable-HTTP client transport, carrying token (or no header at all
// for ""). The standalone SSE stream is disabled — these tests are pure
// request/response, and a stateless server has no server-initiated traffic.
func connectMCPHTTPClient(t *testing.T, endpoint, token string) *mcp.ClientSession {
	t.Helper()
	transport := &mcp.StreamableClientTransport{
		Endpoint:             endpoint,
		HTTPClient:           &http.Client{Transport: mcpBearerTransport{token: token, base: http.DefaultTransport}},
		MaxRetries:           -1,
		DisableStandaloneSSE: true,
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "remote-test-client", Version: "0"}, nil)
	cs, err := client.Connect(context.Background(), transport, nil)
	if err != nil {
		t.Fatalf("client connect (token=%q): %v", token, err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// TestMCPHTTPForwardThroughBearer is the happy-path proof: a real MCP client
// over real HTTP, whose bearer is forwarded VERBATIM to the downstream API per
// request — while the ambient token (base context + env) never appears in any
// downstream request, and bp writes zero bytes to os.Stdout in HTTP mode.
func TestMCPHTTPForwardThroughBearer(t *testing.T) {
	// Capture os.Stdout: HTTP mode has no protocol pipe on stdout, but the
	// serve code must stay silent there regardless (one discipline, both modes).
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

	backend, endpoint := newMCPHTTPStack(t, "tasks")
	cs := connectMCPHTTPClient(t, endpoint, mcpHTTPGoodToken)
	bg := context.Background()

	// tools/list — the same curated set the stdio transport serves: the eight
	// task tools plus the four chat session tools (herd charter D74h).
	lt, err := cs.ListTools(bg, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	names := make([]string, 0, len(lt.Tools))
	for _, tool := range lt.Tools {
		names = append(names, tool.Name)
	}
	sort.Strings(names)
	want := []string{
		"chat_read_tail", "chat_send", "chat_spawn_session", "chat_wait_for_state",
		"task_close", "task_create", "task_next", "task_prime", "task_pulse", "task_ready", "task_show", "task_stamp",
	}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("tools = %v, want %v", names, want)
	}

	// tools/call task_show — the backing body rides back; the API must have seen
	// the CLIENT's bearer on that exact request.
	res, err := cs.CallTool(bg, &mcp.CallToolParams{Name: "task_show", Arguments: map[string]any{"doc_id": "t1"}})
	if err != nil {
		t.Fatalf("CallTool task_show: %v", err)
	}
	if res.IsError {
		t.Fatalf("task_show unexpectedly IsError: %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), `"title":"first"`) {
		t.Fatalf("task_show content = %q, want the task body", mcpContentText(res))
	}

	seen, _, _ := backend.snapshot()
	sawTaskGet := false
	for _, s := range seen {
		if s.Path == "/v1/tasks/t1" {
			sawTaskGet = true
			if s.Auth != "Bearer "+mcpHTTPGoodToken {
				t.Fatalf("downstream task get carried %q, want the client's bearer forwarded verbatim", s.Auth)
			}
		}
		// The no-ambient invariant holds across EVERY downstream request.
		if strings.Contains(s.Auth, mcpHTTPAmbientToken) {
			t.Fatalf("AMBIENT TOKEN LEAKED downstream on %s: %q", s.Path, s.Auth)
		}
	}
	if !sawTaskGet {
		t.Fatalf("backend never saw the task get; requests = %+v", seen)
	}

	// Zero bytes on os.Stdout from the whole HTTP session.
	cs.Close()
	w.Close()
	restore()
	buf := <-stdoutCh
	if len(buf) != 0 {
		t.Fatalf("bp MCP HTTP code wrote %d bytes to os.Stdout: %q", len(buf), buf)
	}
}

// TestMCPHTTPDenyPathsFailClosed is the hard-gate deny-path proof (charter D18):
// a missing bearer and a bogus bearer each yield the downstream 401 unauthorized
// envelope as an isError tool result; the write route performs no side effect
// (claims counter untouched); and the process's ambient token is never
// substituted for the caller's absent/invalid one.
func TestMCPHTTPDenyPathsFailClosed(t *testing.T) {
	cases := []struct {
		name     string
		token    string // "" = no Authorization header at all
		wantAuth string // exactly what the downstream API must have seen
	}{
		{name: "missing bearer", token: "", wantAuth: ""},
		{name: "bogus bearer", token: "wrong-token", wantAuth: "Bearer wrong-token"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			backend, endpoint := newMCPHTTPStack(t, "tasks")

			// The MCP handshake itself needs no downstream call (registration is
			// manifest-only), so initialize succeeds — auth is enforced where the
			// data is, per the forward-through design.
			cs := connectMCPHTTPClient(t, endpoint, tc.token)
			bg := context.Background()

			// A read: fails closed with the downstream 401 envelope.
			res, err := cs.CallTool(bg, &mcp.CallToolParams{Name: "task_show", Arguments: map[string]any{"doc_id": "t1"}})
			if err != nil {
				t.Fatalf("CallTool task_show: %v", err)
			}
			if !res.IsError {
				t.Fatalf("task_show without a valid bearer must be IsError; got %s", mcpContentText(res))
			}
			if !strings.Contains(mcpContentText(res), "unauthorized") {
				t.Fatalf("task_show content = %q, want the downstream 401 unauthorized envelope", mcpContentText(res))
			}

			// A write: same 401 envelope, and the backend's auth gate means the
			// claim handler never ran — zero side effects.
			res, err = cs.CallTool(bg, &mcp.CallToolParams{Name: "task_next", Arguments: map[string]any{"worker_id": "intruder"}})
			if err != nil {
				t.Fatalf("CallTool task_next: %v", err)
			}
			if !res.IsError || !strings.Contains(mcpContentText(res), "unauthorized") {
				t.Fatalf("task_next without a valid bearer must IsError with the 401 envelope; got IsError=%v %q", res.IsError, mcpContentText(res))
			}

			seen, _, claims := backend.snapshot()
			if claims != 0 {
				t.Fatalf("deny path caused %d task claim(s) — side effect on an unauthorized request", claims)
			}
			if len(seen) == 0 {
				t.Fatal("backend saw no requests — the deny path never exercised the downstream choke point")
			}
			for _, s := range seen {
				if s.Auth != tc.wantAuth {
					t.Fatalf("downstream %s carried Authorization=%q, want %q (no ambient substitution, no header invention)", s.Path, s.Auth, tc.wantAuth)
				}
			}
		})
	}
}

// TestMCPHTTPPaperResourcesTemplateOnly proves HTTP mode's resource surface is
// the lazy read template ONLY: resources/templates/list carries
// barkpark://papers/{id}, resources/list enumerates nothing, and — the
// load-bearing part — the downstream doc.ls enumeration GET fires ZERO times
// across the whole session even though the manifest declares doc.ls
// (per-request server builds must not hammer the API; charter D18). Reads by
// URI still work, authorized by the caller's own bearer, and fail closed
// without one.
func TestMCPHTTPPaperResourcesTemplateOnly(t *testing.T) {
	backend, endpoint := newMCPHTTPStack(t, "tasks")
	cs := connectMCPHTTPClient(t, endpoint, mcpHTTPGoodToken)
	bg := context.Background()

	// resources/templates/list: the {id} read template is there.
	tpl, err := cs.ListResourceTemplates(bg, nil)
	if err != nil {
		t.Fatalf("ListResourceTemplates: %v", err)
	}
	foundTpl := false
	for _, rt := range tpl.ResourceTemplates {
		if rt.URITemplate == paperResourceTemplate {
			foundTpl = true
		}
	}
	if !foundTpl {
		t.Fatalf("resources/templates/list = %+v, want %s", tpl.ResourceTemplates, paperResourceTemplate)
	}

	// resources/list: nothing enumerated in HTTP mode.
	lst, err := cs.ListResources(bg, nil)
	if err != nil {
		t.Fatalf("ListResources: %v", err)
	}
	if len(lst.Resources) != 0 {
		t.Fatalf("resources/list = %+v, want empty (template-only in HTTP mode)", lst.Resources)
	}

	// resources/read via the template: works, backed by doc.get with the
	// caller's bearer, round-tripping the body verbatim.
	rd, err := cs.ReadResource(bg, &mcp.ReadResourceParams{URI: paperResourceScheme + "p1"})
	if err != nil {
		t.Fatalf("ReadResource p1: %v", err)
	}
	if len(rd.Contents) != 1 || rd.Contents[0].Text != mcpPaperGetP1Body {
		t.Fatalf("ReadResource p1 did not round-trip the doc.get body: %+v", rd.Contents)
	}

	// A bearer-less session cannot read a paper either — resources fail closed
	// exactly like tools.
	csAnon := connectMCPHTTPClient(t, endpoint, "")
	if _, err := csAnon.ReadResource(bg, &mcp.ReadResourceParams{URI: paperResourceScheme + "p1"}); err == nil {
		t.Fatal("ReadResource without a bearer must fail (downstream 401), got nil error")
	}

	// THE invariant: zero doc.ls enumeration hits across every per-request build.
	_, lsHits, _ := backend.snapshot()
	if lsHits != 0 {
		t.Fatalf("HTTP mode fired %d paper-enumeration (doc.ls) request(s); template-only means ZERO", lsHits)
	}
}

// TestBearerFromRequest pins the header parsing: only a well-formed
// `Bearer <credential>` yields a token; every other shape (absent, other
// scheme, bare scheme, empty credential) yields "" — which the dispatch seam
// turns into a credential-less downstream request, i.e. a guaranteed 401.
func TestBearerFromRequest(t *testing.T) {
	mk := func(h string) *http.Request {
		req, _ := http.NewRequest("POST", "http://x/", nil)
		if h != "" {
			req.Header.Set("Authorization", h)
		}
		return req
	}
	cases := []struct {
		header string
		want   string
	}{
		{"", ""},
		{"Bearer abc123", "abc123"},
		{"bearer abc123", "abc123"}, // scheme is case-insensitive (RFC 9110)
		{"Bearer   abc123  ", "abc123"},
		{"Bearer", ""},
		{"Bearer ", ""},
		{"Basic dXNlcjpwdw==", ""},
		{"Token abc123", ""},
	}
	for _, c := range cases {
		if got := bearerFromRequest(mk(c.header)); got != c.want {
			t.Errorf("bearerFromRequest(%q) = %q, want %q", c.header, got, c.want)
		}
	}
}
