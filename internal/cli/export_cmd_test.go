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
// The CLOSE-DELIMITED sibling — no Content-Length, no chunked framing, so a
// truncated body is byte-identical to a complete one — used to be recorded here
// as an accepted limit (measured: 3 docs, empty stderr, exit 0). It is not one
// any more: since #14597 Export refuses to attest that framing, and
// TestRunExportOutCloseDelimitedWritesNoSidecarAndVerifyRefuses proves the
// refusal reaches the sidecar and `--verify`. Production uses send_chunked — the
// honest framing this test exercises.
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

// ABSENCE IS THE SIGNAL, AND THE STUB IS OFF TO THE SIDE. A truncated stream
// keeps what it got — it is evidence — but that wreckage lives at
// <file>.partial, never at <file>, and it is never attested. The destination
// name is not touched at all on this path: with no earlier backup there it does
// not even exist afterwards, which is why an unattended owner reading only the
// directory listing still cannot mistake a stub for a backup.
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
	if _, err := os.Stat(path + exportPartialSuffix + exportMetaSuffix); !os.IsNotExist(err) {
		t.Fatalf("the partial carries a sidecar %s (err=%v) — nothing incomplete may be attested anywhere",
			path+exportPartialSuffix+exportMetaSuffix, err)
	}
	// The destination is never opened on a failed run, so a first-ever export
	// that dies leaves no file there to be mistaken for a backup.
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("%s exists after a truncated first export (err=%v) — the destination must not be touched", path, err)
	}
	// The stub itself is kept at .partial, and named as PARTIAL on stderr.
	body, err := os.ReadFile(path + exportPartialSuffix)
	if err != nil {
		t.Fatalf("read partial artifact: %v", err)
	}
	if n := strings.Count(string(body), "\n"); n != 3 {
		t.Errorf("partial artifact = %q, want the 3 documents that did arrive", string(body))
	}
	if !strings.Contains(se.String(), path+exportPartialSuffix+" is PARTIAL, do not restore from it") {
		t.Errorf("stderr = %q, want it to name %s PARTIAL", se.String(), path+exportPartialSuffix)
	}
}

// THE INVERSION. This test used to demand that a sidecar be cleared before the
// first byte landed, which was correct only while the first byte destroyed the
// file that sidecar attested. Under the rename that file survives a failed
// re-export untouched — so removing its sidecar would strip the attestation off
// an intact backup and `--verify`, which fails closed, would then REFUSE the
// one good copy the operator has. The sidecar must survive with its file.
func TestRunExportOutTruncatedKeepsPriorSidecar(t *testing.T) {
	srv := exportServeTruncated(t)
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	prior := []byte(`{"documents":999,"sha256":"prior"}`)
	if err := os.WriteFile(path, []byte(`{"_id":"old"}`+"\n"), 0o644); err != nil {
		t.Fatalf("seed prior artifact: %v", err)
	}
	if err := os.WriteFile(path+exportMetaSuffix, prior, 0o644); err != nil {
		t.Fatalf("seed prior sidecar: %v", err)
	}

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitGeneric {
		t.Fatalf("runExport exit = %d, want %d; stderr=%s", code, exitGeneric, se.String())
	}
	got, err := os.ReadFile(path + exportMetaSuffix)
	if err != nil {
		t.Fatalf("prior sidecar did not survive a truncated re-export: %v — it attests a file that survived", err)
	}
	if !bytes.Equal(got, prior) {
		t.Errorf("prior sidecar = %q, want it byte-identical to %q — nothing in this run wrote it", got, prior)
	}
}

// THE INVARIANT THIS SLICE EXISTS FOR, end to end. Last night's export is real
// and attested; tonight's dies mid-stream on top of it. Afterwards the operator
// must still have last night's backup — the same bytes, the same sidecar — and
// `bp export --verify` must still PASS on it. Before the rename this scenario
// left a zero-truncated file and no sidecar: the good backup was gone and the
// verb had reported the loss only on a stderr nobody reads.
func TestRunExportOutTruncatedReExportLeavesPriorBackupVerifiable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup.ndjson")

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{Server: exportServeDocs(t, "a", "b", "c").URL, Workspace: "ws", Project: "proj", Dataset: "production"}
	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitOK {
		t.Fatalf("seeding export exit = %d; stderr=%s", code, se.String())
	}
	good, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read good backup: %v", err)
	}
	goodMeta, err := os.ReadFile(path + exportMetaSuffix)
	if err != nil {
		t.Fatalf("read good sidecar: %v", err)
	}

	// Tonight's run dies after three documents, aimed at the same path.
	var fo, fe bytes.Buffer
	fout := newWriter(&fo, &fe)
	fctx := manifest.Context{Server: exportServeTruncated(t).URL, Dataset: "production"}
	if code := runExport(fout, globals{}, fctx, []string{"--out", path}); code != exitGeneric {
		t.Fatalf("truncated re-export exit = %d, want %d; stderr=%s", code, exitGeneric, fe.String())
	}

	nowBody, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the good backup is GONE after a failed re-export: %v", err)
	}
	if !bytes.Equal(nowBody, good) {
		t.Errorf("backup = %q, want last night's bytes %q — a failed run may not edit the destination", nowBody, good)
	}
	nowMeta, err := os.ReadFile(path + exportMetaSuffix)
	if err != nil {
		t.Fatalf("the good backup's sidecar is GONE: %v — an intact backup must stay attested", err)
	}
	if !bytes.Equal(nowMeta, goodMeta) {
		t.Errorf("sidecar = %q, want the untouched %q", nowMeta, goodMeta)
	}

	// The proof that matters to the operator: the verb that fails closed still
	// says yes.
	var vo, ve bytes.Buffer
	vout := newWriter(&vo, &ve)
	if code := runExport(vout, globals{}, manifest.Context{}, []string{"--verify", path}); code != exitOK {
		t.Fatalf("verify exit = %d, want %d on the INTACT prior backup; stderr=%s", code, exitOK, ve.String())
	}
	if !strings.Contains(vo.String(), "verified: 3 documents") {
		t.Errorf("stdout = %q, want the prior backup verified", vo.String())
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
