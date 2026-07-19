package cli

// cloud_workspace_cmd_test.go proves `bp cloud workspace export|import` against a
// mock CONTENT API (httptest.NewServer, the V3 harness shape) — never the live
// B1 route and never the SSH instSSHStream seam. The three load-bearing claims:
// export streams the tar to a file (a Bearer-authed GET), import REFUSES without
// --yes (and sends nothing), and import with --yes POSTs the exact file bytes and
// prints the {tables,total_rows} receipt. A dry-run and the admin-token gate are
// covered too.

import (
	"bytes"
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
