package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp media usage <id>` is a manifest command (capabilities.ex media.usage):
// it GETs /v1/media/:dataset/:id/usage and tabulates result.documents.
func TestMediaUsagePrintsTheDocumentsAsATable(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"result":{"documents":[{"id":"p1","type":"paper","title":"Spring issue","draft":false,"published":true}],"total":1}}`))
	}))
	t.Cleanup(srv.Close)

	cmd := manifest.Command{
		ID:            "media.usage",
		Noun:          "media",
		Verb:          "usage",
		HTTP:          manifest.HTTP{Method: http.MethodGet, PathTemplate: "/v1/media/:dataset/:id/usage"},
		Args:          []manifest.Arg{{Name: "id", Required: true, Type: "string"}},
		DefaultOutput: "table",
	}

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "table", outputSet: true}
	out.applyGlobals(g)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runCommand(out, g, ctx, &manifest.Manifest{}, cmd, []string{"blob-1"}); code != exitOK {
		t.Fatalf("exit %d; out=%q err=%q", code, stdout.String(), stderr.String())
	}
	if gotPath != "/v1/media/production/blob-1/usage" {
		t.Fatalf("requested %q", gotPath)
	}
	for _, want := range []string{"Spring issue", "paper", "p1"} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("table lacks %q:\n%s", want, stdout.String())
		}
	}
}
