package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// stranger_walk_test.go pins three defects a first-time user hit on a fresh
// local instance (2026-09-30), each at the real dispatch seam:
//
//  1. `bp doc publish <type> <id>` on a LIVE document with no pending draft
//     404s "document not found … does not exist in this scope" — false. The CLI
//     now probes the published lens once and says there is nothing to publish.
//  2. `bp <noun> --help` exited 2, while `bp help <noun>` and
//     `bp <noun> <verb> --help` exit 0 for the same kind of page.
//  3. Under a visible noun a tier-hidden verb (`bp doc create` at tier none)
//     answered `no verb "create"` with nothing saying a credential reveals it.

const strangerManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "auth_tier": "admin",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}],
  "commands": [
    {"id":"doc.get","noun":"doc","verb":"get","summary":"Fetch one document by type and id.",
     "http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"doc_id","required":true,"type":"string","summary":"Document id."}],
     "flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table"},
    {"id":"doc.publish","noun":"doc","verb":"publish","summary":"Publish a draft.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","mutation_op":"publish"}
  ]
}`

const serverNotFound = `{"ok":false,"error":{"code":"not_found","message":"not found: document not found","hint":"Check the document _id, type, and dataset in the URL — the resource does not exist in this scope.","request_id":"rq1"}}`

// strangerHarness serves the mutate publish as the live server does when no
// draft exists (404), and answers the published-lens GET per `live`.
func strangerHarness(t *testing.T, live bool) (*manifest.Manifest, manifest.Context, *[]string) {
	t.Helper()
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet && live {
			_, _ = w.Write([]byte(`{"result":{"_id":"hello","_type":"post","_rev":"r1"}}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(serverNotFound))
	}))
	t.Cleanup(srv.Close)
	m, err := manifest.Parse([]byte(strings.Replace(strangerManifestJSON, "http://replaced", srv.URL, 1)))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	ctx := manifest.Context{Server: srv.URL, Token: "tok", Workspace: "default", Project: "default", Dataset: "production"}
	return m, ctx, &seen
}

func runStrangerPublish(t *testing.T, m *manifest.Manifest, ctx manifest.Context) (int, string, string) {
	t.Helper()
	cmd, ok := m.Tree().Lookup("doc", "publish")
	if !ok {
		t.Fatal("fixture has no doc publish")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	code := runCommand(w, g, ctx, m, *cmd, []string{"post", "hello"})
	return code, so.String(), se.String()
}

func TestPublishWithNothingToPublishSaysSo(t *testing.T) {
	m, ctx, _ := strangerHarness(t, true)
	code, _, stderr := runStrangerPublish(t, m, ctx)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want the refusal's own %d (the advisory must not change it)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "nothing to publish") || !strings.Contains(stderr, "bp doc patch post hello") {
		t.Fatalf("a publish of a live document with no draft must say there is nothing to publish and name the edit step:\n%s", stderr)
	}
}

func TestPublishOfAGenuinelyMissingDocumentAddsNothing(t *testing.T) {
	m, ctx, seen := strangerHarness(t, false)
	_, _, stderr := runStrangerPublish(t, m, ctx)
	if strings.Contains(stderr, "nothing to publish") {
		t.Fatalf("a real absence must keep the plain not_found:\n%s", stderr)
	}
	probed := false
	for _, s := range *seen {
		if strings.HasPrefix(s, "GET ") {
			probed = true
		}
	}
	if !probed {
		t.Fatal("the published lens was never asked — the control arm proves nothing")
	}
}

func TestNounHelpExitsZero(t *testing.T) {
	m, ctx, _ := strangerHarness(t, true)
	_ = ctx
	for _, tc := range []struct {
		args []string
		want int
	}{
		{[]string{"doc", "--help"}, exitOK},
		{[]string{"doc", "-h"}, exitOK},
		{[]string{"doc"}, exitUsage}, // a bare noun is still incomplete usage
	} {
		code := runWithManifest(t, m, tc.args)
		if code != tc.want {
			t.Errorf("bp %s: exit %d, want %d", strings.Join(tc.args, " "), code, tc.want)
		}
	}
}

// runWithManifest drives the REAL Execute with the fixture manifest loaded as
// an offline --manifest file, so the noun-help exit is decided by the same
// dispatch branch a user hits.
func runWithManifest(t *testing.T, m *manifest.Manifest, args []string) int {
	t.Helper()
	_ = m
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, []byte(strangerManifestJSON), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	_, code := captureExecuteCode(t, append([]string{"--manifest", path}, args...))
	return code
}

func TestHiddenVerbNoteNamesTheTier(t *testing.T) {
	if got := hiddenVerbTierNote("admin"); got != "" {
		t.Fatalf("admin sees the whole tree; the note must be empty, got %q", got)
	}
	for _, tier := range []string{"", "none", "read"} {
		got := hiddenVerbTierNote(tier)
		if !strings.Contains(got, "hides the verbs") || !strings.Contains(got, "login") {
			t.Errorf("tier %q: note must say verbs are hidden and name login, got %q", tier, got)
		}
	}
}
