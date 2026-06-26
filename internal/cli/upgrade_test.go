package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.0.0", "1.0.0", 0},
		{"1.0.0", "1.0.1", -1},
		{"1.0.1", "1.0.0", 1},
		{"1.0.0", "1.1.0", -1},
		{"2.0.0", "1.9.9", 1},
		{"1.0", "1.0.0", 0}, // missing parts are 0
		{"1.0.0", "1.0.0.1", -1},
		{"1.10.0", "1.9.0", 1},      // numeric, not lexicographic
		{"1.1.0-rc.1", "1.1.0", -1}, // release > its prerelease
		{"1.1.0", "1.1.0-rc.1", 1},
		{"1.1.0-rc.1", "1.1.0-rc.2", -1},
		{"1.1.0-rc.1", "1.1.0-rc.1", 0},
		{"0.0.1", "0.0.2", -1},
	}
	for _, c := range cases {
		if got := compareVersions(c.a, c.b); got != c.want {
			t.Errorf("compareVersions(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

// fakeReleaseTree serves a GitHub-shaped release tree: /releases/latest
// redirects to the tag page, assets live under /releases/download/<tag>/.
func fakeReleaseTree(t *testing.T, tag string, assets map[string][]byte) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/releases/tag/"+tag, http.StatusFound)
	})
	for name, body := range assets {
		b := body
		mux.HandleFunc("/releases/download/"+tag+"/"+name, func(w http.ResponseWriter, r *http.Request) {
			w.Write(b)
		})
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestLatestReleaseVersionRedirect(t *testing.T) {
	srv := fakeReleaseTree(t, "cli-v1.2.3", nil)
	got, err := latestReleaseVersion(srv.URL)
	if err != nil {
		t.Fatalf("latestReleaseVersion: %v", err)
	}
	if got != "1.2.3" {
		t.Errorf("latestReleaseVersion = %q, want %q", got, "1.2.3")
	}
}

func TestLatestReleaseVersionNoRelease(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	if _, err := latestReleaseVersion(srv.URL); err == nil {
		t.Fatal("latestReleaseVersion succeeded against a tree with no releases")
	}
}

func TestLatestReleaseVersionNonCLITag(t *testing.T) {
	srv := fakeReleaseTree(t, "v1.2.3", nil) // npm-style tag, not cli-v*
	if _, err := latestReleaseVersion(srv.URL); err == nil {
		t.Fatal("latestReleaseVersion accepted a non-cli-v* tag")
	}
}

// upgradeFixture stubs the running binary + release tree for performUpgrade /
// runUpgrade tests. Returns the fake exe path and the release-tree server.
func upgradeFixture(t *testing.T, latest string, newBody []byte, sumOverride string) (string, *httptest.Server) {
	t.Helper()
	dir := t.TempDir()
	exe := filepath.Join(dir, "bp")
	if err := os.WriteFile(exe, []byte("old-binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	asset := "bp-" + runtime.GOOS + "-" + runtime.GOARCH
	sum := sumOverride
	if sum == "" {
		h := sha256.Sum256(newBody)
		sum = hex.EncodeToString(h[:])
	}
	sums := fmt.Sprintf("%s  %s\n", sum, asset)
	srv := fakeReleaseTree(t, "cli-v"+latest, map[string][]byte{
		asset:           newBody,
		"checksums.txt": []byte(sums),
	})
	return exe, srv
}

func TestPerformUpgradeReplacesBinary(t *testing.T) {
	exe, srv := upgradeFixture(t, "0.0.2", []byte("new-binary"), "")
	if err := performUpgrade(srv.URL, "0.0.2", exe); err != nil {
		t.Fatalf("performUpgrade: %v", err)
	}
	got, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "new-binary" {
		t.Errorf("exe content = %q, want %q", got, "new-binary")
	}
	fi, _ := os.Stat(exe)
	if fi.Mode().Perm() != 0o755 {
		t.Errorf("exe mode = %v, want 0755", fi.Mode().Perm())
	}
}

func TestPerformUpgradeChecksumMismatch(t *testing.T) {
	wrong := hex.EncodeToString(bytes.Repeat([]byte{0xab}, 32))
	exe, srv := upgradeFixture(t, "0.0.2", []byte("new-binary"), wrong)
	err := performUpgrade(srv.URL, "0.0.2", exe)
	if err == nil {
		t.Fatal("performUpgrade succeeded despite checksum mismatch")
	}
	got, _ := os.ReadFile(exe)
	if string(got) != "old-binary" {
		t.Errorf("exe was replaced despite mismatch: %q", got)
	}
	// The same-dir temp file must not be left behind.
	entries, _ := os.ReadDir(filepath.Dir(exe))
	for _, e := range entries {
		if e.Name() != "bp" {
			t.Errorf("leftover temp file %q after failed upgrade", e.Name())
		}
	}
}

func TestPerformUpgradeMissingChecksumEntry(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "bp")
	os.WriteFile(exe, []byte("old-binary"), 0o755)
	srv := fakeReleaseTree(t, "cli-v0.0.2", map[string][]byte{
		"checksums.txt": []byte("deadbeef  bp-plan9-mips\n"),
	})
	if err := performUpgrade(srv.URL, "0.0.2", exe); err == nil {
		t.Fatal("performUpgrade succeeded without a checksum entry for this platform")
	}
}

// withCLIVersion swaps the injected version var for one test.
func withCLIVersion(t *testing.T, v string) {
	t.Helper()
	old := cliVersion
	cliVersion = v
	t.Cleanup(func() { cliVersion = old })
}

func newTestWriter() (*writer, *bytes.Buffer, *bytes.Buffer) {
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.applyGlobals(globals{})
	return out, &stdout, &stderr
}

func TestRunUpgradeDevRefusal(t *testing.T) {
	withCLIVersion(t, "dev")
	out, _, stderr := newTestWriter()
	if code := runUpgrade(out, globals{}, nil); code != exitUsage {
		t.Errorf("runUpgrade on dev build = %d, want %d", code, exitUsage)
	}
	if !bytes.Contains(stderr.Bytes(), []byte("dev build")) {
		t.Errorf("dev refusal message missing, stderr: %s", stderr)
	}
}

func TestRunUpgradeUnknownFlag(t *testing.T) {
	withCLIVersion(t, "0.0.1")
	out, _, _ := newTestWriter()
	if code := runUpgrade(out, globals{}, []string{"--bogus"}); code != exitUsage {
		t.Errorf("runUpgrade --bogus = %d, want %d", code, exitUsage)
	}
}

func TestRunUpgradeCheckBehind(t *testing.T) {
	withCLIVersion(t, "0.0.1")
	srv := fakeReleaseTree(t, "cli-v0.0.2", nil)
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)
	out, stdout, _ := newTestWriter()
	if code := runUpgrade(out, globals{}, []string{"--check"}); code != exitGeneric {
		t.Errorf("--check behind = %d, want %d (stdout: %s)", code, exitGeneric, stdout)
	}
}

func TestRunUpgradeCheckUpToDate(t *testing.T) {
	withCLIVersion(t, "0.0.2")
	srv := fakeReleaseTree(t, "cli-v0.0.2", nil)
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)
	out, _, _ := newTestWriter()
	if code := runUpgrade(out, globals{}, []string{"--check"}); code != exitOK {
		t.Errorf("--check up-to-date = %d, want %d", code, exitOK)
	}
}

func TestRunUpgradeEndToEnd(t *testing.T) {
	withCLIVersion(t, "0.0.1")
	exe, srv := upgradeFixture(t, "0.0.2", []byte("new-binary"), "")
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)
	oldExec := upgradeExecutable
	upgradeExecutable = func() (string, error) { return exe, nil }
	t.Cleanup(func() { upgradeExecutable = oldExec })

	out, stdout, stderr := newTestWriter()
	if code := runUpgrade(out, globals{}, nil); code != exitOK {
		t.Fatalf("runUpgrade = %d, want 0 (stdout: %s, stderr: %s)", code, stdout, stderr)
	}
	got, _ := os.ReadFile(exe)
	if string(got) != "new-binary" {
		t.Errorf("exe content = %q, want %q", got, "new-binary")
	}
}
