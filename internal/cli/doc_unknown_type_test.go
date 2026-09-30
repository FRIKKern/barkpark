package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// doc_unknown_type_test.go pins the stranger-walk note (2026-09-30): an EMPTY
// `doc ls`/`doc query` page, or a `doc create`, for a type no schema declares
// says so on stderr; a declared type, a non-empty page, or a tier without
// `schema get` adds nothing; the exit code never moves.

const unknownTypeManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "auth_tier": "admin",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}, {"name": "schema", "summary": "Schemas."}],
  "commands": [
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"List documents of a type.",
     "http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"doc.create","noun":"doc","verb":"create","summary":"Create a document.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[{"name":"set","type":"string","summary":"Field."}],"writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","mutation_op":"create"},
    SCHEMA_GET
  ]
}`

const schemaGetCmd = `{"id":"schema.get","noun":"schema","verb":"get","summary":"Fetch one schema.",
     "http":{"method":"GET","path_template":"/v1/schemas/:dataset/:name"},
     "auth_tier":"admin",
     "args":[{"name":"name","required":true,"type":"string","summary":"Schema name."}],
     "flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"json"}`

func unknownTypeHarness(t *testing.T, withSchemaGet bool, listBody string) (*manifest.Manifest, manifest.Context) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/schemas/"):
			if strings.HasSuffix(r.URL.Path, "/post") {
				_, _ = w.Write([]byte(`{"schema":{"name":"post"}}`))
				return
			}
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"schema not found"}}`))
		case strings.HasPrefix(r.URL.Path, "/v1/data/query/"):
			_, _ = w.Write([]byte(listBody))
		default: // mutate
			_, _ = w.Write([]byte(`{"results":[{"id":"drafts.x-1","operation":"create","document":{"_id":"drafts.x-1","_rev":"r1"}}],"transactionId":"t"}`))
		}
	}))
	t.Cleanup(srv.Close)
	body := strings.Replace(unknownTypeManifestJSON, "http://replaced", srv.URL, 1)
	sg := ""
	if withSchemaGet {
		sg = schemaGetCmd
	}
	body = strings.Replace(body, ",\n    SCHEMA_GET", map[bool]string{true: ",\n    " + sg, false: ""}[withSchemaGet], 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	return m, manifest.Context{Server: srv.URL, Token: "tok", Workspace: "default", Project: "default", Dataset: "production"}
}

func runDoc(t *testing.T, m *manifest.Manifest, ctx manifest.Context, verb string, tail ...string) (int, string) {
	t.Helper()
	cmd, ok := m.Tree().Lookup("doc", verb)
	if !ok {
		t.Fatalf("fixture has no doc %s", verb)
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	return runCommand(w, g, ctx, m, *cmd, tail), se.String()
}

const emptyList = `{"count":0,"documents":[],"hasMore":false,"limit":100,"offset":0}`

func TestEmptyListOfAnUndeclaredTypeSaysSo(t *testing.T) {
	m, ctx := unknownTypeHarness(t, true, emptyList)
	code, stderr := runDoc(t, m, ctx, "ls", "Post")
	if code != exitOK {
		t.Fatalf("exit %d, want 0 (the note must not change it)", code)
	}
	if !strings.Contains(stderr, `no schema named "Post" exists in dataset "production"`) {
		t.Fatalf("an empty page of an undeclared type must say no schema of that name exists:\n%s", stderr)
	}
}

func TestCreateOfAnUndeclaredTypeSaysSo(t *testing.T) {
	m, ctx := unknownTypeHarness(t, true, emptyList)
	_, stderr := runDoc(t, m, ctx, "create", "psot", "--set", "title=x")
	if !strings.Contains(stderr, `no schema named "psot"`) || !strings.Contains(stderr, "stored anyway") {
		t.Fatalf("a create of an undeclared type must say the doc was stored under a type no schema describes:\n%s", stderr)
	}
}

func TestDeclaredOrPopulatedOrTierlessAddsNothing(t *testing.T) {
	m, ctx := unknownTypeHarness(t, true, emptyList)
	if _, stderr := runDoc(t, m, ctx, "ls", "post"); strings.Contains(stderr, "no schema named") {
		t.Errorf("a declared type with an empty page must not be called unknown:\n%s", stderr)
	}
	m2, ctx2 := unknownTypeHarness(t, true, `{"count":1,"documents":[{"_id":"a"}],"hasMore":false,"limit":100,"offset":0}`)
	if _, stderr := runDoc(t, m2, ctx2, "ls", "whatever"); strings.Contains(stderr, "no schema named") {
		t.Errorf("a page WITH rows proves the type is in use:\n%s", stderr)
	}
	m3, ctx3 := unknownTypeHarness(t, false, emptyList)
	if _, stderr := runDoc(t, m3, ctx3, "ls", "Post"); strings.Contains(stderr, "no schema named") {
		t.Errorf("without schema get at this tier the check must be skipped, not guessed:\n%s", stderr)
	}
}
