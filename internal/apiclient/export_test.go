package apiclient

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A finite NDJSON export of two documents (plus a blank line, which must be
// skipped). Every non-blank line dispatches, and a clean EOF returns nil —
// unlike Listen, where a server EOF is an unexpected drop.
func TestExportStreamsNDJSON(t *testing.T) {
	var gotPath, gotAccept string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path + "?" + r.URL.RawQuery
		gotAccept = r.Header.Get("Accept")
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"_id":"a"}` + "\n" + "\n" + `{"_id":"b"}` + "\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"})

	var lines []string
	err := c.Export(context.Background(), ExportOpts{Type: "post"}, func(line string) error {
		lines = append(lines, line)
		return nil
	})
	if err != nil {
		t.Fatalf("Export returned %v, want nil on clean EOF", err)
	}

	if want := []string{`{"_id":"a"}`, `{"_id":"b"}`}; strings.Join(lines, ",") != strings.Join(want, ",") {
		t.Errorf("lines = %v, want %v", lines, want)
	}
	// scoped path + type param + NDJSON Accept
	if !strings.HasPrefix(gotPath, "/w/ws/p/proj/v1/data/export/production") {
		t.Errorf("path = %q, want the scoped export path", gotPath)
	}
	if !strings.Contains(gotPath, "type=post") {
		t.Errorf("path = %q, want type=post", gotPath)
	}
	if gotAccept != "application/x-ndjson" {
		t.Errorf("Accept = %q, want application/x-ndjson", gotAccept)
	}
}

// A non-200 status is an error (so a piping backup script sees a non-zero exit).
func TestExportErrorsOnNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"dataset not found"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"})
	err := c.Export(context.Background(), ExportOpts{}, func(string) error { return nil })
	if err == nil {
		t.Fatal("expected an error on a 404 export, got nil")
	}
	// The server's error envelope must survive into the message, not be replaced
	// by a diagnostic-free "status 404".
	if !strings.Contains(err.Error(), "dataset not found") {
		t.Errorf("error = %q, want the server's message %q", err, "dataset not found")
	}
}
