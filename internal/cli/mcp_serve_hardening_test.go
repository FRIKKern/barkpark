package cli

// mcp_serve_hardening_test.go — the two hardening properties of `bp mcp serve
// --http`, the UNAUTHENTICATED remote transport (forward-through bearer,
// charter D18):
//
//  1. ANONYMOUS MANIFEST ≠ CRASH LOOP (task-1a641b21d19595d3). The --http
//     process holds no ambient credential, so its ONE startup manifest is the
//     anonymous projection of GET /v1/capabilities — doc/media/search/auth and
//     no task noun. Registering the curated task tools fails there, and the
//     fail-fast that is right for stdio turned guerrilla's barkpark-mcp.service
//     into 2464 restarts behind a 503. --http must instead serve what the
//     manifest DOES back and say so, loudly, once.
//
//  2. NO FREE SOCKETS (connectors-mcp-serve-dos-timeouts-ratelimit). The
//     listener accepts before any credential is inspected, so the http.Server
//     must arm read/idle deadlines and cap headers — and must NOT arm
//     WriteTimeout, which would truncate the SSE responses the streamable
//     transport writes.

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpAnonymousManifest is the shape GET /v1/capabilities returns to a caller
// with NO credential: auth_tier "none", and the four anonymous nouns
// (doc/media/search/auth). There is NO task noun — which is exactly what made
// registerTaskTools fail and `mcp serve --http` exit 1 on every start.
const mcpAnonymousManifest = `{
  "manifest_version": "1",
  "server": {"name": "guerrilla", "version": "0", "base_url": "http://x"},
  "auth_tier": "none",
  "generated_at": "now",
  "etag": "e",
  "nouns": [
    {"name": "doc", "summary": "documents"},
    {"name": "media", "summary": "media"},
    {"name": "search", "summary": "search"},
    {"name": "auth", "summary": "auth"}
  ],
  "commands": [
    {"id":"doc.get","noun":"doc","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},"auth_tier":"none","args":[{"name":"type","required":true,"type":"string","summary":"t"},{"name":"doc_id","required":true,"type":"string","summary":"i"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"list","http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},"auth_tier":"none","args":[{"name":"type","required":true,"type":"string","summary":"t"}],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"search.query","noun":"search","verb":"query","summary":"search","http":{"method":"GET","path_template":"/v1/search"},"auth_tier":"none","args":[{"name":"q","required":true,"type":"string","summary":"q"}],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"auth.whoami","noun":"auth","verb":"whoami","summary":"whoami","http":{"method":"GET","path_template":"/v1/auth/whoami"},"auth_tier":"none","args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

// TestMCPServeHTTPAnonymousManifestServesInsteadOfExiting is the row's cli half:
// the anonymous-shaped manifest goes through the REAL --http startup path
// (newMCPHTTPHandler — the call whose error is the only thing that made
// runMCPServeHTTP return exitGeneric before the listener is ever bound), and the
// server must come up, answer a real MCP client, and log ONE loud line.
//
// Before the fix this fails at newMCPHTTPHandler with "register task tools:
// manifest has no task.ready verb" — the exact journal line guerrilla logged
// 1576 times in one morning.
func TestMCPServeHTTPAnonymousManifestServesInsteadOfExiting(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		// Any downstream read is fine; nothing here should be needed at startup.
		io.WriteString(rw, `{"result":{"documents":[]}}`)
	}))
	t.Cleanup(api.Close)

	m, err := manifest.Parse([]byte(mcpAnonymousManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	if _, ok := m.Tree().Lookup("task", "ready"); ok {
		t.Fatal("fixture is not anonymous-shaped: it carries a task.ready verb")
	}

	var stderr strings.Builder
	out := newWriter(io.Discard, &stderr)

	// The default toolset — what barkpark-mcp.service runs (no --tools flag).
	handler, err := newMCPHTTPHandler(out, globals{}, manifest.Context{Server: api.URL, Dataset: "production"}, m, "tasks", nil)
	if err != nil {
		t.Fatalf("newMCPHTTPHandler on an anonymous manifest must NOT fail (this is the exit-1 crash loop): %v", err)
	}

	// ONE loud line, naming the missing curated tools and why.
	logged := stderr.String()
	lines := 0
	for _, ln := range strings.Split(strings.TrimSpace(logged), "\n") {
		if strings.Contains(ln, "DEGRADED") {
			lines++
		}
	}
	if lines != 1 {
		t.Fatalf("want exactly ONE loud DEGRADED line, got %d; stderr:\n%s", lines, logged)
	}
	for _, want := range append(append([]string{}, curatedTaskToolNames...), "anonymous", "no task noun", "task.ready") {
		if !strings.Contains(logged, want) {
			t.Errorf("loud line must name %q; stderr:\n%s", want, logged)
		}
	}

	// And it really serves: a real MCP client over real HTTP initializes and
	// lists the tools the anonymous manifest CAN back.
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)
	cs := connectMCPHTTPClient(t, front.URL, "some-caller-token")
	tools := listAllTools(t, cs)
	if len(tools) == 0 {
		t.Fatal("degraded server served zero tools; want at least the chat tools")
	}
	for _, name := range curatedTaskToolNames {
		if _, ok := tools[name]; ok {
			t.Errorf("curated tool %q must NOT be advertised when the manifest cannot back it", name)
		}
	}
	if _, ok := tools["chat_spawn_session"]; !ok {
		names := make([]string, 0, len(tools))
		for n := range tools {
			names = append(names, n)
		}
		sort.Strings(names)
		t.Errorf("degraded server should still carry the chat tools; have %v", names)
	}
	// The paper resource TEMPLATE survives too (doc.get is in the anonymous set).
	rts, err := cs.ListResourceTemplates(context.Background(), nil)
	if err != nil {
		t.Fatalf("ListResourceTemplates: %v", err)
	}
	if len(rts.ResourceTemplates) == 0 {
		t.Error("degraded server should still register the barkpark://papers/{id} read template")
	}
}

// TestStdioStillFailsFastOnAnonymousManifest is the other side of the fence: the
// degrade is scoped to --http. A stdio server is launched per client WITH that
// user's credential, so a manifest without the task noun there is a real
// misconfiguration and must still exit non-zero rather than come up half-alive.
func TestStdioStillFailsFastOnAnonymousManifest(t *testing.T) {
	m, err := manifest.Parse([]byte(mcpAnonymousManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	out := newWriter(io.Discard, io.Discard)
	if _, err := buildMCPServer(out, globals{}, manifest.Context{Server: "http://x"}, m, "tasks", nil, true); err == nil {
		t.Fatal("stdio --tools tasks must still fail fast on a tasks-less manifest")
	}
}

// TestCuratedTaskToolNamesMatchRegistration pins curatedTaskToolNames (the list
// the loud degrade line reads from) against what registerTaskTools actually
// registers, so a ninth tool or a rename cannot make the degrade line lie.
func TestCuratedTaskToolNamesMatchRegistration(t *testing.T) {
	m, err := manifest.Parse([]byte(mcpHTTPTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	srv := mcp.NewServer(&mcp.Implementation{Name: "x", Version: "0"}, nil)
	if err := registerTaskTools(srv, globals{yes: true}, manifest.Context{Server: "http://x"}, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}
	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "c", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	got := []string{}
	for name := range listAllTools(t, cs) {
		got = append(got, name)
	}
	want := append([]string{}, curatedTaskToolNames...)
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("registered task tools = %v, curatedTaskToolNames = %v", got, want)
	}
}

// TestMCPHTTPServerTimeoutsArmed pins the deadlines newMCPHTTPServer arms on the
// unauthenticated /mcp listener. A bare &http.Server{Handler: h} arms NONE of
// them, which is the filed defect.
func TestMCPHTTPServerTimeoutsArmed(t *testing.T) {
	srv := newMCPHTTPServer(http.NotFoundHandler(), nil)
	if srv.ReadHeaderTimeout != mcpHTTPReadHeaderTimeout || srv.ReadHeaderTimeout <= 0 {
		t.Errorf("ReadHeaderTimeout = %v, want %v (>0): the slowloris clamp", srv.ReadHeaderTimeout, mcpHTTPReadHeaderTimeout)
	}
	if srv.ReadTimeout != mcpHTTPReadTimeout || srv.ReadTimeout <= 0 {
		t.Errorf("ReadTimeout = %v, want %v (>0): the slow-body clamp", srv.ReadTimeout, mcpHTTPReadTimeout)
	}
	if srv.IdleTimeout != mcpHTTPIdleTimeout || srv.IdleTimeout <= 0 {
		t.Errorf("IdleTimeout = %v, want %v (>0): idle keep-alive reclaim", srv.IdleTimeout, mcpHTTPIdleTimeout)
	}
	if srv.MaxHeaderBytes != mcpHTTPMaxHeaderBytes || srv.MaxHeaderBytes <= 0 {
		t.Errorf("MaxHeaderBytes = %d, want %d (>0)", srv.MaxHeaderBytes, mcpHTTPMaxHeaderBytes)
	}
	// Deliberately zero — see TestMCPHTTPWriteTimeoutWouldTruncateSSE.
	if srv.WriteTimeout != 0 {
		t.Errorf("WriteTimeout = %v, want 0: a non-zero value truncates the SDK's SSE responses", srv.WriteTimeout)
	}
}

// serveOn runs srv on a fresh loopback listener and returns its address.
func serveOn(t *testing.T, srv *http.Server) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	return ln.Addr().String()
}

// slowSSEHandler answers with an SSE stream that takes `total` to write, so a
// response-side deadline shows up as a truncated body.
func slowSSEHandler(chunks int, gap time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		rc := http.NewResponseController(w)
		for i := 0; i < chunks; i++ {
			fmt.Fprintf(w, "data: chunk%d\n\n", i)
			_ = rc.Flush()
			time.Sleep(gap)
		}
	})
}

// TestMCPHTTPReadHeaderTimeoutClosesSlowloris proves the clamp WORKS, not just
// that a field is set: a peer that dribbles headers and never finishes them is
// closed by the server. The production constant is 10 s, so the test shrinks it
// after asserting the constructor armed a positive value (the non-vacuity
// guard — a zero would make the shrink the only thing under test).
func TestMCPHTTPReadHeaderTimeoutClosesSlowloris(t *testing.T) {
	srv := newMCPHTTPServer(http.NotFoundHandler(), nil)
	if srv.ReadHeaderTimeout <= 0 {
		t.Fatalf("newMCPHTTPServer armed ReadHeaderTimeout = %v; nothing to shrink", srv.ReadHeaderTimeout)
	}
	srv.ReadHeaderTimeout = 200 * time.Millisecond
	addr := serveOn(t, srv)

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	// Request line + one header, then silence: headers are never terminated.
	if _, err := io.WriteString(conn, "POST /mcp HTTP/1.1\r\nHost: x\r\n"); err != nil {
		t.Fatalf("write: %v", err)
	}
	start := time.Now()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := conn.Read(make([]byte, 64)); err == nil {
		t.Fatal("server answered a half-sent request; want the connection closed")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatalf("connection still open after %v — ReadHeaderTimeout did not fire", time.Since(start))
	}
	if el := time.Since(start); el > 2*time.Second {
		t.Errorf("slowloris held the socket %v; want ~ReadHeaderTimeout", el)
	}
}

// TestMCPHTTPReadTimeoutDoesNotTruncateSSE settles the one risk of arming
// ReadTimeout on a streaming endpoint: Go arms it for the REQUEST read only, so
// a response that outlives it still completes. Proven by shrinking ReadTimeout
// well below the response duration.
func TestMCPHTTPReadTimeoutDoesNotTruncateSSE(t *testing.T) {
	srv := newMCPHTTPServer(slowSSEHandler(4, 150*time.Millisecond), nil) // ~600ms
	if srv.ReadTimeout <= 0 {
		t.Fatalf("newMCPHTTPServer armed ReadTimeout = %v; nothing to shrink", srv.ReadTimeout)
	}
	srv.ReadTimeout = 200 * time.Millisecond
	addr := serveOn(t, srv)

	body, err := postAndRead(t, addr)
	if err != nil {
		t.Fatalf("slow SSE response under ReadTimeout=200ms: %v (body %q)", err, body)
	}
	if n := strings.Count(body, "data: chunk"); n != 4 {
		t.Fatalf("got %d chunks (%q), want 4 — ReadTimeout truncated the stream", n, body)
	}
}

// TestMCPHTTPWriteTimeoutWouldTruncateSSE is the evidence behind leaving
// WriteTimeout at zero: with one armed, the SAME slow SSE response is cut off
// mid-stream. It documents the hazard so a later "tidy up the timeouts" pass
// cannot quietly set it.
func TestMCPHTTPWriteTimeoutWouldTruncateSSE(t *testing.T) {
	srv := newMCPHTTPServer(slowSSEHandler(4, 150*time.Millisecond), nil) // ~600ms
	if srv.WriteTimeout != 0 {
		t.Fatalf("newMCPHTTPServer set WriteTimeout = %v; production must leave it 0", srv.WriteTimeout)
	}
	srv.WriteTimeout = 250 * time.Millisecond
	addr := serveOn(t, srv)

	body, err := postAndRead(t, addr)
	if err == nil && strings.Count(body, "data: chunk") == 4 {
		t.Fatal("a 250ms WriteTimeout did NOT truncate a 600ms SSE response — re-check the zero-WriteTimeout rationale in newMCPHTTPServer")
	}
}

// postAndRead POSTs a small JSON body to /mcp and drains the response.
func postAndRead(t *testing.T, addr string) (string, error) {
	t.Helper()
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Post("http://"+addr+"/mcp", "application/json", strings.NewReader(`{"jsonrpc":"2.0"}`))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(bufio.NewReader(resp.Body))
	return string(b), err
}
