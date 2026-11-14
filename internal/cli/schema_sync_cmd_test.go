package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// syncFakeServer answers the three schema routes the way the real server
// does: the list echoes each stored definition with the keys the server adds
// itself (id, schemaHash and the defaults of keys the definition left out),
// the upsert stores the body, and the delete answers a receipt that names the
// schema. It counts the writes it gets.
type syncFakeServer struct {
	srv *httptest.Server

	mu      sync.Mutex
	schemas map[string]map[string]any
	posts   []string
	deletes []string
}

func newSyncFakeServer(t *testing.T) *syncFakeServer {
	t.Helper()
	s := &syncFakeServer{schemas: map[string]map[string]any{}}
	s.srv = httptest.NewServer(http.HandlerFunc(s.handle))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *syncFakeServer) ctx() manifest.Context {
	return manifest.Context{Server: s.srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}
}

func (s *syncFakeServer) handle(w http.ResponseWriter, r *http.Request) {
	const route = "/w/ws/p/proj/v1/schemas/production"
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case r.Method == http.MethodGet && r.URL.Path == route:
		list := []map[string]any{}
		for name, def := range s.schemas {
			out := map[string]any{
				"id": name, "schemaHash": "hash-of-" + name, "updatedAt": "2026-11-14T10:00:00Z",
				"kind": "document", "singleton": false, "icon": nil, "actions": []any{}, "desk": map[string]any{},
			}
			for k, v := range def {
				out[k] = v
			}
			list = append(list, out)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"schemas": list, "_schemaVersion": 1})
	case r.Method == http.MethodPost && r.URL.Path == route:
		body, _ := io.ReadAll(r.Body)
		var def map[string]any
		if json.Unmarshal(body, &def) != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		name, _ := def["name"].(string)
		s.schemas[name] = def
		s.posts = append(s.posts, name)
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(def)
	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, route+"/"):
		name := strings.TrimPrefix(r.URL.Path, route+"/")
		delete(s.schemas, name)
		s.deletes = append(s.deletes, name)
		_ = json.NewEncoder(w).Encode(map[string]any{"deleted": name, "id": "row-" + name, "dataset": "production"})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (s *syncFakeServer) writes() (posts, deletes []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string{}, s.posts...), append([]string{}, s.deletes...)
}

func syncSchema(name string, fields ...string) map[string]any {
	list := []any{}
	for _, f := range fields {
		list = append(list, map[string]any{"name": f, "type": "string"})
	}
	return map[string]any{"name": name, "title": strings.ToUpper(name[:1]) + name[1:], "fields": list}
}

func writeSyncFile(t *testing.T, dir, name string, def any) {
	t.Helper()
	b, err := json.Marshal(def)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// runSync runs one of the three verbs and returns its exit code and output.
func runSync(run func(*writer, globals, manifest.Context, []string) int, s *syncFakeServer, g globals, tail ...string) (int, string, string) {
	var so, se strings.Builder
	out := newWriter(&so, &se)
	out.output = g.output
	return run(out, g, s.ctx(), tail), so.String(), se.String()
}

// PULL, THEN DIFF, IS CLEAN; PUSH, THEN DIFF, IS CLEAN. The server's own keys
// (id, schemaHash, a timestamp, filled-in defaults) do not count as a
// difference, and a schema whose name could leave the folder is skipped.
func TestSchemaPullDiffPushRoundTrip(t *testing.T) {
	s := newSyncFakeServer(t)
	s.schemas["post"] = syncSchema("post", "title", "body")
	s.schemas["author"] = syncSchema("author", "name")
	s.schemas["../evil"] = syncSchema("../evil", "x")
	parent := t.TempDir()
	dir := filepath.Join(parent, "schemas")

	code, stdout, stderr := runSync(runSchemaPull, s, globals{}, dir)
	if code != exitOK {
		t.Fatalf("pull exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "wrote 2 schema(s)") || !strings.Contains(stdout, `skipped schema "../evil"`) {
		t.Errorf("pull stdout = %s, want 2 written and ../evil skipped", stdout)
	}
	if _, err := os.Stat(filepath.Join(parent, "evil.json")); err == nil {
		t.Fatal("pull wrote a file outside the folder")
	}
	raw, err := os.ReadFile(filepath.Join(dir, "post.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "schemaHash") || !strings.Contains(string(raw), "\n  \"fields\": [") {
		t.Errorf("post.json = %s, want indented JSON without schemaHash", raw)
	}
	if strings.Index(string(raw), `"fields"`) > strings.Index(string(raw), `"name": "post"`) {
		t.Errorf("post.json keys are not sorted: %s", raw)
	}

	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
		t.Fatalf("diff after pull exit = %d, want 0; stdout=%s", code, stdout)
	}

	// Edit one pulled file and add a short hand-written one, then push.
	post := syncSchema("post", "title", "body", "subtitle")
	writeSyncFile(t, dir, "post", post)
	writeSyncFile(t, dir, "page", syncSchema("page", "slug"))
	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitSchemaDiff {
		t.Fatalf("diff before push exit = %d, want %d; stdout=%s", code, exitSchemaDiff, stdout)
	}
	if code, stdout, stderr := runSync(runSchemaPush, s, globals{}, dir); code != exitOK {
		t.Fatalf("push exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	posts, deletes := s.writes()
	if !reflect.DeepEqual(posts, []string{"page", "post"}) || len(deletes) != 0 {
		t.Fatalf("push wrote posts=%v deletes=%v, want page and post and no delete", posts, deletes)
	}
	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
		t.Fatalf("diff after push exit = %d, want 0; stdout=%s", code, stdout)
	}
}

// One added, one changed, one removed, one unchanged: the plan names each,
// with the field-level summary, and the exit code says there is a difference.
func TestSchemaDiffPlansAddedChangedRemoved(t *testing.T) {
	s := newSyncFakeServer(t)
	s.schemas["post"] = syncSchema("post", "title", "body", "legacy")
	s.schemas["author"] = syncSchema("author", "name")
	s.schemas["tag"] = syncSchema("tag", "label")
	dir := t.TempDir()
	post := syncSchema("post", "title", "body", "subtitle")
	post["title"] = "Article"
	post["fields"].([]any)[1].(map[string]any)["type"] = "text"
	writeSyncFile(t, dir, "post", post)
	writeSyncFile(t, dir, "author", syncSchema("author", "name"))
	writeSyncFile(t, dir, "page", syncSchema("page", "slug"))

	code, stdout, stderr := runSync(runSchemaDiff, s, globals{output: "json"}, dir)
	if code != exitSchemaDiff {
		t.Fatalf("diff exit = %d, want %d; stderr=%s", code, exitSchemaDiff, stderr)
	}
	var plan struct {
		Added       []string       `json:"added"`
		Changed     []schemaChange `json:"changed"`
		Removed     []string       `json:"removed"`
		Unchanged   int            `json:"unchanged"`
		Differences bool           `json:"differences"`
	}
	if err := json.Unmarshal([]byte(stdout), &plan); err != nil {
		t.Fatalf("diff -o json did not parse: %v\n%s", err, stdout)
	}
	want := schemaChange{Name: "post", FieldsAdded: []string{"subtitle"}, FieldsRemoved: []string{"legacy"}, FieldsChanged: []string{"body"}, Keys: []string{"title"}}
	if !reflect.DeepEqual(plan.Added, []string{"page"}) || !reflect.DeepEqual(plan.Removed, []string{"tag"}) ||
		plan.Unchanged != 1 || !plan.Differences || len(plan.Changed) != 1 || !reflect.DeepEqual(plan.Changed[0], want) {
		t.Fatalf("plan = %+v, want page added, tag removed, 1 unchanged and %+v", plan, want)
	}

	_, human, _ := runSync(runSchemaDiff, s, globals{}, dir)
	for _, line := range []string{"+ page", "~ post  changed (fields: +subtitle, -legacy, ~body; keys: title)", "- tag", "1 added, 1 changed, 1 removed, 1 unchanged"} {
		if !strings.Contains(human, line) {
			t.Errorf("diff output lacks %q:\n%s", line, human)
		}
	}
	if posts, deletes := s.writes(); len(posts)+len(deletes) != 0 {
		t.Errorf("diff wrote to the server: posts=%v deletes=%v", posts, deletes)
	}
}

// A dry run and a file that does not parse write nothing. A push applies the
// added and changed schemas and leaves the server-only one alone. --prune
// deletes it, and only after --yes when nobody can be asked.
func TestSchemaPushAppliesAndPrunesOnlyWhenAsked(t *testing.T) {
	oldTTY := destroyStdinIsTTY
	destroyStdinIsTTY = func(io.Reader) bool { return false }
	t.Cleanup(func() { destroyStdinIsTTY = oldTTY })

	s := newSyncFakeServer(t)
	s.schemas["post"] = syncSchema("post", "title")
	s.schemas["tag"] = syncSchema("tag", "label")
	dir := t.TempDir()
	writeSyncFile(t, dir, "post", syncSchema("post", "title", "subtitle"))
	writeSyncFile(t, dir, "page", syncSchema("page", "slug"))
	noWrites := func(step string) {
		t.Helper()
		if posts, deletes := s.writes(); len(posts)+len(deletes) != 0 {
			t.Fatalf("%s wrote to the server: posts=%v deletes=%v", step, posts, deletes)
		}
	}

	code, stdout, _ := runSync(runSchemaPush, s, globals{dryRun: true}, dir, "--prune")
	if code != exitOK || !strings.Contains(stdout, "dry run: nothing was written") || !strings.Contains(stdout, "- tag  will be deleted") {
		t.Fatalf("dry run exit = %d; stdout=%s", code, stdout)
	}
	noWrites("the dry run")

	bad := filepath.Join(dir, "broken.json")
	if err := os.WriteFile(bad, []byte(`{"name": "broken",`), 0o644); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := runSync(runSchemaPush, s, globals{}, dir)
	if code != exitValidation || !strings.Contains(stderr, bad) {
		t.Fatalf("push with a broken file exit = %d, want %d and the file name; stderr=%s", code, exitValidation, stderr)
	}
	noWrites("the push with a broken file")
	if err := os.Remove(bad); err != nil {
		t.Fatal(err)
	}

	code, _, stderr = runSync(runSchemaPush, s, globals{}, dir, "--prune")
	if code != exitUsage || !strings.Contains(stderr, "re-run with --yes") {
		t.Fatalf("prune without --yes exit = %d, want %d; stderr=%s", code, exitUsage, stderr)
	}
	noWrites("the unconfirmed prune")

	code, stdout, stderr = runSync(runSchemaPush, s, globals{}, dir)
	if code != exitOK || !strings.Contains(stdout, "- tag  left alone") {
		t.Fatalf("push exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if posts, deletes := s.writes(); !reflect.DeepEqual(posts, []string{"page", "post"}) || len(deletes) != 0 {
		t.Fatalf("push wrote posts=%v deletes=%v, want page and post and no delete", posts, deletes)
	}

	code, stdout, stderr = runSync(runSchemaPush, s, globals{yes: true}, dir, "--prune")
	if code != exitOK {
		t.Fatalf("prune exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if posts, deletes := s.writes(); len(posts) != 2 || !reflect.DeepEqual(deletes, []string{"tag"}) {
		t.Fatalf("prune wrote posts=%v deletes=%v, want no new post and tag deleted", posts, deletes)
	}
	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
		t.Fatalf("diff after prune exit = %d, want 0; stdout=%s", code, stdout)
	}
}
