package cli

// mcp_http_local_file_test.go — the FILESYSTEM half of the remote boundary of
// `bp mcp serve --http` (r2-lane-b Go secret-exposure audit, 2026-10-01).
//
// newMCPHTTPHandler withdraws the serving process's ambient CREDENTIALS from a
// remote caller (mcp_http_ingest_test.go). The bridge still handed a caller's
// `file` flag and file-typed args to the headless dispatcher, which reads them
// with os.ReadFile / os.Open on the SERVING host — so a remote caller with any
// write token could post a host file (an env file, the operator's config.json)
// as a document body or a media upload and read it back. The fixture below
// plays that file; its content must never reach the backend.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const mcpLocalFileManifest = `{
  "manifest_version": "1",
  "server": {"name": "test", "version": "0", "base_url": "http://x"},
  "auth_tier": "admin",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "doc", "summary": "docs"}, {"name": "media", "summary": "media"}],
  "commands": [
    {"id":"doc.create","noun":"doc","verb":"create","summary":"create","http":{"method":"POST","path_template":"/v1/data/create/:dataset/:type"},"auth_tier":"write","args":[{"name":"type","required":true,"type":"string","summary":"t"}],"flags":[{"name":"file","type":"string","summary":"body file"}],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"json"},
    {"id":"media.upload","noun":"media","verb":"upload","summary":"upload","http":{"method":"POST","path_template":"/media/upload"},"auth_tier":"write","args":[{"name":"path","required":true,"type":"file","summary":"file"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"json"},
    {"id":"doc.get","noun":"doc","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},"auth_tier":"read","args":[{"name":"type","required":true,"type":"string","summary":"t"},{"name":"doc_id","required":true,"type":"string","summary":"i"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

// An invented credential-shaped string standing in for a host file's content.
const mcpHostFileSecret = `{"cloud_token":"bpc_HOST_FILE_FIXTURE_NEVER_SENT"}`

type mcpBodyBackend struct {
	mu     sync.Mutex
	bodies []string
}

func (b *mcpBodyBackend) handler() http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		b.mu.Lock()
		b.bodies = append(b.bodies, string(body))
		b.mu.Unlock()
		io.WriteString(rw, `{"ok":true}`)
	})
}

func (b *mcpBodyBackend) sawSecret() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, s := range b.bodies {
		if strings.Contains(s, "bpc_HOST_FILE_FIXTURE_NEVER_SENT") {
			return true
		}
	}
	return false
}

func newMCPLocalFileStack(t *testing.T) (*mcpBodyBackend, string, string) {
	t.Helper()
	dir := t.TempDir()
	hostFile := filepath.Join(dir, "config.json")
	if err := os.WriteFile(hostFile, []byte(mcpHostFileSecret), 0o600); err != nil {
		t.Fatal(err)
	}

	backend := &mcpBodyBackend{}
	api := httptest.NewServer(backend.handler())
	t.Cleanup(api.Close)

	m, err := manifest.Parse([]byte(mcpLocalFileManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	base := manifest.Context{Server: api.URL, Dataset: "production", AmbientCredentialsOK: true}
	handler, err := newMCPHTTPHandler(newWriter(io.Discard, io.Discard), globals{yes: true}, base, m, "all", nil)
	if err != nil {
		t.Fatalf("newMCPHTTPHandler: %v", err)
	}
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)
	return backend, front.URL, hostFile
}

func TestMCPHTTPRefusesHostFileAsDocumentBody(t *testing.T) {
	backend, endpoint, hostFile := newMCPLocalFileStack(t)
	cs := connectMCPHTTPClient(t, endpoint, "fixture-write-token")

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "bp_doc_create",
		Arguments: map[string]any{"type": "post", "file": hostFile},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if backend.sawSecret() {
		t.Fatalf("a remote MCP caller read a host file into a document body")
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected a refusal naming the file argument, got %+v", res)
	}
}

func TestMCPHTTPRefusesHostFileAsMediaUpload(t *testing.T) {
	backend, endpoint, hostFile := newMCPLocalFileStack(t)
	cs := connectMCPHTTPClient(t, endpoint, "fixture-write-token")

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "bp_media_upload",
		Arguments: map[string]any{"path": hostFile},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if backend.sawSecret() {
		t.Fatalf("a remote MCP caller uploaded a host file")
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected a refusal naming the file argument, got %+v", res)
	}
}

// The operator-local surface keeps local paths: the boundary is the remote
// transport, not the bridge.
func TestRefuseRemoteLocalFileKeepsOperatorLocalPaths(t *testing.T) {
	m, err := manifest.Parse([]byte(mcpLocalFileManifest))
	if err != nil {
		t.Fatal(err)
	}
	var create manifest.Command
	for _, c := range m.Commands {
		if c.ID == "doc.create" {
			create = c
		}
	}
	args := map[string]any{"type": "post", "file": "/tmp/x.json"}
	if err := refuseRemoteLocalFile(manifest.Context{AmbientCredentialsOK: true}, create, args); err != nil {
		t.Fatalf("operator-local context refused a local path: %v", err)
	}
	if err := refuseRemoteLocalFile(manifest.Context{}, create, args); err == nil {
		t.Fatalf("remote context accepted a local path")
	}
	if err := refuseRemoteLocalFile(manifest.Context{}, create, map[string]any{"type": "post"}); err != nil {
		t.Fatalf("remote context refused a call that names no file: %v", err)
	}
}
