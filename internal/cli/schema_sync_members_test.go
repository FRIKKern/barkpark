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
	if code != exitOK || !strings.Contains(stderr, "without their own fields") {
		t.Fatalf("pull exit = %d, want the note about cut-down members; stderr=%s", code, stderr)
	}
	if code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir); code != exitOK {
		t.Fatalf("diff after pull exit = %d; stdout=%s", code, stdout)
	}
	retitleSyncFile(t, dir, "table")
	retitleSyncFile(t, dir, "post")
	code, stdout, stderr := runSync(runSchemaPush, s, globals{}, dir)
	if code != exitConflict || !strings.Contains(stderr, "table (rows)") || !strings.Contains(stdout, "push would replace the stored members of: rows") {
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
