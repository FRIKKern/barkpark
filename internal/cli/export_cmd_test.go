package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

// exportServeDocs serves `ids` as NDJSON and ends the body cleanly — a complete
// export.
func exportServeDocs(t *testing.T, ids ...string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/x-ndjson")
		for _, id := range ids {
			_, _ = w.Write([]byte(`{"_id":"` + id + `"}` + "\n"))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// exportServeTruncated serves three documents and then kills the connection
// without terminating the chunked body — the framing a dying ExportController
// produces.
func exportServeTruncated(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/x-ndjson")
		for _, id := range []string{"a", "b", "c"} {
			_, _ = w.Write([]byte(`{"_id":"` + id + `"}` + "\n"))
		}
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// ARTIFACT DURABILITY. `bp export > backup.ndjson` puts the count on stderr,
// which on a cron box goes nowhere — six months later the file itself says
// nothing about whether it is whole. `--out` fixes that with a sidecar written
// only after a clean completion: this test proves the sidecar exists, that its
// sha256 and byte total describe EXACTLY the bytes on disk, and that the count
// matches the lines in the file — all readable without stderr, without the exit
// code and without a log line.
func TestRunExportOutWritesSidecarAfterCleanCompletion(t *testing.T) {
	srv := exportServeDocs(t, "a", "b")
	path := filepath.Join(t.TempDir(), "backup.ndjson")

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}

	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitOK {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitOK, se.String())
	}
	// The NDJSON goes to the FILE, not to stdout — nothing else changed about
	// the body: still one document per line, no receipt line.
	if so.Len() != 0 {
		t.Errorf("stdout = %q, want empty when --out names a file", so.String())
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read artifact: %v", err)
	}
	if got := string(body); got != `{"_id":"a"}`+"\n"+`{"_id":"b"}`+"\n" {
		t.Errorf("artifact = %q, want the two documents verbatim, one per line", got)
	}

	raw, err := os.ReadFile(path + exportMetaSuffix)
	if err != nil {
		t.Fatalf("read sidecar: %v", err)
	}
	var meta exportMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		t.Fatalf("sidecar is not valid JSON: %v (%s)", err, raw)
	}
	if meta.Documents != 2 {
		t.Errorf("sidecar documents = %d, want 2", meta.Documents)
	}
	if meta.Bytes != int64(len(body)) {
		t.Errorf("sidecar bytes = %d, want %d (the file's real size)", meta.Bytes, len(body))
	}
	sum := sha256.Sum256(body)
	if meta.SHA256 != hex.EncodeToString(sum[:]) {
		t.Errorf("sidecar sha256 = %q, want %q (the file's real digest)", meta.SHA256, hex.EncodeToString(sum[:]))
	}
	if meta.Scope != "ws/proj/production" {
		t.Errorf("sidecar scope = %q, want %q — a backup must say WHICH dataset it is", meta.Scope, "ws/proj/production")
	}
	if _, err := time.Parse(time.RFC3339, meta.CompletedAt); err != nil {
		t.Errorf("sidecar completed_at = %q, want an RFC3339 timestamp: %v", meta.CompletedAt, err)
	}
}

// ABSENCE IS THE SIGNAL. A truncated stream must leave the partial file (it is
// evidence) but NO sidecar — that is the whole design: an unattended owner who
// only ever sees the directory listing can tell a whole backup from a stub.
func TestRunExportOutTruncatedLeavesNoSidecar(t *testing.T) {
	srv := exportServeTruncated(t)
	path := filepath.Join(t.TempDir(), "backup.ndjson")

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitGeneric {
		t.Fatalf("runExport exit = %d, want %d (a truncated backup must fail); stderr=%s",
			code, exitGeneric, se.String())
	}
	if _, err := os.Stat(path + exportMetaSuffix); !os.IsNotExist(err) {
		t.Fatalf("sidecar %s exists after a truncated export (err=%v) — absence IS the truncation signal",
			path+exportMetaSuffix, err)
	}
	// The partial artifact itself is kept, and named as PARTIAL on stderr.
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read partial artifact: %v", err)
	}
	if n := strings.Count(string(body), "\n"); n != 3 {
		t.Errorf("partial artifact = %q, want the 3 documents that did arrive", string(body))
	}
	if !strings.Contains(se.String(), path+" is PARTIAL, do not restore from it") {
		t.Errorf("stderr = %q, want it to name %s PARTIAL", se.String(), path)
	}
}

// A sidecar from an EARLIER, complete export would vouch for the file a later
// run truncates on top of. It must be cleared before the first byte lands.
func TestRunExportOutClearsStaleSidecarBeforeWriting(t *testing.T) {
	srv := exportServeTruncated(t)
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	if err := os.WriteFile(path+exportMetaSuffix, []byte(`{"documents":999,"sha256":"stale"}`), 0o644); err != nil {
		t.Fatalf("seed stale sidecar: %v", err)
	}

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitGeneric {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitGeneric, se.String())
	}
	if _, err := os.Stat(path + exportMetaSuffix); !os.IsNotExist(err) {
		t.Fatalf("stale sidecar survived a truncated re-export (err=%v) — it would attest a stub", err)
	}
}

// ROUND TRIP. --verify re-derives the digest and count from the artifact alone
// and agrees with the sidecar. No stderr, no exit code, no log involved.
func TestRunExportVerifyAcceptsCompleteArtifact(t *testing.T) {
	srv := exportServeDocs(t, "a", "b", "c")
	path := filepath.Join(t.TempDir(), "backup.ndjson")

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}
	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}

	var vo, ve bytes.Buffer
	vout := newWriter(&vo, &ve)
	if code := runExport(vout, globals{}, manifest.Context{}, []string{"--verify", path}); code != exitOK {
		t.Fatalf("verify exit = %d, want %d; stderr=%s", code, exitOK, ve.String())
	}
	if !strings.Contains(vo.String(), "verified: 3 documents") {
		t.Errorf("stdout = %q, want the re-derived count", vo.String())
	}
}

// FAIL CLOSED — the load-bearing branch. scripts/pds-pull-proof.sh's precedent
// treats a missing meta as a pass (`""|full) return 0`); this one must REFUSE.
// Delete the os.IsNotExist refusal in runExportVerify and this test reds.
func TestRunExportVerifyRefusesMissingSidecar(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	if err := os.WriteFile(path, []byte(`{"_id":"a"}`+"\n"), 0o644); err != nil {
		t.Fatalf("seed artifact: %v", err)
	}

	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	if code := runExport(out, globals{}, manifest.Context{}, []string{"--verify", path}); code != exitGeneric {
		t.Fatalf("verify exit = %d, want %d — an unattested artifact must REFUSE, never pass; stderr=%s",
			code, exitGeneric, se.String())
	}
	if !strings.Contains(se.String(), "no sidecar") || !strings.Contains(se.String(), "PARTIAL") {
		t.Errorf("stderr = %q, want it to say there is no sidecar and the file must be treated as PARTIAL", se.String())
	}
}

// The other fail-closed shapes: a sidecar that exists but says nothing usable is
// no better than none. Each must refuse, and none may be mistaken for a pass.
func TestRunExportVerifyRefusesUnusableSidecar(t *testing.T) {
	cases := []struct {
		name string
		meta string
		want string
	}{
		{"empty", "   \n", "is empty"},
		{"unparsable", "{not json", "not valid JSON"},
		{"no sha256", `{"documents":1,"bytes":12}`, "carries no sha256"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "backup.ndjson")
			if err := os.WriteFile(path, []byte(`{"_id":"a"}`+"\n"), 0o644); err != nil {
				t.Fatalf("seed artifact: %v", err)
			}
			if err := os.WriteFile(path+exportMetaSuffix, []byte(tc.meta), 0o644); err != nil {
				t.Fatalf("seed sidecar: %v", err)
			}

			var so, se bytes.Buffer
			out := newWriter(&so, &se)
			if code := runExport(out, globals{}, manifest.Context{}, []string{"--verify", path}); code != exitGeneric {
				t.Fatalf("verify exit = %d, want %d; stderr=%s", code, exitGeneric, se.String())
			}
			if !strings.Contains(se.String(), tc.want) {
				t.Errorf("stderr = %q, want it to contain %q", se.String(), tc.want)
			}
			if strings.Contains(so.String(), "verified") {
				t.Errorf("stdout = %q, must not claim a verification", so.String())
			}
		})
	}
}

// A file cut AFTER its sidecar was written (a copy that died, a disk that filled
// during a move) must be caught by the re-derived digest, not trusted because a
// sidecar happens to sit next to it.
func TestRunExportVerifyRefusesTamperedArtifact(t *testing.T) {
	srv := exportServeDocs(t, "a", "b", "c")
	path := filepath.Join(t.TempDir(), "backup.ndjson")

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}
	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read artifact: %v", err)
	}
	// Cut the last document, sidecar untouched.
	if err := os.WriteFile(path, body[:len(body)-len(`{"_id":"c"}`+"\n")], 0o644); err != nil {
		t.Fatalf("truncate artifact: %v", err)
	}

	var vo, ve bytes.Buffer
	vout := newWriter(&vo, &ve)
	if code := runExport(vout, globals{}, manifest.Context{}, []string{"--verify", path}); code != exitGeneric {
		t.Fatalf("verify exit = %d, want %d for a cut artifact; stderr=%s", code, exitGeneric, ve.String())
	}
	if !strings.Contains(ve.String(), "does NOT match its sidecar") {
		t.Errorf("stderr = %q, want the mismatch named", ve.String())
	}
	if !strings.Contains(ve.String(), "2 documents, sidecar says 3") {
		t.Errorf("stderr = %q, want both counts so an operator can see the size of the loss", ve.String())
	}
}

// --verify inspects a file that already exists; combining it with the streaming
// flags would silently drop half the command.
func TestRunExportVerifyRejectsStreamingFlags(t *testing.T) {
	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	code := runExport(out, globals{}, manifest.Context{}, []string{"--verify", "f.ndjson", "--type", "post"})

	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage (%d); stderr=%s", code, exitUsage, se.String())
	}
	if !strings.Contains(se.String(), "cannot be combined") {
		t.Errorf("stderr = %q, want it to explain the conflict", se.String())
	}
}
