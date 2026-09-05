package cli

// mcp_write_fence_test.go — pds-bl-mcp-exec-bypasses-write-fence.
//
// Two proofs, one fence:
//
//  1. END-TO-END (c2/c4): `task_stamp` — the verb the row names — driven over a
//     REAL MCP client/server transport against a store that answers 200 and
//     writes NOTHING. The tool must come back IsError. This drives the actual
//     registered handler (mcp_tasks.go:722 -> execManifestCommand -> mcpRunFor),
//     never runTaskStamp.
//  2. SHARED SEAM (c5): the CLI render path and the MCP tool result must return
//     the SAME verdict for the same response, over the whole write poison matrix
//     AND the honest bodies — because both read writeReceiptVerdict (run.go) and
//     neither owns a copy. Delete or rename that function and BOTH callers fail
//     to compile, which is what makes the sharing structural rather than a
//     convention.

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// writeFencePoison is the matrix of 2xx bodies that say NOTHING about a write —
// exactly the set unreadableWriteReceipt already names, plus the status-arm case
// (an UNDECLARED empty 200) the 204/205 exemption must not swallow.
var writeFencePoison = []struct {
	name   string
	status int
	body   string
	want   string // required substring of the reason
}{
	{"empty_object", 200, `{}`, "empty JSON object"},
	{"json_null", 200, `null`, "JSON literal null"},
	{"result_null", 200, `{"result":null}`, "envelope was empty"},
	{"empty_array", 200, `[]`, "empty JSON array"},
	{"undeclared_empty_200", 200, ``, "without declaring one"},
	{"html_proxy_page", 200, `<!doctype html><html>502</html>`, "not JSON"},
	{"error_envelope_on_2xx", 200, `{"ok":false,"error":{"code":"boom"}}`, "ERROR envelope"},
}

// writeFenceHonest is the counterweight: bodies that MUST stay success, so the
// proof cannot be satisfied by a fence that simply refuses everything.
var writeFenceHonest = []struct {
	name   string
	status int
	body   string
}{
	{"normal_receipt", 200, `{"ok":true,"doc":{"doc_id":"t1"}}`},
	{"unknown_keys_still_pass", 200, `{"whatever":{"nested":1}}`},
	{"declared_no_content_204", http.StatusNoContent, ``},
	{"declared_no_content_205", http.StatusResetContent, ``},
}

// TestMCPTaskStampPoisonedWriteIsError is the c4 proof, end-to-end through the
// real MCP dispatch: an MCP-issued task stamp against a store that answers 200
// and writes nothing must not report success.
func TestMCPTaskStampPoisonedWriteIsError(t *testing.T) {
	for _, tc := range writeFencePoison {
		t.Run(tc.name, func(t *testing.T) {
			cs, stop := mcpWriteFenceClient(t, "/v1/tasks/t1/stamp", tc.status, tc.body)
			defer stop()
			res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
				Name: "task_stamp",
				Arguments: map[string]any{
					"doc_id": "t1", "worker_id": "w1", "observed_epoch": 1,
					"criterion": 0, "met": true, "evidence": "e",
				},
			})
			if err != nil {
				t.Fatalf("CallTool task_stamp: %v", err)
			}
			if !res.IsError {
				t.Fatalf("HTTP %d body %q: task_stamp reported SUCCESS to the model; content = %q",
					tc.status, tc.body, mcpContentText(res))
			}
			if !strings.Contains(mcpContentText(res), tc.want) {
				t.Fatalf("content = %q, want it to name %q", mcpContentText(res), tc.want)
			}
		})
	}
}

// TestMCPTaskStampHonestWriteStaysSuccess is the non-vacuity half: the same
// end-to-end path must still hand an honest receipt back as a success, so the
// test above is not passing because everything is refused.
func TestMCPTaskStampHonestWriteStaysSuccess(t *testing.T) {
	for _, tc := range writeFenceHonest {
		t.Run(tc.name, func(t *testing.T) {
			cs, stop := mcpWriteFenceClient(t, "/v1/tasks/t1/stamp", tc.status, tc.body)
			defer stop()
			res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
				Name: "task_stamp",
				Arguments: map[string]any{
					"doc_id": "t1", "worker_id": "w1", "observed_epoch": 1,
					"criterion": 0, "met": true, "evidence": "e",
				},
			})
			if err != nil {
				t.Fatalf("CallTool task_stamp: %v", err)
			}
			if res.IsError {
				t.Fatalf("HTTP %d body %q: honest receipt refused; content = %q",
					tc.status, tc.body, mcpContentText(res))
			}
		})
	}
}

// TestWriteFenceIsShared is the c5 proof: for every response in both matrices the
// CLI render path (screenWriteReceipt) and the MCP tool result (mcpRunFor) must
// AGREE — refuse together or pass together — because both read the one
// writeReceiptVerdict. A copy of the fence in either caller shows up here as a
// disagreement the moment the two drift.
func TestWriteFenceIsShared(t *testing.T) {
	cmd := manifest.Command{ID: "task.stamp", Writes: true}

	check := func(t *testing.T, status int, body string, wantRefused bool, wantReason string) {
		t.Helper()

		// The seam itself.
		kind, reason, _ := writeReceiptVerdict(status, []byte(body))
		if (kind == writeReceiptPoisoned) != wantRefused {
			t.Fatalf("writeReceiptVerdict kind = %v, want poisoned = %v", kind, wantRefused)
		}
		if wantRefused && !strings.Contains(reason, wantReason) {
			t.Fatalf("writeReceiptVerdict reason = %q, want %q", reason, wantReason)
		}

		// Caller 1 — the human CLI.
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		code, handled := screenWriteReceipt(w, cmd, status, []byte(body))
		cliRefused := handled && code != exitOK

		// Caller 2 — the MCP tool result.
		mcpRefused := mcpRunFor(status, []byte(body), nil, true).IsError

		if cliRefused != mcpRefused {
			t.Fatalf("HTTP %d body %q: CLI refused = %v but MCP refused = %v — the fence is NOT shared",
				status, body, cliRefused, mcpRefused)
		}
		if cliRefused != wantRefused {
			t.Fatalf("HTTP %d body %q: both callers said refused = %v, want %v",
				status, body, cliRefused, wantRefused)
		}
	}

	for _, tc := range writeFencePoison {
		t.Run("poison/"+tc.name, func(t *testing.T) { check(t, tc.status, tc.body, true, tc.want) })
	}
	for _, tc := range writeFenceHonest {
		t.Run("honest/"+tc.name, func(t *testing.T) { check(t, tc.status, tc.body, false, "") })
	}
}

// mcpWriteFenceClient stands up an httptest store that answers ONE path with a
// fixed status+body (and 404s everything else), registers the real curated task
// tools against it over an in-memory MCP transport, and returns the connected
// client session plus its teardown.
func mcpWriteFenceClient(t *testing.T, path string, status int, body string) (*mcp.ClientSession, func()) {
	t.Helper()

	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if req.URL.Path != path {
			rw.WriteHeader(http.StatusNotFound)
			io.WriteString(rw, `{"error":{"code":"not_found"}}`)
			return
		}
		// The poisoned store: it answers, it writes NOTHING, and it says 2xx.
		if status != http.StatusOK {
			rw.WriteHeader(status)
		}
		io.WriteString(rw, body)
	}))

	m, err := manifest.Parse([]byte(mcpReceiptHonestyManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	srv := mcp.NewServer(&mcp.Implementation{Name: "barkpark-tasks", Version: "test"}, nil)
	if err := registerTaskTools(srv, globals{yes: true}, manifest.Context{Server: ts.URL, Token: "tok"}, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	return cs, func() {
		cs.Close()
		ss.Close()
		ts.Close()
	}
}
