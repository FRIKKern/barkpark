package apiclient

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

// PaperDoc must GET the scoped /v1/data/doc/<dataset>/paper/<slug>, carry the
// bearer token, append ?perspective when non-empty, and hand back the JSON of
// the response envelope's "result" object (the bare paper document).
func TestPaperDocRequestShapeAndUnwrap(t *testing.T) {
	var seen url.URL
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = *r.URL
		auth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"result":{"_id":"drafts.p1","title":"Charter","_rev":"rev-9","blocks":[{"type":"heading"}]},"etag":"x"}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "tok-abc", Workspace: "ws", Project: "proj", Dataset: "production"})

	raw, err := c.PaperDoc("production", "drafts.p1", "drafts")
	if err != nil {
		t.Fatalf("PaperDoc: %v", err)
	}
	if seen.Path != "/w/ws/p/proj/v1/data/doc/production/paper/drafts.p1" {
		t.Errorf("path = %q, want the scoped paper-doc path", seen.Path)
	}
	if auth != "Bearer tok-abc" {
		t.Errorf("auth header = %q, want Bearer tok-abc", auth)
	}
	if seen.Query().Get("perspective") != "drafts" {
		t.Errorf("perspective = %q, want drafts", seen.Query().Get("perspective"))
	}
	// The returned bytes must be the UNWRAPPED result object, not the envelope.
	got := string(raw)
	want := `{"_id":"drafts.p1","title":"Charter","_rev":"rev-9","blocks":[{"type":"heading"}]}`
	if got != want {
		t.Errorf("PaperDoc result\n got: %s\nwant: %s", got, want)
	}
}

// The dataset argument (not the client's configured Dataset) drives the path
// segment, and a slug with reserved characters is PathEscaped.
func TestPaperDocEscapesSlugAndUsesArgDataset(t *testing.T) {
	var seen url.URL
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = *r.URL
		_, _ = w.Write([]byte(`{"result":{"title":"x"}}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production"})

	if _, err := c.PaperDoc("staging", "a b/c", ""); err != nil {
		t.Fatalf("PaperDoc: %v", err)
	}
	// httptest decodes the path back to its raw form; the dataset arg wins.
	if seen.Path != "/w/ws/p/proj/v1/data/doc/staging/paper/a b/c" {
		t.Errorf("path = %q, want the arg-dataset + escaped-slug path", seen.Path)
	}
	if seen.Query().Has("perspective") {
		t.Errorf("perspective must be omitted when empty, got %q", seen.Query().Get("perspective"))
	}
}

// A non-2xx status is a typed error carrying the server's reason preview, not a
// silent empty document.
func TestPaperDocErrorsOnNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"not_found"}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production"})

	if _, err := c.PaperDoc("production", "ghost", ""); err == nil {
		t.Fatalf("PaperDoc on 404 must error")
	}
}

// A flat/legacy body with no "result" wrapper is handed back verbatim.
func TestPaperDocPassesThroughUnwrappedBody(t *testing.T) {
	body := `{"_id":"p2","title":"Flat","blocks":[]}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production"})

	raw, err := c.PaperDoc("production", "p2", "")
	if err != nil {
		t.Fatalf("PaperDoc: %v", err)
	}
	if string(raw) != body {
		t.Errorf("flat body\n got: %s\nwant: %s", string(raw), body)
	}
}
