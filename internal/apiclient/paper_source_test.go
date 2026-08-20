package apiclient

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestPaperSourceUsesScopedDatasetContract(t *testing.T) {
	var seen url.URL
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = *r.URL
		auth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"id":"p1","title":"Canonical","_rev":"rev-2","source":{"kind":"blocks","blocks":[{"type":"paragraph","text":"safe"}]}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "tok", Workspace: "ws", Project: "proj"})
	source, err := c.PaperSource("staging", "p1", "drafts")
	if err != nil {
		t.Fatalf("PaperSource: %v", err)
	}
	if seen.Path != "/w/ws/p/proj/d/staging/papers/p1/source" {
		t.Fatalf("path = %q", seen.Path)
	}
	if seen.Query().Get("perspective") != "drafts" {
		t.Fatalf("perspective = %q", seen.Query().Get("perspective"))
	}
	if auth != "Bearer tok" {
		t.Fatalf("Authorization = %q", auth)
	}
	if source.Kind != "blocks" || source.Rev != "rev-2" || source.Title != "Canonical" {
		t.Fatalf("source = %#v", source)
	}

	raw, err := source.DocumentJSON("fallback")
	if err != nil {
		t.Fatalf("DocumentJSON: %v", err)
	}
	for _, want := range []string{`"_id":"p1"`, `"_rev":"rev-2"`, `"blocks":[`} {
		if !strings.Contains(string(raw), want) {
			t.Errorf("document %s missing %s", raw, want)
		}
	}
}

func TestPaperSourceFailsClosedOnRejectedOrUnknownSource(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"ambiguous", http.StatusUnprocessableEntity, `{"error":{"code":"ambiguous_source"}}`},
		{"unknown kind", http.StatusOK, `{"title":"x","source":{"kind":"mixed"}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			c := New(Config{BaseURL: srv.URL, Token: "tok", Workspace: "ws", Project: "proj"})
			if _, err := c.PaperSource("production", "p", "published"); err == nil {
				t.Fatal("PaperSource accepted a rejected/unknown source")
			}
		})
	}
}

func TestPaperSourceUsesFlatPublicRouteWithoutToken(t *testing.T) {
	var path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		_, _ = w.Write([]byte(`{"id":"p","title":"Public","source":{"kind":"html","html":"<p>safe</p>"}}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Workspace: "default", Project: "default"})
	if _, err := c.PaperSource("production", "p", "published"); err != nil {
		t.Fatalf("PaperSource: %v", err)
	}
	if path != "/d/production/papers/p/source" {
		t.Fatalf("path = %q", path)
	}
}
