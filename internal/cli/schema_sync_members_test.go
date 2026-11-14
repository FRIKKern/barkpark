package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// syncRowsSchema has an array field whose member is an object with a nested
// field: the part the served schema list leaves out.
func syncRowsSchema() map[string]any {
	return map[string]any{"name": "table", "title": "Table", "fields": []any{
		map[string]any{"name": "rows", "type": "array", "of": []any{
			map[string]any{"type": "object", "name": "row", "fields": []any{map[string]any{"name": "label", "type": "string"}}},
		}},
	}}
}

func retitleSyncFile(t *testing.T, dir, name string) {
	t.Helper()
	path := filepath.Join(dir, name+".json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var def map[string]any
	if err := json.Unmarshal(raw, &def); err != nil {
		t.Fatal(err)
	}
	def["title"] = "Renamed"
	writeSyncFile(t, dir, name, def)
}

func storedMember(t *testing.T, s *syncFakeServer) map[string]any {
	t.Helper()
	fields, _ := s.stored("table", "fields").([]any)
	rows, _ := fields[0].(map[string]any)
	of, _ := rows["of"].([]any)
	member, _ := of[0].(map[string]any)
	return member
}

// PULL, EDIT THE TITLE, PUSH: THE NESTED FIELDS OF AN ARRAY MEMBER SURVIVE.
// The server sends stored fields when asked, so the pulled file has the
// member in full and the push sends it back as it was.
func TestSchemaPushKeepsNestedArrayMembers(t *testing.T) {
	s := newSyncFakeServer(t)
	s.seed(syncRowsSchema())
	want := storedMember(t, s)
	dir := t.TempDir()
	if code, _, stderr := runSync(runSchemaPull, s, globals{}, dir); code != exitOK || strings.Contains(stderr, "note:") {
		t.Fatalf("pull exit = %d; stderr=%s", code, stderr)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "table.json"))
	if !strings.Contains(string(raw), `"label"`) || strings.Contains(string(raw), "required?") {
		t.Fatalf("table.json should hold the stored fields, nested member included: %s", raw)
	}
	retitleSyncFile(t, dir, "table")
	if code, stdout, stderr := runSync(runSchemaPush, s, globals{}, dir); code != exitOK {
		t.Fatalf("push exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if got := storedMember(t, s); !reflect.DeepEqual(got, want) || s.stored("table", "title") != "Renamed" {
		t.Fatalf("after push the server holds member %v and title %v, want %v and Renamed", got, s.stored("table", "title"), want)
	}
	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
		t.Fatalf("diff after push exit = %d; stdout=%s", code, stdout)
	}
}

// A SERVER THAT CANNOT SEND STORED FIELDS: pull says the files are cut down,
// and push refuses the change instead of replacing the stored member. A file
// that writes the member out in full is applied.
func TestSchemaPushRefusesCutDownMembersOnAnOlderServer(t *testing.T) {
	s := newSyncFakeServer(t)
	s.old = true
	s.seed(syncRowsSchema(), syncSchema("post", "title"))
	want := storedMember(t, s)
	dir := t.TempDir()
	code, _, stderr := runSync(runSchemaPull, s, globals{}, dir)
	if code != exitOK || !strings.Contains(stderr, "cannot send fields as stored") {
		t.Fatalf("pull exit = %d, want the note about cut-down members; stderr=%s", code, stderr)
	}
	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
		t.Fatalf("diff after pull exit = %d; stdout=%s", code, stdout)
	}
	retitleSyncFile(t, dir, "table")
	retitleSyncFile(t, dir, "post")
	code, stdout, stderr := runSync(runSchemaPush, s, globals{}, dir)
	if code != exitConflict || !strings.Contains(stderr, "table (rows)") || !strings.Contains(stdout, "push would replace the stored definition of: rows") {
		t.Fatalf("push exit = %d, want %d naming table (rows); stdout=%s stderr=%s", code, exitConflict, stdout, stderr)
	}
	if posts, _ := s.writes(); len(posts) != 0 {
		t.Fatalf("the refused push wrote %v", posts)
	}
	if got := storedMember(t, s); !reflect.DeepEqual(got, want) {
		t.Fatalf("the refused push changed the stored member to %v", got)
	}

	full := syncRowsSchema()
	full["title"] = "Renamed"
	writeSyncFile(t, dir, "table", full)
	if code, stdout, stderr := runSync(runSchemaPush, s, globals{}, dir); code != exitOK {
		t.Fatalf("push of the full member exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if got := storedMember(t, s); !reflect.DeepEqual(got, want) {
		t.Fatalf("after the full push the server holds member %v, want %v", got, want)
	}
}

// A FIELD OF A NAMED TYPE STAYS A REFERENCE. The stored read serves
// {"name":"seo","type":"seo"} as stored, so pull, a title edit and push leave
// the row pointing at the type. An older server serves a copy of the type; a
// push of that copy is refused.
func TestSchemaPushKeepsNamedTypeReferences(t *testing.T) {
	ref := map[string]any{"name": "seo", "type": "seo"}
	seed := func(old bool) (*syncFakeServer, string) {
		s := newSyncFakeServer(t)
		s.old = old
		seo := syncSchema("seo", "metaTitle")
		seo["kind"] = "object"
		s.seed(seo, map[string]any{"name": "article", "title": "Article", "fields": []any{ref}})
		dir := t.TempDir()
		if code, _, stderr := runSync(runSchemaPull, s, globals{}, dir); code != exitOK {
			t.Fatalf("pull exit = %d; stderr=%s", code, stderr)
		}
		if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
			t.Fatalf("diff after pull exit = %d; stdout=%s", code, stdout)
		}
		retitleSyncFile(t, dir, "article")
		return s, dir
	}
	storedRef := func(s *syncFakeServer) any { return s.stored("article", "fields").([]any)[0] }

	s, dir := seed(false)
	if code, stdout, stderr := runSync(runSchemaPush, s, globals{}, dir); code != exitOK {
		t.Fatalf("push exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if got := storedRef(s); !reflect.DeepEqual(got, ref) || s.stored("article", "title") != "Renamed" {
		t.Fatalf("after push the server holds field %v and title %v, want the reference %v", got, s.stored("article", "title"), ref)
	}

	s, dir = seed(true)
	code, _, stderr := runSync(runSchemaPush, s, globals{}, dir)
	if posts, _ := s.writes(); code != exitConflict || !strings.Contains(stderr, "article (seo)") || len(posts) != 0 {
		t.Fatalf("push to an older server exit = %d, want %d naming article (seo) and no write; posts=%v stderr=%s", code, exitConflict, posts, stderr)
	}
	if got := storedRef(s); !reflect.DeepEqual(got, ref) {
		t.Fatalf("the refused push changed the stored field to %v", got)
	}
}

// A FILE WITHOUT visibility LEAVES A PRIVATE SCHEMA PRIVATE. The plan says so,
// the push does not send the key, and a file that sets it still changes it.
func TestSchemaPushKeepsVisibilityTheFileDoesNotSet(t *testing.T) {
	s := newSyncFakeServer(t)
	secret := syncSchema("secret", "code")
	secret["visibility"] = "private"
	s.seed(secret)
	dir := t.TempDir()
	short := syncSchema("secret", "code")
	short["title"] = "Renamed"
	writeSyncFile(t, dir, "secret", short)
	code, stdout, stderr := runSync(runSchemaPush, s, globals{}, dir)
	if code != exitOK || !strings.Contains(stdout, "~ secret  changed (keys: title)") || !strings.Contains(stdout, "= secret  stays private") {
		t.Fatalf("push exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if vis := s.stored("secret", "visibility"); vis != "private" || s.stored("secret", "title") != "Renamed" {
		t.Fatalf("after push visibility = %v, title = %v; want private and Renamed", vis, s.stored("secret", "title"))
	}
	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
		t.Fatalf("diff after push exit = %d; stdout=%s", code, stdout)
	}
	short["visibility"] = "public"
	writeSyncFile(t, dir, "secret", short)
	if code, stdout, _ := runSync(runSchemaPush, s, globals{}, dir); code != exitOK || !strings.Contains(stdout, "keys: visibility") {
		t.Fatalf("push of an explicit visibility exit = %d; stdout=%s", code, stdout)
	}
	if vis := s.stored("secret", "visibility"); vis != "public" {
		t.Fatalf("an explicit visibility was not applied: %v", vis)
	}
}
