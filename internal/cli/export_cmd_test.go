package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// CONTENT NEGOTIATION. The export route rides `plug(:accepts, ["json"])`, so a
// bare `Accept: application/x-ndjson` 406s BEFORE auth and the operator sees
// only `export: unknown error` while `bp export > backup.ndjson` writes an
// empty file (live-proven on guerrilla: ndjson=406, ndjson+json=401 on the
// identical URL). This server mirrors that matcher exactly — it 406s unless the
// Accept keeps `application/json` negotiable — so a regression that drops the
// appended type fails here instead of in an operator's terminal.
func TestRunExportNegotiatesJSONAccept(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		accept := r.Header.Get("Accept")
		if !strings.Contains(accept, "application/json") && !strings.Contains(accept, "*/*") {
			w.WriteHeader(http.StatusNotAcceptable)
			_, _ = w.Write([]byte(`{"error":{"code":"internal_error","message":"unknown error"}}`))
			return
		}
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = w.Write([]byte(`{"_id":"a"}` + "\n" + `{"_id":"b"}` + "\n"))
	}))
	defer srv.Close()

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}

	if code := runExport(out, globals{}, ctx, nil); code != exitOK {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitOK, se.String())
	}
	if n := strings.Count(so.String(), "\n"); n != 2 {
		t.Errorf("stdout = %q, want 2 NDJSON lines", so.String())
	}
	// The count is the whole point: a backup verb must say what it wrote.
	if !strings.Contains(se.String(), "exported 2 documents") {
		t.Errorf("stderr = %q, want it to report %q", se.String(), "exported 2 documents")
	}
	if !strings.Contains(se.String(), "ws/proj/production") {
		t.Errorf("stderr = %q, want the scope it exported", se.String())
	}
}

// TRUNCATION HONESTY. The server streams three documents and then aborts the
// connection without terminating the body — the framing the real chunked
// ExportController produces when it dies mid-stream. The operator's file is a
// stub, so the verb must exit NON-ZERO and say the output is PARTIAL rather
// than returning the old silent success.
//
// LIMIT, stated honestly: a truncated CLOSE-DELIMITED body is indistinguishable
// from a complete one at the client (measured: 3 docs, empty stderr, exit 0),
// so no test can catch that framing. Production uses send_chunked — the honest
// framing — which is why this test can assert anything at all.
func TestRunExportTruncatedStreamIsPartialAndNonZero(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/x-ndjson")
		for _, id := range []string{"a", "b", "c"} {
			_, _ = w.Write([]byte(`{"_id":"` + id + `"}` + "\n"))
		}
		w.(http.Flusher).Flush()
		// Kill the connection mid-stream: no terminating chunk, so the client
		// sees "unexpected EOF" instead of a clean end-of-body.
		panic(http.ErrAbortHandler)
	}))
	defer srv.Close()

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, nil); code != exitGeneric {
		t.Fatalf("runExport exit = %d, want %d (a truncated backup must fail); stderr=%s",
			code, exitGeneric, se.String())
	}
	if !strings.Contains(se.String(), "PARTIAL, do not restore from it") {
		t.Errorf("stderr = %q, want it to name the output PARTIAL", se.String())
	}
	if !strings.Contains(se.String(), "stopped after 3 documents") {
		t.Errorf("stderr = %q, want the count it actually wrote", se.String())
	}
	if strings.Contains(se.String(), "exported 3 documents") {
		t.Errorf("stderr = %q, must not claim a completed export", se.String())
	}
}

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
