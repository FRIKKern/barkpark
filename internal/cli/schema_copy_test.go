package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// schemaFakeServer adds the schema routes to an importFakeServer: the list
// with a schemaHash per schema, and the upsert. It records the order of the
// writes it gets, so a test can tell the schemas went before the documents.
type schemaFakeServer struct {
	*importFakeServer
	srv *httptest.Server

	mu       sync.Mutex
	schemas  map[string]map[string]any
	order    []string // "schema:<name>" or "mutate", per write
	throttle int      // answer this many schema writes with 429 first
	missing  bool     // every schema route answers 404, as for a missing workspace
}

func newSchemaFakeServer(t *testing.T) *schemaFakeServer {
	t.Helper()
	s := &schemaFakeServer{importFakeServer: newImportFakeServer(t), schemas: map[string]map[string]any{}}
	s.srv = httptest.NewServer(http.HandlerFunc(s.handle))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *schemaFakeServer) ctx() manifest.Context {
	return manifest.Context{Server: s.srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}
}

func (s *schemaFakeServer) handle(w http.ResponseWriter, r *http.Request) {
	const route = "/w/ws/p/proj/v1/schemas/production"
	switch {
	case r.URL.Path == route && s.missing:
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": "not_found", "message": "workspace not found"}})
	case r.Method == http.MethodGet && r.URL.Path == route:
		s.mu.Lock()
		list := []map[string]any{}
		for name, def := range s.schemas {
			out := map[string]any{"schemaHash": "hash-of-" + name}
			for k, v := range def {
				out[k] = v
			}
			list = append(list, out)
		}
		s.mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"schemas": list, "datasetSchemaHash": "dataset-hash", "_schemaVersion": 1})
	case r.Method == http.MethodPost && r.URL.Path == route:
		s.mu.Lock()
		if s.throttle > 0 {
			s.throttle--
			s.mu.Unlock()
			w.Header().Set("Retry-After", "2")
			w.WriteHeader(http.StatusTooManyRequests)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": "rate_limited", "message": "slow down"}})
			return
		}
		s.mu.Unlock()
		body, _ := io.ReadAll(r.Body)
		var def map[string]any
		if err := json.Unmarshal(body, &def); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		name, _ := def["name"].(string)
		s.mu.Lock()
		s.schemas[name] = def
		s.order = append(s.order, "schema:"+name)
		s.mu.Unlock()
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(def)
	case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/w/ws/p/proj/v1/data/mutate/"):
		s.mu.Lock()
		s.order = append(s.order, "mutate")
		s.mu.Unlock()
		s.importFakeServer.handle(w, r)
	default:
		s.importFakeServer.handle(w, r)
	}
}

// schemaCopySource is a source with two schemas and two documents, exported
// with --schemas into a temp dir.
func schemaCopySource(t *testing.T) (backup, schemasPath string) {
	t.Helper()
	src := newSchemaFakeServer(t)
	src.schemas["post"] = map[string]any{"name": "post", "title": "Post", "fields": []any{map[string]any{"name": "title", "type": "string"}}}
	src.schemas["author"] = map[string]any{"name": "author", "title": "Author", "fields": []any{map[string]any{"name": "name", "type": "string"}}}
	src.seed("post-1", "post", map[string]any{"title": "One"})
	src.seed("author-1", "author", map[string]any{"name": "Ada"})
	dir := t.TempDir()
	backup = filepath.Join(dir, "backup.ndjson")
	schemasPath = filepath.Join(dir, "schemas.json")
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, src.ctx(), []string{"--out", backup, "--schemas", schemasPath}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	if !strings.Contains(se.String(), "exported 2 schema(s)") {
		t.Errorf("export stderr = %s, want the schema count", se.String())
	}
	return backup, schemasPath
}

// SCHEMAS TRAVEL WITH THE DATA (task-cdd4555f010c1893). One export with
// --schemas and one import with --schemas copy a dataset to an empty target:
// every schema arrives without the source's schemaHash, all schemas are
// written before the first document, and no per-schema apply is needed.
func TestExportImportSchemasCopiesEverySchemaBeforeTheDocuments(t *testing.T) {
	backup, schemasPath := schemaCopySource(t)

	raw, err := os.ReadFile(schemasPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "schemaHash") {
		t.Errorf("schema file keeps the source's schemaHash: %s", raw)
	}

	dst := newSchemaFakeServer(t)
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--schemas", schemasPath)
	if code != exitOK {
		t.Fatalf("import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if len(dst.schemas) != 2 || dst.schemas["post"] == nil || dst.schemas["author"] == nil {
		t.Fatalf("target schemas = %v, want post and author", dst.schemas)
	}
	if _, ok := dst.schemas["post"]["schemaHash"]; ok {
		t.Error("the import sent schemaHash to the target")
	}
	if len(dst.order) < 3 || dst.order[0] == "mutate" || dst.order[1] == "mutate" || dst.order[2] != "mutate" {
		t.Errorf("write order = %v, want both schemas before the first mutate", dst.order)
	}
	if _, ok := dst.docs["post-1"]; !ok {
		t.Error("post-1 was not imported")
	}
	if !strings.Contains(stderr, "applied 2 schema(s)") {
		t.Errorf("import stderr = %s, want the schema count", stderr)
	}

	// A second run with --overwrite applies the same schemas again and
	// changes nothing.
	if code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--schemas", schemasPath, "--overwrite"); code != exitOK {
		t.Fatalf("second import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if len(dst.schemas) != 2 {
		t.Errorf("target schemas after a re-run = %d, want 2", len(dst.schemas))
	}
}

// The dry run names the schema count and writes no schema.
func TestImportSchemasDryRunWritesNothing(t *testing.T) {
	backup, schemasPath := schemaCopySource(t)
	dst := newSchemaFakeServer(t)
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--schemas", schemasPath, "--dry-run")
	if code != exitOK {
		t.Fatalf("dry run exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "2 schema(s) from") {
		t.Errorf("dry run stdout = %s, want the schema count", stdout)
	}
	if len(dst.order) != 0 {
		t.Errorf("dry run wrote %v", dst.order)
	}
}

// A 429 on a schema write waits out Retry-After and sends the same schema
// again, so the copy finishes without a manual step.
func TestImportSchemasRetriesAfter429(t *testing.T) {
	var slept time.Duration
	oldSleep := mediaSleep
	mediaSleep = func(d time.Duration) { slept += d }
	t.Cleanup(func() { mediaSleep = oldSleep })

	backup, schemasPath := schemaCopySource(t)
	dst := newSchemaFakeServer(t)
	dst.throttle = 2
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--schemas", schemasPath)
	if code != exitOK {
		t.Fatalf("import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if len(dst.schemas) != 2 {
		t.Errorf("target schemas = %d, want 2", len(dst.schemas))
	}
	if slept < 4*time.Second {
		t.Errorf("waited %s, want at least the two Retry-After values of 2 s", slept)
	}
	if !strings.Contains(stderr, "answered 429 to 2 schema write(s)") {
		t.Errorf("import stderr = %s, want the 429 count", stderr)
	}
}

// A target without the workspace refuses the first schema. The import names
// `bp workspace create` and writes no document.
func TestImportSchemasMissingWorkspaceNamesTheFix(t *testing.T) {
	backup, schemasPath := schemaCopySource(t)
	dst := newSchemaFakeServer(t)
	dst.missing = true
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--schemas", schemasPath)
	if code == exitOK {
		t.Fatalf("import exit = 0, want a refusal; stdout=%s", stdout)
	}
	if !strings.Contains(stdout+stderr, "bp workspace create ws") {
		t.Errorf("import output lacks the workspace hint: %s %s", stdout, stderr)
	}
	if len(dst.docs) != 0 {
		t.Errorf("target holds %d documents, want none", len(dst.docs))
	}
}

// A file that is not a schema export is refused before anything is written.
func TestImportSchemasRefusesAFileWithoutNames(t *testing.T) {
	backup, _ := schemaCopySource(t)
	bad := filepath.Join(t.TempDir(), "bad.json")
	if err := os.WriteFile(bad, []byte(`{"schemas":[{"title":"no name"}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := newSchemaFakeServer(t)
	code, _, _ := runImportForTest(t, dst.ctx(), globals{}, backup, "--schemas", bad)
	if code != exitValidation {
		t.Fatalf("import exit = %d, want %d", code, exitValidation)
	}
	if len(dst.order) != 0 {
		t.Errorf("a refused import wrote %v", dst.order)
	}
}
