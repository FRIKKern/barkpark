package cli

// mcp_receipt_honesty_test.go — regression guard for the MCP receipt-honesty
// fix (task wbt-go-mcp-receipt-honesty): mcpRunFor must not let a STATED
// success (status < 400) carrying a poisoned body reach the model as
// IsError:false. The table below drives mcpRunFor directly over the write and
// read poison matrices, and a short end-to-end test proves the wiring holds
// through a real curated tool call (task_next), not just the helper in
// isolation.
//
// The discriminators themselves are NOT re-implemented here: mcpRunFor (and
// this test) call run.go's unexported unreadableWriteReceipt / unreadableReadBody
// — run.go stays unmodified (fenced to a different task this cycle).

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// TestMCPRunForPoisonMatrix is the core proof: mcpRunFor must flag every
// poisoned 2xx body IsError:true with the reason text in the tool content, and
// must leave every honest outcome (including the honest empties) IsError:false.
func TestMCPRunForPoisonMatrix(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		body       string
		writes     bool
		wantErr    bool
		wantSubstr string // required substring in the tool content when wantErr
	}{
		// --- WRITE poison matrix (task.next/close/stamp/pulse shape) ---
		{
			name:       "write/error_envelope_on_2xx",
			status:     200,
			body:       `{"ok":false,"error":{"code":"boom"}}`,
			writes:     true,
			wantErr:    true,
			wantSubstr: "ERROR envelope",
		},
		{
			name:       "write/html_proxy_page",
			status:     200,
			body:       `<!doctype html><html><body>502 Bad Gateway</body></html>`,
			writes:     true,
			wantErr:    true,
			wantSubstr: "not JSON",
		},
		{
			name:       "write/result_null",
			status:     200,
			body:       `{"result":null}`,
			writes:     true,
			wantErr:    true,
			wantSubstr: "envelope was empty",
		},
		{
			name:       "write/bare_empty_object",
			status:     200,
			body:       `{}`,
			writes:     true,
			wantErr:    true,
			wantSubstr: "empty JSON object",
		},
		// --- WRITE honest outcomes: must stay clean ---
		{
			name:    "write/empty_queue_claim_is_not_an_error",
			status:  200,
			body:    `{"ok":false,"reason":"no_ready"}`,
			writes:  true,
			wantErr: false,
		},
		{
			name:    "write/normal_receipt",
			status:  200,
			body:    `{"ok":true,"doc":{"doc_id":"t1"}}`,
			writes:  true,
			wantErr: false,
		},
		{
			name:    "write/declared_no_content_204",
			status:  http.StatusNoContent,
			body:    ``,
			writes:  true,
			wantErr: false,
		},
		// --- READ poison matrix (task.ready/get/prime shape) ---
		{
			name:       "read/html_proxy_page",
			status:     200,
			body:       `<!doctype html><html><body>401 please sign in</body></html>`,
			writes:     false,
			wantErr:    true,
			wantSubstr: "HTML document",
		},
		{
			name:       "read/empty_body",
			status:     200,
			body:       ``,
			writes:     false,
			wantErr:    true,
			wantSubstr: "empty body",
		},
		{
			name:       "read/error_envelope_on_2xx",
			status:     200,
			body:       `{"ok":false,"error":{"code":"boom"}}`,
			writes:     false,
			wantErr:    true,
			wantSubstr: "ERROR envelope",
		},
		// --- READ honest empties: must stay clean ---
		{
			name:    "read/empty_object_from_counts",
			status:  200,
			body:    `{}`,
			writes:  false,
			wantErr: false,
		},
		{
			name:    "read/empty_array_from_list",
			status:  200,
			body:    `[]`,
			writes:  false,
			wantErr: false,
		},
		{
			name:    "read/ok_false_reason_no_ready",
			status:  200,
			body:    `{"ok":false,"reason":"no_ready"}`,
			writes:  false,
			wantErr: false,
		},
		// --- status >= 400 stays IsError regardless of poison-matrix logic ---
		{
			name:    "status_409_stays_error",
			status:  409,
			body:    `{"error":{"code":"doc_changed_since_claim"}}`,
			writes:  true,
			wantErr: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := mcpRunFor(tc.status, []byte(tc.body), nil, tc.writes)
			if res.IsError != tc.wantErr {
				t.Fatalf("IsError = %v, want %v; content = %q", res.IsError, tc.wantErr, mcpContentText(res))
			}
			if tc.wantErr && tc.wantSubstr != "" && !strings.Contains(mcpContentText(res), tc.wantSubstr) {
				t.Fatalf("content = %q, want it to contain %q", mcpContentText(res), tc.wantSubstr)
			}
		})
	}
}

// TestMCPRunForTransportErrorStillReports confirms a transport-level error
// (the request never reached the server) is unaffected by the poison-matrix
// change — it still surfaces as IsError regardless of writes.
func TestMCPRunForTransportErrorStillReports(t *testing.T) {
	for _, writes := range []bool{true, false} {
		res := mcpRunFor(0, nil, io.ErrClosedPipe, writes)
		if !res.IsError {
			t.Fatalf("writes=%v: transport error must be IsError; got %s", writes, mcpContentText(res))
		}
		if !strings.Contains(mcpContentText(res), "request failed") {
			t.Fatalf("writes=%v: content = %q, want it to name the transport failure", writes, mcpContentText(res))
		}
	}
}

// mcpReceiptHonestyManifest carries one write verb (task.next) and one read
// verb (task.get, mapped by task_show) — enough to drive registerTaskTools
// end-to-end and prove the poison-matrix fix actually reaches a real curated
// tool call, not just the mcpRunFor helper in isolation.
const mcpReceiptHonestyManifest = `{
  "manifest_version": "1",
  "server": {"name": "test", "version": "0", "base_url": "http://x"},
  "auth_tier": "admin",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {"id":"task.ready","noun":"task","verb":"ready","summary":"ready","http":{"method":"GET","path_template":"/v1/tasks/ready"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"task.prime","noun":"task","verb":"prime","summary":"prime","http":{"method":"GET","path_template":"/v1/tasks/prime"},"auth_tier":"read","args":[],"flags":[{"name":"worker","type":"string","summary":"w"},{"name":"limit","type":"int","summary":"l"}],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"json"},
    {"id":"task.get","noun":"task","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"task.next","noun":"task","verb":"next","summary":"next","http":{"method":"POST","path_template":"/v1/tasks/claim"},"auth_tier":"read","args":[{"name":"worker_id","required":true,"type":"string","summary":"w"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.close","noun":"task","verb":"close","summary":"close","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/close"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"},{"name":"observed_epoch","required":true,"type":"int","summary":"e"},{"name":"lifecycle_status","required":false,"type":"string","summary":"s"},{"name":"reason","required":false,"type":"string","summary":"r"}],"flags":[{"name":"set","repeatable":true,"type":"string","summary":"x"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.stamp","noun":"task","verb":"stamp","summary":"stamp","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/stamp"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"},{"name":"observed_epoch","required":true,"type":"int","summary":"e"}],"flags":[{"name":"criterion","type":"int","summary":"c"},{"name":"met","type":"bool","summary":"m"},{"name":"evidence","type":"string","summary":"ev"},{"name":"miss","type":"bool","summary":"x"},{"name":"note","type":"string","summary":"n"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.pulse","noun":"task","verb":"pulse","summary":"pulse","http":{"method":"POST","path_template":"/v1/tasks/:doc_id/pulse"},"auth_tier":"read","args":[{"name":"doc_id","required":true,"type":"string","summary":"id"},{"name":"worker_id","required":true,"type":"string","summary":"w"}],"flags":[{"name":"now","type":"string","summary":"t"},{"name":"criterion","type":"int","summary":"c"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"}
  ]
}`

// TestMCPTaskNextPoisonedSuccessIsError is the end-to-end proof: a real curated
// MCP tool (task_next, a WRITE) driven over an in-memory transport against a
// stub API that answers the claim with a 200 carrying an error envelope — the
// defect's own example. Before the fix this reached the model as
// IsError:false with the poisoned envelope presented as the claimed task.
func TestMCPTaskNextPoisonedSuccessIsError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		switch {
		case req.URL.Path == "/v1/tasks/claim":
			// Poisoned 2xx: a write whose body is the canonical failure envelope,
			// not an honest receipt.
			io.WriteString(rw, `{"ok":false,"error":{"code":"internal_error","message":"boom"}}`)
		case req.URL.Path == "/v1/tasks/t1":
			// Poisoned read: an HTML interstitial on a 200.
			io.WriteString(rw, `<!doctype html><html><body>Gateway Timeout</body></html>`)
		default:
			rw.WriteHeader(http.StatusNotFound)
			io.WriteString(rw, `{"error":{"code":"not_found"}}`)
		}
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpReceiptHonestyManifest))
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

	res, err := cs.CallTool(bg, &mcp.CallToolParams{Name: "task_next", Arguments: map[string]any{"worker_id": "w1"}})
	if err != nil {
		t.Fatalf("CallTool task_next: %v", err)
	}
	if !res.IsError {
		t.Fatalf("task_next over a 200 error envelope must be IsError; got content %q", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), "ERROR envelope") {
		t.Fatalf("task_next content = %q, want the ERROR-envelope reason named", mcpContentText(res))
	}

	res, err = cs.CallTool(bg, &mcp.CallToolParams{Name: "task_show", Arguments: map[string]any{"doc_id": "t1"}})
	if err != nil {
		t.Fatalf("CallTool task_show: %v", err)
	}
	if !res.IsError {
		t.Fatalf("task_show over a 200 HTML interstitial must be IsError; got content %q", mcpContentText(res))
	}
	if !strings.Contains(mcpContentText(res), "HTML document") {
		t.Fatalf("task_show content = %q, want the HTML-document reason named", mcpContentText(res))
	}
}
