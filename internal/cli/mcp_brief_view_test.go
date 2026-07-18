package cli

// mcp_brief_view_test.go — guards for the AXI brief-view consumption seams
// (axi-s3-cli-brief-consume): the mcpRun last-resort byte clamp (R4) and the
// generic manifest-declared view inheritance the bridge rides (R1).

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpRun must clamp an oversized payload with an AXI truncation notice naming
// the byte total and the escape command — and pass small payloads through
// byte-identical (the passthrough half of the R4 criterion).
func TestMCPRunClampsOversizedPayload(t *testing.T) {
	big := []byte(`{"docs":["` + strings.Repeat("a", 100<<10) + `"]}`)

	res := mcpRun(200, big, nil)
	if res.IsError {
		t.Fatal("a clamped 200 must not be IsError")
	}
	text := mcpContentText(res)
	if len(text) >= len(big) {
		t.Fatalf("oversized payload was not clamped: %d bytes out of %d in", len(text), len(big))
	}
	// The notice's constant overhead is small; the clamp must land near the cap.
	if len(text) > mcpToolResultMaxBytes+256 {
		t.Fatalf("clamped result is %d bytes, want <= cap %d + notice", len(text), mcpToolResultMaxBytes)
	}
	wantTotal := fmt.Sprintf("%d bytes total", len(big))
	if !strings.Contains(text, wantTotal) {
		t.Fatalf("truncation notice must name the byte total %q; tail = %q", wantTotal, text[len(text)-200:])
	}
	if !strings.Contains(text, "task_show") {
		t.Fatalf("truncation notice must name the escape command; tail = %q", text[len(text)-200:])
	}

	// Small payloads pass through untouched — the guard is last-resort, not a tax.
	small := []byte(`{"ok":true,"doc":{"doc_id":"t1"}}`)
	if got := mcpContentText(mcpRun(200, small, nil)); got != string(small) {
		t.Fatalf("small payload was altered: %q", got)
	}

	// An oversized ERROR body clamps too, and stays IsError.
	if res := mcpRun(500, big, nil); !res.IsError || len(mcpContentText(res)) >= len(big) {
		t.Fatalf("oversized error body must clamp and keep IsError; IsError=%v len=%d", res.IsError, len(mcpContentText(res)))
	}
}

// The clamp must cut on a rune boundary — a multi-byte rune straddling the cap
// is walked back, never split into invalid UTF-8.
func TestClampMCPToolResultRuneBoundary(t *testing.T) {
	// Fill to exactly the cap minus 1 byte, then place a 3-byte rune across it.
	s := strings.Repeat("a", mcpToolResultMaxBytes-1) + "€€€"
	got := clampMCPToolResult(s)
	cutBody := got[:strings.Index(got, "\n[truncated")]
	if strings.ContainsRune(cutBody, '�') || !strings.HasSuffix(cutBody, "a") {
		t.Fatalf("clamp split a rune: body tail = %q", cutBody[len(cutBody)-8:])
	}
}

// agentViewGlobals is the ONE generic inheritance seam: a command declaring
// views.default_for_agents flips g.view; one without passes through untouched;
// --full always wins.
func TestAgentViewGlobals(t *testing.T) {
	withViews := manifest.Command{Views: &manifest.Views{
		Supported: []string{"brief", "full"}, Default: "full", DefaultForAgents: "brief",
	}}
	if g := agentViewGlobals(globals{}, withViews); g.view != "brief" {
		t.Fatalf("views-declaring command: g.view = %q, want brief", g.view)
	}
	if g := agentViewGlobals(globals{}, manifest.Command{}); g.view != "" {
		t.Fatalf("views-less command: g.view = %q, want empty", g.view)
	}
	if g := agentViewGlobals(globals{full: true}, withViews); g.view != "" {
		t.Fatalf("--full must win over the agent default; g.view = %q", g.view)
	}
}

// The bridge inherits brief views generically from the manifest: a command
// declaring views.default_for_agents sends ?view=<it>, a command without a
// views declaration sends NO view param — with zero per-tool code in the
// bridge (the whole point of the manifest-first law).
func TestBridgeInheritsAgentDefaultView(t *testing.T) {
	queries := map[string]string{}
	hadView := map[string]bool{}
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		queries[req.URL.Path] = req.URL.Query().Get("view")
		_, hadView[req.URL.Path] = req.URL.Query()["view"]
		_, _ = rw.Write([]byte(`{"ok":true}`))
	}))
	defer ts.Close()

	const briefManifest = `{
	  "manifest_version":"1",
	  "server":{"name":"t","version":"0","base_url":"http://x"},
	  "auth_tier":"admin","generated_at":"n","etag":"e",
	  "nouns":[{"name":"task","summary":"tasks"}],
	  "commands":[
	    {"id":"task.ls","noun":"task","verb":"ls","summary":"list","http":{"method":"GET","path_template":"/v1/tasks/ls"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table","views":{"supported":["brief","full"],"default":"full","default_for_agents":"brief"}},
	    {"id":"task.claim","noun":"task","verb":"claim","summary":"claim","http":{"method":"POST","path_template":"/v1/tasks/plain"},"auth_tier":"read","args":[],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"}
	  ]
	}`
	m, err := manifest.Parse([]byte(briefManifest))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	cs := newBridgeSession(t, globals{yes: true}, manifest.Context{Server: ts.URL}, m)
	bg := context.Background()

	if _, err := cs.CallTool(bg, &mcp.CallToolParams{Name: "bp_task_ls", Arguments: map[string]any{}}); err != nil {
		t.Fatalf("CallTool bp_task_ls: %v", err)
	}
	if queries["/v1/tasks/ls"] != "brief" {
		t.Fatalf("views-declaring bridge tool sent view=%q, want brief", queries["/v1/tasks/ls"])
	}

	if _, err := cs.CallTool(bg, &mcp.CallToolParams{Name: "bp_task_claim", Arguments: map[string]any{}}); err != nil {
		t.Fatalf("CallTool bp_task_claim: %v", err)
	}
	if hadView["/v1/tasks/plain"] {
		t.Fatalf("views-less bridge tool sent a view param (%q); want none", queries["/v1/tasks/plain"])
	}
}
