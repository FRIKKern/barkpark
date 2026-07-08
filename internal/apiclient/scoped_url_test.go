package apiclient

import (
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
