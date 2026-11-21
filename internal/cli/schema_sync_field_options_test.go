package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// A field's options travel through `bp schema push` and `pull` untouched: the Studio reads
// them (a slug's options.slugify names its slug table, barkpark-studio task-15e2e504dd3c74cc),
// so a key the CLI does not know must not be dropped on the way.
func TestSchemaSyncKeepsFieldOptions(t *testing.T) {
	opts := map[string]any{"source": "tittel", "slugify": "nb", "maxLength": float64(96)}
	side := syncSchema("side", "tittel")
	side["fields"] = append(side["fields"].([]any), map[string]any{"name": "slug", "type": "slug", "options": opts})
	slugOptions := func(fields any) any {
		for _, f := range fields.([]any) {
			if m := f.(map[string]any); m["name"] == "slug" {
				return m["options"]
			}
		}
		return nil
	}

	s := newSyncFakeServer(t)
	local := t.TempDir()
	writeSyncFile(t, local, "side", side)
	if code, out, errs := runSync(runSchemaPush, s, globals{}, local); code != exitOK {
		t.Fatalf("push: exit %d\n%s%s", code, out, errs)
	}
	if got := slugOptions(s.stored("side", "fields")); !reflect.DeepEqual(got, opts) {
		t.Fatalf("pushed options = %v, want %v", got, opts)
	}

	pulled := t.TempDir()
	if code, out, errs := runSync(runSchemaPull, s, globals{}, pulled); code != exitOK {
		t.Fatalf("pull: exit %d\n%s%s", code, out, errs)
	}
	raw, err := os.ReadFile(filepath.Join(pulled, "side.json"))
	if err != nil {
		t.Fatal(err)
	}
	var def map[string]any
	if err := json.Unmarshal(raw, &def); err != nil {
		t.Fatal(err)
	}
	if got := slugOptions(def["fields"]); !reflect.DeepEqual(got, opts) {
		t.Fatalf("pulled options = %v, want %v", got, opts)
	}
	if code, out, errs := runSync(runSchemaDiff, s, globals{}, pulled); code != exitOK {
		t.Fatalf("diff after pull: exit %d\n%s%s", code, out, errs)
	}
}
