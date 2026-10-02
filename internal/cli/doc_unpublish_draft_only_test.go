package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp doc unpublish` on a never-published draft 404'd "document not found … the
// resource does not exist in this scope" (stranger walk, 2026-09-30). These run
// the real dispatch seam against a server that answers the way the live one did.

const unpublishManifestJSON = `{
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
     "flags":[{"name":"perspective","type":"string","summary":"published | drafts | raw."}],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table"},
    {"id":"doc.unpublish","noun":"doc","verb":"unpublish","summary":"Unpublish a document (move it back to draft).",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","mutation_op":"unpublish"}
  ]
}`

// unpublishHarness 404s the unpublish (no published row) and answers the
// drafts-lens GET per draftExists. It records every GET's query string.
func unpublishHarness(t *testing.T, draftExists bool) (*manifest.Manifest, manifest.Context, *[]string) {
	t.Helper()
	var gets []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			gets = append(gets, r.URL.Path+"?"+r.URL.RawQuery)
			if draftExists && r.URL.Query().Get("perspective") == "drafts" {
				_, _ = w.Write([]byte(`{"result":{"_id":"drafts.fresh","_type":"post","_draft":true,"_rev":"r1"}}`))
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(serverNotFound))
	}))
	t.Cleanup(srv.Close)
	m, err := manifest.Parse([]byte(strings.Replace(unpublishManifestJSON, "http://replaced", srv.URL, 1)))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	ctx := manifest.Context{Server: srv.URL, Token: "tok", Workspace: "default", Project: "default", Dataset: "production"}
	return m, ctx, &gets
}

func runUnpublish(t *testing.T, m *manifest.Manifest, ctx manifest.Context, extra ...string) (int, string, string) {
	t.Helper()
	cmd, ok := m.Tree().Lookup("doc", "unpublish")
	if !ok {
		t.Fatal("fixture has no doc unpublish")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	code := runCommand(w, g, ctx, m, *cmd, append([]string{"post", "fresh"}, extra...))
	return code, so.String(), se.String()
}

func TestUnpublishOfANeverPublishedDraftSaysSo(t *testing.T) {
	m, ctx, gets := unpublishHarness(t, true)
	code, _, stderr := runUnpublish(t, m, ctx)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want the refusal's own %d (the advisory must not change it)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "nothing to unpublish") || !strings.Contains(stderr, "never been published") {
		t.Fatalf("an unpublish of a draft-only document must say it was never published:\n%s", stderr)
	}
	if !strings.Contains(stderr, "bp doc discard-draft post fresh --delete-unpublished") {
		t.Fatalf("the advisory must name how to remove the draft:\n%s", stderr)
	}
	if len(*gets) != 1 || !strings.Contains((*gets)[0], "perspective=drafts") {
		t.Fatalf("want exactly one drafts-lens probe, got %v", *gets)
	}
}

func TestUnpublishOfAGenuinelyMissingDocumentAddsNothing(t *testing.T) {
	m, ctx, gets := unpublishHarness(t, false)
	_, _, stderr := runUnpublish(t, m, ctx)
	if strings.Contains(stderr, "nothing to unpublish") {
		t.Fatalf("a real absence must keep the plain not_found:\n%s", stderr)
	}
	if len(*gets) != 1 {
		t.Fatalf("the drafts lens was never asked — the control arm proves nothing (%v)", *gets)
	}
}

func TestUnpublishJSONOutputIsUnchanged(t *testing.T) {
	m, ctx, _ := unpublishHarness(t, true)
	_, stdout, _ := runUnpublish(t, m, ctx, "-o", "json")
	if strings.Contains(stdout, "nothing to unpublish") {
		t.Fatalf("the advisory leaked onto stdout:\n%s", stdout)
	}
}
