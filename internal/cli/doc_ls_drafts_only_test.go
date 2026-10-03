package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-6b46358de4554981: every new document starts as a DRAFT, and `doc ls`
// reads the published perspective, so the first list after `bp seed recipe`
// was "(no rows) count: 0" with nothing on stderr. An empty published page of
// a type that HAS drafts now says so; nothing else changes.

const lsDraftsManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "auth_tier": "admin",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}],
  "commands": [
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"List documents of a type.",
     "http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[{"name":"perspective","type":"string","summary":"published|drafts|raw"}],
     "writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"}
  ]
}`

func lsDraftsHarness(t *testing.T, published, drafts string, seen *[]string) (*manifest.Manifest, manifest.Context) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		p := r.URL.Query().Get("perspective")
		*seen = append(*seen, p)
		if p == "drafts" {
			_, _ = w.Write([]byte(drafts))
			return
		}
		_, _ = w.Write([]byte(published))
	}))
	t.Cleanup(srv.Close)
	m, err := manifest.Parse([]byte(strings.Replace(lsDraftsManifestJSON, "http://replaced", srv.URL, 1)))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	return m, manifest.Context{Server: srv.URL, Token: "tok", Workspace: "default", Project: "default", Dataset: "production"}
}

func runLs(t *testing.T, m *manifest.Manifest, ctx manifest.Context, tail ...string) (int, string, string) {
	t.Helper()
	cmd, _ := m.Tree().Lookup("doc", "ls")
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	return runCommand(w, g, ctx, m, *cmd, tail), so.String(), se.String()
}

const (
	lsEmpty    = `{"count":0,"documents":[],"hasMore":false,"limit":100,"offset":0}`
	lsOneDraft = `{"count":1,"documents":[{"_id":"drafts.seed-recipe-1","_type":"recipe"}],"hasMore":true,"limit":1,"offset":0}`
)

func TestEmptyPublishedPageWithDraftsSaysSo(t *testing.T) {
	var seen []string
	m, ctx := lsDraftsHarness(t, lsEmpty, lsOneDraft, &seen)
	code, _, stderr := runLs(t, m, ctx, "recipe")
	if code != exitOK {
		t.Fatalf("exit %d, want 0 (the note must not change it)", code)
	}
	if !strings.Contains(stderr, "--perspective drafts") || !strings.Contains(stderr, "bp doc publish recipe") {
		t.Fatalf("an empty published page of a type with drafts must say drafts exist and how to see/publish them:\n%s", stderr)
	}
}

func TestNoDraftsNoteWhenItWouldBeWrong(t *testing.T) {
	cases := []struct {
		name, published, drafts string
		tail                    []string
	}{
		{"drafts empty too", lsEmpty, lsEmpty, []string{"recipe"}},
		{"published page has rows", `{"count":1,"documents":[{"_id":"r1"}],"hasMore":false,"limit":100,"offset":0}`, lsOneDraft, []string{"recipe"}},
		{"caller already asked for drafts", lsEmpty, lsEmpty, []string{"recipe", "--perspective", "drafts"}},
		{"caller asked for raw", lsEmpty, lsOneDraft, []string{"recipe", "--perspective", "raw"}},
	}
	for _, tc := range cases {
		var seen []string
		m, ctx := lsDraftsHarness(t, tc.published, tc.drafts, &seen)
		_, _, stderr := runLs(t, m, ctx, tc.tail...)
		if strings.Contains(stderr, "drafts exist") {
			t.Errorf("%s: must not print the drafts note:\n%s", tc.name, stderr)
		}
	}
}
