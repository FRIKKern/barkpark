package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Every new paper starts as a draft, and `bp paper view` reads the published
// perspective. The first view of one's own paper failed with a bare 404 and no
// pointer (r4-lane-c dogfood: `bp paper view paper-4e96…` → status 404, exit 4,
// while `--perspective drafts` rendered it). The 404 now names the way in.
func paperDraftOnlyServer(t *testing.T, draftExists bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Query().Get("perspective") == "drafts" && draftExists {
			_, _ = w.Write([]byte(`{"_id":"drafts.paper-new","_draft":true,"blocks":[{"type":"paragraph","text":"wip"}]}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"not found"}}`))
	}))
}

func runPaperViewAgainst(t *testing.T, srv *httptest.Server, token string) (int, string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("BARKPARK_API_URL", "")
	t.Setenv("BARKPARK_API_TOKEN", "")
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	code := runPaperView(out, globals{server: srv.URL, token: token}, []string{"paper-new"})
	return code, stderr.String()
}

func TestPaperViewOnADraftOnlyPaperNamesTheDraftsPerspective(t *testing.T) {
	srv := paperDraftOnlyServer(t, true)
	defer srv.Close()

	code, stderr := runPaperViewAgainst(t, srv, "tok")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (the published read still 404s)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "bp paper view paper-new --perspective drafts") {
		t.Fatalf("the 404 does not point at the draft:\n%s", stderr)
	}
}

func TestPaperViewMissingPaperGetsNoDraftHint(t *testing.T) {
	srv := paperDraftOnlyServer(t, false)
	defer srv.Close()

	code, stderr := runPaperViewAgainst(t, srv, "tok")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if strings.Contains(stderr, "--perspective drafts") {
		t.Fatalf("a paper with no draft either got the draft hint:\n%s", stderr)
	}
}
