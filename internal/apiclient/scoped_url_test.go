package apiclient

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// scopedURL must percent-encode the workspace/project slugs — parity with the
// escaped dataset/type/id segments and the JS SDK. A raw splice of a slug with a
// space, '/', '#', or '?' would produce a broken/ambiguous path.
func TestScopedURLEscapesWorkspaceAndProject(t *testing.T) {
	c := New(Config{
		BaseURL:   "https://api.example.com",
		Workspace: "my ws/#a",
		Project:   "proj?b",
		Dataset:   "production",
	})
	got := c.scopedURL("/v1/data/query/production/post")

	// Encoded forms present (space→%20, /→%2F, #→%23, ?→%3F)…
	if !strings.Contains(got, "my%20ws%2F%23a") {
		t.Errorf("workspace not encoded in %q", got)
	}
	if !strings.Contains(got, "proj%3Fb") {
		t.Errorf("project not encoded in %q", got)
	}
	// …and the raw, unencoded slugs are NOT.
	if strings.Contains(got, "my ws/#a") || strings.Contains(got, "proj?b") {
		t.Errorf("raw slug leaked into %q", got)
	}
	// The already-built suffix passes through untouched.
	if !strings.HasSuffix(got, "/v1/data/query/production/post") {
		t.Errorf("suffix altered: %q", got)
	}
}

// Plain slugs (the common case) stay byte-identical — no regression.
func TestScopedURLPlainSlugsUnchanged(t *testing.T) {
	c := New(Config{
		BaseURL:   "https://api.example.com",
		Workspace: "acme",
		Project:   "web",
		Dataset:   "production",
	})
	got := c.scopedURL("/v1/data/doc/production/post/p1")
	want := "https://api.example.com/w/acme/p/web/v1/data/doc/production/post/p1"
	if got != want {
		t.Errorf("plain slugs should be byte-identical:\n got=%q\nwant=%q", got, want)
	}
}

// A base URL carrying a trailing slash must be normalized so the scheme splices a
// single "/w/", not a doubled "//w/". This is the drift the extraction fixes: the
// old Client.scopedURL used c.baseURL RAW (no trim) while the CLI's migrate copy
// trimmed — so a trailing-slash base produced a malformed "//w/" on the apiclient
// path only. Folding strings.TrimRight into the shared ScopedURL closes it.
//
// RED before the fix (raw base → ".../#/w/acme/..." with "//w/"), GREEN after.
func TestScopedURLTrailingSlashBaseNormalized(t *testing.T) {
	got := ScopedURL("https://api.example.com/", "acme", "web", "/v1/schemas/production")
	want := "https://api.example.com/w/acme/p/web/v1/schemas/production"
	if got != want {
		t.Errorf("trailing-slash base not normalized:\n got=%q\nwant=%q", got, want)
	}
	if strings.Contains(got, "//w/") {
		t.Errorf("doubled slash before /w/ (drift not fixed): %q", got)
	}
	// The Client method must inherit the same normalization via delegation.
	c := New(Config{BaseURL: "https://api.example.com/", Workspace: "acme", Project: "web", Dataset: "production"})
	if cgot := c.scopedURL("/v1/schemas/production"); cgot != want {
		t.Errorf("Client.scopedURL did not inherit trailing-slash normalization:\n got=%q\nwant=%q", cgot, want)
	}
}

// flatURL is the NOT-scoped (no /w/<ws>/p/<proj>) twin of ScopedURL, backing the
// five flat sites (taskPostRaw, GraphShow, tenancyPost, ListWorkspaces,
// ListProjects). A trailing-slash base must not splice a doubled "//v1/…" —
// RED before flatURL existed (these sites spliced c.baseURL+path raw), GREEN
// after routing through it.
func TestFlatURLTrailingSlashBaseNormalized(t *testing.T) {
	c := New(Config{BaseURL: "https://api.example.com/"})
	got := c.flatURL("/v1/tasks/task-7/claim")
	want := "https://api.example.com/v1/tasks/task-7/claim"
	if got != want {
		t.Errorf("flatURL trailing-slash base not normalized:\n got=%q\nwant=%q", got, want)
	}
	if strings.Contains(got, "//v1/") {
		t.Errorf("doubled slash before /v1/ (drift not fixed): %q", got)
	}
}

// A trailing-slash BaseURL must not produce "//..." on the wire for any of the
// three highest-traffic flat sites: taskPostRaw (via TaskClaim), GraphShow, and
// ListWorkspaces. RED before the flatURL fix (each spliced c.baseURL+path raw).
func TestFlatSitesTrailingSlashBaseSingleSlashOnWire(t *testing.T) {
	var gotPaths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPaths = append(gotPaths, r.URL.RequestURI())
		if strings.Contains(r.URL.Path, "/claim") {
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":1}}}`))
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/graph/") {
			_, _ = w.Write([]byte(`{"ok":true,"root":"x","nodes":[],"edges":[]}`))
			return
		}
		_, _ = w.Write([]byte(`{"workspaces":[]}`))
	}))
	defer srv.Close()

	// Base carries a trailing slash, exactly as a user-supplied -s / env var can.
	c := New(Config{BaseURL: srv.URL + "/", Token: "t", Dataset: "production"})

	if _, err := c.TaskClaim("task-7", "worker-a"); err != nil {
		t.Fatalf("TaskClaim: %v", err)
	}
	if _, err := c.GraphShow("task-7"); err != nil {
		t.Fatalf("GraphShow: %v", err)
	}
	if _, err := c.ListWorkspaces(); err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}

	for _, p := range gotPaths {
		if strings.Contains(p, "//") {
			t.Errorf("doubled slash on the wire (trailing-slash base not normalized): %q (all=%v)", p, gotPaths)
		}
	}
	if len(gotPaths) != 3 {
		t.Fatalf("expected 3 requests, got %d: %v", len(gotPaths), gotPaths)
	}
	if gotPaths[0] != "/v1/tasks/task-7/claim" {
		t.Errorf("taskPostRaw path = %q, want /v1/tasks/task-7/claim", gotPaths[0])
	}
	if !strings.HasPrefix(gotPaths[1], "/v1/graph/task-7?") {
		t.Errorf("GraphShow path = %q, want prefix /v1/graph/task-7?", gotPaths[1])
	}
	if gotPaths[2] != "/api/workspaces" {
		t.Errorf("ListWorkspaces path = %q, want /api/workspaces", gotPaths[2])
	}
}

// ListWorkspaces/ListProjects must surface the server's real error message
// (humanAPIError) on a non-2xx, not a bare "status 401" — a 401 (expired
// token) and a 403 previously read identically. RED before the fix (bare
// fmt.Errorf("… status %d", …)); GREEN after reading the body through
// humanAPIError.
func TestListWorkspacesSurfacesServerErrorMessage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"token expired"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "stale"})
	_, err := c.ListWorkspaces()
	if err == nil {
		t.Fatal("expected an error on a 401, got nil")
	}
	if !strings.Contains(err.Error(), "token expired") {
		t.Errorf("error = %q, want it to surface the server's message %q", err.Error(), "token expired")
	}
	if strings.Contains(err.Error(), "status 401") {
		t.Errorf("error = %q, still surfacing the bare status instead of the server message", err.Error())
	}
}

func TestListProjectsSurfacesServerErrorMessage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"token expired"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "stale"})
	_, err := c.ListProjects("acme")
	if err == nil {
		t.Fatal("expected an error on a 401, got nil")
	}
	if !strings.Contains(err.Error(), "token expired") {
		t.Errorf("error = %q, want it to surface the server's message %q", err.Error(), "token expired")
	}
	if strings.Contains(err.Error(), "status 401") {
		t.Errorf("error = %q, still surfacing the bare status instead of the server message", err.Error())
	}
}

// LoadSchemasFor/LoadStructure (schema.go) share the same defect: a non-2xx
// dropped the server's real message behind a bare "status %d".
func TestLoadSchemasForSurfacesServerErrorMessage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"token expired"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "stale", Workspace: "acme", Project: "web"})
	_, err := c.LoadSchemasFor("acme", "web", "production")
	if err == nil {
		t.Fatal("expected an error on a 401, got nil")
	}
	if !strings.Contains(err.Error(), "token expired") {
		t.Errorf("error = %q, want it to surface the server's message %q", err.Error(), "token expired")
	}
	if strings.Contains(err.Error(), "status 401") {
		t.Errorf("error = %q, still surfacing the bare status instead of the server message", err.Error())
	}
}

func TestLoadStructureSurfacesServerErrorMessage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"token expired"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "stale", Workspace: "acme", Project: "web", Dataset: "production"})
	_, err := c.LoadStructure()
	if err == nil {
		t.Fatal("expected an error on a 401, got nil")
	}
	if !strings.Contains(err.Error(), "token expired") {
		t.Errorf("error = %q, want it to surface the server's message %q", err.Error(), "token expired")
	}
	if strings.Contains(err.Error(), "status 401") {
		t.Errorf("error = %q, still surfacing the bare status instead of the server message", err.Error())
	}
}
