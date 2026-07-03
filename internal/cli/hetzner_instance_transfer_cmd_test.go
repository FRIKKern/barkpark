package cli

// hetzner_instance_transfer_cmd_test.go — export/import ride two SSH stream
// seams, so the tests substitute in-memory pipes and assert (a) the remote
// scripts carry their load-bearing pieces (the dump, the identity-secret
// merge, the role-preserving restore, the health sentinel) and (b) the bytes
// actually flow: what the "box" streams out is what lands in the export file,
// and what the import feeds the box is exactly the file's content.

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstanceExportStreamsTarballToFile(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(23, "bp-gyldendal-1", "192.0.2.23", "gyldendal.barkpark.cloud")+`]}`)
	})

	var gotHost, gotScript string
	oldStream := instSSHStream
	instSSHStream = func(host, command string, w io.Writer) error {
		gotHost, gotScript = host, command
		_, err := w.Write([]byte("FAKE-TARBALL-BYTES"))
		return err
	}
	t.Cleanup(func() { instSSHStream = oldStream })

	outPath := filepath.Join(t.TempDir(), "gy.tar.gz")
	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "export", "gyldendal.barkpark.cloud", "--out", outPath)
	if code != exitOK {
		t.Fatalf("export exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	if gotHost != "192.0.2.23" {
		t.Errorf("export dialed %q, want the box's IP", gotHost)
	}
	for _, piece := range []string{
		"pg_dump --format=custom --no-owner barkpark_prod",
		"cp /opt/barkpark/.env",
		"api/uploads",
		`"fqdn":"%s"`,
		"tar -C \"$STAGE\" -czf -",
	} {
		if !strings.Contains(gotScript, piece) {
			t.Errorf("export script is missing %q", piece)
		}
	}
	data, rerr := os.ReadFile(outPath)
	if rerr != nil {
		t.Fatalf("export wrote no file: %v", rerr)
	}
	if string(data) != "FAKE-TARBALL-BYTES" {
		t.Errorf("file content = %q, want the streamed bytes", data)
	}
	if !strings.Contains(stdout, outPath) {
		t.Errorf("receipt does not name the output file: %s", stdout)
	}
}

func TestInstanceExportFailureRemovesTruncatedFile(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(23, "bp-gy-1", "192.0.2.23", "gyldendal.barkpark.cloud")+`]}`)
	})
	oldStream := instSSHStream
	instSSHStream = func(host, command string, w io.Writer) error {
		_, _ = w.Write([]byte("HALF-A-TAR"))
		return io.ErrUnexpectedEOF
	}
	t.Cleanup(func() { instSSHStream = oldStream })

	outPath := filepath.Join(t.TempDir(), "gy.tar.gz")
	_, _, code := runHzCLI(t, "json", "hetzner", "instance", "export", "gyldendal.barkpark.cloud", "--out", outPath)
	if code == exitOK {
		t.Fatal("a failed export exited 0")
	}
	if _, err := os.Stat(outPath); !os.IsNotExist(err) {
		t.Error("a truncated export file was left behind, looking valid")
	}
}

func TestInstanceImportFeedsFileAndChecksSentinel(t *testing.T) {
	instTestTuning(t)
	newFakeHzAPI(t) // token resolution; the IP target never touches the API

	src := filepath.Join(t.TempDir(), "in.tar.gz")
	if err := os.WriteFile(src, []byte("ARCHIVE-CONTENT"), 0o644); err != nil {
		t.Fatal(err)
	}

	var gotHost, gotScript, fed string
	oldFeed := instSSHFeed
	instSSHFeed = func(host, command string, r io.Reader) (string, error) {
		b, _ := io.ReadAll(r)
		gotHost, gotScript, fed = host, command, string(b)
		return "restoring…\nBP_IMPORT_HEALTH_OK\n", nil
	}
	t.Cleanup(func() { instSSHFeed = oldFeed })

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "import", src, "--target", "203.0.113.7", "--yes")
	if code != exitOK {
		t.Fatalf("import exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	if gotHost != "203.0.113.7" {
		t.Errorf("import dialed %q, want the raw --target IP (the anywhere case)", gotHost)
	}
	if fed != "ARCHIVE-CONTENT" {
		t.Errorf("import fed %q, want the file's bytes", fed)
	}
	for _, piece := range []string{
		"tar -C \"$STAGE\" -xzf -",
		"SECRET_KEY_BASE BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_INGEST_TOKEN",
		"DROP DATABASE IF EXISTS barkpark_prod",
		`pg_restore --no-owner --role="${DBUSER:-postgres}"`,
		"systemctl stop barkpark",
		"systemctl start barkpark",
		"BP_IMPORT_HEALTH_OK",
	} {
		if !strings.Contains(gotScript, piece) {
			t.Errorf("import script is missing %q", piece)
		}
	}
}

func TestInstanceImportRequiresYes(t *testing.T) {
	instTestTuning(t)
	called := false
	oldFeed := instSSHFeed
	instSSHFeed = func(host, command string, r io.Reader) (string, error) {
		called = true
		return "", nil
	}
	t.Cleanup(func() { instSSHFeed = oldFeed })

	_, _, code := runHzCLI(t, "json", "hetzner", "instance", "import", "x.tar.gz", "--target", "203.0.113.7")
	if code != exitUsage {
		t.Fatalf("import without --yes exited %d, want usage error %d", code, exitUsage)
	}
	if called {
		t.Error("import touched the box without --yes")
	}
}

func TestInstanceImportFailsWithoutSentinel(t *testing.T) {
	instTestTuning(t)
	src := filepath.Join(t.TempDir(), "in.tar.gz")
	_ = os.WriteFile(src, []byte("X"), 0o644)
	oldFeed := instSSHFeed
	instSSHFeed = func(host, command string, r io.Reader) (string, error) {
		return "restore ran but the service never came up", nil // no sentinel
	}
	t.Cleanup(func() { instSSHFeed = oldFeed })

	_, _, code := runHzCLI(t, "json", "hetzner", "instance", "import", src, "--target", "203.0.113.7", "--yes")
	if code == exitOK {
		t.Fatal("import without the health sentinel exited 0 — a vacuous green")
	}
}

func TestInstanceAuditExternalAllowlist(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(23, "bp-gy-1", "192.0.2.23", "gyldendal.barkpark.cloud")+`]}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[
			{"id":"gyldendal/A","name":"gyldendal","type":"A","records":[{"value":"192.0.2.23"}]},
			{"id":"@/A","name":"@","type":"A","records":[{"value":"192.0.2.100"}]},
			{"id":"www/A","name":"www","type":"A","records":[{"value":"192.0.2.100"}]},
			{"id":"rogue/A","name":"rogue","type":"A","records":[{"value":"192.0.2.200"}]}
		]}`)
	})
	f.mux.HandleFunc("GET /images", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"images":[]}`)
	})
	f.mux.HandleFunc("GET /primary_ips", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"primary_ips":[]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "audit", "--external", "@,www")
	if code != exitGeneric {
		t.Fatalf("audit exited %d, want %d — rogue is still an orphan; stderr: %s stdout: %s", code, exitGeneric, stderr, stdout)
	}
	if strings.Contains(stdout, "www.barkpark.cloud") || strings.Contains(stdout, "@.barkpark.cloud") {
		t.Errorf("allowlisted labels were still flagged: %s", stdout)
	}
	if !strings.Contains(stdout, "rogue") {
		t.Errorf("the real orphan was swallowed by the allowlist: %s", stdout)
	}
	if !strings.Contains(stdout, `"external_dns": 2`) {
		t.Errorf("external count missing from the summary: %s", stdout)
	}
}
