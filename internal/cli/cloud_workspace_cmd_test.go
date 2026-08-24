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
	"compress/gzip"
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
	// axi-b4: derived from the shared dialect lists — a hand-written copy here
	// silently reads whatever the developer exported (measured: on a machine
	// exporting BARKPARK_TOKEN, this suite resolved a live admin token in place
	// of its own fixture).
	for _, k := range append(append([]string{}, ServerEnvNames...), TokenEnvNames...) {
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

// realImportReceipt is the import response shape the SERVER actually sends:
// `tables` is a MAP of table name → row count (Barkpark.Tenancy.WorkspaceBundle
// typespecs it at workspace_bundle.ex:182; both import arms pass `stats.tables`
// through verbatim at workspace_controller.ex:330 and :348). Six members, 42
// rows — the numbers the older `{"tables":6,…}` mocks claimed while hiding that
// the client could not read the real shape at all.
const realImportReceipt = `{"tables":{"workspaces":1,"projects":1,"datasets":1,"documents":30,"media_files":6,"roles":3},"total_rows":42}`

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
		_, _ = w.Write([]byte(`{"tables":{"documents":1},"total_rows":1}`))
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
		// The REAL receipt shape: `tables` is a map of table → row count
		// (workspace_bundle.ex:182), never a bare integer. The old int mock is
		// what let the double-em-dash bug ship green.
		_, _ = w.Write([]byte(realImportReceipt))
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
	if strings.Contains(stdout, "— rows") || strings.Contains(stdout, "— tables") {
		t.Fatalf("a receipt the client CAN read must print no unknown-count em dash:\n%s", stdout)
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
		_, _ = w.Write([]byte(`{"tables":{"documents":1},"total_rows":1,"mode":"merge"}`))
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
		[]string{"id", "path", "size", "workspace_id"},
		[][]string{
			{"id-1", "2026/07/5-styleguide-dark-338df37b.png", fmt.Sprint(len(blobs["2026/07/5-styleguide-dark-338df37b.png"])), "ws-1"},
			{"id-2", "2026/06/cover-a1b2c3d4.jpg", fmt.Sprint(len(blobs["2026/06/cover-a1b2c3d4.jpg"])), "ws-1"},
			{"id-3", "\\N", "0", "ws-1"}, // NULL path — no blob to move, must not fail
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
	// Both rows declare a size, and both fetches matched it byte for byte.
	if !strings.Contains(stdout, "2 size-verified") {
		t.Fatalf("report must own how many blobs were size-verified:\n%s", stdout)
	}
	if strings.Contains(stdout, "no declared size") {
		t.Fatalf("no row here lacks a declared size:\n%s", stdout)
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
		_, _ = w.Write([]byte(`{"tables":{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6},"total_rows":42}`))
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
				_, _ = w.Write([]byte(`{"tables":{"documents":1},"total_rows":1}`))
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
	const withProv = `{"tables":{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6},"total_rows":42,"provenance":{"source_server":"https://guerrilla.barkpark.cloud","dataset":"production","profile":"dev","pulled_at":"2026-07-19T19:00:00Z"}}`
	const withoutProv = `{"tables":{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6},"total_rows":42}`

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
		_, _ = w.Write([]byte(`{"tables":{"documents":1},"total_rows":1}`))
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

// TestBundleMediaRefsHonoursManifestColumnOrder: the path column is located via
// the MANIFEST's declared column list, never a positional assumption, and COPY
// escapes round-trip. A bundle with no media_files member is 0 blobs, not an error.
func TestBundleMediaRefsHonoursManifestColumnOrder(t *testing.T) {
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
	got, err := bundleMediaRefs(f)
	if err != nil {
		t.Fatalf("bundleMediaRefs: %v", err)
	}
	if len(got) != 1 || got[0].path != "2026/07/a-11112222.png" {
		t.Fatalf("refs = %#v, want the single de-duplicated path", got)
	}
	// This manifest declares NO size column: the refs still carry the paths, and
	// they honestly report that there is nothing to verify a fetch against.
	if got[0].sizeKnown {
		t.Fatalf("ref = %#v, want sizeKnown=false when the manifest declares no size column", got[0])
	}
}

// TestBundleMediaRefsReadsDeclaredSize: when the manifest declares the (real,
// non-generated) media_files.size column, each ref carries the declared byte
// count — and a `\N` size is NOT a zero, it is "nothing declared".
func TestBundleMediaRefsReadsDeclaredSize(t *testing.T) {
	bundle := makeBundleTar(t,
		[]string{"id", "path", "size", "workspace_id"},
		[][]string{
			{"id-1", "2026/07/a-11112222.png", "1234", "ws"},
			{"id-2", "2026/07/b-33334444.jpg", "\\N", "ws"},
		})
	f := filepath.Join(t.TempDir(), "b.tar")
	if err := os.WriteFile(f, bundle, 0o644); err != nil {
		t.Fatalf("write bundle: %v", err)
	}
	got, err := bundleMediaRefs(f)
	if err != nil {
		t.Fatalf("bundleMediaRefs: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("refs = %#v, want 2", got)
	}
	if !got[0].sizeKnown || got[0].size != 1234 {
		t.Fatalf("ref[0] = %#v, want the declared 1234 bytes", got[0])
	}
	if got[1].sizeKnown || got[1].size != 0 {
		t.Fatalf("ref[1] = %#v, want sizeKnown=false for a NULL size (never a fabricated 0)", got[1])
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

// ---------------------------------------------------------------------------
// ARGV-LEVEL export tests (PDS-D62).
//
// Everything above drives runCloud(w, g, args) directly — DOWNSTREAM of
// parseGlobals. That harness structurally cannot see the defect this section
// exists for: `-d/--dataset` is a GLOBAL value flag (globals.go valueFlags), so
// parseGlobals consumes it wherever it appears in argv and the export verb's own
// `dataset` flag always resolved empty — `bp cloud workspace export … --dataset
// production` silently sent NO dataset param while TestCloudWorkspaceExportScopeParams
// stayed green. The tests below enter through Execute(os.Args[1:]) — the same
// path a real invocation takes, parseGlobals included — so the class is
// reachable by a test at all.

// captureExecuteArgv runs Execute(args) with os.Stdout/os.Stderr redirected to pipes
// and returns what the process would have printed plus the exit code. Execute
// builds its writer from the real os.Stdout/os.Stderr at call time, so the swap
// must happen (and be undone) around the call.
func captureExecuteArgv(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	rOut, wOut, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stdout: %v", err)
	}
	rErr, wErr, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stderr: %v", err)
	}
	origOut, origErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = wOut, wErr

	outCh, errCh := make(chan string, 1), make(chan string, 1)
	go func() { b, _ := io.ReadAll(rOut); outCh <- string(b) }()
	go func() { b, _ := io.ReadAll(rErr); errCh <- string(b) }()

	code := Execute(args)

	_ = wOut.Close()
	_ = wErr.Close()
	os.Stdout, os.Stderr = origOut, origErr
	return <-outCh, <-errCh, code
}

// TestCloudWorkspaceExportDatasetSurvivesArgv is the instrument for PDS-D62: an
// EXPLICITLY typed --dataset must reach the server as ?dataset=, in every
// spelling the global parser accepts (`--dataset X`, `--dataset=X`, and a global
// `-d X` placed before the noun). On unpatched code all three send
// `profile=dev` alone.
func TestCloudWorkspaceExportDatasetSurvivesArgv(t *testing.T) {
	workspaceEnvIsolate(t)
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/x-tar")
		_, _ = w.Write([]byte("TAR"))
	}))
	t.Cleanup(srv.Close)
	t.Setenv("BARKPARK_API_URL", srv.URL)
	t.Setenv("BARKPARK_API_TOKEN", "admin-tok")

	dir := t.TempDir()
	spellings := [][]string{
		{"cloud", "workspace", "export", "acme", "--file", filepath.Join(dir, "a.tar"), "--profile", "dev", "--dataset", "production"},
		{"cloud", "workspace", "export", "acme", "--file", filepath.Join(dir, "b.tar"), "--profile", "dev", "--dataset=production"},
		{"-d", "production", "cloud", "workspace", "export", "acme", "--file", filepath.Join(dir, "c.tar"), "--profile", "dev"},
	}
	for _, argv := range spellings {
		gotQuery = ""
		stdout, stderr, code := captureExecuteArgv(t, argv...)
		if code != exitOK {
			t.Fatalf("argv %v: exit = %d, want 0\nstdout:%s\nstderr:%s", argv, code, stdout, stderr)
		}
		if gotQuery != "dataset=production&profile=dev" {
			t.Fatalf("argv %v: query = %q, want dataset=production&profile=dev", argv, gotQuery)
		}
	}
}

// TestCloudWorkspaceExportUnflaggedIgnoresAmbientDataset is the other half of the
// fix, and the reason the cloud_site_cmd.go:163 fallback must NOT be copied
// naively: the global `-d` also carries the saved context's dataset, so an
// unconditional `g.dataset` fallback would silently narrow a bare
// `export --profile dev` to whatever ~/.config/barkpark/config.json holds —
// trading one silent-wrong-answer for another. With an ambient dataset saved and
// no --dataset in argv, the request must carry NO dataset param.
func TestCloudWorkspaceExportUnflaggedIgnoresAmbientDataset(t *testing.T) {
	workspaceEnvIsolate(t)
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/x-tar")
		_, _ = w.Write([]byte("TAR"))
	}))
	t.Cleanup(srv.Close)
	// The ambient layer: a saved config that names a dataset (and the server).
	if err := SaveConfig(&Config{Server: srv.URL, Token: "admin-tok", AdminToken: "admin-tok", Dataset: "ambient-ds"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	dir := t.TempDir()
	stdout, stderr, code := captureExecuteArgv(t,
		"cloud", "workspace", "export", "acme", "--file", filepath.Join(dir, "a.tar"), "--profile", "dev")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if gotQuery != "profile=dev" {
		t.Fatalf("query = %q, want profile=dev alone (an ambient dataset must never narrow an unflagged export)", gotQuery)
	}
}

// TestCloudWorkspaceExportSourceServer: --source-server is threaded into the
// query as ?source_server=, so a CLI-taken bundle can stamp WHERE it came from
// (the server reads params["source_server"] into the manifest; without a CLI
// surface every CLI-taken bundle stamped source_server: null).
func TestCloudWorkspaceExportSourceServer(t *testing.T) {
	workspaceEnvIsolate(t)
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/x-tar")
		_, _ = w.Write([]byte("TAR"))
	}))
	t.Cleanup(srv.Close)
	t.Setenv("BARKPARK_API_URL", srv.URL)
	t.Setenv("BARKPARK_API_TOKEN", "admin-tok")

	dir := t.TempDir()
	stdout, stderr, code := captureExecuteArgv(t, "cloud", "workspace", "export", "acme",
		"--file", filepath.Join(dir, "a.tar"), "--profile", "dev", "--dataset", "production",
		"--source-server", "https://guerrilla.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	want := "dataset=production&profile=dev&source_server=https%3A%2F%2Fguerrilla.barkpark.cloud"
	if gotQuery != want {
		t.Fatalf("query = %q, want %q", gotQuery, want)
	}
}

// TestCloudWorkspaceExportDryRunRendersScope: the --dry-run line an operator
// actually reads names the full scope it would request. A dry run that omits a
// flag the operator typed is the same silent-wrong-answer in preview form.
func TestCloudWorkspaceExportDryRunRendersScope(t *testing.T) {
	workspaceEnvIsolate(t)
	t.Setenv("BARKPARK_API_URL", "https://guerrilla.barkpark.cloud")
	stdout, stderr, code := captureExecuteArgv(t, "--dry-run", "cloud", "workspace", "export", "default",
		"--file", filepath.Join(t.TempDir(), "x.tar"), "--profile", "dev", "--dataset", "production",
		"--source-server", "https://guerrilla.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:%s", code, stderr)
	}
	// The dry-run line rides progressf, which follows the resolved output mode —
	// stdout for the human view, stderr once machine output is in play (a piped
	// test process resolves to the machine default). Assert on both streams:
	// what matters is that the operator sees the full scope, not which fd it
	// arrived on.
	line := stdout + stderr
	for _, want := range []string{"DRY RUN", "profile=dev", "dataset=production", "source_server=https%3A%2F%2Fguerrilla.barkpark.cloud"} {
		if !strings.Contains(line, want) {
			t.Fatalf("dry-run line missing %q:\nstdout:%s\nstderr:%s", want, stdout, stderr)
		}
	}
}

// ---------------------------------------------------------------------------
// PDS wave 22 — receipt + sidecar honesty (PDS-D294 / PDS-D295)
// ---------------------------------------------------------------------------

// TestImportCountsReadsTheServersTableMap: the receipt the SERVER sends carries
// `tables` as a MAP, and the count is its size. Before this fix the whole decode
// was guarded on `err == nil`, so the type error on `tables` threw away the
// total_rows that HAD decoded and every human-mode import printed
// "Imported workspace acme — — rows across — tables" with exit 0.
func TestImportCountsReadsTheServersTableMap(t *testing.T) {
	const body = `{"tables":{"documents":10,"media_files":3,"datasets":1},"total_rows":13}`
	tables, rows := importCounts([]byte(body))
	if tables != 3 || rows != 13 {
		t.Fatalf("importCounts = tables:%d rows:%d, want tables:3 rows:13", tables, rows)
	}
	line := fmt.Sprintf("%s across %s", pluralize(rows, "row"), pluralize(tables, "table"))
	if line != "13 rows across 3 tables" {
		t.Fatalf("receipt line = %q, want %q", line, "13 rows across 3 tables")
	}
}

// TestImportCountsNeverFabricatesZero: every shape the client cannot fully read
// must degrade to an em dash for the UNREADABLE half only — never a fabricated
// 0, and never at the cost of the half that decoded. The bare-int case is the
// trap the naive fix walks into: encoding/json allocates the destination before
// it fails, so dropping the guard without retyping prints "0 tables".
func TestImportCountsNeverFabricatesZero(t *testing.T) {
	for _, tc := range []struct {
		name       string
		body       string
		wantTables int
		wantRows   int
		wantLine   string
	}{
		{"tables absent", `{"total_rows":13}`, -1, 13, "13 rows across — tables"},
		{"rows absent", `{"tables":{"documents":10}}`, 1, -1, "— rows across 1 table"},
		{"older int shape", `{"tables":6,"total_rows":42}`, -1, 42, "42 rows across — tables"},
		{"not json at all", `<html>502</html>`, -1, -1, "— rows across — tables"},
		{"empty body", ``, -1, -1, "— rows across — tables"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tables, rows := importCounts([]byte(tc.body))
			if tables != tc.wantTables || rows != tc.wantRows {
				t.Fatalf("importCounts = tables:%d rows:%d, want tables:%d rows:%d", tables, rows, tc.wantTables, tc.wantRows)
			}
			line := fmt.Sprintf("%s across %s", pluralize(rows, "row"), pluralize(tables, "table"))
			if line != tc.wantLine {
				t.Fatalf("receipt line = %q, want %q", line, tc.wantLine)
			}
		})
	}
}

// TestCloudWorkspaceImportPartialReceiptPrintsWhatItKnows: end to end through the
// real command — a receipt carrying only total_rows prints the rows it moved and
// an honest em dash for the tables, never "0 tables".
func TestCloudWorkspaceImportPartialReceiptPrintsWhatItKnows(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"total_rows":13}`))
	}))
	t.Cleanup(srv.Close)

	tarFile := filepath.Join(t.TempDir(), "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	g := globals{server: srv.URL, token: "admin-tok", yes: true}
	stdout, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:%s", code, stderr)
	}
	if !strings.Contains(stdout, "13 rows across — tables") {
		t.Fatalf("stdout must print the rows it knows and an em dash for the rest:\n%s", stdout)
	}
	if strings.Contains(stdout, "0 tables") {
		t.Fatalf("an unreadable field must NEVER print as a fabricated zero:\n%s", stdout)
	}
}

// TestBlobUploadReportsBytesTheTargetReceived: the upload leg returns the
// TARGET's echoed byte count (media_controller.ex:247-251), not the local stat,
// and says "received" — put_bytes/3 returns a bare :ok, so nothing here has
// measured what was STORED.
func TestBlobUploadReportsBytesTheTargetReceived(t *testing.T) {
	workspaceEnvIsolate(t)
	const blob = "PNG\x00\xff-bytes"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"written":"2026/07/pic-abcd1234.png","bytes":` + fmt.Sprint(len(body)) + `}`))
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(realImportReceipt))
	}))
	t.Cleanup(srv.Close)

	tarFile := seedBlobSidecar(t, map[string]string{"2026/07/pic-abcd1234.png": blob})
	g := globals{server: srv.URL, token: "admin-tok", yes: true}
	stdout, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile, "--with-blobs")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	want := fmt.Sprintf("Blobs: 1 uploaded, 0 failed, %d bytes received by the target", len(blob))
	if !strings.Contains(stdout, want) {
		t.Fatalf("report = %q, want it to contain %q", stdout, want)
	}
	if strings.Contains(stdout, "stored") {
		t.Fatalf("the echo measures bytes RECEIVED — the receipt must not claim stored:\n%s", stdout)
	}
}

// TestBlobUploadByteMismatchIsANamedFailure: a 2xx whose echoed byte count
// disagrees with what the client sent is exactly "success while being wrong" —
// it must be NAMED and must not count as an upload.
func TestBlobUploadByteMismatchIsANamedFailure(t *testing.T) {
	for _, tc := range []struct{ name, echo, wantFrag string }{
		{"short write", `{"written":"ok","bytes":3}`, "byte mismatch"},
		{"no echo", `{"written":"ok"}`, "echoed no byte count"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			workspaceEnvIsolate(t)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPut {
					_, _ = io.Copy(io.Discard, r.Body)
					w.Header().Set("Content-Type", "application/json")
					_, _ = w.Write([]byte(tc.echo))
					return
				}
				_, _ = io.Copy(io.Discard, r.Body)
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(realImportReceipt))
			}))
			t.Cleanup(srv.Close)

			tarFile := seedBlobSidecar(t, map[string]string{"2026/07/pic-abcd1234.png": "PNG-BYTES-LONGER-THAN-3"})
			g := globals{server: srv.URL, token: "admin-tok", yes: true}
			stdout, stderr, code := runWorkspace(t, g, "table", "import", "acme", "--file", tarFile, "--with-blobs")
			if code == exitOK {
				t.Fatalf("an unverifiable transfer MUST NOT exit 0\nstdout:%s\nstderr:%s", stdout, stderr)
			}
			if !strings.Contains(stderr, "2026/07/pic-abcd1234.png") || !strings.Contains(stderr, tc.wantFrag) {
				t.Fatalf("failure must NAME the blob and the reason (%q):\n%s", tc.wantFrag, stderr)
			}
			if !strings.Contains(stdout, "0 uploaded, 1 failed") {
				t.Fatalf("report must own the failure:\n%s", stdout)
			}
		})
	}
}

// TestBlobFetchSizeMismatchIsANamedFailure: a truncated blob that arrives with a
// 200 is caught by comparing io.Copy's count against the bundle's declared
// media_files.size.
func TestBlobFetchSizeMismatchIsANamedFailure(t *testing.T) {
	workspaceEnvIsolate(t)
	bundle := makeBundleTar(t,
		[]string{"id", "path", "size"},
		[][]string{{"id-1", "2026/07/short-11112222.png", "9999"}})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/media/files/") {
			_, _ = w.Write([]byte("TRUNCATED"))
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
		t.Fatalf("a blob that does not match its declared size MUST NOT exit 0\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	if !strings.Contains(stderr, "2026/07/short-11112222.png") || !strings.Contains(stderr, "size mismatch") {
		t.Fatalf("failure must NAME the blob and the mismatch:\n%s", stderr)
	}
	if !strings.Contains(stdout, "0 fetched, 1 failed") {
		t.Fatalf("report must own the failure:\n%s", stdout)
	}

	// A named failure that LEAVES the short bytes on disk is only half honest:
	// they sit under the FINAL name in the sidecar directory, which is exactly
	// what `import --with-blobs` walks and PUTs back.
	blobDir := outFile + ".blobs"
	dest := filepath.Join(blobDir, "2026", "07", "short-11112222.png")
	if _, serr := os.Stat(dest); !os.IsNotExist(serr) {
		body, _ := os.ReadFile(dest)
		t.Fatalf("the truncated blob survived at %s (%q, stat err %v)", dest, body, serr)
	}
	// sidecarBlobPaths IS the upload half's input, so an empty answer is the
	// upload half being unable to pick the truncated blob up.
	paths, perr := sidecarBlobPaths(blobDir)
	if perr != nil && !os.IsNotExist(perr) {
		t.Fatalf("sidecarBlobPaths: %v", perr)
	}
	if len(paths) != 0 {
		t.Fatalf("the upload half can still see %v, want nothing to re-upload", paths)
	}
}

// TestBlobFetchAbsentDeclaredSizeIsNotAPass: media_files.size is NULLABLE (a
// blob pushed through put_blob/2 creates no row at all), so a NULL size has
// NOTHING to verify against. The transfer still succeeds — but it is reported as
// unverified, never counted as a size-verified pass. That distinction is the
// whole difference between a verify and the vacuous green it replaces.
func TestBlobFetchAbsentDeclaredSizeIsNotAPass(t *testing.T) {
	workspaceEnvIsolate(t)
	bundle := makeBundleTar(t,
		[]string{"id", "path", "size"},
		[][]string{
			{"id-1", "2026/07/known-11112222.png", "5"},
			{"id-2", "2026/07/unknown-33334444.png", "\\N"},
		})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/media/files/") {
			_, _ = w.Write([]byte("BYTES"))
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
		t.Fatalf("an absent declared size is not a failure\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	if !strings.Contains(stdout, "declared size absent") {
		t.Fatalf("the CLI must SAY a blob had no declared size:\n%s", stdout)
	}
	if !strings.Contains(stdout, "1 size-verified") || !strings.Contains(stdout, "1 with no declared size") {
		t.Fatalf("an unverifiable blob must never be counted as verified:\n%s", stdout)
	}
}

// seedBlobSidecar writes a stub bundle tar plus its `<tar>.blobs/` sidecar tree
// and returns the tar path — the shape `import --with-blobs` walks.
func seedBlobSidecar(t *testing.T, blobs map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	tarFile := filepath.Join(dir, "acme.tar")
	if err := os.WriteFile(tarFile, []byte("BUNDLE"), 0o644); err != nil {
		t.Fatalf("seed tar: %v", err)
	}
	for p, body := range blobs {
		dest := filepath.Join(tarFile+".blobs", filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			t.Fatalf("seed blob dir: %v", err)
		}
		if err := os.WriteFile(dest, []byte(body), 0o644); err != nil {
			t.Fatalf("seed blob %s: %v", p, err)
		}
	}
	return tarFile
}

// shortBundleServer answers the export route with a Content-Length that LIES: it
// declares declaredBytes and then sends `body` (shorter) before hanging up. It
// has to hijack the connection because net/http's own writer truncates or errors
// a handler that disagrees with its declared length — the only way to put a
// genuinely over-declared response on the wire is to write the response
// ourselves. This is the failure the export sink previously reported as a
// success: `bytes: n` with nothing to compare n against.
func shortBundleServer(t *testing.T, declaredBytes int, body string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Errorf("test server does not support hijacking")
			return
		}
		conn, buf, err := hj.Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		defer conn.Close()
		fmt.Fprintf(buf, "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: %d\r\n\r\n", declaredBytes)
		_, _ = buf.WriteString(body)
		_ = buf.Flush()
	}))
}

// TestCloudWorkspaceExportFailedTransferLeavesBackupIntact: the destination is a
// PRE-EXISTING backup. `os.Create` truncated it before the first byte arrived,
// so a transfer that then died destroyed the very artifact the verb exists to
// protect. The bytes now land in a temp file beside the destination and only a
// verified transfer renames over it — a failed export leaves the old bundle byte
// for byte, and leaves no `.part` litter behind either.
func TestCloudWorkspaceExportFailedTransferLeavesBackupIntact(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := shortBundleServer(t, 4096, "SHORT")
	t.Cleanup(srv.Close)

	dir := t.TempDir()
	outFile := filepath.Join(dir, "acme.tar")
	const previous = "PREVIOUS-GOOD-BUNDLE-BYTES"
	if err := os.WriteFile(outFile, []byte(previous), 0o644); err != nil {
		t.Fatalf("seed previous backup: %v", err)
	}

	g := globals{server: srv.URL, token: "admin-tok"}
	stdout, stderr, code := runWorkspace(t, g, "table", "export", "acme", "--file", outFile)
	if code == exitOK {
		t.Fatalf("a transfer that did not deliver the declared bytes MUST NOT exit 0\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	got, err := os.ReadFile(outFile)
	if err != nil {
		t.Fatalf("read destination after failed export: %v", err)
	}
	if string(got) != previous {
		t.Fatalf("failed export clobbered the existing backup: file = %q, want %q", string(got), previous)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read dir: %v", err)
	}
	if len(entries) != 1 || entries[0].Name() != "acme.tar" {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("failed export left litter in the destination dir: %v", names)
	}
}

// TestCloudWorkspaceExportSizeMismatchIsANamedFailure: when the server DECLARES a
// length, the receipt is checked against it. A short delivery is a named,
// non-zero failure that says both numbers — never a `bytes: n` success claim
// about a truncated bundle — and the partial never reaches the destination path.
func TestCloudWorkspaceExportSizeMismatchIsANamedFailure(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := shortBundleServer(t, 4096, "SHORT")
	t.Cleanup(srv.Close)

	outFile := filepath.Join(t.TempDir(), "acme.tar")
	g := globals{server: srv.URL, token: "admin-tok"}
	stdout, stderr, code := runWorkspace(t, g, "table", "export", "acme", "--file", outFile)
	if code == exitOK {
		t.Fatalf("size mismatch must exit non-zero\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	if !strings.Contains(stderr, "size mismatch") || !strings.Contains(stderr, "4096") {
		t.Fatalf("the failure must NAME the mismatch and the declared size:\n%s", stderr)
	}
	if _, err := os.Stat(outFile); !os.IsNotExist(err) {
		t.Fatalf("the partial download must NOT be renamed into place (stat err = %v)", err)
	}
	if strings.Contains(stdout, "Exported workspace") {
		t.Fatalf("a failed export must not print a success receipt:\n%s", stdout)
	}
}

// TestCloudWorkspaceExportVerifiesDeclaredSize: the happy path carries an
// EXPLICIT verified field, not a bare byte count. The receipt states what the
// server declared alongside what arrived, so a reader can see the comparison was
// actually made.
func TestCloudWorkspaceExportVerifiesDeclaredSize(t *testing.T) {
	workspaceEnvIsolate(t)
	const tarBytes = "BUNDLE-TAR-BYTES-\x00\x01\x02-verified"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-tar")
		// net/http sets Content-Length itself for a body this small; state it
		// anyway so the declared length is the mock's claim, not a side effect.
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(tarBytes)))
		_, _ = w.Write([]byte(tarBytes))
	}))
	t.Cleanup(srv.Close)

	outFile := filepath.Join(t.TempDir(), "acme.tar")
	g := globals{server: srv.URL, token: "admin-tok"}
	stdout, stderr, code := runWorkspace(t, g, "json", "export", "acme", "--file", outFile)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// The declared length is READ from the response, never pinned to a literal:
	// the real bundle is not byte-reproducible (three consecutive live runs
	// produced three different sizes), so the only honest assertion is that the
	// receipt's numbers agree with the body this run actually carried.
	if !strings.Contains(stdout, `"verified": true`) && !strings.Contains(stdout, `"verified":true`) {
		t.Fatalf("receipt must carry verified:true, never a bare byte count:\n%s", stdout)
	}
	want := fmt.Sprintf("%d", len(tarBytes))
	if !strings.Contains(stdout, want) {
		t.Fatalf("receipt must state the byte count the response carried (%s):\n%s", want, stdout)
	}
	if !strings.Contains(stdout, "declared_bytes") {
		t.Fatalf("receipt must state what the server declared:\n%s", stdout)
	}
	if !strings.Contains(stderr, "size-verified") {
		t.Fatalf("the human line must say the size was verified:\n%s", stderr)
	}
}

// TestCloudWorkspaceExportAbsentDeclaredSizeIsNotAFailure: Go's transport adds
// `Accept-Encoding: gzip` itself, and when a response comes back gzipped it
// decompresses transparently and STRIPS Content-Length to -1. Probed live on the
// deployed stack: /api/schemas answers ContentLength=-1 Uncompressed=true. This
// route ends in send_file/2 today so it keeps its length — but PDS-D204 already
// moved this route once, and a naive `n != resp.ContentLength` would fail EVERY
// successful export the moment it moves back. -1 means unverifiable, which is
// reported honestly and is NEVER a failure.
func TestCloudWorkspaceExportAbsentDeclaredSizeIsNotAFailure(t *testing.T) {
	workspaceEnvIsolate(t)
	const tarBytes = "BUNDLE-TAR-BYTES-gzipped-on-the-wire-so-the-length-is-stripped"
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write([]byte(tarBytes)); err != nil {
		t.Fatalf("gzip write: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			t.Errorf("Go's transport should have offered gzip itself; Accept-Encoding = %q", r.Header.Get("Accept-Encoding"))
		}
		w.Header().Set("Content-Type", "application/x-tar")
		w.Header().Set("Content-Encoding", "gzip")
		_, _ = w.Write(gz.Bytes())
	}))
	t.Cleanup(srv.Close)

	outFile := filepath.Join(t.TempDir(), "acme.tar")
	g := globals{server: srv.URL, token: "admin-tok"}
	stdout, stderr, code := runWorkspace(t, g, "json", "export", "acme", "--file", outFile)
	if code != exitOK {
		t.Fatalf("an absent declared size is NOT a failure: exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	got, err := os.ReadFile(outFile)
	if err != nil {
		t.Fatalf("read export file: %v", err)
	}
	if string(got) != tarBytes {
		t.Fatalf("export file bytes = %q, want the decompressed body verbatim", string(got))
	}
	if !strings.Contains(stdout, `"verified": false`) && !strings.Contains(stdout, `"verified":false`) {
		t.Fatalf("an unverifiable transfer must report verified:false, never true:\n%s", stdout)
	}
	if strings.Contains(stdout, "declared_bytes") {
		t.Fatalf("there was no declared size — the receipt must not invent one:\n%s", stdout)
	}
	if !strings.Contains(stderr, "declared size absent") {
		t.Fatalf("the CLI must SAY the declared size was absent:\n%s", stderr)
	}
}
