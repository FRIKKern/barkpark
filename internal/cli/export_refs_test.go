package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const (
	refAssetA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	refAssetB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	refAssetC = "cccccccc-cccc-cccc-cccc-cccccccccccc"
	refAssetD = "dddddddd-dddd-dddd-dddd-dddddddddddd"
)

// refsSource is a dataset shaped like the Pensum set (task-c3df8afd76b35c2f):
// seed types with a common prefix, a seed id of another type, references by
// _ref (one to a drafts. id), by an asset-<uuid> string and by a
// /media/files/<path> URL, a chain two hops deep, a dangling reference, and
// documents and media nothing reaches.
func refsSource(t *testing.T) (*mediaFakeServer, manifest.Context) {
	t.Helper()
	m := newMediaFakeServer(t, "d/src")
	m.store(refAssetA, "a.png", []byte("a"))
	m.store(refAssetB, "b.png", []byte("b"))
	m.store(refAssetC, "c.png", []byte("c"))
	m.store(refAssetD, "d.png", []byte("d"))
	m.seed("pensumBook-1", "pensumBook", map[string]any{
		"author": map[string]any{"_type": "reference", "_ref": "drafts.contributor-1"},
		"cover":  map[string]any{"asset": map[string]any{"_ref": "asset-" + refAssetA}},
		"body":   `<p><img src="https://cms.example/media/files/` + m.files[refAssetB].Path + `?w=200"></p>`,
	})
	m.seed("pensumShelf-1", "pensumShelf", map[string]any{"note": "see asset-" + refAssetC})
	m.seed("product-1", "product", map[string]any{"title": "P"})
	m.seed("contributor-1", "contributor", map[string]any{"org": map[string]any{"_ref": "organization-1"}})
	m.seed("drafts.contributor-1", "contributor", map[string]any{"org": map[string]any{"_ref": "organization-1"}, "name": "draft"})
	m.seed("organization-1", "organization", map[string]any{"parent": map[string]any{"_ref": "missing-1"}})
	m.seed("deskStructure.pensum", "deskStructure", map[string]any{"items": []any{"pensumBook"}})
	m.seed("deskStructure.other", "deskStructure", map[string]any{"items": []any{"x"}})
	m.seed("unrelated-1", "unrelated", map[string]any{"img": map[string]any{"_ref": "asset-" + refAssetD}})

	schemas := []map[string]any{
		{"name": "pensumBook", "kind": "document", "fields": []any{map[string]any{"name": "author", "type": "reference", "to": []any{map[string]any{"type": "contributor"}}}}},
		{"name": "contributor", "kind": "document", "fields": []any{map[string]any{"name": "bio", "type": "object", "namedType": "bioBlock"}}},
		{"name": "bioBlock", "kind": "object", "fields": []any{}},
		{"name": "unrelated", "kind": "document", "fields": []any{}},
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/w/ws/p/proj/v1/schemas/production" {
			_ = json.NewEncoder(w).Encode(map[string]any{"schemas": schemas})
			return
		}
		m.handle(w, r)
	}))
	t.Cleanup(srv.Close)
	ctx := m.ctx()
	ctx.Server = srv.URL
	return m, ctx
}

func exportedIDs(t *testing.T, path string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var head struct {
			ID string `json:"_id"`
		}
		if err := json.Unmarshal([]byte(line), &head); err != nil {
			t.Fatalf("line %q: %v", line, err)
		}
		ids = append(ids, head.ID)
	}
	return ids
}

func mediaIDs(t *testing.T, dir string) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, mediaCopyManifest))
	if err != nil {
		t.Fatal(err)
	}
	var f mediaCopyFile
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, a := range f.Assets {
		ids = append(ids, a.ID)
		if _, err := os.Stat(filepath.Join(dir, "files", a.ID)); err != nil {
			t.Errorf("media.json lists %s but files/%s is missing", a.ID, a.ID)
		}
	}
	entries, _ := os.ReadDir(filepath.Join(dir, "files"))
	if len(entries) != len(ids) {
		t.Errorf("files/ holds %d files, media.json lists %d", len(entries), len(ids))
	}
	sort.Strings(ids)
	return ids
}

// The full closure: the seeds by type prefix, exact type and id, every
// document their references reach with draft and published rows together,
// the asset documents of the media they use, and only those media files.
func TestExportFollowRefsWritesTheClosureAndItsMedia(t *testing.T) {
	_, ctx := refsSource(t)
	dir := t.TempDir()
	out := filepath.Join(dir, "set.ndjson")
	media := filepath.Join(dir, "media")
	schemas := filepath.Join(dir, "schemas.json")
	var so, se strings.Builder
	code := runExport(newWriter(&so, &se), globals{}, ctx, []string{
		"--type", "pensum*,product", "--id", "deskStructure.pensum", "--follow-refs",
		"--out", out, "--media", media, "--schemas", schemas})
	if code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	got := exportedIDs(t, out)
	want := []string{
		"contributor-1", "deskStructure.pensum", "drafts.asset-" + refAssetA, "drafts.asset-" + refAssetB,
		"drafts.asset-" + refAssetC, "drafts.contributor-1", "organization-1", "pensumBook-1", "pensumShelf-1", "product-1",
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("exported ids in this order:\n %v\nwant\n %v", got, want)
	}
	if m := mediaIDs(t, media); strings.Join(m, ",") != strings.Join([]string{refAssetA, refAssetB, refAssetC}, ",") {
		t.Errorf("media written = %v, want A, B and C and not D", m)
	}
	for _, wantErr := range []string{
		"exported 10 documents", "4 seed id(s), 5 more reached by references",
		"1 referenced id(s) are not in ws/proj/production", "missing-1",
		"exported 3 of the 4 media file(s)",
	} {
		if !strings.Contains(se.String(), wantErr) {
			t.Errorf("stderr does not say %q:\n%s", wantErr, se.String())
		}
	}
	sc, err := readSchemaCopy(schemas)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, s := range sc.Schemas {
		names = append(names, schemaCopyName(s))
	}
	sort.Strings(names)
	if strings.Join(names, ",") != "bioBlock,contributor,pensumBook" {
		t.Errorf("schema file holds %v, want the exported types with a schema and what they use", names)
	}
	if code, _, stderr := runExportVerifyForTest(t, out); code != exitOK {
		t.Errorf("--verify of the subset failed: %s", stderr)
	}
}

func runExportVerifyForTest(t *testing.T, path string) (int, string, string) {
	t.Helper()
	var so, se strings.Builder
	code := runExport(newWriter(&so, &se), globals{}, manifest.Context{}, []string{"--verify", path})
	return code, so.String(), se.String()
}

// --follow-refs=1 stops after one hop: contributor-1 is reached, the
// organization it points at is not.
func TestExportFollowRefsDepthStopsAfterNHops(t *testing.T) {
	_, ctx := refsSource(t)
	out := filepath.Join(t.TempDir(), "set.ndjson")
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, ctx, []string{"--type", "pensumBook", "--follow-refs=1", "--out", out}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	got := strings.Join(exportedIDs(t, out), ",")
	if !strings.Contains(got, "contributor-1") || strings.Contains(got, "organization-1") {
		t.Errorf("one hop exported %s, want contributor-1 and not organization-1", got)
	}
	for _, bad := range []string{"--follow-refs=0", "--follow-refs=x"} {
		var so, se strings.Builder
		if code := runExport(newWriter(&so, &se), globals{}, ctx, []string{"--type", "pensumBook", bad}); code == exitOK {
			t.Errorf("%s was accepted", bad)
		}
	}
	var so2, se2 strings.Builder
	if code := runExport(newWriter(&so2, &se2), globals{}, ctx, []string{"--follow-refs"}); code == exitOK || !strings.Contains(se2.String(), "needs seed documents") {
		t.Errorf("--follow-refs with no seeds: exit %d, stderr %s", code, se2.String())
	}
}

// --id and a * type without --follow-refs export only the seeds, and an id
// the dataset does not hold is named.
func TestExportSeedsWithoutFollowingRefs(t *testing.T) {
	_, ctx := refsSource(t)
	out := filepath.Join(t.TempDir(), "set.ndjson")
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, ctx, []string{"--type", "pensum*", "--id", "deskStructure.pensum,nope", "--out", out}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	if got := strings.Join(exportedIDs(t, out), ","); got != "deskStructure.pensum,pensumBook-1,pensumShelf-1" {
		t.Errorf("exported %s, want the three seeds only", got)
	}
	if !strings.Contains(se.String(), "holds no document with id nope") {
		t.Errorf("stderr does not name the missing id: %s", se.String())
	}
}

// task-c3df8afd76b35c2f, the media half: --type with --media writes only the
// files the exported documents use, and an export of the whole dataset still
// writes every file.
func TestExportTypedMediaWritesOnlyReferencedFiles(t *testing.T) {
	_, ctx := refsSource(t)
	dir := t.TempDir()
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, ctx, []string{"--type", "pensumBook,unrelated",
		"--out", filepath.Join(dir, "b.ndjson"), "--media", filepath.Join(dir, "typed")}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	if m := mediaIDs(t, filepath.Join(dir, "typed")); strings.Join(m, ",") != strings.Join([]string{refAssetA, refAssetB, refAssetD}, ",") {
		t.Errorf("typed export wrote media %v, want A and B from pensumBook-1 and D from unrelated-1", m)
	}
	var so2, se2 strings.Builder
	if code := runExport(newWriter(&so2, &se2), globals{}, ctx, []string{
		"--out", filepath.Join(dir, "all.ndjson"), "--media", filepath.Join(dir, "all")}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se2.String())
	}
	if m := mediaIDs(t, filepath.Join(dir, "all")); len(m) != 4 {
		t.Errorf("whole-dataset export wrote %d media files, want all 4", len(m))
	}
}
