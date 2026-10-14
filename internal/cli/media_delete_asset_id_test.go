package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const testMediaFileID = "6f1c2a9e-4b7d-4c1e-9a55-0d3e2f1b7c88"

func mediaDeleteManifest() (*manifest.Manifest, manifest.Command) {
	del := manifest.Command{
		ID: "media.delete", Noun: "media", Verb: "delete",
		AuthTier: "write", Writes: true, DefaultOutput: "minimal",
		HTTP: manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/media/:dataset/:id"},
		Args: []manifest.Arg{{Name: "id", Required: true, Type: "string"}},
	}
	get := manifest.Command{
		ID: "doc.get", Noun: "doc", Verb: "get",
		AuthTier: "none",
		HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:id"},
		Args: []manifest.Arg{
			{Name: "type", Required: true, Type: "string"},
			{Name: "id", Required: true, Type: "string"},
		},
		Flags: []manifest.Flag{{Name: "perspective", Type: "string", Default: "published"}},
	}
	return &manifest.Manifest{Commands: []manifest.Command{del, get}}, del
}

// mediaServer answers the asset document read and the media delete the way
// the server does: the delete route knows only media file ids, the document
// read finds `asset-<id>` under the drafts perspective. assetReadable=false
// makes the document read answer 404, to exercise the fallback.
type mediaServer struct {
	mu            sync.Mutex
	assetReadable bool
	deletes       []string
	reads         []string
}

func (s *mediaServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	switch {
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/data/doc/production/mediaAsset/"):
		s.reads = append(s.reads, r.URL.Path+"?"+r.URL.RawQuery)
		if !s.assetReadable {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"document not found"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"result":{"_id":"drafts.asset-` + testMediaFileID + `","_type":"mediaAsset","_draft":true,"mediaFileId":"` + testMediaFileID + `"}}`))
	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/media/production/"):
		id := strings.TrimPrefix(r.URL.Path, "/v1/media/production/")
		s.deletes = append(s.deletes, id)
		if id != testMediaFileID {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"media file not found"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"result":{"deleted":"` + id + `","filename":"a.jpg","dataset":"production"}}`))
	default:
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no route"}}`))
	}
}

func runMediaDelete(t *testing.T, srv *mediaServer, id string) (int, string) {
	t.Helper()
	ts := httptest.NewServer(srv)
	t.Cleanup(ts.Close)
	m, del := mediaDeleteManifest()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{yes: true}
	out.applyGlobals(g)
	ctx := manifest.Context{Server: ts.URL, Token: "tok", Dataset: "production"}
	code := runCommand(out, g, ctx, m, del, []string{id})
	return code, stderr.String()
}

// The id `bp media upload` hands back, in both spellings, deletes the media
// file. The asset document is read and its mediaFileId is what reaches the
// delete route.
func TestMediaDeleteAcceptsTheUploadAssetID(t *testing.T) {
	for _, id := range []string{"asset-" + testMediaFileID, "drafts.asset-" + testMediaFileID} {
		t.Run(id, func(t *testing.T) {
			srv := &mediaServer{assetReadable: true}
			code, stderr := runMediaDelete(t, srv, id)
			if code != exitOK {
				t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
			}
			if len(srv.reads) != 1 || !strings.Contains(srv.reads[0], "asset-"+testMediaFileID) || !strings.Contains(srv.reads[0], "perspective=drafts") {
				t.Fatalf("asset document reads = %q, want one drafts-perspective read of asset-<id>", srv.reads)
			}
			if len(srv.deletes) != 1 || srv.deletes[0] != testMediaFileID {
				t.Fatalf("deletes = %q, want exactly the media file id %s", srv.deletes, testMediaFileID)
			}
			if !strings.Contains(stderr, "mediaFileId") {
				t.Errorf("stderr does not say how the id was resolved: %q", stderr)
			}
		})
	}
}

// When the asset document cannot be read, the id after `asset-` is used, which
// is how the server names the document in the first place.
func TestMediaDeleteFallsBackToTheIDInsideTheAssetID(t *testing.T) {
	srv := &mediaServer{assetReadable: false}
	code, stderr := runMediaDelete(t, srv, "drafts.asset-"+testMediaFileID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
	}
	if len(srv.deletes) != 1 || srv.deletes[0] != testMediaFileID {
		t.Fatalf("deletes = %q, want the media file id %s", srv.deletes, testMediaFileID)
	}
}

// A media file id goes straight to the delete route: no document read, no note.
func TestMediaDeleteWithAMediaFileIDIsUnchanged(t *testing.T) {
	srv := &mediaServer{assetReadable: true}
	code, stderr := runMediaDelete(t, srv, testMediaFileID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
	}
	if len(srv.reads) != 0 {
		t.Fatalf("a media file id triggered an asset document read: %q", srv.reads)
	}
	if len(srv.deletes) != 1 || srv.deletes[0] != testMediaFileID {
		t.Fatalf("deletes = %q", srv.deletes)
	}
	if strings.Contains(stderr, "note:") {
		t.Errorf("unexpected note on stderr: %q", stderr)
	}
}
