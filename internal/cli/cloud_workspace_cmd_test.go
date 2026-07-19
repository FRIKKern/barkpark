package cli

// cloud_workspace_cmd_test.go proves `bp cloud workspace export|import` against a
// mock CONTENT API (httptest.NewServer, the V3 harness shape) — never the live
// B1 route and never the SSH instSSHStream seam. The three load-bearing claims:
// export streams the tar to a file (a Bearer-authed GET), import REFUSES without
// --yes (and sends nothing), and import with --yes POSTs the exact file bytes and
// prints the {tables,total_rows} receipt. A dry-run and the admin-token gate are
// covered too.

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// workspaceEnvIsolate clears the BARKPARK_* content-context env vars so the test
// resolves its target purely from the globals it passes (the httptest URL +
// token), never from an ambient dev shell. Pairs with withTempConfigHome for a
// hermetic config layer.
func workspaceEnvIsolate(t *testing.T) {
	t.Helper()
	withTempConfigHome(t)
	for _, k := range []string{"BARKPARK_API_URL", "BARKPARK_SERVER", "BARKPARK_API_TOKEN"} {
		t.Setenv(k, "")
	}
}

// acceptNegotiatesJSON mirrors the server's `:accepts ["json"]` matcher: a set
// Accept header must offer json (application/json or the */* wildcard) or the
// request 406s in the `:api` pipeline BEFORE it reaches the controller. The
// workspace export route rides that pipeline even though the controller answers
// application/x-tar — AcceptBarkparkVendor appends json for a bare x-tar, and a
// spec-clean client states both. The mock enforces the invariant so a regression
// to a non-negotiable Accept (the class the 200-always mock hid since #3012)
// fails the test instead of silently passing.
func acceptNegotiatesJSON(accept string) bool {
	if strings.TrimSpace(accept) == "" {
		return true
	}
	return strings.Contains(accept, "application/json") || strings.Contains(accept, "*/*")
}

// runWorkspace drives the FULL runCloud dispatcher (case "workspace") with an
// in-memory writer and the given globals, returning stdout, stderr, exit. Driving
// runCloud (not runCloudWorkspace) proves the switch wiring, per the V3 pattern.
func runWorkspace(t *testing.T, g globals, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = false
	code := runCloud(w, g, append([]string{"workspace"}, args...))
	return sout.String(), serr.String(), code
}

// TestCloudWorkspaceExportWritesFile: export GETs the bundle route with the admin
// bearer and streams the tar body verbatim to --file.
func TestCloudWorkspaceExportWritesFile(t *testing.T) {
	workspaceEnvIsolate(t)
	const tarBytes = "BUNDLE-TAR-BYTES-\x00\x01\x02-workspace-acme"
	var gotMethod, gotPath, gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		// Mirror the server's `:accepts ["json"]` matcher: a bare
		// `application/x-tar` Accept 406s in the `:api` pipeline before the
		// controller runs. Enforcing it here means a regression to a
		// non-json-negotiable export Accept FAILS this test instead of hiding
		// behind a 200-always mock (the class latent since #3012).
		if !acceptNegotiatesJSON(r.Header.Get("Accept")) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotAcceptable)
			_, _ = w.Write([]byte(`{"error":{"code":"not_acceptable","message":"Accept cannot negotiate json"}}`))
			return
		}
		w.Header().Set("Content-Type", "application/x-tar")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(tarBytes))
	}))
	t.Cleanup(srv.Close)

	outFile := filepath.Join(t.TempDir(), "acme.tar")
	g := globals{server: srv.URL, token: "admin-tok"}
	stdout, stderr, code := runWorkspace(t, g, "table", "export", "acme", "--file", outFile)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if gotMethod != "GET" || gotPath != "/api/workspaces/acme/export" {
		t.Fatalf("hit %s %s, want GET /api/workspaces/acme/export", gotMethod, gotPath)
	}
	if gotAuth != "Bearer admin-tok" {
		t.Fatalf("auth = %q, want Bearer admin-tok", gotAuth)
	}
	got, err := os.ReadFile(outFile)
	if err != nil {
		t.Fatalf("read export file: %v", err)
	}
	if string(got) != tarBytes {
		t.Fatalf("export file bytes = %q, want the tar body verbatim", string(got))
	}
	if !strings.Contains(stdout, "Exported workspace acme") {
		t.Fatalf("stdout missing export receipt:\n%s", stdout)
	}
}

// TestCloudWorkspaceImportRefusesWithoutYes: import is destructive — without --yes
// it refuses (exit 2) and sends NO request to the server.
func TestCloudWorkspaceImportRefusesWithoutYes(t *testing.T) {
	workspaceEnvIsolate(t)
	hit := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"tables":1,"total_rows":1}`))
	}))
	t.Cleanup(srv.Close)

	tarFile := filepath.Join(t.TempDir(), "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	g := globals{server: srv.URL, token: "admin-tok"} // no yes
	stdout, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile)
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (refusal)\nstdout:%s\nstderr:%s", code, exitUsage, stdout, stderr)
	}
	if hit {
		t.Fatalf("import without --yes MUST NOT reach the server")
	}
	if !strings.Contains(stderr, "--yes") {
		t.Fatalf("refusal should name --yes, got stderr:\n%s", stderr)
	}
}

// TestCloudWorkspaceImportPostsBytesWithYes: with --yes, import POSTs the exact
// file bytes to the import route (admin bearer, application/x-tar) and prints the
// {tables,total_rows} receipt the engine returned.
func TestCloudWorkspaceImportPostsBytesWithYes(t *testing.T) {
	workspaceEnvIsolate(t)
	const tarBytes = "BUNDLE-TAR-\x00\xff-payload"
	var gotMethod, gotPath, gotAuth, gotCT string
	var gotBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath = r.Method, r.URL.Path
		gotAuth, gotCT = r.Header.Get("Authorization"), r.Header.Get("Content-Type")
		gotBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"tables":6,"total_rows":42}`))
	}))
	t.Cleanup(srv.Close)

	tarFile := filepath.Join(t.TempDir(), "acme.tar")
	if err := os.WriteFile(tarFile, []byte(tarBytes), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	g := globals{server: srv.URL, token: "admin-tok", yes: true}
	stdout, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if gotMethod != "POST" || gotPath != "/api/workspaces/acme/import" {
		t.Fatalf("hit %s %s, want POST /api/workspaces/acme/import", gotMethod, gotPath)
	}
	if gotAuth != "Bearer admin-tok" {
		t.Fatalf("auth = %q, want Bearer admin-tok", gotAuth)
	}
	if gotCT != "application/x-tar" {
		t.Fatalf("content-type = %q, want application/x-tar", gotCT)
	}
	if string(gotBody) != tarBytes {
		t.Fatalf("posted body = %q, want the file bytes verbatim", string(gotBody))
	}
	if !strings.Contains(stdout, "42 rows") || !strings.Contains(stdout, "6 tables") {
		t.Fatalf("stdout missing {tables,total_rows} receipt:\n%s", stdout)
	}
}

// TestCloudWorkspaceImportDryRunPreviews: --dry-run (or the global --dry-run)
// previews the request and sends nothing, even without --yes.
func TestCloudWorkspaceImportDryRunPreviews(t *testing.T) {
	workspaceEnvIsolate(t)
	hit := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
	}))
	t.Cleanup(srv.Close)

	tarFile := filepath.Join(t.TempDir(), "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	g := globals{server: srv.URL, token: "admin-tok", dryRun: true}
	stdout, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if hit {
		t.Fatalf("dry-run MUST NOT reach the server")
	}
	if !strings.Contains(stdout, "DRY RUN") {
		t.Fatalf("dry-run should print a preview line, got:\n%s", stdout)
	}
}

// TestCloudWorkspaceExportForbiddenMapsAuth: the bundle route is admin-gated
// SERVER-SIDE — a non-admin bearer earns a 403, which maps onto the CLI's auth
// exit (3) through the shared error seam. The client carries the bearer and
// surfaces the server's authority honestly rather than second-guessing it.
func TestCloudWorkspaceExportForbiddenMapsAuth(t *testing.T) {
	workspaceEnvIsolate(t)
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"admin required"}}`))
	}))
	t.Cleanup(srv.Close)

	outFile := filepath.Join(t.TempDir(), "acme.tar")
	g := globals{server: srv.URL, token: "non-admin-tok"}
	_, stderr, code := runWorkspace(t, g, "table", "export", "acme", "--file", outFile)
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (403→auth)\nstderr:%s", code, exitAuth, stderr)
	}
	if gotAuth != "Bearer non-admin-tok" {
		t.Fatalf("auth = %q, want the bearer carried to the content API", gotAuth)
	}
	if _, err := os.Stat(outFile); err == nil {
		t.Fatalf("a forbidden export MUST NOT write the output file")
	}
}

// TestCloudWorkspaceImportServerErrorMapsExit: a non-2xx import response maps onto
// the CLI's stable exit-code scheme through the shared error seam (a 404 → exit 4).
func TestCloudWorkspaceImportServerErrorMapsExit(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such workspace"}}`))
	}))
	t.Cleanup(srv.Close)

	tarFile := filepath.Join(t.TempDir(), "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	g := globals{server: srv.URL, token: "admin-tok", yes: true}
	_, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (404)\nstderr:%s", code, exitNotFound, stderr)
	}
}

// TestCloudWorkspaceUnknownVerb: an unknown subcommand is a usage error.
func TestCloudWorkspaceUnknownVerb(t *testing.T) {
	workspaceEnvIsolate(t)
	g := globals{server: "http://127.0.0.1:1", token: "t"}
	_, _, code := runWorkspace(t, g, "table", "frobnicate")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d for an unknown verb", code, exitUsage)
	}
}

// ── PULL DIALECT (PDS wave 1) ────────────────────────────────────────────────
//
// The pull tests below prove the four claims a broken build could NOT also
// produce: the scope flags reach the server as EXACT query params (and an
// unflagged export still sends a bare URL), the blob sidecar round-trips real
// bytes through a real tar, a blob failure is NAMED and exits NON-ZERO with the
// server's own classified code, and the provenance receipt is conditional on the
// response actually carrying the key.

// makeBundleTar builds a minimal bp-export-v1 tar in memory: manifest.json
// declaring the media_files column order, plus the COPY-text dump. This is the
// same container shape WorkspaceBundle.Archive.pack/2 emits, so the parser is
// tested against the real format rather than a convenient stub.
func makeBundleTar(t *testing.T, columns []string, rows [][]string) []byte {
	t.Helper()
	manifest := `{"format":"bp-export-v1","workspace_slug":"acme","tables":[` +
		`{"name":"documents","columns":["id","type"]},` +
		`{"name":"media_files","columns":["` + strings.Join(columns, `","`) + `"]}]}`
	var dump strings.Builder
	for _, r := range rows {
		dump.WriteString(strings.Join(r, "\t"))
		dump.WriteString("\n")
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	write := func(name, body string) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(body))}); err != nil {
			t.Fatalf("tar header %s: %v", name, err)
		}
		if _, err := tw.Write([]byte(body)); err != nil {
			t.Fatalf("tar body %s: %v", name, err)
		}
	}
	// Members deliberately out of "nice" order: the parser must not assume the
	// manifest arrives before the dump.
	write("tables/media_files.copy", dump.String())
	write("manifest.json", manifest)
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	return buf.Bytes()
}

// TestCloudWorkspaceExportScopeParams: --profile/--dataset reach the server as
// the exact query params, and an UNFLAGGED export still sends a bare URL (the
// shipped B2 request, byte-identical).
func TestCloudWorkspaceExportScopeParams(t *testing.T) {
	workspaceEnvIsolate(t)
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/x-tar")
		_, _ = w.Write([]byte("TAR"))
	}))
	t.Cleanup(srv.Close)

	dir := t.TempDir()
	g := globals{server: srv.URL, token: "admin-tok"}

	if _, _, code := runWorkspace(t, g, "table", "export", "acme",
		"--file", filepath.Join(dir, "a.tar"), "--profile", "dev", "--dataset", "production"); code != exitOK {
		t.Fatalf("scoped export exit = %d, want 0", code)
	}
	if gotQuery != "dataset=production&profile=dev" {
		t.Fatalf("query = %q, want dataset=production&profile=dev", gotQuery)
	}

	if _, _, code := runWorkspace(t, g, "table", "export", "acme", "--file", filepath.Join(dir, "b.tar")); code != exitOK {
		t.Fatalf("unflagged export exit = %d, want 0", code)
	}
	if gotQuery != "" {
		t.Fatalf("unflagged export query = %q, want empty (the shipped B2 request)", gotQuery)
	}
}

// TestCloudWorkspaceImportMergeMode: --merge sends ?mode=merge; without it the
// import URL carries no query at all.
func TestCloudWorkspaceImportMergeMode(t *testing.T) {
	workspaceEnvIsolate(t)
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"tables":1,"total_rows":1,"mode":"merge"}`))
	}))
	t.Cleanup(srv.Close)

	tarFile := filepath.Join(t.TempDir(), "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	g := globals{server: srv.URL, token: "admin-tok", yes: true}

	if _, _, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile, "--merge"); code != exitOK {
		t.Fatalf("merge import exit = %d, want 0", code)
	}
	if gotQuery != "mode=merge" {
		t.Fatalf("query = %q, want mode=merge", gotQuery)
	}

	if _, _, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile); code != exitOK {
		t.Fatalf("clean import exit = %d, want 0", code)
	}
	if gotQuery != "" {
		t.Fatalf("clean import query = %q, want empty", gotQuery)
	}
}

// TestCloudWorkspaceExportWithBlobsStreamsSidecar: the sidecar reads the REAL
// tar's media_files member (column order taken from the manifest, COPY escapes
// unescaped) and streams each blob to <bundle>.blobs/<path> verbatim.
func TestCloudWorkspaceExportWithBlobsStreamsSidecar(t *testing.T) {
	workspaceEnvIsolate(t)
	blobs := map[string]string{
		"2026/07/5-styleguide-dark-338df37b.png": "PNG-BYTES-\x00\x01",
		"2026/06/cover-a1b2c3d4.jpg":             "JPEG-BYTES",
	}
	bundle := makeBundleTar(t,
		[]string{"id", "path", "workspace_id"},
		[][]string{
			{"id-1", "2026/07/5-styleguide-dark-338df37b.png", "ws-1"},
			{"id-2", "2026/06/cover-a1b2c3d4.jpg", "ws-1"},
			{"id-3", "\\N", "ws-1"}, // NULL path — no blob to move, must not fail
		})

	var served []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/media/files/") {
			p := strings.TrimPrefix(r.URL.Path, "/media/files/")
			served = append(served, p)
			body, ok := blobs[p]
			if !ok {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such blob"}}`))
				return
			}
			_, _ = w.Write([]byte(body))
			return
		}
		w.Header().Set("Content-Type", "application/x-tar")
		_, _ = w.Write(bundle)
	}))
	t.Cleanup(srv.Close)

	outFile := filepath.Join(t.TempDir(), "acme.tar")
	g := globals{server: srv.URL, token: "admin-tok"}
	stdout, stderr, code := runWorkspace(t, g, "table", "export", "acme", "--file", outFile, "--with-blobs")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if len(served) != 2 {
		t.Fatalf("fetched %v, want exactly the 2 non-NULL media paths", served)
	}
	for p, want := range blobs {
		got, err := os.ReadFile(filepath.Join(outFile+".blobs", filepath.FromSlash(p)))
		if err != nil {
			t.Fatalf("sidecar blob %s: %v", p, err)
		}
		if string(got) != want {
			t.Fatalf("sidecar blob %s = %q, want %q", p, string(got), want)
		}
	}
	if !strings.Contains(stdout, "Blobs: 2 fetched, 0 failed") {
		t.Fatalf("missing honest blob report:\n%s", stdout)
	}
}

// TestCloudWorkspaceExportBlobFailureExitsNonZero: a blob the source cannot serve
// is NAMED and the command exits non-zero with the server's classified code — a
// partial media set never reports success.
func TestCloudWorkspaceExportBlobFailureExitsNonZero(t *testing.T) {
	workspaceEnvIsolate(t)
	bundle := makeBundleTar(t,
		[]string{"id", "path"},
		[][]string{{"id-1", "2026/07/gone-deadbeef.png"}})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/media/files/") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such blob"}}`))
			return
		}
		w.Header().Set("Content-Type", "application/x-tar")
		_, _ = w.Write(bundle)
	}))
	t.Cleanup(srv.Close)

	outFile := filepath.Join(t.TempDir(), "acme.tar")
	g := globals{server: srv.URL, token: "admin-tok"}
	stdout, stderr, code := runWorkspace(t, g, "table", "export", "acme", "--file", outFile, "--with-blobs")
	if code == exitOK {
		t.Fatalf("a failed blob MUST exit non-zero\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (the server's classified code, not a blanket 1)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "2026/07/gone-deadbeef.png") {
		t.Fatalf("failure must NAME the blob, got stderr:\n%s", stderr)
	}
	if !strings.Contains(stdout, "0 fetched, 1 failed") {
		t.Fatalf("report must own the failure count:\n%s", stdout)
	}
}

// TestCloudWorkspaceImportWithBlobsPutsPathVerbatim: every sidecar file is PUT to
// the blob route under its path RELATIVE to the sidecar dir, byte-verbatim, as
// application/octet-stream (a JSON content-type would earn a 422 empty_body).
func TestCloudWorkspaceImportWithBlobsPutsPathVerbatim(t *testing.T) {
	workspaceEnvIsolate(t)
	got := map[string]string{}
	var gotCT string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			body, _ := io.ReadAll(r.Body)
			got[r.URL.Path] = string(body)
			gotCT = r.Header.Get("Content-Type")
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"written":"ok","bytes":` + fmt.Sprint(len(body)) + `}`))
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"tables":6,"total_rows":42}`))
	}))
	t.Cleanup(srv.Close)

	dir := t.TempDir()
	tarFile := filepath.Join(dir, "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	blobDir := tarFile + ".blobs"
	if err := os.MkdirAll(filepath.Join(blobDir, "2026", "07"), 0o755); err != nil {
		t.Fatalf("seed blob dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(blobDir, "2026", "07", "pic-abcd1234.png"), []byte("PNG\x00\xff"), 0o644); err != nil {
		t.Fatalf("seed blob: %v", err)
	}

	g := globals{server: srv.URL, token: "admin-tok", yes: true}
	stdout, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile, "--with-blobs")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	want := "/api/workspaces/acme/media/blob/2026/07/pic-abcd1234.png"
	if got[want] != "PNG\x00\xff" {
		t.Fatalf("PUT bodies = %#v, want the blob bytes at %s", got, want)
	}
	if gotCT != "application/octet-stream" {
		t.Fatalf("blob content-type = %q, want application/octet-stream", gotCT)
	}
	if !strings.Contains(stdout, "Blobs: 1 uploaded, 0 failed") {
		t.Fatalf("missing upload report:\n%s", stdout)
	}
}

// TestCloudWorkspaceImportBlobInvalidPathExitsValidation: the blob route's live
// 422 codes map onto exit 5 through codeExit — pinned on the EXIT CODE, not the
// HTTP status (the CLI never re-derives an exit from a status).
func TestCloudWorkspaceImportBlobInvalidPathExitsValidation(t *testing.T) {
	for _, tc := range []struct{ code, message string }{
		{"invalid_path", "invalid blob path"},
		{"empty_body", "empty blob body — send the raw bytes as application/octet-stream"},
	} {
		t.Run(tc.code, func(t *testing.T) {
			workspaceEnvIsolate(t)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPut {
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusUnprocessableEntity)
					_, _ = w.Write([]byte(`{"error":{"code":"` + tc.code + `","message":"` + tc.message + `"}}`))
					return
				}
				_, _ = io.Copy(io.Discard, r.Body)
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"tables":1,"total_rows":1}`))
			}))
			t.Cleanup(srv.Close)

			dir := t.TempDir()
			tarFile := filepath.Join(dir, "acme.tar")
			if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
				t.Fatalf("seed tar: %v", err)
			}
			blobDir := tarFile + ".blobs"
			if err := os.MkdirAll(blobDir, 0o755); err != nil {
				t.Fatalf("seed blob dir: %v", err)
			}
			if err := os.WriteFile(filepath.Join(blobDir, "shot-12345678.png"), []byte("PNG"), 0o644); err != nil {
				t.Fatalf("seed blob: %v", err)
			}

			g := globals{server: srv.URL, token: "admin-tok", yes: true}
			_, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile, "--with-blobs")
			if code != exitValidation {
				t.Fatalf("exit = %d, want %d for %s", code, exitValidation, tc.code)
			}
			if !strings.Contains(stderr, "shot-12345678.png") {
				t.Fatalf("failure must NAME the blob, got stderr:\n%s", stderr)
			}
		})
	}
}

// TestBlobErrorCodesMapToValidation: the codeExit table itself carries both live
// blob 422 codes — the unit that keeps the doc table and the map honest.
func TestBlobErrorCodesMapToValidation(t *testing.T) {
	for _, code := range []string{"invalid_path", "empty_body"} {
		if got := exitForCode(code); got != exitValidation {
			t.Fatalf("exitForCode(%q) = %d, want %d (docs/cli/error-exit-table.md)", code, got, exitValidation)
		}
	}
}

// TestCloudWorkspaceImportProvenanceReceipt: the receipt prints when the response
// carries a `provenance` key and stays SILENT when it does not — mocked, so this
// slice never waited on the provenance-guard slice.
func TestCloudWorkspaceImportProvenanceReceipt(t *testing.T) {
	const withProv = `{"tables":6,"total_rows":42,"provenance":{"source_server":"https://guerrilla.barkpark.cloud","dataset":"production","profile":"dev","pulled_at":"2026-07-19T19:00:00Z"}}`
	const withoutProv = `{"tables":6,"total_rows":42}`

	for _, tc := range []struct {
		name string
		body string
		want bool
	}{
		{"stamped", withProv, true},
		{"unstamped", withoutProv, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			workspaceEnvIsolate(t)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.Copy(io.Discard, r.Body)
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(tc.body))
			}))
			t.Cleanup(srv.Close)

			tarFile := filepath.Join(t.TempDir(), "acme.tar")
			if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
				t.Fatalf("seed tar: %v", err)
			}
			g := globals{server: srv.URL, token: "admin-tok", yes: true}
			stdout, _, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile)
			if code != exitOK {
				t.Fatalf("exit = %d, want 0", code)
			}
			has := strings.Contains(stdout, "Provenance")
			if has != tc.want {
				t.Fatalf("provenance printed = %v, want %v\nstdout:%s", has, tc.want, stdout)
			}
			if tc.want {
				for _, frag := range []string{"guerrilla.barkpark.cloud", "production", "dev", "2026-07-19T19:00:00Z"} {
					if !strings.Contains(stdout, frag) {
						t.Fatalf("receipt missing %q:\n%s", frag, stdout)
					}
				}
			}
		})
	}
}

// TestCloudTargetWarningIsCloudOnly: the advisory line fires for a cloud-
// classified target and is absent for a local one. UX only — neither branch
// refuses anything (the enforcement is the server's 403 bundle_import_disabled).
func TestCloudTargetWarningIsCloudOnly(t *testing.T) {
	withTempConfigHome(t)
	if w := cloudTargetWarning("https://guerrilla.barkpark.cloud", "acme"); w == "" {
		t.Fatalf("a cloud target must earn a warning")
	} else if !strings.Contains(w, "cloud") || !strings.Contains(w, "acme") {
		t.Fatalf("warning should name the target and the workspace, got %q", w)
	}
	for _, local := range []string{"http://localhost:4000", "http://127.0.0.1:4000", "http://192.168.1.9:4000"} {
		if w := cloudTargetWarning(local, "acme"); w != "" {
			t.Fatalf("local target %s must NOT warn, got %q", local, w)
		}
	}
}

// TestCloudWorkspaceImportLocalTargetDoesNotWarn: the httptest loopback target is
// local, so the write proceeds with no warning line — proving the warning is
// classified, not unconditional noise.
func TestCloudWorkspaceImportLocalTargetDoesNotWarn(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"tables":1,"total_rows":1}`))
	}))
	t.Cleanup(srv.Close)

	tarFile := filepath.Join(t.TempDir(), "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	g := globals{server: srv.URL, token: "admin-tok", yes: true}
	_, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if strings.Contains(stderr, "[cloud]") {
		t.Fatalf("loopback target must not print the cloud warning, got:\n%s", stderr)
	}
}

// TestCloudWorkspaceExportWithBlobsRefusesStdout: the sidecar re-reads the saved
// bundle, so `--file -` + `--with-blobs` is refused up front rather than half-run.
func TestCloudWorkspaceExportWithBlobsRefusesStdout(t *testing.T) {
	workspaceEnvIsolate(t)
	hit := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hit = true }))
	t.Cleanup(srv.Close)
	g := globals{server: srv.URL, token: "admin-tok"}
	_, stderr, code := runWorkspace(t, g, "table", "export", "acme", "--file", "-", "--with-blobs")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if hit {
		t.Fatalf("the refusal must happen before any request")
	}
	if !strings.Contains(stderr, "--with-blobs") {
		t.Fatalf("refusal should name the flag, got:\n%s", stderr)
	}
}

// TestBundleMediaPathsHonoursManifestColumnOrder: the path column is located via
// the MANIFEST's declared column list, never a positional assumption, and COPY
// escapes round-trip. A bundle with no media_files member is 0 blobs, not an error.
func TestBundleMediaPathsHonoursManifestColumnOrder(t *testing.T) {
	dir := t.TempDir()
	// `path` is the THIRD column here — a positional guess would read the wrong field.
	bundle := makeBundleTar(t,
		[]string{"id", "workspace_id", "path", "title"},
		[][]string{
			{"id-1", "ws", "2026/07/a-11112222.png", "A\\tB"},
			{"id-2", "ws", "2026/07/a-11112222.png", "dup"},
			{"id-3", "ws", "\\N", "no path"},
		})
	f := filepath.Join(dir, "b.tar")
	if err := os.WriteFile(f, bundle, 0o644); err != nil {
		t.Fatalf("write bundle: %v", err)
	}
	got, err := bundleMediaPaths(f)
	if err != nil {
		t.Fatalf("bundleMediaPaths: %v", err)
	}
	if len(got) != 1 || got[0] != "2026/07/a-11112222.png" {
		t.Fatalf("paths = %#v, want the single de-duplicated path", got)
	}
}

// TestSafeBlobPathRejectsTraversal: the client-side fence refuses anything that
// could escape the sidecar dir before it ever becomes a filesystem destination.
func TestSafeBlobPathRejectsTraversal(t *testing.T) {
	for _, bad := range []string{"", "  ", "/etc/passwd", "../../etc/passwd", "2026/../../x.png", "2026//x.png", "a\\b.png", "./x.png"} {
		if safeBlobPath(bad) {
			t.Fatalf("safeBlobPath(%q) = true, want false", bad)
		}
	}
	for _, ok := range []string{"2026/07/5-styleguide-dark-338df37b.png", "x.png"} {
		if !safeBlobPath(ok) {
			t.Fatalf("safeBlobPath(%q) = false, want true", ok)
		}
	}
}
