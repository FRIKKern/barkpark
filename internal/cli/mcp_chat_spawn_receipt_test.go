package cli

// mcp_chat_spawn_receipt_test.go — task-c3c5b24d4724f95e.
//
// chat_spawn_session is a hardcoded BUILT-IN (D74h), not a manifest-dispatched
// command, so it never reaches mcpRunFor and was the one MCP write outside the
// shared write fence that PR #15900
// (pds-bl-mcp-exec-bypasses-write-fence) closed for everything else. A store
// answering 200 with {} / null / {"result":null} handed the model a zero
// ChatSession — an EMPTY session id reported as a successfully spawned agent.
//
// These proofs drive the REAL MCP client/server transport (newChatToolSession →
// registerChatTools → the registered handler), never the helper directly.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// chatFixedBackend answers EVERY request with one status/body, so the poison
// under test is the only variable.
func chatFixedBackend(t *testing.T, status int, body string) *mcp.ClientSession {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return newChatToolSession(t, manifest.Context{Server: srv.URL, Token: "tok"})
}

func callSpawn(t *testing.T, cs *mcp.ClientSession) *mcp.CallToolResult {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "chat_spawn_session",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("CallTool chat_spawn_session: %v", err)
	}
	return res
}

func resultText(res *mcp.CallToolResult) string {
	var sb strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			sb.WriteString(tc.Text)
		}
	}
	return sb.String()
}

// TestMCPChatSpawnPoisonedReceiptIsError is the c1 proof: the exact bodies the
// row names, plus the fence's wider poison matrix, must come back IsError with
// the reason NAMED — not a success carrying an empty session id.
func TestMCPChatSpawnPoisonedReceiptIsError(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{"empty_object", 200, `{}`, "empty JSON object"},
		{"json_null", 200, `null`, "JSON literal null"},
		{"result_null", 200, `{"result":null}`, "envelope was empty"},
		{"undeclared_empty_200", 200, ``, "without declaring one"},
		{"html_proxy_page", 200, `<!doctype html><html>502</html>`, "not JSON"},
		{"error_envelope_on_2xx", 200, `{"ok":false,"error":{"code":"boom"}}`, "ERROR envelope"},
		// The fence is key-agnostic by design, so these two reach the id gate:
		// honest-looking objects that name no session to address.
		{"object_without_id", 200, `{"ok":true}`, "no session id"},
		{"blank_id", 201, `{"id":"   "}`, "no session id"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := callSpawn(t, chatFixedBackend(t, tc.status, tc.body))
			text := resultText(res)
			if !res.IsError {
				t.Fatalf("IsError = false, want true — a poisoned receipt was reported as a spawned agent: %s", text)
			}
			if !strings.Contains(text, tc.want) {
				t.Errorf("refusal text %q does not name %q", text, tc.want)
			}
			if !strings.Contains(text, "chat_spawn_session write receipt") {
				t.Errorf("refusal text %q does not name the surface", text)
			}
		})
	}
}

// TestMCPChatSpawnHonestReceiptStillSucceeds is the NON-VACUITY arm: a real
// spawn still returns success, and the id survives into the result.
func TestMCPChatSpawnHonestReceiptStillSucceeds(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"created_201", 201, `{"id":"sess-abc","provider":"claude","status":"idle"}`},
		{"ok_200", 200, `{"id":"sess-abc"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := callSpawn(t, chatFixedBackend(t, tc.status, tc.body))
			text := resultText(res)
			if res.IsError {
				t.Fatalf("IsError = true on an honest spawn receipt: %s", text)
			}
			if !strings.Contains(text, "sess-abc") {
				t.Errorf("result %q does not carry the spawned session id", text)
			}
			var probe map[string]any
			if json.Unmarshal([]byte(text), &probe) == nil && probe["id"] != "sess-abc" {
				t.Errorf("result id = %v, want sess-abc", probe["id"])
			}
		})
	}
}

// TestMCPChatSendPoisonedReceiptIsError covers the SIBLING built-in found by the
// same measurement: chat_send synthesises {"accepted":true} from a nil error, so
// a 2xx that said nothing became a confident local accept. chat_controller
// answers 202 {accepted:true} — a receipt the fence passes — so fencing it costs
// nothing honest.
func TestMCPChatSendPoisonedReceiptIsError(t *testing.T) {
	send := func(t *testing.T, cs *mcp.ClientSession) *mcp.CallToolResult {
		t.Helper()
		res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
			Name:      "chat_send",
			Arguments: map[string]any{"session_id": "s1", "content": "hi"},
		})
		if err != nil {
			t.Fatalf("CallTool chat_send: %v", err)
		}
		return res
	}
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{"empty_object", 202, `{}`, "empty JSON object"},
		{"json_null", 202, `null`, "JSON literal null"},
		{"undeclared_empty_200", 200, ``, "without declaring one"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := send(t, chatFixedBackend(t, tc.status, tc.body))
			text := resultText(res)
			if !res.IsError {
				t.Fatalf("IsError = false, want true — an empty 2xx became accepted:true: %s", text)
			}
			if !strings.Contains(text, tc.want) {
				t.Errorf("refusal text %q does not name %q", text, tc.want)
			}
		})
	}
	t.Run("honest_202_still_accepted", func(t *testing.T) {
		res := send(t, chatFixedBackend(t, 202, `{"accepted":true}`))
		if res.IsError {
			t.Fatalf("IsError = true on the server's real 202 receipt: %s", resultText(res))
		}
		if !strings.Contains(resultText(res), "accepted") {
			t.Errorf("result %q lost the accept", resultText(res))
		}
	})
}
