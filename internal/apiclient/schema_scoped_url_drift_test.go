package apiclient

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// LoadSchemasFor must route through the canonical ScopedURL so a base URL that
// carries a trailing slash (a supported input — ScopedURL and bootstrap both
// TrimRight it, and nothing in the CLI resolve path normalizes -s /
// BARKPARK_API_URL) does NOT splice a doubled "//w/" into the request path.
//
// RED before the collapse: schema.go built the scoped URL from c.baseURL RAW, so
// a trailing-slash base produced the wire path "//w/acme/p/web/v1/schemas/production"
// — a malformed path that the server routes to 404. GREEN after folding onto
// ScopedURL, which normalizes the base.
func TestLoadSchemasForTrailingSlashBaseNoDoubleSlash(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.RequestURI()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"schemas":[]}`))
	}))
	defer srv.Close()

	// Base carries a trailing slash, exactly as a user-supplied -s / env var can.
	c := New(Config{
		BaseURL:   srv.URL + "/",
		Workspace: "acme",
		Project:   "web",
		Dataset:   "production",
	})
	if _, err := c.LoadSchemasFor("acme", "web", "production"); err != nil {
		t.Fatalf("LoadSchemasFor errored: %v", err)
	}

	want := "/w/acme/p/web/v1/schemas/production"
	if gotPath != want {
		t.Errorf("scoped schema path drifted:\n got=%q\nwant=%q", gotPath, want)
	}
	if strings.Contains(gotPath, "//w/") {
		t.Errorf("doubled slash before /w/ (trailing-slash drift not fixed): %q", gotPath)
	}
}
