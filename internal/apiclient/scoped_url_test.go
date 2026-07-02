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
