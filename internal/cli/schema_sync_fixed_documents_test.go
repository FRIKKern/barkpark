package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// FIXEDDOCUMENTS ROUND-TRIPS THROUGH bp schema (task-f4c80d82cc25b19b): a pulled
// file carries the list, pushing it back changes nothing, editing it is a change,
// and a file without the key clears it on the server (the server reads null as
// "no list"), as for readerWrites.
func TestSchemaSyncCarriesFixedDocuments(t *testing.T) {
	s := newSyncFakeServer(t)
	side := syncSchema("side", "body")
	side["fixed_documents"] = []any{"side-om-oss", "side-hva-vi-jobber-med"}
	s.seed(side)
	dir := t.TempDir()
	step := func(what string, run func(*writer, globals, manifest.Context, []string) int, want int) {
		t.Helper()
		if code, stdout, stderr := runSync(run, s, globals{}, dir); code != want {
			t.Fatalf("%s exit = %d, want %d; stdout=%s stderr=%s", what, code, want, stdout, stderr)
		}
	}
	step("pull", runSchemaPull, exitOK)
	var pulled map[string]any
	raw, _ := os.ReadFile(filepath.Join(dir, "side.json"))
	if err := json.Unmarshal(raw, &pulled); err != nil {
		t.Fatal(err)
	}
	want := []any{"side-om-oss", "side-hva-vi-jobber-med"}
	if !reflect.DeepEqual(pulled["fixedDocuments"], want) {
		t.Fatalf("pulled fixedDocuments = %v, want %v", pulled["fixedDocuments"], want)
	}
	step("diff after pull", runSchemaDiff, exitOK)
	step("push of the pulled file", runSchemaPush, exitOK)
	if got := s.stored("side", "fixed_documents"); !reflect.DeepEqual(got, want) {
		t.Fatalf("stored after push = %v, want %v", got, want)
	}

	pulled["fixedDocuments"] = []any{"side-om-oss"}
	writeSyncFile(t, dir, "side", pulled)
	code, stdout, _ := runSync(runSchemaDiff, s, globals{}, dir)
	if code != exitSchemaDiff || !strings.Contains(stdout, "fixedDocuments") {
		t.Fatalf("diff after editing the list exit = %d; stdout=%s", code, stdout)
	}
	step("push of the edited list", runSchemaPush, exitOK)
	step("diff after the edit", runSchemaDiff, exitOK)

	delete(pulled, "fixedDocuments")
	writeSyncFile(t, dir, "side", pulled)
	step("push without the key", runSchemaPush, exitOK)
	if got := s.stored("side", "fixed_documents"); got != nil {
		t.Fatalf("the server kept the removed list: %v", got)
	}
	step("diff after the list was cleared", runSchemaDiff, exitOK)
}
