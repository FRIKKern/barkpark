package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp schema delete <name>` on a type that still has documents is refused with
// `schema_has_documents` and told to "pass ?force=true" — a param bp could not
// send, because the manifest declared no flag (stranger walk, 2026-10-01). The
// manifest now declares `force` as a bool; this pins that `--force` reaches the
// server as `?force=true` and that the plain delete sends no force at all.

const schemaDeleteManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "auth_tier": "admin",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "schema", "summary": "Schemas."}],
  "commands": [
    {"id":"schema.delete","noun":"schema","verb":"delete","summary":"Delete a content-type schema by name.",
     "http":{"method":"DELETE","path_template":"/v1/schemas/:dataset/:name"},
     "auth_tier":"admin",
     "args":[{"name":"name","required":true,"type":"string","summary":"Schema/type name to delete."}],
     "flags":[{"name":"force","type":"bool","summary":"Delete the schema even though documents of this type exist."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal"}
  ]
}`

func runSchemaDelete(t *testing.T, extra ...string) (string, int) {
	t.Helper()
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"deleted":"r2dReq"}`))
	}))
	defer srv.Close()
	m, err := manifest.Parse([]byte(strings.Replace(schemaDeleteManifestJSON, "http://replaced", srv.URL, 1)))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	cmd, ok := m.Tree().Lookup("schema", "delete")
	if !ok {
		t.Fatal("fixture has no schema delete")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	ctx := manifest.Context{Server: srv.URL, Token: "tok", Dataset: "production"}
	code := runCommand(w, g, ctx, m, *cmd, append([]string{"r2dReq"}, extra...))
	return gotQuery, code
}

func TestSchemaDeleteForceReachesTheServer(t *testing.T) {
	q, code := runSchemaDelete(t, "--force")
	if code != exitOK {
		t.Fatalf("exit %d", code)
	}
	if q != "force=true" {
		t.Errorf("query = %q, want force=true", q)
	}
}

func TestSchemaDeleteWithoutForceSendsNone(t *testing.T) {
	q, _ := runSchemaDelete(t)
	if strings.Contains(q, "force") {
		t.Errorf("a plain delete must not send force, got query %q", q)
	}
}
