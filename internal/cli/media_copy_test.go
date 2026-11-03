package cli

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// mediaFakeServer adds the media routes `bp export --media` and
// `bp import --media` use to an importFakeServer: the media list, the scoped
// file route, and the upload, which keeps a sent mediaFileId and creates the
// asset document drafts.asset-<id> as the media plugin does.
type mediaFakeServer struct {
	*importFakeServer
	srv    *httptest.Server
	prefix string // the path prefix this instance stores files under
	taken  bool   // every upload answers 409, as when another dataset holds the id
	noSHA1 bool   // the media list answers sha1 null, as for rows born before the column

	uploads int      // uploads received
	deletes []string // DELETE requests received, path and query

	mu    sync.Mutex
	files map[string]mediaCopyAsset
	bytes map[string][]byte
}

func newMediaFakeServer(t *testing.T, prefix string) *mediaFakeServer {
	t.Helper()
	m := &mediaFakeServer{importFakeServer: newImportFakeServer(t), prefix: prefix,
		files: map[string]mediaCopyAsset{}, bytes: map[string][]byte{}}
	m.srv = httptest.NewServer(http.HandlerFunc(m.handle))
	t.Cleanup(m.srv.Close)
	return m
}

func (m *mediaFakeServer) ctx() manifest.Context {
	return manifest.Context{Server: m.srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}
}

func (m *mediaFakeServer) store(id, name string, data []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	sum := sha1.Sum(data)
	path := m.prefix + "/" + id + "-" + name
	m.files[id] = mediaCopyAsset{ID: id, SHA1: hex.EncodeToString(sum[:]), Size: int64(len(data)), OriginalName: name, MimeType: "image/png", Path: path}
	m.bytes[id] = data
	m.seed("drafts.asset-"+id, "mediaAsset", map[string]any{
		"mediaFileId": id, "altText": "",
		"fileInfo": map[string]any{"path": path, "url": "/media/files/" + path, "originalName": name},
	})
}

func (m *mediaFakeServer) handle(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/w/ws/p/proj/v1/media/production":
		m.mu.Lock()
		assets := []mediaCopyAsset{}
		for _, f := range m.files {
			if m.noSHA1 {
				f.SHA1 = ""
			}
			assets = append(assets, f)
		}
		m.mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"assets": assets, "hasMore": false}})
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/w/ws/p/proj/media/files/"):
		path := strings.TrimPrefix(r.URL.Path, "/w/ws/p/proj/media/files/")
		m.mu.Lock()
		defer m.mu.Unlock()
		for id, f := range m.files {
			if f.Path == path {
				_, _ = w.Write(m.bytes[id])
				return
			}
		}
		http.NotFound(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/w/ws/p/proj/v1/media/production/upload":
		if err := r.ParseMultipartForm(10 << 20); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		file, hdr, err := r.FormFile("file")
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		data, _ := io.ReadAll(file)
		id := r.FormValue("mediaFileId")
		m.mu.Lock()
		m.uploads++
		m.mu.Unlock()
		if m.taken {
			w.WriteHeader(http.StatusConflict)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": "conflict", "message": "document already exists"}})
			return
		}
		if id == "" {
			id = fmt.Sprintf("new-%d", len(m.files)+1)
		}
		m.mu.Lock()
		_, existed := m.files[id]
		m.mu.Unlock()
		if !existed {
			m.store(id, hdr.Filename, data)
		}
		m.mu.Lock()
		f := m.files[id]
		m.mu.Unlock()
		status := http.StatusCreated
		if existed {
			status = http.StatusOK
		}
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"id": f.ID, "sha1": f.SHA1, "path": f.Path, "assetDocId": "drafts.asset-" + f.ID}, "existing": existed})
	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/w/ws/p/proj/v1/media/production/"):
		id := strings.TrimPrefix(r.URL.Path, "/w/ws/p/proj/v1/media/production/")
		m.mu.Lock()
		m.deletes = append(m.deletes, id+"?"+r.URL.RawQuery)
		_, ok := m.files[id]
		delete(m.files, id)
		delete(m.bytes, id)
		m.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		m.importFakeServer.mu.Lock()
		delete(m.docs, "drafts.asset-"+id)
		m.importFakeServer.mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"deleted": id}})
	default:
		m.importFakeServer.handle(w, r)
	}
}

// MEDIA COPY (task-fa5aedea4a584d34). Export a dataset with its media,
// import both into an empty target, and the target holds every file under the
// same asset id with the same SHA-1, byte duplicates included. The asset
// documents keep their exported fields and point at the target's copy.
func TestExportImportMediaKeepsAssetIDs(t *testing.T) {
	src := newMediaFakeServer(t, "d/source")
	src.store("11111111-1111-1111-1111-111111111111", "a.png", []byte("png bytes a"))
	src.store("22222222-2222-2222-2222-222222222222", "dup.png", []byte("same bytes"))
	src.store("33333333-3333-3333-3333-333333333333", "dup.png", []byte("same bytes"))
	src.seed("post-1", "post", map[string]any{"image": map[string]any{"asset": map[string]any{"_ref": "asset-11111111-1111-1111-1111-111111111111"}}})
	// The source's asset document carries an edit the import must keep.
	src.seed("drafts.asset-11111111-1111-1111-1111-111111111111", "mediaAsset", map[string]any{
		"mediaFileId": "11111111-1111-1111-1111-111111111111", "altText": "A red square",
		"fileInfo": map[string]any{"path": src.files["11111111-1111-1111-1111-111111111111"].Path, "originalName": "a.png"},
	})

	dir := t.TempDir()
	backup := filepath.Join(dir, "backup.ndjson")
	mediaDir := filepath.Join(dir, "media")
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, src.ctx(), []string{"--out", backup, "--media", mediaDir}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	if !strings.Contains(se.String(), "exported 3 media file(s)") {
		t.Errorf("export stderr = %s, want the media count", se.String())
	}

	dst := newMediaFakeServer(t, "d/target")
	for run := 1; run <= 2; run++ {
		code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--media", mediaDir, "--overwrite")
		if code != exitOK {
			t.Fatalf("import run %d exit = %d; stdout=%s stderr=%s", run, code, stdout, stderr)
		}
	}
	if len(dst.files) != 3 {
		t.Fatalf("target holds %d files, want 3", len(dst.files))
	}
	for id, want := range src.files {
		got, ok := dst.files[id]
		if !ok || got.SHA1 != want.SHA1 {
			t.Errorf("file %s on the target = %+v, want sha1 %s", id, got, want.SHA1)
		}
	}
	doc := dst.docs["drafts.asset-11111111-1111-1111-1111-111111111111"]
	var alt string
	_ = json.Unmarshal(doc["altText"], &alt)
	var info map[string]string
	_ = json.Unmarshal(doc["fileInfo"], &info)
	if alt != "A red square" || !strings.HasPrefix(info["path"], "d/target/") || info["url"] != "/media/files/"+info["path"] || info["originalName"] != "a.png" {
		t.Errorf("asset document on the target = alt %q fileInfo %v, want the exported fields with the target's path", alt, info)
	}
	if _, ok := dst.docs["post-1"]; !ok {
		t.Error("post-1 was not imported")
	}
}

// Without --overwrite a second run is still not refused for the asset
// documents its own uploads made.
func TestImportMediaRerunIsNotACollision(t *testing.T) {
	src := newMediaFakeServer(t, "d/source")
	src.store("44444444-4444-4444-4444-444444444444", "b.png", []byte("b"))
	dir := t.TempDir()
	backup := filepath.Join(dir, "backup.ndjson")
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, src.ctx(), []string{"--out", backup, "--media", dir}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	dst := newMediaFakeServer(t, "d/target")
	for run := 1; run <= 2; run++ {
		if code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--media", dir); code != exitOK {
			t.Fatalf("run %d exit = %d; stdout=%s stderr=%s", run, code, stdout, stderr)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, mediaCopyManifest)); err != nil {
		t.Fatal(err)
	}
}

// Media file ids are unique per instance, so an import into a second dataset
// on the same instance is refused 409. The error names that cause and the
// SELF-HOST-MOVE.md section.
func TestImportMediaSameInstanceConflictNamesCause(t *testing.T) {
	src := newMediaFakeServer(t, "d/source")
	src.store("55555555-5555-5555-5555-555555555555", "c.png", []byte("c"))
	dir := t.TempDir()
	backup := filepath.Join(dir, "backup.ndjson")
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, src.ctx(), []string{"--out", backup, "--media", dir}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	dst := newMediaFakeServer(t, "d/target")
	dst.taken = true
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--media", dir)
	if code == exitOK {
		t.Fatalf("import exit = 0, want a refusal; stdout=%s", stdout)
	}
	all := stdout + stderr
	for _, want := range []string{"unique per instance", "SELF-HOST-MOVE.md#copy-one-dataset-over-the-api"} {
		if !strings.Contains(all, want) {
			t.Errorf("import output lacks %q: %s", want, all)
		}
	}
}

// mediaCopyExport writes a source with three files to dir and returns the
// NDJSON path and the media directory.
func mediaCopyExport(t *testing.T) (*mediaFakeServer, string, string) {
	t.Helper()
	src := newMediaFakeServer(t, "d/source")
	src.store("a1111111-1111-1111-1111-111111111111", "a.png", []byte("png bytes a"))
	src.store("b2222222-2222-2222-2222-222222222222", "b.png", []byte("png bytes b"))
	src.store("c3333333-3333-3333-3333-333333333333", "c.png", []byte("png bytes c"))
	src.seed("post-1", "post", map[string]any{"title": "One"})
	src.seed("post-2", "post", map[string]any{"title": "Two"})
	dir := t.TempDir()
	backup := filepath.Join(dir, "backup.ndjson")
	mediaDir := filepath.Join(dir, "media")
	var so, se strings.Builder
	if code := runExport(newWriter(&so, &se), globals{}, src.ctx(), []string{"--out", backup, "--media", mediaDir}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	return src, backup, mediaDir
}

// RESUME SKIPS WHAT THE TARGET HOLDS (task-634da0d58fbf2543). The target
// already holds two of the three files with the same bytes, as after a
// stopped run. The import sends only the third, says how many it skipped, and
// still points each skipped asset document at the target's copy. A second
// run with --from-line sends nothing.
func TestImportMediaSkipsFilesTheTargetHolds(t *testing.T) {
	src, backup, mediaDir := mediaCopyExport(t)
	dst := newMediaFakeServer(t, "d/target")
	dst.store("a1111111-1111-1111-1111-111111111111", "a.png", []byte("png bytes a"))
	dst.store("b2222222-2222-2222-2222-222222222222", "b.png", []byte("png bytes b"))

	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--media", mediaDir)
	if code != exitOK {
		t.Fatalf("import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if dst.uploads != 1 {
		t.Errorf("target received %d upload(s), want 1", dst.uploads)
	}
	if want := "1 media file(s) uploaded with their asset ids, 2 already on the target and skipped"; !strings.Contains(stdout, want) {
		t.Errorf("stdout lacks %q: %s", want, stdout)
	}
	if strings.Contains(stdout, "size only") {
		t.Errorf("stdout reports a size-only match although both sides have SHA-1: %s", stdout)
	}
	for id, want := range src.files {
		if got := dst.files[id]; got.SHA1 != want.SHA1 {
			t.Errorf("file %s on the target has sha1 %q, want %q", id, got.SHA1, want.SHA1)
		}
	}
	var info map[string]string
	_ = json.Unmarshal(dst.docs["drafts.asset-a1111111-1111-1111-1111-111111111111"]["fileInfo"], &info)
	if !strings.HasPrefix(info["path"], "d/target/") {
		t.Errorf("skipped asset fileInfo = %v, want the target's path", info)
	}

	code, stdout, stderr = runImportForTest(t, dst.ctx(), globals{}, backup, "--media", mediaDir, "--overwrite", "--from-line", "2")
	if code != exitOK {
		t.Fatalf("resumed import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if dst.uploads != 1 {
		t.Errorf("the resumed import sent %d more upload(s), want 0", dst.uploads-1)
	}
	if want := "0 media file(s) uploaded with their asset ids, 3 already on the target and skipped"; !strings.Contains(stdout, want) {
		t.Errorf("resumed stdout lacks %q: %s", want, stdout)
	}
}

// A target that lists no SHA-1 is matched by size, and the report says how
// many files that covers.
func TestImportMediaSkipBySizeOnlyIsReported(t *testing.T) {
	_, backup, mediaDir := mediaCopyExport(t)
	dst := newMediaFakeServer(t, "d/target")
	dst.store("a1111111-1111-1111-1111-111111111111", "a.png", []byte("png bytes a"))
	dst.noSHA1 = true

	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--media", mediaDir)
	if code != exitOK {
		t.Fatalf("import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if dst.uploads != 2 {
		t.Errorf("target received %d upload(s), want 2", dst.uploads)
	}
	if want := "1 skipped file(s) were matched by size only"; !strings.Contains(stdout, want) {
		t.Errorf("stdout lacks %q: %s", want, stdout)
	}
}

// SAME ID, OTHER BYTES. The target holds an id with another size. The dry run
// and the import both refuse, name the id and both sizes, and write nothing.
// --replace-media deletes the target's file with force=true and uploads the
// exported one.
func TestImportMediaRefusesSameIDWithOtherBytes(t *testing.T) {
	src, backup, mediaDir := mediaCopyExport(t)
	dst := newMediaFakeServer(t, "d/target")
	const id = "b2222222-2222-2222-2222-222222222222"
	dst.store(id, "b.png", []byte("other, longer bytes"))

	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--media", mediaDir, "--dry-run")
	if code != exitConflict {
		t.Fatalf("dry run exit = %d, want %d; stdout=%s stderr=%s", code, exitConflict, stdout, stderr)
	}

	code, stdout, stderr = runImportForTest(t, dst.ctx(), globals{}, backup, "--media", mediaDir)
	if code != exitConflict {
		t.Fatalf("import exit = %d, want %d; stdout=%s stderr=%s", code, exitConflict, stdout, stderr)
	}
	all := stdout + stderr
	for _, want := range []string{id + " (target 19 bytes, export 11 bytes)", "Nothing was written", "--replace-media"} {
		if !strings.Contains(all, want) {
			t.Errorf("refusal lacks %q: %s", want, all)
		}
	}
	if dst.uploads != 0 || len(dst.deletes) != 0 {
		t.Errorf("a refused import sent %d upload(s) and %d delete(s), want none", dst.uploads, len(dst.deletes))
	}
	if _, ok := dst.docs["post-1"]; ok {
		t.Error("a refused import wrote post-1")
	}

	code, stdout, stderr = runImportForTest(t, dst.ctx(), globals{}, backup, "--media", mediaDir, "--replace-media", "--overwrite")
	if code != exitOK {
		t.Fatalf("import --replace-media exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if len(dst.deletes) != 1 || dst.deletes[0] != id+"?force=true" {
		t.Errorf("deletes = %v, want one forced delete of %s", dst.deletes, id)
	}
	if got := dst.files[id]; got.SHA1 != src.files[id].SHA1 {
		t.Errorf("file %s on the target has sha1 %q, want the export's %q", id, got.SHA1, src.files[id].SHA1)
	}
	if want := "1 of the sent replace a file with other bytes"; !strings.Contains(stdout, want) {
		t.Errorf("stdout lacks %q: %s", want, stdout)
	}
}

func TestImportReplaceMediaNeedsMedia(t *testing.T) {
	_, backup, _ := mediaCopyExport(t)
	dst := newMediaFakeServer(t, "d/target")
	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, backup, "--replace-media")
	if code != exitUsage || !strings.Contains(stderr, "--replace-media works only with --media") {
		t.Errorf("exit = %d stderr = %s, want a usage error", code, stderr)
	}
}
