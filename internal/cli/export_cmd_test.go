package cli

import (
	"bytes"
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
