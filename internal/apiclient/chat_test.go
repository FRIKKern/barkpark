package apiclient

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// chatTestToken is the data-plane bearer every chat call must carry (D3). The
// tests assert this value reaches the server so a regression that dropped auth,
// or reached for a different token field, would red.
const chatTestToken = "dataplane-tok-123"

func newChatClient(baseURL string) *Client {
	return New(Config{BaseURL: baseURL, Token: chatTestToken})
}

func wantBearer(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get("Authorization"); got != "Bearer "+chatTestToken {
		t.Errorf("Authorization = %q, want %q (data-plane token, D3)", got, "Bearer "+chatTestToken)
	}
}

func TestCreateChatSession(t *testing.T) {
	var gotBody map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/sessions" {
			t.Errorf("got %s %s, want POST /v1/chat/sessions", r.Method, r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"id":"sess-1","status":"idle","cwd":"/tmp","mode":"default","draft":"hi","model_choice":"opus"}`)
	}))
	defer srv.Close()

	s, err := newChatClient(srv.URL).CreateChatSession("default", "opus", "high")
	if err != nil {
		t.Fatalf("CreateChatSession: %v", err)
	}
	if s.ID != "sess-1" || s.Cwd != "/tmp" || s.Mode != "default" {
		t.Fatalf("decoded session = %+v", s)
	}
	// Full struct carries the D14 continuity fields on create too.
	if s.Draft != "hi" || s.ModelChoice != "opus" {
		t.Errorf("continuity fields lost: draft=%q model_choice=%q", s.Draft, s.ModelChoice)
	}
	// The create body carries ONLY mode/model/effort (C0).
	if gotBody["mode"] != "default" || gotBody["model"] != "opus" || gotBody["effort"] != "high" {
		t.Errorf("request body = %v, want mode/model/effort set", gotBody)
	}
	// cwd is a launcher control the client must NEVER send, even though the
	// server may report a read-only Cwd on the response (C0).
	if _, ok := gotBody["cwd"]; ok {
		t.Errorf("create body must not send cwd (launcher control), got %v", gotBody)
	}
	// No launcher/session/token/bypass control keys leak into the body.
	for _, forbidden := range []string{"cwd", "session_id", "token", "bypass", "launcher"} {
		if _, ok := gotBody[forbidden]; ok {
			t.Errorf("create body leaked forbidden key %q: %v", forbidden, gotBody)
		}
	}
}

func TestCreateChatSessionOmitsEmptyOptions(t *testing.T) {
	var gotBody map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"id":"sess-2"}`)
	}))
	defer srv.Close()

	if _, err := newChatClient(srv.URL).CreateChatSession("", "", ""); err != nil {
		t.Fatalf("CreateChatSession: %v", err)
	}
	if len(gotBody) != 0 {
		t.Errorf("empty options should be omitted, got body %v", gotBody)
	}
}

func TestCreateChatSessionWithProviderExecutionOptions(t *testing.T) {
	var gotBody map[string]interface{}
	const hostID = "0f9d8c7b-6a5e-4d3c-2b1a-0f9e8d7c6b5a"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"id":"sess-codex","provider":"codex","execution_target":"registered_host","execution_host_id":"`+hostID+`","provider_session_id":"thread-7"}`)
	}))
	defer srv.Close()

	s, err := newChatClient(srv.URL).CreateChatSessionWithOptions(ChatSessionCreateOptions{
		Provider:        "codex",
		ExecutionTarget: "registered_host",
		ExecutionHostID: hostID,
		Mode:            "read-only",
		Model:           "gpt-5.6",
		Effort:          "high",
	})
	if err != nil {
		t.Fatalf("CreateChatSessionWithOptions: %v", err)
	}

	if gotBody["provider"] != "codex" || gotBody["execution_target"] != "registered_host" || gotBody["execution_host_id"] != hostID {
		t.Errorf("provider execution body = %v", gotBody)
	}
	if s.Provider != "codex" || s.ExecutionTarget != "registered_host" || s.ExecutionHostID != hostID || s.ProviderSessionID != "thread-7" {
		t.Errorf("provider identity decode = %+v", s)
	}
}

func TestListChatSessions(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/v1/chat/sessions" {
			t.Errorf("got %s %s, want GET /v1/chat/sessions", r.Method, r.URL.Path)
		}
		if got := r.URL.Query().Get("archived"); got != "true" {
			t.Errorf("archived query = %q, want true", got)
		}
		_, _ = io.WriteString(w, `{"sessions":[{"id":"a","title":"First"},{"id":"b","title":"Second","archived":true}]}`)
	}))
	defer srv.Close()

	got, err := newChatClient(srv.URL).ListChatSessions(true)
	if err != nil {
		t.Fatalf("ListChatSessions: %v", err)
	}
	if len(got) != 2 || got[0].ID != "a" || got[1].Title != "Second" {
		t.Fatalf("list = %+v", got)
	}
}

// TestChatSessionSummaryDecodesHerdFields is the D50h decode lock: the herd
// cold-mount fields (agent_state / agent_state_at / total_cost_usd) decode off
// the widened sidebar wire, and an older server that omits them is
// ignore-safe (zero values, no error).
func TestChatSessionSummaryDecodesHerdFields(t *testing.T) {
	widened := []byte(`{"id":"a","title":"T","agent_state":"blocked",
		"agent_state_at":"2026-07-18T11:55:00.123456Z","total_cost_usd":1.25}`)
	var s ChatSessionSummary
	if err := json.Unmarshal(widened, &s); err != nil {
		t.Fatalf("decode widened summary: %v", err)
	}
	if s.AgentState != "blocked" || s.AgentStateAt != "2026-07-18T11:55:00.123456Z" {
		t.Fatalf("herd fields must decode, got %+v", s)
	}
	if s.TotalCostUSD != 1.25 {
		t.Fatalf("total_cost_usd must decode, got %v", s.TotalCostUSD)
	}

	var old ChatSessionSummary
	if err := json.Unmarshal([]byte(`{"id":"b","title":"pre-widen"}`), &old); err != nil {
		t.Fatalf("decode pre-widen summary: %v", err)
	}
	if old.AgentState != "" || old.AgentStateAt != "" || old.TotalCostUSD != 0 {
		t.Fatalf("a pre-widen wire must decode to zero values, got %+v", old)
	}
}

func TestListChatSessionsActiveFlag(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("archived"); got != "false" {
			t.Errorf("archived query = %q, want false", got)
		}
		_, _ = io.WriteString(w, `{"sessions":[]}`)
	}))
	defer srv.Close()

	got, err := newChatClient(srv.URL).ListChatSessions(false)
	if err != nil {
		t.Fatalf("ListChatSessions: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("want empty list, got %+v", got)
	}
}

func TestGetChatSessionPassesBlocksRaw(t *testing.T) {
	// The assistant row's blocks JSON must reach the caller VERBATIM as raw
	// JSON for pdrender.Decode (D8) — the client must not project or reshape it.
	const blocks = `[{"type":"heading","level":2,"text":"Hi"},{"type":"paragraph","content":[{"type":"text","value":"body"}]}]`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/v1/chat/sessions/sess-1" {
			t.Errorf("got %s %s, want GET /v1/chat/sessions/sess-1", r.Method, r.URL.Path)
		}
		if r.URL.RawQuery != "" {
			t.Errorf("sinceSeq 0 must send no query, got %q", r.URL.RawQuery)
		}
		_, _ = io.WriteString(w, `{"id":"sess-1","draft":"wip","rail_snapshot":{"x":1},"mode":"plan","model_choice":"opus","effort_choice":"high","messages":[{"seq":1,"role":"user","content":"hey"},{"seq":2,"role":"assistant","source_markdown":"## Hi\n\nbody","blocks":`+blocks+`}]}`)
	}))
	defer srv.Close()

	s, err := newChatClient(srv.URL).GetChatSession("sess-1", 0)
	if err != nil {
		t.Fatalf("GetChatSession: %v", err)
	}
	// D14 continuity set present on the full GET.
	if s.Draft != "wip" || s.Mode != "plan" || s.ModelChoice != "opus" || s.EffortChoice != "high" {
		t.Errorf("continuity fields = %+v", s)
	}
	if string(s.RailSnapshot) == "" {
		t.Errorf("rail_snapshot dropped")
	}
	if len(s.Messages) != 2 {
		t.Fatalf("want 2 messages, got %d", len(s.Messages))
	}
	asst := s.Messages[1]
	if asst.Role != "assistant" || asst.SourceMarkdown == "" {
		t.Errorf("assistant row = %+v", asst)
	}
	// blocks survived as raw JSON that pdrender.Decode can consume: decode it
	// back and confirm the first block type round-tripped untouched.
	var decoded []map[string]interface{}
	if err := json.Unmarshal(asst.Blocks, &decoded); err != nil {
		t.Fatalf("blocks not valid raw JSON: %v", err)
	}
	if len(decoded) != 2 || decoded[0]["type"] != "heading" {
		t.Errorf("blocks passthrough corrupted: %+v", decoded)
	}
}

// PROTECTIVE (charter D26 / the dedup 3-way merge): the full GET must decode the
// live server projection's FLAT usage metrics, denormalised counters,
// rail_snapshot, and message metadata/inserted_at — the exact fields the fork
// was blind to. A revert to the old apiclient shape (token_metrics/
// context_metrics/archived/created_at) would leave every one of these zero and
// red this test, because none of those keys are on the wire.
func TestGetChatSessionDecodesLiveProjection(t *testing.T) {
	const body = `{
		"id":"sess-1","title":"T","status":"running","mode":"plan","model_choice":"opus","effort_choice":"high",
		"draft":"wip","summary":"a chat","message_count":4,"pending_approvals":1,
		"input_tokens":1200,"output_tokens":800,"total_cost_usd":0.042,"context_window":200000,"last_context_tokens":15000,
		"last_active_at":"2026-07-13T00:00:00Z","inserted_at":"2026-07-12T00:00:00Z","updated_at":"2026-07-13T00:00:00Z",
		"rail_snapshot":{"task-abc":{"status":"running","origin":"background","description":"survey the tree","seq":1,"usage":{"input":10}}},
		"messages":[{"seq":9,"role":"tool","source_markdown":"ran ls","metadata":{"prompt":"list files"},"inserted_at":"2026-07-13T00:00:01Z"}]
	}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, body)
	}))
	defer srv.Close()

	s, err := newChatClient(srv.URL).GetChatSession("sess-1", 0)
	if err != nil {
		t.Fatalf("GetChatSession: %v", err)
	}
	// Flat usage metrics (top-level, NOT nested).
	if s.InputTokens != 1200 || s.OutputTokens != 800 || s.ContextWindow != 200000 || s.LastContextTokens != 15000 {
		t.Errorf("flat token metrics = %+v", s)
	}
	if s.TotalCostUSD != 0.042 {
		t.Errorf("total_cost_usd = %v, want 0.042", s.TotalCostUSD)
	}
	// Denormalised counters + timestamps.
	if s.MessageCount != 4 || s.PendingApprovals != 1 {
		t.Errorf("counters = msg %d / pending %d", s.MessageCount, s.PendingApprovals)
	}
	if s.InsertedAt == "" || s.LastActiveAt == "" {
		t.Errorf("inserted_at / last_active_at dropped: %+v", s)
	}
	// Rail decodes the task_id-keyed map with origin/status/description.
	rail, err := s.Rail()
	if err != nil {
		t.Fatalf("Rail: %v", err)
	}
	entry, ok := rail["task-abc"]
	if !ok {
		t.Fatalf("rail entry missing, got %v", rail)
	}
	if entry.Status != "running" || entry.Origin != "background" || entry.Description != "survey the tree" {
		t.Errorf("rail entry = %+v", entry)
	}
	if len(entry.Usage) == 0 {
		t.Errorf("rail entry usage passthrough dropped")
	}
	// Message metadata reaches the read-only cards; inserted_at present.
	if len(s.Messages) != 1 {
		t.Fatalf("want 1 message, got %d", len(s.Messages))
	}
	m := s.Messages[0]
	if m.Metadata["prompt"] != "list files" || m.InsertedAt == "" {
		t.Errorf("message metadata/inserted_at = %+v", m)
	}
}

// An absent or empty rail_snapshot is the common idle case: Rail returns nil,nil
// (never an error), so callers can range over it safely.
func TestChatSessionRailEmpty(t *testing.T) {
	for _, raw := range []string{"", "{}", "null", "  "} {
		s := ChatSession{RailSnapshot: json.RawMessage(raw)}
		rail, err := s.Rail()
		if err != nil {
			t.Errorf("Rail(%q) errored: %v", raw, err)
		}
		if rail != nil {
			t.Errorf("Rail(%q) = %v, want nil", raw, rail)
		}
	}
}

func TestGetChatSessionSinceTail(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("since"); got != "7" {
			t.Errorf("since query = %q, want 7", got)
		}
		_, _ = io.WriteString(w, `{"id":"sess-1","messages":[{"seq":8,"role":"assistant"}]}`)
	}))
	defer srv.Close()

	s, err := newChatClient(srv.URL).GetChatSession("sess-1", 7)
	if err != nil {
		t.Fatalf("GetChatSession since: %v", err)
	}
	if len(s.Messages) != 1 || s.Messages[0].Seq != 8 {
		t.Errorf("tail refetch = %+v", s.Messages)
	}
}

func TestUpdateChatSession(t *testing.T) {
	var gotBody map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		if r.Method != http.MethodPatch || r.URL.Path != "/v1/chat/sessions/sess-1" {
			t.Errorf("got %s %s, want PATCH /v1/chat/sessions/sess-1", r.Method, r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	draft := "a new draft"
	mode := "plan"
	if err := newChatClient(srv.URL).UpdateChatSession("sess-1", ChatSessionPatch{Draft: &draft, Mode: &mode}); err != nil {
		t.Fatalf("UpdateChatSession: %v", err)
	}
	if gotBody["draft"] != "a new draft" || gotBody["mode"] != "plan" {
		t.Errorf("patch body = %v", gotBody)
	}
	// Unset pointer fields must be omitted, not sent as null.
	if _, ok := gotBody["title"]; ok {
		t.Errorf("nil title should be omitted, body = %v", gotBody)
	}
}

func TestUpdateChatSessionClearsDraft(t *testing.T) {
	// A pointer to "" must SEND draft:"" (clear), distinct from nil (untouched).
	var gotBody map[string]json.RawMessage
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	empty := ""
	if err := newChatClient(srv.URL).UpdateChatSession("sess-1", ChatSessionPatch{Draft: &empty}); err != nil {
		t.Fatalf("UpdateChatSession: %v", err)
	}
	raw, ok := gotBody["draft"]
	if !ok || string(raw) != `""` {
		t.Errorf("draft clear should send empty string, got %q ok=%v", string(raw), ok)
	}
}

func TestSendChatMessage(t *testing.T) {
	var gotBody map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/sessions/sess-1/messages" {
			t.Errorf("got %s %s, want POST .../messages", r.Method, r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusAccepted)
		_, _ = io.WriteString(w, `{"accepted":true}`)
	}))
	defer srv.Close()

	if err := newChatClient(srv.URL).SendChatMessage("sess-1", "hello there"); err != nil {
		t.Fatalf("SendChatMessage: %v", err)
	}
	if gotBody["content"] != "hello there" {
		t.Errorf("send body = %v", gotBody)
	}
}

func TestInterruptChat(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/sessions/sess-1/interrupt" {
			t.Errorf("got %s %s, want POST .../interrupt", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusAccepted)
		_, _ = io.WriteString(w, `{"request_id":"req-9"}`)
	}))
	defer srv.Close()

	reqID, err := newChatClient(srv.URL).InterruptChat("sess-1")
	if err != nil {
		t.Fatalf("InterruptChat: %v", err)
	}
	if reqID != "req-9" {
		t.Errorf("request_id = %q, want req-9", reqID)
	}
}

func TestInterruptChatEmptyAck(t *testing.T) {
	// D11: the control ack is semantically empty — a no-turn Esc yields a benign
	// body with no request_id and must NOT error.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
		_, _ = io.WriteString(w, `{"still_queued":[]}`)
	}))
	defer srv.Close()

	reqID, err := newChatClient(srv.URL).InterruptChat("sess-1")
	if err != nil {
		t.Fatalf("InterruptChat empty ack must not error: %v", err)
	}
	if reqID != "" {
		t.Errorf("want empty request_id, got %q", reqID)
	}
}

func TestRespondChatApproval(t *testing.T) {
	var gotBody map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/sessions/sess-1/approval" {
			t.Errorf("got %s %s, want POST .../approval", r.Method, r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	if err := newChatClient(srv.URL).RespondChatApproval("sess-1", "req-3", "allow"); err != nil {
		t.Fatalf("RespondChatApproval: %v", err)
	}
	if gotBody["request_id"] != "req-3" || gotBody["decision"] != "allow" {
		t.Errorf("approval body = %v", gotBody)
	}
}

func TestChatMethodErrorPropagates(t *testing.T) {
	// A non-2xx must surface through humanAPIError, not be swallowed.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, `{"error":{"code":"forbidden","message":"admin token required"}}`)
	}))
	defer srv.Close()

	_, err := newChatClient(srv.URL).GetChatSession("sess-1", 0)
	if err == nil {
		t.Fatalf("expected error on 403")
	}
	if !strings.Contains(err.Error(), "admin token required") {
		t.Errorf("error = %v, want human message", err)
	}
}

// ChatEvents: full stream covering the replay phase (id=seq message frames), the
// live phase (id-less chat deltas), the keepalive comment (ignored), and the
// caller-owned cursor being sent on connect. onEvent stops the stream by
// cancelling ctx after the live frame so no reconnect fires.
func TestChatEventsReplayLiveKeepalive(t *testing.T) {
	var seededCursor string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seededCursor = r.Header.Get("Last-Event-ID")
		if r.URL.Path != "/v1/chat/sessions/sess-1/events" {
			t.Errorf("path = %s, want events route", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+chatTestToken {
			t.Errorf("events auth = %q", got)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		// Replay phase: persisted rows > Last-Event-ID, each with id:<seq>.
		_, _ = io.WriteString(w, "id: 4\nevent: message\ndata: {\"seq\":4,\"role\":\"user\"}\n\n")
		_, _ = io.WriteString(w, ": keepalive\n\n") // comment — ignored
		// Live phase: raw claude stream-json delta, NO id.
		_, _ = io.WriteString(w, "event: chat\ndata: {\"type\":\"text\",\"text\":\"streaming\"}\n\n")
		if fl != nil {
			fl.Flush()
		}
		<-r.Context().Done()
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var mu sync.Mutex
	var events []string
	err := newChatClient(srv.URL).ChatEvents(ctx, "sess-1", "3", func(event, data string) error {
		mu.Lock()
		events = append(events, event+"|"+data)
		n := len(events)
		mu.Unlock()
		if n == 2 {
			cancel()
		}
		return nil
	}, nil)
	if err != nil {
		t.Fatalf("ChatEvents: %v", err)
	}
	if seededCursor != "3" {
		t.Errorf("caller-owned cursor not sent: Last-Event-ID = %q, want 3", seededCursor)
	}
	want := []string{`message|{"seq":4,"role":"user"}`, `chat|{"type":"text","text":"streaming"}`}
	if len(events) != len(want) {
		t.Fatalf("got %d events, want %d: %v", len(events), len(want), events)
	}
	for i := range want {
		if events[i] != want[i] {
			t.Errorf("event[%d] = %q, want %q", i, events[i], want[i])
		}
	}
}

// PROTECTIVE: the first connection replays one row with id:5 then drops (EOF).
// ChatEvents must reconnect carrying Last-Event-ID:5 — the cursor ADVANCED from
// the caller's seed (3) by the replayed id, proving resume is by the last row
// actually seen, and onReconnect must fire.
func TestChatEventsReconnectAdvancesCursor(t *testing.T) {
	var (
		mu           sync.Mutex
		reqs         int
		secondResume string
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		reqs++
		n := reqs
		if n == 2 {
			secondResume = r.Header.Get("Last-Event-ID")
		}
		mu.Unlock()

		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		if n == 1 {
			_, _ = io.WriteString(w, "id: 5\nevent: message\ndata: {\"seq\":5}\n\n")
			if fl != nil {
				fl.Flush()
			}
			return // drop → triggers reconnect
		}
		// Second connection: one live frame, then hold until ctx cancel.
		_, _ = io.WriteString(w, "event: chat\ndata: {\"type\":\"done\"}\n\n")
		if fl != nil {
			fl.Flush()
		}
		<-r.Context().Done()
	}))
	defer srv.Close()

	c := newChatClient(srv.URL)
	c.listenBackoffFloor = time.Millisecond // fast reconnect for the test

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var reconnected int32
	var mu2 sync.Mutex
	var events []string
	err := c.ChatEvents(ctx, "sess-1", "3", func(event, data string) error {
		mu2.Lock()
		events = append(events, event)
		n := len(events)
		mu2.Unlock()
		if n == 2 { // first replay + second-conn live frame
			cancel()
		}
		return nil
	}, func() { reconnected++ })
	if err != nil {
		t.Fatalf("ChatEvents: %v", err)
	}
	if secondResume != "5" {
		t.Errorf("reconnect Last-Event-ID = %q, want 5 (advanced from seed 3)", secondResume)
	}
	if reconnected == 0 {
		t.Errorf("onReconnect never fired")
	}
}

// The initial connect stays strict: a non-200 on the first attempt fails fast
// rather than looping forever (bad creds must not retry).
func TestChatEventsInitialErrorFailsFast(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":{"code":"unauthorized","message":"bad token"}}`)
	}))
	defer srv.Close()

	c := newChatClient(srv.URL)
	c.listenBackoffFloor = time.Millisecond

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	err := c.ChatEvents(ctx, "sess-1", "", func(event, data string) error { return nil }, nil)
	if err == nil {
		t.Fatalf("expected error on 401 initial connect")
	}
	if !strings.Contains(err.Error(), "bad token") {
		t.Errorf("error = %v, want human message", err)
	}
}

// The terminal exit frame carries a PUBLIC {status, reason} only — the client
// forwards it verbatim and never surfaces raw process-error vocabulary (C2).
// This proves the exit frame flows through the shared parser and that the data
// the client passes on holds status+reason, nothing stderr-shaped.
func TestChatEventsPublicExit(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		// event:exit — public status + reason, nothing stderr-shaped.
		_, _ = io.WriteString(w, "event: exit\ndata: {\"status\":\"completed\",\"reason\":\"aborted_streaming\"}\n\n")
		if fl != nil {
			fl.Flush()
		}
		<-r.Context().Done()
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var gotEvent, gotData string
	err := newChatClient(srv.URL).ChatEvents(ctx, "sess-1", "", func(event, data string) error {
		gotEvent, gotData = event, data
		cancel()
		return nil
	}, nil)
	if err != nil {
		t.Fatalf("ChatEvents: %v", err)
	}
	if gotEvent != "exit" {
		t.Errorf("event = %q, want exit", gotEvent)
	}
	// The forwarded payload decodes to public {status, reason} and carries no
	// stderr-shaped key.
	var exit map[string]interface{}
	if err := json.Unmarshal([]byte(gotData), &exit); err != nil {
		t.Fatalf("exit data not valid JSON: %v", err)
	}
	if exit["status"] != "completed" || exit["reason"] != "aborted_streaming" {
		t.Errorf("exit payload = %v, want public status+reason", exit)
	}
	if strings.Contains(gotData, "stderr") {
		t.Errorf("exit frame must not carry stderr vocabulary, got %q", gotData)
	}
}

// TestArchiveChatSessionVerbs is the archive wire pin (charter D28). Archive is
// a lifecycle ACTION with its own POST routes — NOT a key on the PATCH
// allowlist — so these assert the method and the exact path, both directions.
func TestArchiveChatSessionVerbs(t *testing.T) {
	for _, tc := range []struct {
		name string
		call func(*Client) (ChatSession, error)
		want string
	}{
		{"archive", func(c *Client) (ChatSession, error) { return c.ArchiveChatSession("s1") },
			"/v1/chat/sessions/s1/archive"},
		{"unarchive", func(c *Client) (ChatSession, error) { return c.UnarchiveChatSession("s1") },
			"/v1/chat/sessions/s1/unarchive"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var gotMethod, gotPath string
			var gotBody []byte
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				wantBearer(t, r)
				gotMethod, gotPath = r.Method, r.URL.Path
				gotBody, _ = io.ReadAll(r.Body)
				_, _ = io.WriteString(w, `{"id":"s1","title":"T","status":"active"}`)
			}))
			defer srv.Close()

			got, err := tc.call(newChatClient(srv.URL))
			if err != nil {
				t.Fatalf("%s: %v", tc.name, err)
			}
			if gotMethod != http.MethodPost || gotPath != tc.want {
				t.Errorf("got %s %s, want POST %s", gotMethod, gotPath, tc.want)
			}
			// A verb, not a field write: no JSON body rides along.
			if len(gotBody) != 0 {
				t.Errorf("archive verbs must send no body, got %q", gotBody)
			}
			// The 200 carries the refreshed session; callers that want it get it.
			if got.ID != "s1" || got.Title != "T" {
				t.Errorf("the 200 must decode into the session, got %+v", got)
			}
		})
	}
}

// TestArchiveChatSessionNotFoundOracle: a foreign tenant's session and a
// missing id are DELIBERATELY indistinguishable (both 404). The client must
// surface that as an error so an optimistic caller can roll back — never
// swallow it into a zero-value success.
func TestArchiveChatSessionNotFoundOracle(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"error":{"code":"not_found"}}`)
	}))
	defer srv.Close()

	if _, err := newChatClient(srv.URL).ArchiveChatSession("nope"); err == nil {
		t.Fatal("a 404 must be an error — a silent success would strand the row off both shelves")
	}
}

// TestArchiveChatSessionEscapesID: ids reach the path escaped, so a hostile or
// merely awkward id cannot climb out of its route segment.
func TestArchiveChatSessionEscapesID(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.EscapedPath()
		_, _ = io.WriteString(w, `{"id":"x"}`)
	}))
	defer srv.Close()

	if _, err := newChatClient(srv.URL).UnarchiveChatSession("a/b"); err != nil {
		t.Fatalf("unarchive: %v", err)
	}
	if gotPath != "/v1/chat/sessions/a%2Fb/unarchive" {
		t.Errorf("id must be path-escaped, got %q", gotPath)
	}
}
