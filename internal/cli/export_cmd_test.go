package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A bogus --perspective must be rejected up front (exitUsage) rather than sent
// verbatim to the server, which would silently return the wrong/default view.
// The guard fires before any client call, so no server is needed.
func TestRunExportRejectsInvalidPerspective(t *testing.T) {
	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	code := runExport(out, globals{}, manifest.Context{}, []string{"--perspective", "bogus"})

	if code != exitUsage {
		t.Fatalf("exit code = %d, want exitUsage (%d)", code, exitUsage)
	}
	if !strings.Contains(se.String(), "invalid --perspective") {
		t.Fatalf("stderr = %q, want it to contain %q", se.String(), "invalid --perspective")
	}
}

// A failed export prints its error with exactly one "export: " prefix. The
// apiclient no longer wraps the message, so a regression that re-adds a wrap
// would stutter "export: export: …".
func TestRunExportSinglePrefixOnError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"no read access"}}`))
	}))
	defer srv.Close()

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, nil); code != exitGeneric {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitGeneric, se.String())
	}
	if n := strings.Count(se.String(), "export: "); n != 1 {
		t.Errorf("stderr = %q, want exactly one %q prefix (got %d)", se.String(), "export: ", n)
	}
	if !strings.Contains(se.String(), "no read access") {
		t.Errorf("stderr = %q, want the server's message %q", se.String(), "no read access")
	}
}
