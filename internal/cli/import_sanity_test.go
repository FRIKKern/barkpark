package cli

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-936c12b4a6f29030 — `bp import <sanity export.tar.gz>` uploads each
// asset file once and rewrites every image/file value to a Barkpark asset ref.

const (
	sanityShaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	sanityShaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

// sanityFakeServer wraps importFakeServer with the media upload route. Each
// upload gets a new asset; the receipt names its draft asset doc id, as the
// real upload receipt can.
type sanityFakeServer struct {
	*importFakeServer
	srv *httptest.Server

	mu      sync.Mutex
	uploads []string // filename of each upload, in order
}

func newSanityFakeServer(t *testing.T) *sanityFakeServer {
	t.Helper()
	s := &sanityFakeServer{importFakeServer: newImportFakeServer(t)}
	s.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/w/ws/p/proj/v1/media/production/upload" {
			f, h, err := r.FormFile("file")
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			f.Close()
			s.mu.Lock()
			s.uploads = append(s.uploads, h.Filename)
			n := len(s.uploads)
			s.mu.Unlock()
			w.WriteHeader(http.StatusCreated)
			_, _ = fmt.Fprintf(w, `{"result":{"id":"file-%d","assetDocId":"drafts.asset-%d"}}`, n, n)
			return
		}
		s.importFakeServer.handle(w, r)
	}))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *sanityFakeServer) ctx() manifest.Context {
	return manifest.Context{Server: s.srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}
}

func (s *sanityFakeServer) uploadCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.uploads)
}

// writeSanityTarball builds a tarball shaped like `sanity dataset export`
// output: one top directory with data.ndjson, assets.json and the files.
func writeSanityTarball(t *testing.T, lines []string, files map[string]string, extra ...string) string {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	add := func(name, body string) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	add("production-export/data.ndjson", strings.Join(lines, "\n")+"\n")
	add("production-export/assets.json", `{"image-`+sanityShaA+`-10x10-png":{"originalFilename":"hero.png"}}`)
	for name, body := range files {
		add("production-export/"+name, body)
	}
	for _, name := range extra {
		add(name, "x")
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "production.tar.gz")
	if err := os.WriteFile(p, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

var sanityFixtureLines = []string{
	// The export's own shape: _sanityAsset in place of asset.
	`{"_id":"post-1","_type":"post","title":"One","hero":{"_type":"image","_sanityAsset":"image@file://./images/` + sanityShaA + `-10x10.png","hotspot":{"x":0.5,"y":0.5,"height":1,"width":1}},"brochure":{"_type":"file","_sanityAsset":"file@file://./files/` + sanityShaB + `.pdf"}}`,
	// The same image again, in an array, and as Sanity's own ref shape.
	`{"_id":"post-2","_type":"post","title":"Two","gallery":[{"_key":"k1","_type":"image","_sanityAsset":"image@file://./images/` + sanityShaA + `-10x10.png"},{"_key":"k2","_type":"image","asset":{"_type":"reference","_ref":"image-` + sanityShaA + `-10x10-png"}}],"author":{"_type":"reference","_ref":"author-1"}}`,
	// A document with no asset, copied as-is.
	`{"_id":"author-1","_type":"author","name":"Åse"}`,
	// Sanity's own asset document: not imported.
	`{"_id":"image-` + sanityShaA + `-10x10-png","_type":"sanity.imageAsset","url":"https://cdn.sanity.io/x.png"}`,
}

var sanityFixtureFiles = map[string]string{
	"images/" + sanityShaA + "-10x10.png": "\x89PNG fake",
	"files/" + sanityShaB + ".pdf":        "%PDF fake",
}

func sanityAssetRef(t *testing.T, v any) string {
	t.Helper()
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("want an asset holder object, got %#v", v)
	}
	if _, left := m["_sanityAsset"]; left {
		t.Errorf("_sanityAsset survived the import: %#v", m)
	}
	a, _ := m["asset"].(map[string]any)
	if a["_type"] != "reference" {
		t.Errorf("asset is not a reference: %#v", m["asset"])
	}
	ref, _ := a["_ref"].(string)
	return ref
}

func TestRunImportSanityTarballUploadsAssetsOnceAndRewritesRefs(t *testing.T) {
	f := newSanityFakeServer(t)
	tarball := writeSanityTarball(t, sanityFixtureLines, sanityFixtureFiles)

	code, _, stderr := runImportForTest(t, f.ctx(), globals{}, tarball)
	if code != exitOK {
		t.Fatalf("import exit = %d; stderr=%s", code, stderr)
	}
	// Two distinct files (the image is referenced three times), two uploads.
	// Uploads go in Sanity asset id order, so the file (file-…) is asset-1
	// and the image (image-…) asset-2.
	if got := f.uploads; len(got) != 2 || got[1] != "hero.png" {
		t.Fatalf("uploads = %v, want 2 with the image named by assets.json", got)
	}

	docs := importDocsByID(t, importExportTo(t, f.importFakeServer))
	if len(docs) != 3 {
		t.Fatalf("imported %d documents, want 3 (the sanity.imageAsset row is not imported): %v", len(docs), docs)
	}
	imageRef := sanityAssetRef(t, docs["post-1"]["hero"])
	fileRef := sanityAssetRef(t, docs["post-1"]["brochure"])
	if imageRef != "asset-2" || fileRef != "asset-1" {
		t.Errorf("refs = %q, %q; want the published asset ids asset-2, asset-1", imageRef, fileRef)
	}
	if hs, _ := docs["post-1"]["hero"].(map[string]any)["hotspot"].(map[string]any); hs["x"] != 0.5 {
		t.Errorf("the hotspot beside the asset was lost: %#v", docs["post-1"]["hero"])
	}
	gallery := docs["post-2"]["gallery"].([]any)
	for i, item := range gallery {
		if got := sanityAssetRef(t, item); got != "asset-2" {
			t.Errorf("gallery[%d] ref = %q, want asset-2 (the same image, uploaded once)", i, got)
		}
	}
	if author := docs["post-2"]["author"].(map[string]any); author["_ref"] != "author-1" {
		t.Errorf("a document reference was rewritten: %#v", author)
	}

	// The re-run uploads nothing: the sidecar maps both assets for this scope.
	code, _, stderr = runImportForTest(t, f.ctx(), globals{}, tarball, "--overwrite")
	if code != exitOK {
		t.Fatalf("re-run exit = %d; stderr=%s", code, stderr)
	}
	if n := f.uploadCount(); n != 2 {
		t.Errorf("re-run uploaded again: %d uploads in total, want 2", n)
	}
	docs = importDocsByID(t, importExportTo(t, f.importFakeServer))
	if got := sanityAssetRef(t, docs["post-1"]["hero"]); got != "asset-2" {
		t.Errorf("re-run ref = %q, want asset-2 from the sidecar", got)
	}
}

func TestRunImportSanityDryRunUploadsAndWritesNothing(t *testing.T) {
	f := newSanityFakeServer(t)
	tarball := writeSanityTarball(t, sanityFixtureLines, sanityFixtureFiles)

	code, stdout, stderr := runImportForTest(t, f.ctx(), globals{}, tarball, "--dry-run")
	if code != exitOK {
		t.Fatalf("dry run exit = %d; stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "2 asset(s) referenced by 4 value(s): 2 to upload") {
		t.Errorf("dry run does not report the assets: %s", stdout)
	}
	if f.uploadCount() != 0 || len(f.requests) != 0 {
		t.Errorf("dry run sent %d uploads and %d mutate requests, want none", f.uploadCount(), len(f.requests))
	}
	if _, err := os.Stat(tarball + sanityAssetsSuffix); !os.IsNotExist(err) {
		t.Errorf("dry run wrote the assets sidecar")
	}
}

func TestRunImportSanityMissingAssetFileRefusesBeforeAnyWrite(t *testing.T) {
	f := newSanityFakeServer(t)
	files := map[string]string{"images/" + sanityShaA + "-10x10.png": "\x89PNG fake"} // the pdf is missing
	tarball := writeSanityTarball(t, sanityFixtureLines, files)

	code, _, stderr := runImportForTest(t, f.ctx(), globals{}, tarball)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d; stderr=%s", code, exitValidation, stderr)
	}
	if !strings.Contains(stderr, "files/"+sanityShaB+".pdf (line 1)") {
		t.Errorf("the refusal does not name the missing file and line: %s", stderr)
	}
	if f.uploadCount() != 0 || len(f.requests) != 0 {
		t.Errorf("a refused import sent %d uploads and %d mutate requests", f.uploadCount(), len(f.requests))
	}
}

func TestRunImportSanityCollisionRefusalUploadsNothing(t *testing.T) {
	f := newSanityFakeServer(t)
	f.seed("post-1", "post", map[string]any{"title": "Already here"})
	tarball := writeSanityTarball(t, sanityFixtureLines, sanityFixtureFiles)

	code, _, stderr := runImportForTest(t, f.ctx(), globals{}, tarball)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d; stderr=%s", code, exitConflict, stderr)
	}
	if f.uploadCount() != 0 {
		t.Errorf("a refused import uploaded %d asset(s)", f.uploadCount())
	}
}

func TestRunImportSanityRefusesEntryOutsideTheExport(t *testing.T) {
	f := newSanityFakeServer(t)
	tarball := writeSanityTarball(t, sanityFixtureLines, sanityFixtureFiles, "production-export/../../evil")

	code, _, stderr := runImportForTest(t, f.ctx(), globals{}, tarball)
	if code != exitValidation || !strings.Contains(stderr, "points outside the export") {
		t.Fatalf("exit = %d, stderr=%s; want a validation refusal naming the entry", code, stderr)
	}
}

func TestSanityAssetIDRoundTrip(t *testing.T) {
	for v, want := range map[string]string{
		"image@file://./images/" + sanityShaA + "-10x10.png": "image-" + sanityShaA + "-10x10-png",
		"file@file://./files/" + sanityShaB + ".pdf":         "file-" + sanityShaB + "-pdf",
	} {
		got, err := sanityAssetID(v)
		if err != nil || got != want {
			t.Errorf("sanityAssetID(%q) = %q, %v; want %q", v, got, err, want)
		}
	}
	if _, err := sanityAssetID("image@https://cdn.sanity.io/x.png"); err == nil {
		t.Errorf("a remote _sanityAsset was accepted")
	}
}
