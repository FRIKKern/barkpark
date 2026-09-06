package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpResourcesManifest carries the two doc verbs the paper-resource registration
// rides — doc.ls (the query endpoint, for enumeration) and doc.get (the read
// endpoint, for the shared read handler) — in the same HTTP shapes the live and
// docs/cli/fixtures manifests declare. doc.ls deliberately declares NO
// perspective flag (matching the real manifest), so the enumeration must not try
// to pass one; doc.get DOES, so a read asks for the published perspective.
const mcpResourcesManifest = `{
  "manifest_version": "1",
  "server": {"name": "test", "version": "0", "base_url": "http://x"},
  "auth_tier": "admin",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "doc", "summary": "docs"}],
  "commands": [
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"list","http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},"auth_tier":"read","args":[{"name":"type","required":true,"type":"string","summary":"t"}],"flags":[{"name":"limit","type":"int","default":50,"summary":"l"},{"name":"offset","type":"int","default":0,"summary":"o"},{"name":"all","type":"bool","default":false,"summary":"a"}],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"doc.get","noun":"doc","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},"auth_tier":"read","args":[{"name":"type","required":true,"type":"string","summary":"t"},{"name":"doc_id","required":true,"type":"string","summary":"i"}],"flags":[{"name":"perspective","type":"string","default":"published","summary":"p"}],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

// The body the paper-list (doc.ls) stub returns: two published papers in the
// LIVE query-endpoint shape — content fields rendered FLAT on the document, so
// "blocks" is top-level (verified against guerrilla). p1 has a level-1 heading
// (its title), p2 has none (title must fall back to its _id).
const mcpPaperListBody = `{"result":{"documents":[` +
	`{"_id":"p1","blocks":[{"type":"paragraph","text":"intro"},{"type":"heading","level":2,"text":"Not the title"},{"type":"heading","level":1,"text":"First Paper"}]},` +
	`{"_id":"p2","blocks":[{"type":"paragraph","text":"no heading here"}]}` +
	`],"count":2,"perspective":"published"}}`

// The body the doc.get stub returns for p1 — the read handler must round-trip
// this VERBATIM as the resource content (no re-render; charter decision 9).
const mcpPaperGetP1Body = `{"result":{"_id":"p1","_type":"paper","title":"First Paper","content":{"blocks":[{"type":"heading","level":1,"text":"First Paper"}],"body":{"html":"<h1>First Paper</h1>"}}}}`

// newMCPResourceTestServer stands in for a Barkpark API, routing the query
// (list) and doc (read) endpoints. An unknown paper id 404s so the read handler
// can map it to a resource-not-found error.
func newMCPResourceTestServer() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		switch {
		case req.URL.Path == "/v1/data/query/production/paper":
			io.WriteString(rw, mcpPaperListBody)
		case req.URL.Path == "/v1/data/doc/production/paper/p1":
			io.WriteString(rw, mcpPaperGetP1Body)
		default:
			// Unknown paper id (e.g. /v1/data/doc/production/paper/nope): 404.
			rw.WriteHeader(http.StatusNotFound)
			io.WriteString(rw, `{"error":{"code":"not_found"}}`)
		}
	}))
}

// connectResourceSession registers paper resources on a fresh server backed by
// ctx and drives an in-memory MCP client session against it. It returns the
// connected client session plus a cleanup func. out is the writer the
// registration warns through (stderr side); its stdout side is asserted empty by
// the caller to prove no stdout leakage from registration.
func connectResourceSession(t *testing.T, ctx manifest.Context, m *manifest.Manifest, out *writer) (*mcp.ClientSession, func()) {
	t.Helper()
	srv := mcp.NewServer(&mcp.Implementation{Name: "barkpark-tasks", Version: "test"}, nil)
	registerPaperResources(out, srv, globals{yes: true}, ctx, m)

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		ss.Close()
		t.Fatalf("client connect: %v", err)
	}
	return cs, func() { cs.Close(); ss.Close() }
}

// TestMCPPaperResourcesLiveOverInMemory is the primary proof: over a real
// in-memory MCP session (initialize -> resources/list -> resources/templates/list
// -> resources/read) backed by a stub Barkpark API, it asserts that
//   - resources/list carries the enumerated published papers, titled from the
//     first level-1 heading (or the _id when there is none),
//   - resources/templates/list carries the barkpark://papers/{id} template,
//   - a resources/read round-trips the backing doc.get body VERBATIM,
//   - an unknown id reads as an error (not a crash),
//
// all while bp's server code writes ZERO bytes to os.Stdout (the sacred JSON-RPC
// stream — a stray byte corrupts a real stdio transport).
func TestMCPPaperResourcesLiveOverInMemory(t *testing.T) {
	// Capture os.Stdout for the whole test: any stray write is a protocol bug.
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

	ts := newMCPResourceTestServer()
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpResourcesManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	ctx := manifest.Context{Server: ts.URL, Token: "tok", Dataset: "production"}

	// The writer registration warns through; its stdout side must stay empty.
	var regStdout, regStderr bytes.Buffer
	out := newWriter(&regStdout, &regStderr)

	cs, cleanup := connectResourceSession(t, ctx, m, out)
	bg := context.Background()

	// resources/list — exactly the two enumerated papers, titled correctly.
	lr, err := cs.ListResources(bg, nil)
	if err != nil {
		t.Fatalf("ListResources: %v", err)
	}
	byURI := map[string]*mcp.Resource{}
	for _, res := range lr.Resources {
		byURI[res.URI] = res
	}
	if len(byURI) != 2 {
		t.Fatalf("resources/list = %d resources, want 2: %+v", len(byURI), lr.Resources)
	}
	if p1 := byURI["barkpark://papers/p1"]; p1 == nil {
		t.Fatalf("resources/list missing barkpark://papers/p1: %+v", lr.Resources)
	} else {
		if p1.Title != "First Paper" {
			t.Errorf("p1 title = %q, want %q (first level-1 heading)", p1.Title, "First Paper")
		}
		if p1.MIMEType != "application/json" {
			t.Errorf("p1 MIMEType = %q, want application/json", p1.MIMEType)
		}
	}
	if p2 := byURI["barkpark://papers/p2"]; p2 == nil {
		t.Fatalf("resources/list missing barkpark://papers/p2: %+v", lr.Resources)
	} else if p2.Title != "p2" {
		t.Errorf("p2 title = %q, want %q (_id fallback — no level-1 heading)", p2.Title, "p2")
	}

	// resources/templates/list — the lazy-read template is present.
	tr, err := cs.ListResourceTemplates(bg, nil)
	if err != nil {
		t.Fatalf("ListResourceTemplates: %v", err)
	}
	foundTemplate := false
	for _, tmpl := range tr.ResourceTemplates {
		if tmpl.URITemplate == "barkpark://papers/{id}" {
			foundTemplate = true
			if tmpl.MIMEType != "application/json" {
				t.Errorf("template MIMEType = %q, want application/json", tmpl.MIMEType)
			}
		}
	}
	if !foundTemplate {
		t.Fatalf("resources/templates/list missing barkpark://papers/{id}: %+v", tr.ResourceTemplates)
	}

	// resources/read p1 — the backing doc.get body rides back VERBATIM.
	rr, err := cs.ReadResource(bg, &mcp.ReadResourceParams{URI: "barkpark://papers/p1"})
	if err != nil {
		t.Fatalf("ReadResource p1: %v", err)
	}
	if len(rr.Contents) != 1 {
		t.Fatalf("ReadResource p1 returned %d contents, want 1", len(rr.Contents))
	}
	c0 := rr.Contents[0]
	if c0.Text != mcpPaperGetP1Body {
		t.Errorf("ReadResource p1 body not verbatim:\n got: %q\nwant: %q", c0.Text, mcpPaperGetP1Body)
	}
	if c0.MIMEType != "application/json" {
		t.Errorf("ReadResource p1 MIMEType = %q, want application/json", c0.MIMEType)
	}
	if c0.URI != "barkpark://papers/p1" {
		t.Errorf("ReadResource p1 content URI = %q, want the requested URI", c0.URI)
	}

	// resources/read of an unknown id (matches the template, doc.get 404s) — an
	// error, not a crash. The SDK surfaces the ResourceNotFoundError to the client.
	if _, err := cs.ReadResource(bg, &mcp.ReadResourceParams{URI: "barkpark://papers/nope"}); err == nil {
		t.Fatalf("ReadResource of unknown id must error, got nil")
	}

	// Tear down, then assert zero stdout leakage — both the writer's stdout side
	// and the real os.Stdout the seam could accidentally touch.
	cleanup()
	if regStdout.Len() != 0 {
		t.Fatalf("registration wrote %d bytes to its stdout writer: %q", regStdout.Len(), regStdout.String())
	}
	w.Close()
	restore()
	buf := <-stdoutCh
	if len(buf) != 0 {
		t.Fatalf("bp MCP code wrote %d bytes to os.Stdout (corrupts a real stdio stream): %q", len(buf), buf)
	}
}

// TestMCPPaperResourcesUnreachableAPIDegradesTemplateOnly proves the load-bearing
// best-effort contract: when the API is unreachable at startup (the smoke gate's
// BARKPARK_API_URL=http://127.0.0.1:0 shape), enumeration fails, the server STILL
// comes up, resources/list is empty, and the read template is still registered so
// papers remain readable by id. It also asserts the failure warns on stderr and
// leaks nothing to stdout.
func TestMCPPaperResourcesUnreachableAPIDegradesTemplateOnly(t *testing.T) {
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

	m, err := manifest.Parse([]byte(mcpResourcesManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	// A dead target: port 0 refuses instantly, so enumeration fails fast.
	ctx := manifest.Context{Server: "http://127.0.0.1:0", Token: "tok", Dataset: "production"}

	var regStdout, regStderr bytes.Buffer
	out := newWriter(&regStdout, &regStderr)

	cs, cleanup := connectResourceSession(t, ctx, m, out)
	bg := context.Background()

	// resources/list is empty (enumeration failed) — but the server is alive.
	lr, err := cs.ListResources(bg, nil)
	if err != nil {
		t.Fatalf("ListResources: %v", err)
	}
	if len(lr.Resources) != 0 {
		t.Fatalf("unreachable-API resources/list should be empty, got %d: %+v", len(lr.Resources), lr.Resources)
	}

	// The read template survives — papers still read by id (best-effort degrade).
	tr, err := cs.ListResourceTemplates(bg, nil)
	if err != nil {
		t.Fatalf("ListResourceTemplates: %v", err)
	}
	foundTemplate := false
	for _, tmpl := range tr.ResourceTemplates {
		if tmpl.URITemplate == "barkpark://papers/{id}" {
			foundTemplate = true
		}
	}
	if !foundTemplate {
		t.Fatalf("template must survive an unreachable API: %+v", tr.ResourceTemplates)
	}

	// The degrade was announced on stderr (never stdout).
	if !strings.Contains(regStderr.String(), "template-only") {
		t.Errorf("expected a stderr warning about template-only degrade, got: %q", regStderr.String())
	}

	cleanup()
	if regStdout.Len() != 0 {
		t.Fatalf("registration wrote %d bytes to its stdout writer: %q", regStdout.Len(), regStdout.String())
	}
	w.Close()
	restore()
	buf := <-stdoutCh
	if len(buf) != 0 {
		t.Fatalf("bp MCP code wrote %d bytes to os.Stdout: %q", len(buf), buf)
	}
}

// TestPaperTitleFromBlocks unit-tests the title-derivation rule in isolation:
// first level-1 heading wins; absent that, the _id.
func TestPaperTitleFromBlocks(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"top-level blocks (live rendered shape) wins", `{"_id":"p1","blocks":[{"type":"heading","level":2,"text":"sub"},{"type":"heading","level":1,"text":"Title"}]}`, "Title"},
		{"content-nested blocks also read", `{"_id":"p2","content":{"blocks":[{"type":"heading","level":1,"text":"Nested Title"}]}}`, "Nested Title"},
		{"no heading falls back to id", `{"_id":"p9","blocks":[{"type":"paragraph","text":"x"}]}`, "p9"},
		{"empty heading text falls back to id", `{"_id":"p7","blocks":[{"type":"heading","level":1,"text":"   "}]}`, "p7"},
		{"null blocks falls back to id", `{"_id":"p6","blocks":null}`, "p6"},
		{"no blocks at all falls back to id", `{"_id":"p5"}`, "p5"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var doc paperDocShape
			if err := json.Unmarshal([]byte(c.body), &doc); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if got := paperTitle(doc); got != c.want {
				t.Errorf("paperTitle = %q, want %q", got, c.want)
			}
		})
	}
}

// TestParsePaperListSkipsMalformed proves parsePaperList is best-effort over the
// document array: an idless or malformed document is skipped, the rest survive.
func TestParsePaperListSkipsMalformed(t *testing.T) {
	body := `{"result":{"documents":[` +
		`{"_id":"good1","content":{"blocks":[{"type":"heading","level":1,"text":"Good One"}]}},` +
		`{"content":{"blocks":[]}},` + // no _id → skipped
		`{"_id":"good2","content":{"blocks":[]}}` +
		`]}}`
	papers, err := parsePaperList([]byte(body))
	if err != nil {
		t.Fatalf("parsePaperList: %v", err)
	}
	if len(papers) != 2 {
		t.Fatalf("parsePaperList = %d papers, want 2 (idless skipped): %+v", len(papers), papers)
	}
	if papers[0].ID != "good1" || papers[0].Title != "Good One" {
		t.Errorf("papers[0] = %+v, want {good1 Good One}", papers[0])
	}
	if papers[1].ID != "good2" || papers[1].Title != "good2" {
		t.Errorf("papers[1] = %+v, want {good2 good2}", papers[1])
	}
}

// TestPaperIDFromURI covers the URI → id extraction for both concrete and
// template reads (the SDK hands the handler the full concrete URI in both).
func TestPaperIDFromURI(t *testing.T) {
	cases := map[string]string{
		"barkpark://papers/p1":       "p1",
		"barkpark://papers/my-slug":  "my-slug",
		"barkpark://papers/":         "",
		"barkpark://other/p1":        "",
		"https://example.com/p1":     "",
		"":                           "",
		"barkpark://papers/p1/extra": "p1/extra",
	}
	for uri, want := range cases {
		if got := paperIDFromURI(uri); got != want {
			t.Errorf("paperIDFromURI(%q) = %q, want %q", uri, got, want)
		}
	}
}
