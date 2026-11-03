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

// The export controller commits its 200 before the first document. When it
// fails after that, it ends the chunked body cleanly with one
// {"_barkpark_export":"incomplete", ...} line. The framing is then complete,
// so only that line tells a cut export from a whole one (task-610177501686e7fb).
const exportTestMarker = `{"_barkpark_export":"incomplete","_cause":"the database connection dropped (DBConnection.ConnectionError)","_delivered":2,"_error":"the export failed mid-stream; this backup is INCOMPLETE"}`

func exportServeMarked(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = w.Write([]byte(`{"_id":"a","_type":"post"}` + "\n" + `{"_id":"b","_type":"post"}` + "\n" + exportTestMarker + "\n"))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestRunExportFailsOnTheServersIncompleteMarker(t *testing.T) {
	srv := exportServeMarked(t)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, nil); code != exitGeneric {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitGeneric, se.String())
	}
	for _, want := range []string{
		"the server ended the export early after 2 documents",
		"the database connection dropped (DBConnection.ConnectionError)",
		"stopped after 2 documents",
		"PARTIAL, do not restore from it",
	} {
		if !strings.Contains(se.String(), want) {
			t.Errorf("stderr = %q, want it to contain %q", se.String(), want)
		}
	}
	if strings.Contains(se.String(), "exported ") {
		t.Errorf("stderr = %q, must not claim a completed export", se.String())
	}
	// The marker stays the last line of the output, so a redirected file
	// still carries its own proof of truncation for `bp import`.
	lines := strings.Split(strings.TrimRight(so.String(), "\n"), "\n")
	if len(lines) != 3 || lines[2] != exportTestMarker {
		t.Errorf("stdout = %q, want the 2 documents and then the marker", so.String())
	}
}

func TestRunExportOutWritesNoSidecarOnTheIncompleteMarker(t *testing.T) {
	srv := exportServeMarked(t)
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitGeneric {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitGeneric, se.String())
	}
	for _, p := range []string{path, path + exportMetaSuffix, path + exportPartialSuffix + exportMetaSuffix} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s exists after a marked export (err=%v); nothing incomplete may be attested or promoted", p, err)
		}
	}
	body, err := os.ReadFile(path + exportPartialSuffix)
	if err != nil {
		t.Fatalf("read partial: %v", err)
	}
	if !strings.HasSuffix(string(body), exportTestMarker+"\n") {
		t.Errorf("partial = %q, want it to end with the marker", body)
	}
	// bp import refuses the partial on the marker line.
	if _, err := importReadRows(path + exportPartialSuffix); err == nil || !strings.Contains(err.Error(), "incomplete marker") {
		t.Errorf("importReadRows(partial) err = %v, want the incomplete-marker refusal", err)
	}
}

// A document whose content mentions the marker key is still a document.
func TestRunExportCountsADocumentThatMentionsTheMarkerKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = w.Write([]byte(`{"_id":"doc","body":{"_barkpark_export":"incomplete"}}` + "\n" +
			`{"_id":"doc2","_barkpark_export":"quoted in a document"}` + "\n"))
	}))
	defer srv.Close()
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitOK, se.String())
	}
	if !strings.Contains(se.String(), "exported 2 documents") {
		t.Errorf("stderr = %q, want both documents counted", se.String())
	}
}
