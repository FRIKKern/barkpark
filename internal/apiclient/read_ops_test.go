package apiclient

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

// captureGet answers GETs with body and records the request URL.
func captureGet(t *testing.T, body string, seen *url.URL) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := *r.URL
		*seen = u
		_, _ = w.Write([]byte(body))
	}))
}

// Search must GET the scoped /v1/data/search/<dataset> with a URL-encoded `q`,
// the `limit` when > 0, and `perspective` when the client sets one; a wrong
// param name or unescaped query would silently break search.
func TestSearchRequestShapeAndDecode(t *testing.T) {
	var seen url.URL
	srv := captureGet(t, `{"documents":[{"_id":"p1"},{"_id":"p2"}]}`, &seen)
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production", Perspective: "drafts"})

	docs, err := c.Search("a b&c", 10)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if seen.Path != "/w/ws/p/proj/v1/data/search/production" {
		t.Errorf("path = %q, want the scoped search path", seen.Path)
	}
	q := seen.Query()
	if q.Get("q") != "a b&c" {
		t.Errorf("q = %q, want the raw query decoded back (encoding round-trip)", q.Get("q"))
	}
	if q.Get("limit") != "10" {
		t.Errorf("limit = %q, want 10", q.Get("limit"))
	}
	if q.Get("perspective") != "drafts" {
		t.Errorf("perspective = %q, want drafts", q.Get("perspective"))
	}
	if len(docs) != 2 {
		t.Errorf("decoded %d docs, want 2", len(docs))
	}
}

func TestSearchOmitsLimitWhenZeroAndPerspectiveWhenUnset(t *testing.T) {
	var seen url.URL
	srv := captureGet(t, `{"documents":[]}`, &seen)
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production"})

	if _, err := c.Search("x", 0); err != nil {
		t.Fatalf("Search: %v", err)
	}
	q := seen.Query()
	if q.Has("limit") {
		t.Errorf("limit must be omitted when 0, got %q", q.Get("limit"))
	}
	if q.Has("perspective") {
		t.Errorf("perspective must be omitted when unset, got %q", q.Get("perspective"))
	}
}

// History GETs the scoped /v1/data/history/<ds>/<type>/<id> with type+id
// PathEscaped and `limit` gated, decoding {revisions:[...]}.
func TestHistoryRequestShapeAndDecode(t *testing.T) {
	var seen url.URL
	srv := captureGet(t, `{"revisions":[{},{},{}]}`, &seen)
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production"})

	revs, err := c.History("post", "p 1", 5)
	if err != nil {
		t.Fatalf("History: %v", err)
	}
	if seen.EscapedPath() != "/w/ws/p/proj/v1/data/history/production/post/p%201" {
		t.Errorf("path = %q, want type+id PathEscaped", seen.EscapedPath())
	}
	if seen.Query().Get("limit") != "5" {
		t.Errorf("limit = %q, want 5", seen.Query().Get("limit"))
	}
	if len(revs) != 3 {
		t.Errorf("decoded %d revisions, want 3", len(revs))
	}
}

// RevisionDoc GETs the scoped /v1/data/revision/<ds>/<id> with the id
// PathEscaped.
func TestRevisionDocRequestShape(t *testing.T) {
	var seen url.URL
	srv := captureGet(t, `{"revision":{"_id":"r1","content":{}}}`, &seen)
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production"})

	if _, err := c.RevisionDoc("rev/1"); err != nil {
		t.Fatalf("RevisionDoc: %v", err)
	}
	if seen.EscapedPath() != "/w/ws/p/proj/v1/data/revision/production/rev%2F1" {
		t.Errorf("path = %q, want the id PathEscaped", seen.EscapedPath())
	}
}
