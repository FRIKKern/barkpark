package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp audit ls` is a manifest command (capabilities.ex audit.ls): a scoped
// admin read of GET /w/:ws/p/:proj/v1/audit that sends its filters as the query
// and tabulates the events.
func TestAuditLsSendsFiltersToTheWorkspaceRouteAndPrintsEvents(t *testing.T) {
	var gotPath, gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotQuery = r.URL.Path, r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"events":[{"at":"2026-11-16T10:00:00Z","category":"token","action":"token_minted","actor_type":"user","actor_id":"u-1","actor_name":"Ada","target_type":"token","target_id":"tok-9","dataset":null,"doc_type":null,"project_wide":true}],"next_cursor":null,"limit":2}`))
	}))
	t.Cleanup(srv.Close)

	prefix := "/w/:workspace_slug/p/:project_slug"
	cmd := manifest.Command{
		ID:           "audit.ls",
		Noun:         "audit",
		Verb:         "ls",
		HTTP:         manifest.HTTP{Method: http.MethodGet, PathTemplate: "/v1/audit"},
		AuthTier:     "scoped_admin",
		ScopedPrefix: &prefix,
		Flags: []manifest.Flag{
			{Name: "category", Type: "string"},
			{Name: "actor", Type: "string"},
			{Name: "since", Type: "string"},
			{Name: "until", Type: "string"},
			{Name: "limit", Type: "int"},
			{Name: "cursor", Type: "string"},
		},
		DefaultOutput: "table",
	}

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "table", outputSet: true, limit: 2, limitSet: true}
	out.applyGlobals(g)
	ctx := manifest.Context{Server: srv.URL, Workspace: "acme", Project: "site", Dataset: "production"}

	args := []string{"--category", "token", "--since", "2026-11-01"}
	if code := runCommand(out, g, ctx, &manifest.Manifest{}, cmd, args); code != exitOK {
		t.Fatalf("exit %d; out=%q err=%q", code, stdout.String(), stderr.String())
	}
	if gotPath != "/w/acme/p/site/v1/audit" {
		t.Fatalf("requested %q", gotPath)
	}
	for _, want := range []string{"category=token", "since=2026-11-01", "limit=2"} {
		if !strings.Contains(gotQuery, want) {
			t.Fatalf("query %q lacks %q", gotQuery, want)
		}
	}
	for _, want := range []string{"token_minted", "tok-9"} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("table lacks %q:\n%s", want, stdout.String())
		}
	}
}
