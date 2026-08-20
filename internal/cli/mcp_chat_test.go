package cli

// mcp_chat_test.go — the four curated chat session tools (herd charter
// D73h–D77h): registration surface + tenancy fail-closed shape, the httptest
// E2E herd round-trip (spawn → send → read_tail → wait), and the D76h hybrid
// resumable wait legs: resolve-on-flip, resolve-from-snapshot,
// timeout-returns-cursor, cursor-resume, and ctx-cancel teardown.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// newChatToolSession registers ONLY the four curated chat tools on a real
// mcp.Server and connects a client over the SDK's in-memory transport,
// returning the live client session. Cleanup is automatic.
func newChatToolSession(t *testing.T, ctx manifest.Context) *mcp.ClientSession {
	t.Helper()
	srv := mcp.NewServer(&mcp.Implementation{Name: "chat-test", Version: "0"}, nil)
	registerChatTools(srv, ctx)
	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "chat-test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// TestChatToolsSurface pins the registration contract: all four tools present,
// honest annotations (read_tail + wait ReadOnlyHint:true; spawn + send are
// writes with DestructiveHint:true), and — the D77h tenancy law — NO tool
// exposes a workspace parameter anywhere in its input schema: a cross-workspace
// call is unrepresentable on this surface, not merely rejected.
func TestChatToolsSurface(t *testing.T) {
	cs := newChatToolSession(t, manifest.Context{Server: "http://x", Token: "tok"})
	tools := listAllTools(t, cs)

	reads := []string{"chat_read_tail", "chat_wait_for_state"}
	writes := []string{"chat_spawn_session", "chat_send"}

	for _, name := range append(append([]string{}, reads...), writes...) {
		tool, ok := tools[name]
		if !ok {
			t.Fatalf("tool %q not registered; have %v", name, toolNames(tools))
		}
		// D77h: workspace must not appear in the schema in any form.
		schema, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatalf("marshal %s schema: %v", name, err)
		}
		if strings.Contains(strings.ToLower(string(schema)), "workspace") {
			t.Errorf("%s input schema mentions workspace — cross-workspace must be UNREPRESENTABLE: %s", name, schema)
		}
	}
	for _, name := range reads {
		a := tools[name].Annotations
		if a == nil || a.ReadOnlyHint != true || a.DestructiveHint != nil {
			t.Errorf("%s annotations = %+v, want ReadOnlyHint:true, no DestructiveHint", name, a)
		}
	}
	for _, name := range writes {
		a := tools[name].Annotations
		if a == nil || a.ReadOnlyHint != false || a.DestructiveHint == nil || *a.DestructiveHint != true {
			t.Errorf("%s annotations = %+v, want ReadOnlyHint:false + DestructiveHint:true", name, a)
		}
	}
}

// chatStubBackend is an httptest /v1/chat implementation for the E2E round
// trip: session create, message accept, tail read (with since tracking), and
// the fleet SSE (snapshot working → flip idle after the first send).
type chatStubBackend struct {
	mu        sync.Mutex
	created   int
	sent      []string
	lastSince string
	bearer    string
}

func (b *chatStubBackend) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b.mu.Lock()
		b.bearer = r.Header.Get("Authorization")
		b.mu.Unlock()
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/chat/sessions":
			b.mu.Lock()
			b.created++
			b.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, `{"id":"sess-1","status":"active","provider":"claude"}`)
		case r.Method == http.MethodPost && r.URL.Path == "/v1/chat/sessions/sess-1/messages":
			var body struct {
				Content string `json:"content"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			b.mu.Lock()
			b.sent = append(b.sent, body.Content)
			b.mu.Unlock()
			w.WriteHeader(http.StatusAccepted)
			_, _ = io.WriteString(w, `{"accepted":true}`)
		case r.Method == http.MethodGet && r.URL.Path == "/v1/chat/sessions/sess-1":
			b.mu.Lock()
			b.lastSince = r.URL.Query().Get("since")
			b.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"id":"sess-1","status":"active","messages":[`+
				`{"seq":1,"role":"user","source_markdown":"count to three"},`+
				`{"seq":2,"role":"assistant","source_markdown":"one two three"}]}`)
		case r.Method == http.MethodGet && r.URL.Path == "/v1/chat/events":
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			fl, _ := w.(http.Flusher)
			// Snapshot: still working; then the settle flip.
			_, _ = io.WriteString(w, "id: 9:1\nevent: snapshot\ndata: {\"sessions\":[{\"session_id\":\"sess-1\",\"agent_state\":\"working\",\"ts\":\"2026-07-22T00:00:00Z\",\"title\":\"child\"}]}\n\n")
			_, _ = io.WriteString(w, "id: 9:2\nevent: state\ndata: {\"session_id\":\"sess-1\",\"agent_state\":\"idle\",\"ts\":\"2026-07-22T00:00:05Z\",\"title\":null}\n\n")
			if fl != nil {
				fl.Flush()
			}
			<-r.Context().Done()
		default:
			// The 404 not-found oracle: anything out of scope (a foreign
			// session id included) answers the standard envelope.
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":{"code":"not_found"}}`)
		}
	})
}

// TestChatToolsE2ERoundTrip drives the full herd loop over a live MCP session
// against the httptest backend: spawn → send → wait (resolves idle off the
// fleet stream) → read_tail — every call carrying the server context's bearer,
// none carrying a workspace.
func TestChatToolsE2ERoundTrip(t *testing.T) {
	backend := &chatStubBackend{}
	api := httptest.NewServer(backend.handler(t))
	defer api.Close()

	cs := newChatToolSession(t, manifest.Context{Server: api.URL, Token: "herder-tok"})
	bg := context.Background()

	// 1. Spawn — row only, no runtime.
	res, err := cs.CallTool(bg, &mcp.CallToolParams{Name: "chat_spawn_session", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("chat_spawn_session: %v", err)
	}
	if res.IsError {
		t.Fatalf("chat_spawn_session IsError: %s", mcpContentText(res))
	}
	var spawned struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(mcpContentText(res)), &spawned); err != nil || spawned.ID != "sess-1" {
		t.Fatalf("spawn result = %q (err %v), want id sess-1", mcpContentText(res), err)
	}

	// 2. Send — 202 fire-and-forget.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{Name: "chat_send", Arguments: map[string]any{
		"session_id": spawned.ID, "content": "count to three",
	}})
	if err != nil {
		t.Fatalf("chat_send: %v", err)
	}
	if res.IsError {
		t.Fatalf("chat_send IsError: %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), `"accepted":true`) {
		t.Fatalf("chat_send result = %q, want accepted:true", mcpContentText(res))
	}

	// 3. Wait — resolves idle from the flip on the fleet stream.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{Name: "chat_wait_for_state", Arguments: map[string]any{
		"session_id": spawned.ID, "timeout_seconds": 10,
	}})
	if err != nil {
		t.Fatalf("chat_wait_for_state: %v", err)
	}
	if res.IsError {
		t.Fatalf("chat_wait_for_state IsError: %s", mcpContentText(res))
	}
	var waited struct {
		Resolved bool   `json:"resolved"`
		State    string `json:"state"`
	}
	if err := json.Unmarshal([]byte(mcpContentText(res)), &waited); err != nil {
		t.Fatalf("decode wait result %q: %v", mcpContentText(res), err)
	}
	if !waited.Resolved || waited.State != "idle" {
		t.Fatalf("wait = %+v, want resolved idle", waited)
	}

	// 4. Read the tail.
	res, err = cs.CallTool(bg, &mcp.CallToolParams{Name: "chat_read_tail", Arguments: map[string]any{
		"session_id": spawned.ID, "since": 0,
	}})
	if err != nil {
		t.Fatalf("chat_read_tail: %v", err)
	}
	if res.IsError {
		t.Fatalf("chat_read_tail IsError: %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), "one two three") {
		t.Fatalf("read_tail result = %q, want the assistant row", mcpContentText(res))
	}

	backend.mu.Lock()
	defer backend.mu.Unlock()
	if backend.created != 1 || len(backend.sent) != 1 || backend.sent[0] != "count to three" {
		t.Errorf("backend saw created=%d sent=%v, want 1 create + the prompt", backend.created, backend.sent)
	}
	if backend.bearer != "Bearer herder-tok" {
		t.Errorf("bearer = %q, want the server context token (tenancy rides the token, D77h)", backend.bearer)
	}
}

// TestChatReadTailForeignSession404 — the tenancy oracle (D77h): a session id
// outside the caller's workspace scope answers the server's 404 not-found
// envelope, surfaced as an honest tool error.
func TestChatReadTailForeignSession404(t *testing.T) {
	backend := &chatStubBackend{}
	api := httptest.NewServer(backend.handler(t))
	defer api.Close()

	cs := newChatToolSession(t, manifest.Context{Server: api.URL, Token: "tok"})
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "chat_read_tail", Arguments: map[string]any{
		"session_id": "foreign-workspace-session",
	}})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if !res.IsError {
		t.Fatalf("a foreign session id must surface the 404 oracle as IsError, got: %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), "not_found") {
		t.Errorf("error text = %q, want the not_found envelope", mcpContentText(res))
	}
}

// waitResult decodes a runChatWait tool result, failing the test on an
// unexpected IsError.
func waitResult(t *testing.T, res *mcp.CallToolResult) (out struct {
	Resolved  bool   `json:"resolved"`
	State     string `json:"state"`
	LastState string `json:"last_state"`
	Cursor    string `json:"cursor"`
}) {
	t.Helper()
	if res.IsError {
		t.Fatalf("wait unexpectedly IsError: %s", mcpContentText(res))
	}
	if err := json.Unmarshal([]byte(mcpContentText(res)), &out); err != nil {
		t.Fatalf("decode wait result %q: %v", mcpContentText(res), err)
	}
	return out
}

// fleetSSEServer serves GET /v1/chat/events from the supplied per-connection
// script and records each connection's Last-Event-ID. done is closed-signalled
// per request context so teardown tests can observe the SSE dying.
type fleetSSEServer struct {
	mu      sync.Mutex
	resumes []string
	closed  chan struct{}
	script  func(conn int, w io.Writer, fl http.Flusher)
	hold    bool
}

func (s *fleetSSEServer) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/events" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":{"code":"not_found"}}`)
			return
		}
		s.mu.Lock()
		s.resumes = append(s.resumes, r.Header.Get("Last-Event-ID"))
		conn := len(s.resumes)
		s.mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		s.script(conn, w, fl)
		if s.hold {
			<-r.Context().Done()
			if s.closed != nil && conn == 1 {
				close(s.closed)
			}
		}
	})
}

// TestChatWaitResolvesOnFlip — snapshot says working, a later state flip to
// blocked resolves the wait via the onEvent-error stop, cursor = the flip's id.
func TestChatWaitResolvesOnFlip(t *testing.T) {
	sse := &fleetSSEServer{hold: true, script: func(conn int, w io.Writer, fl http.Flusher) {
		_, _ = io.WriteString(w, "id: 4:1\nevent: snapshot\ndata: {\"sessions\":[{\"session_id\":\"s1\",\"agent_state\":\"working\",\"ts\":\"2026-07-22T00:00:00Z\",\"title\":\"x\"}]}\n\n")
		_, _ = io.WriteString(w, "event: heartbeat\ndata: {\"session_id\":\"s1\",\"ts\":\"2026-07-22T00:00:30Z\"}\n\n")
		_, _ = io.WriteString(w, "id: 4:2\nevent: state\ndata: {\"session_id\":\"s1\",\"agent_state\":\"blocked\",\"ts\":\"2026-07-22T00:00:31Z\",\"title\":null}\n\n")
		if fl != nil {
			fl.Flush()
		}
	}}
	api := httptest.NewServer(sse.handler())
	defer api.Close()

	cli := apiclient.New(apiclient.Config{BaseURL: api.URL, Token: "tok"})
	got := waitResult(t, runChatWait(context.Background(), cli, "s1", "", 5*time.Second))
	if !got.Resolved || got.State != "blocked" {
		t.Fatalf("wait = %+v, want resolved blocked", got)
	}
	if got.Cursor != "4:2" {
		t.Errorf("cursor = %q, want 4:2 (the resolving flip's id)", got.Cursor)
	}
}

// TestChatWaitResolvesFromSnapshot — the already-settled case: the snapshot
// itself reports idle, so the wait resolves instantly with no flip needed
// (kills the check-then-wait race, D76h).
func TestChatWaitResolvesFromSnapshot(t *testing.T) {
	sse := &fleetSSEServer{hold: true, script: func(conn int, w io.Writer, fl http.Flusher) {
		_, _ = io.WriteString(w, "id: 4:7\nevent: snapshot\ndata: {\"sessions\":[{\"session_id\":\"s1\",\"agent_state\":\"idle\",\"ts\":\"2026-07-22T00:00:00Z\",\"title\":\"x\"}]}\n\n")
		if fl != nil {
			fl.Flush()
		}
	}}
	api := httptest.NewServer(sse.handler())
	defer api.Close()

	cli := apiclient.New(apiclient.Config{BaseURL: api.URL, Token: "tok"})
	start := time.Now()
	got := waitResult(t, runChatWait(context.Background(), cli, "s1", "", 30*time.Second))
	if !got.Resolved || got.State != "idle" {
		t.Fatalf("wait = %+v, want resolved idle from the snapshot", got)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("snapshot resolve took %v — must answer instantly, never sit out the bound", elapsed)
	}
}

// TestChatWaitTimeoutReturnsCursor — the bound is a VALID outcome: the session
// never leaves working, so the wait returns IsError:false {resolved:false,
// last_state, cursor} with the cursor advanced to the last id-bearing frame
// (pinned across the id-less heartbeat after it).
func TestChatWaitTimeoutReturnsCursor(t *testing.T) {
	sse := &fleetSSEServer{hold: true, script: func(conn int, w io.Writer, fl http.Flusher) {
		_, _ = io.WriteString(w, "id: 4:1\nevent: snapshot\ndata: {\"sessions\":[{\"session_id\":\"s1\",\"agent_state\":\"working\",\"ts\":\"2026-07-22T00:00:00Z\",\"title\":\"x\"}]}\n\n")
		_, _ = io.WriteString(w, "id: 4:2\nevent: state\ndata: {\"session_id\":\"s1\",\"agent_state\":\"working\",\"ts\":\"2026-07-22T00:00:01Z\",\"title\":null}\n\n")
		_, _ = io.WriteString(w, "event: heartbeat\ndata: {\"session_id\":\"s1\",\"ts\":\"2026-07-22T00:00:30Z\"}\n\n")
		if fl != nil {
			fl.Flush()
		}
	}}
	api := httptest.NewServer(sse.handler())
	defer api.Close()

	cli := apiclient.New(apiclient.Config{BaseURL: api.URL, Token: "tok"})
	got := waitResult(t, runChatWait(context.Background(), cli, "s1", "", 500*time.Millisecond))
	if got.Resolved {
		t.Fatalf("wait = %+v, want unresolved on the bound", got)
	}
	if got.LastState != "working" {
		t.Errorf("last_state = %q, want the honest last observation \"working\"", got.LastState)
	}
	if got.Cursor != "4:2" {
		t.Errorf("cursor = %q, want 4:2 (last id-bearing frame; the heartbeat must not move it)", got.Cursor)
	}
}

// TestChatWaitCursorResume — the resumable half of D76h: a wait that timed out
// hands its cursor to a re-call, whose connection carries it as Last-Event-ID;
// the server replays the missed flip and the second wait resolves from it.
func TestChatWaitCursorResume(t *testing.T) {
	sse := &fleetSSEServer{hold: true, script: func(conn int, w io.Writer, fl http.Flusher) {
		switch conn {
		case 1:
			_, _ = io.WriteString(w, "id: 4:1\nevent: snapshot\ndata: {\"sessions\":[{\"session_id\":\"s1\",\"agent_state\":\"working\",\"ts\":\"2026-07-22T00:00:00Z\",\"title\":\"x\"}]}\n\n")
		default:
			// Replay from the cursor: exactly the missed flip.
			_, _ = io.WriteString(w, "id: 4:2\nevent: state\ndata: {\"session_id\":\"s1\",\"agent_state\":\"idle\",\"ts\":\"2026-07-22T00:00:09Z\",\"title\":null}\n\n")
		}
		if fl != nil {
			fl.Flush()
		}
	}}
	api := httptest.NewServer(sse.handler())
	defer api.Close()

	cli := apiclient.New(apiclient.Config{BaseURL: api.URL, Token: "tok"})

	first := waitResult(t, runChatWait(context.Background(), cli, "s1", "", 500*time.Millisecond))
	if first.Resolved || first.Cursor != "4:1" {
		t.Fatalf("first wait = %+v, want unresolved with cursor 4:1", first)
	}

	second := waitResult(t, runChatWait(context.Background(), cli, "s1", first.Cursor, 5*time.Second))
	if !second.Resolved || second.State != "idle" {
		t.Fatalf("second wait = %+v, want resolved idle from the replayed flip", second)
	}

	sse.mu.Lock()
	defer sse.mu.Unlock()
	if len(sse.resumes) < 2 {
		t.Fatalf("saw %d connections, want 2", len(sse.resumes))
	}
	if sse.resumes[0] != "" {
		t.Errorf("first connect Last-Event-ID = %q, want empty (fresh)", sse.resumes[0])
	}
	if sse.resumes[1] != "4:1" {
		t.Errorf("resume Last-Event-ID = %q, want the handed-out cursor 4:1", sse.resumes[1])
	}
}

// TestChatWaitCtxCancelTeardown — the MCP client abandoning the call cancels
// the handler ctx; the wait must tear the SSE down promptly (both the read and
// backoff paths select on ctx) and return the honest unresolved shape instead
// of hanging out its bound.
func TestChatWaitCtxCancelTeardown(t *testing.T) {
	sse := &fleetSSEServer{hold: true, closed: make(chan struct{}), script: func(conn int, w io.Writer, fl http.Flusher) {
		_, _ = io.WriteString(w, "id: 4:1\nevent: snapshot\ndata: {\"sessions\":[{\"session_id\":\"s1\",\"agent_state\":\"working\",\"ts\":\"2026-07-22T00:00:00Z\",\"title\":\"x\"}]}\n\n")
		if fl != nil {
			fl.Flush()
		}
	}}
	api := httptest.NewServer(sse.handler())
	defer api.Close()

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()

	cli := apiclient.New(apiclient.Config{BaseURL: api.URL, Token: "tok"})
	start := time.Now()
	got := waitResult(t, runChatWait(ctx, cli, "s1", "", 30*time.Second))
	elapsed := time.Since(start)

	if got.Resolved {
		t.Fatalf("wait = %+v, want unresolved on cancel", got)
	}
	if elapsed > 5*time.Second {
		t.Errorf("cancel teardown took %v — must return promptly, not sit out the 30s bound", elapsed)
	}
	select {
	case <-sse.closed:
		// server observed the connection torn down
	case <-time.After(5 * time.Second):
		t.Errorf("SSE connection not torn down after ctx cancel")
	}
}

// TestChatWaitInitialConnectErrorSurfaces — a refused fleet stream (401 on the
// strict initial connect) is a REAL error, not a bound: the tool reports it.
func TestChatWaitInitialConnectErrorSurfaces(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":{"code":"unauthorized"}}`)
	}))
	defer api.Close()

	cli := apiclient.New(apiclient.Config{BaseURL: api.URL, Token: "bad"})
	res := runChatWait(context.Background(), cli, "s1", "", time.Second)
	if !res.IsError {
		t.Fatalf("a refused stream must surface IsError, got %s", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), "unauthorized") {
		t.Errorf("error text = %q, want the server envelope", mcpContentText(res))
	}
}

// TestChatReadTailClampNotice — an oversized cold read clamps at the shared
// 48KB guard with the chat-honest escape hatch (page by since).
func TestChatReadTailClampNotice(t *testing.T) {
	big := strings.Repeat("x", mcpToolResultMaxBytes)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"id":"sess-1","messages":[{"seq":1,"role":"assistant","source_markdown":%q}]}`, big)
	}))
	defer api.Close()

	cs := newChatToolSession(t, manifest.Context{Server: api.URL, Token: "tok"})
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "chat_read_tail", Arguments: map[string]any{
		"session_id": "sess-1",
	}})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	text := mcpContentText(res)
	if len(text) > mcpToolResultMaxBytes+512 {
		t.Errorf("clamped result is %d bytes, want <= cap + notice", len(text))
	}
	if !strings.Contains(text, "since = the highest seq") {
		t.Errorf("truncation notice must name the since escape hatch, got tail %q", text[len(text)-200:])
	}
}
