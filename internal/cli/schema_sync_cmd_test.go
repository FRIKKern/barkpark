package cli

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

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
	s.seed(syncSchema("post", "title", "body"), syncSchema("author", "name"), syncSchema("../evil", "x"))
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
	s.seed(syncSchema("post", "title", "body", "legacy"), syncSchema("author", "name"), syncSchema("tag", "label"))
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
	s.seed(syncSchema("post", "title"))
	s.seed(syncSchema("tag", "label"))
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

// AFTER A PUSH, DIFF IS CLEAN FOR EVERY FILE SHAPE, against a server that
// casts and echoes like the real one: a pulled file with keys removed (the
// server must really clear them), a short hand-written file, and the
// `bp make schema` skeleton. A falsy value below the top level is a change.
func TestSchemaPushReachesDiffZeroForEveryFileShape(t *testing.T) {
	s := newSyncFakeServer(t)
	post := syncSchema("post", "title")
	post["icon"], post["singleton"], post["groups"] = "star", true, []any{map[string]any{"name": "seo"}}
	s.seed(post)
	dir := t.TempDir()
	step := func(what string, run func(*writer, globals, manifest.Context, []string) int, want int) {
		t.Helper()
		if code, stdout, stderr := runSync(run, s, globals{}, dir); code != want {
			t.Fatalf("%s exit = %d, want %d; stdout=%s stderr=%s", what, code, want, stdout, stderr)
		}
	}
	step("pull", runSchemaPull, exitOK)
	step("diff after pull", runSchemaDiff, exitOK)

	// Remove three keys from the pulled file.
	path := filepath.Join(dir, "post.json")
	raw, _ := os.ReadFile(path)
	var pulled map[string]any
	if err := json.Unmarshal(raw, &pulled); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"icon", "singleton", "groups"} {
		delete(pulled, k)
	}
	writeSyncFile(t, dir, "post", pulled)
	step("diff after removing keys", runSchemaDiff, exitSchemaDiff)
	step("push after removing keys", runSchemaPush, exitOK)
	if icon, single, groups := s.stored("post", "icon"), s.stored("post", "singleton"), s.stored("post", "groups"); icon != nil || single != false || len(groups.([]any)) != 0 {
		t.Fatalf("the server kept the removed keys: icon=%v singleton=%v groups=%v", icon, single, groups)
	}
	step("diff after the keys were cleared", runSchemaDiff, exitOK)

	// A short hand-written file and the skeleton `bp make schema` prints.
	writeSyncFile(t, dir, "page", map[string]any{"name": "page", "title": "Page", "fields": []any{
		map[string]any{"name": "slug", "type": "string", "validation": map[string]any{"required": true}},
		map[string]any{"name": "tags", "type": "array"},
		map[string]any{"name": "author", "type": "reference", "refType": "author"},
	}})
	skeleton, err := schemaSkeleton("product")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "product.json"), []byte(skeleton), 0o644); err != nil {
		t.Fatal(err)
	}
	step("push of hand-written files", runSchemaPush, exitOK)
	step("diff after hand-written files", runSchemaDiff, exitOK)

	// A false inside initialValues is data, not a default.
	var page map[string]any
	raw, _ = os.ReadFile(filepath.Join(dir, "page.json"))
	_ = json.Unmarshal(raw, &page)
	page["initialValues"] = map[string]any{"featured": false}
	writeSyncFile(t, dir, "page", page)
	code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir)
	if code != exitSchemaDiff || !strings.Contains(stdout, "~ page  changed (keys: initialValues)") {
		t.Fatalf("diff after initialValues exit = %d; stdout=%s", code, stdout)
	}
	step("push of initialValues", runSchemaPush, exitOK)
	step("diff after initialValues", runSchemaDiff, exitOK)
	page["fields"].([]any)[0].(map[string]any)["default"] = false
	writeSyncFile(t, dir, "page", page)
	step("diff after a false field default", runSchemaDiff, exitSchemaDiff)
}

// pull --dry-run writes nothing. pull --prune removes a stale schema file and
// nothing else: not package.json, not a JSON file that is not a schema, not a
// symlink.
func TestSchemaPullDryRunAndPruneTouchOnlySchemaFiles(t *testing.T) {
	s := newSyncFakeServer(t)
	s.seed(syncSchema("post", "title"))
	fresh := filepath.Join(t.TempDir(), "new")
	code, stdout, _ := runSync(runSchemaPull, s, globals{dryRun: true}, fresh)
	if code != exitOK || !strings.Contains(stdout, "dry run: would write 1 schema(s)") {
		t.Fatalf("dry-run pull exit = %d; stdout=%s", code, stdout)
	}
	if _, err := os.Stat(fresh); err == nil {
		t.Fatal("pull --dry-run created the folder")
	}

	dir := t.TempDir()
	writeSyncFile(t, dir, "old", syncSchema("old", "x"))
	writeSyncFile(t, dir, "package", map[string]any{"name": "my-app", "version": "1.0.0"})
	writeSyncFile(t, dir, "tsconfig", map[string]any{"compilerOptions": map[string]any{}})
	outside := filepath.Join(t.TempDir(), "link.json")
	writeSyncFile(t, filepath.Dir(outside), "link", syncSchema("link", "x"))
	if err := os.Symlink(outside, filepath.Join(dir, "link.json")); err != nil {
		t.Fatal(err)
	}
	if code, stdout, _ := runSync(runSchemaPull, s, globals{dryRun: true}, dir, "--prune"); code != exitOK || !strings.Contains(stdout, "dry run: would remove old.json") {
		t.Fatalf("dry-run prune exit = %d; stdout=%s", code, stdout)
	}
	if _, err := os.Stat(filepath.Join(dir, "old.json")); err != nil {
		t.Fatal("pull --prune --dry-run removed old.json")
	}
	code, stdout, stderr := runSync(runSchemaPull, s, globals{}, dir, "--prune")
	if code != exitOK || !strings.Contains(stdout, "removed old.json") {
		t.Fatalf("prune exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if _, err := os.Stat(filepath.Join(dir, "old.json")); err == nil {
		t.Error("pull --prune kept the stale schema file old.json")
	}
	for _, keep := range []string{"post.json", "package.json", "tsconfig.json", "link.json"} {
		if _, err := os.Lstat(filepath.Join(dir, keep)); err != nil {
			t.Errorf("pull --prune removed %s", keep)
		}
	}
}
