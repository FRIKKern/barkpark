package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
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
		{"1.1.0-rc.2", "1.1.0-rc.10", -1}, // numeric prerelease, not lexicographic
		{"1.1.0-rc.10", "1.1.0-rc.2", 1},
		{"1.1.0-rc.2", "1.1.0-rc.2", 0},
		{"1.1.0-alpha", "1.1.0-alpha.1", -1}, // longer prerelease ranks higher
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

// TestLatestReleaseVersionAPIWinsOverDecoyLatest proves the API path is
// preferred over releases/latest: the API lists a build-<sha> server-artifact
// release at the top and the real cli-v1.5.0 below, while releases/latest
// points at the decoy build release (which would 404 bp assets). Resolution
// must return the highest cli-v* (1.5.0), skipping the newer prerelease.
func TestLatestReleaseVersionAPIWinsOverDecoyLatest(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/releases", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `[
			{"tag_name":"build-deadbeef","draft":false,"prerelease":false},
			{"tag_name":"cli-v1.7.0","draft":true,"prerelease":false},
			{"tag_name":"cli-v1.6.0-rc.1","draft":false,"prerelease":true},
			{"tag_name":"cli-v1.5.0","draft":false,"prerelease":false},
			{"tag_name":"cli-v1.4.0","draft":false,"prerelease":false}
		]`)
	})
	// releases/latest points at the decoy build release the API path must beat.
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/releases/tag/build-deadbeef", http.StatusFound)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	got, err := latestReleaseVersion(srv.URL)
	if err != nil {
		t.Fatalf("latestReleaseVersion: %v", err)
	}
	if got != "1.5.0" {
		t.Errorf("latestReleaseVersion = %q, want %q (API cli-v* must win over decoy latest; prerelease skipped)", got, "1.5.0")
	}
}

func TestLatestReleaseVersionAPIIgnoresMalformedStableTags(t *testing.T) {
	cases := []struct {
		name string
		tag  string
	}{
		{"nonnumeric component", "cli-v2.x"},
		{"empty component", "cli-v2..0"},
		{"integer overflow", "cli-v999999999999999999999999999999999999"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mux := http.NewServeMux()
			mux.HandleFunc("/releases", func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprintf(w, `[
					{"tag_name":%q,"draft":false,"prerelease":false},
					{"tag_name":"cli-v1.5.0","draft":false,"prerelease":false}
				]`, tc.tag)
			})
			srv := httptest.NewServer(mux)
			defer srv.Close()

			got, err := latestReleaseVersionAPI(srv.URL)
			if err != nil {
				t.Fatalf("latestReleaseVersionAPI: %v", err)
			}
			if got != "1.5.0" {
				t.Fatalf("latestReleaseVersionAPI = %q, want %q; malformed %q masked the valid stable release", got, "1.5.0", tc.tag)
			}
		})
	}
}

func TestLatestReleaseVersionRedirectRejectsMalformedStableTags(t *testing.T) {
	for _, tag := range []string{
		"cli-v2.x",
		"cli-v2..0",
		"cli-v2.0-rc.1",
		"cli-v999999999999999999999999999999999999",
	} {
		t.Run(tag, func(t *testing.T) {
			srv := fakeReleaseTree(t, tag, nil)
			if _, err := latestReleaseVersionRedirect(srv.URL); err == nil {
				t.Fatalf("latestReleaseVersionRedirect accepted malformed stable tag %q", tag)
			}
		})
	}
}

// TestDoctorReleaseCadenceUsesPublishedStableRelease proves the shell doctor
// ignores newer local unpublished/prerelease tags and newer API draft/
// prerelease/non-CLI releases. The published stable 1.5.0 must remain the
// cadence anchor, matching latestReleaseVersionAPI.
func TestDoctorReleaseCadenceUsesPublishedStableRelease(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
	doctor, err := os.ReadFile(filepath.Join(repoRoot, "scripts", "doctor.sh"))
	if err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	doctorPath := filepath.Join(root, "scripts", "doctor.sh")
	if err := os.WriteFile(doctorPath, doctor, 0o755); err != nil {
		t.Fatal(err)
	}

	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	gitLog := filepath.Join(root, "git.log")
	fakeGit := `#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
case "$1 $2" in
  "fetch --quiet") exit 0 ;;
  "rev-list --count")
    case "$3" in
      HEAD..origin/main|origin/main..HEAD) echo 0 ;;
      cli-v1.5.0..origin/main) echo 300 ;;
      *) echo 0 ;;
    esac
    ;;
  "rev-parse --verify") exit 0 ;;
  "log -1") echo 1 ;;
  "tag -l") printf 'cli-v1.6.0\ncli-v1.6.0-rc.1\ncli-v1.5.0\n' ;;
  "status --porcelain") exit 0 ;;
  *) exit 0 ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte(fakeGit), 0o755); err != nil {
		t.Fatal(err)
	}
	fakeCurl := `#!/bin/sh
cat <<'JSON'
[
  {"tag_name":"build-deadbeef","draft":false,"prerelease":false},
  {"tag_name":"cli-v1.7.0","draft":true,"prerelease":false},
  {"tag_name":"cli-v1.6.0-rc.1","draft":false,"prerelease":true},
  {"tag_name":"cli-v2.x","draft":false,"prerelease":false},
  {"tag_name":"cli-v999999999999999999999999999999999999","draft":false,"prerelease":false},
  {"tag_name":"cli-v1.5.0","draft":false,"prerelease":false}
]
JSON
`
	if err := os.WriteFile(filepath.Join(bin, "curl"), []byte(fakeCurl), 0o755); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("/bin/bash", doctorPath)
	cmd.Env = append(os.Environ(),
		"PATH="+bin+":/usr/bin:/bin",
		"FAKE_GIT_LOG="+gitLog,
		"BARKPARK_RELEASES_API_URL=https://example.invalid/releases",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("doctor failed: %v\n%s", err, out)
	}
	text := string(out)
	if !strings.Contains(text, "release cli-v1.5.0 is 300 commit(s)") {
		t.Fatalf("doctor did not anchor cadence to published stable 1.5.0:\n%s", text)
	}
	if strings.Contains(text, "release cli-v1.6.0") || strings.Contains(text, "release cli-v1.7.0") {
		t.Fatalf("draft/prerelease/unpublished release masked stable cadence:\n%s", text)
	}
	invocations, err := os.ReadFile(gitLog)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(invocations), "tag -l") {
		t.Fatalf("doctor consulted local tags instead of published releases:\n%s", invocations)
	}
}

// TestLatestReleaseVersionFallsBackToRedirect proves that when the API path
// yields nothing (no /releases endpoint), resolution falls back to the
// /releases/latest redirect.
func TestLatestReleaseVersionFallsBackToRedirect(t *testing.T) {
	srv := fakeReleaseTree(t, "cli-v1.2.3", nil) // serves only /releases/latest
	got, err := latestReleaseVersion(srv.URL)
	if err != nil {
		t.Fatalf("latestReleaseVersion: %v", err)
	}
	if got != "1.2.3" {
		t.Errorf("latestReleaseVersion = %q, want %q (redirect fallback)", got, "1.2.3")
	}
}

func TestReleaseAPIURL(t *testing.T) {
	cases := []struct{ base, want string }{
		{"https://github.com/FRIKKern/barkpark", "https://api.github.com/repos/FRIKKern/barkpark/releases?per_page=30"},
		{"https://github.com/FRIKKern/barkpark/", "https://api.github.com/repos/FRIKKern/barkpark/releases?per_page=30"},
		{"http://127.0.0.1:8080", "http://127.0.0.1:8080/releases?per_page=30"},
	}
	for _, c := range cases {
		if got := releaseAPIURL(c.base); got != c.want {
			t.Errorf("releaseAPIURL(%q) = %q, want %q", c.base, got, c.want)
		}
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

// TestRunUpgradeCheckDevIsUnreportedNotAnError: `--check` ASKS a question
// ("how fresh am I?"), it does not request a mutation. On a dev build the honest
// answer is "no reading can be taken" — which `bp doctor --onboarding` treats as
// a non-failure — so --check reports UNREPORTED and exits 0 instead of exiting 2
// while the doctor next door says everything is fine. Fail-before on
// origin/main, which returns exitUsage here.
func TestRunUpgradeCheckDevIsUnreportedNotAnError(t *testing.T) {
	withCLIVersion(t, "dev")
	out, stdout, stderr := newTestWriter()
	out.output = "table" // the human render

	if code := runUpgrade(out, globals{}, []string{"--check"}); code != exitOK {
		t.Fatalf("upgrade --check on a dev build = %d, want exitOK (an unknown is not a failure)\nstdout: %s\nstderr: %s", code, stdout, stderr)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("UNREPORTED")) {
		t.Errorf("--check on a dev build must say its freshness is UNREPORTED; stdout: %s", stdout)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("make cli-install")) {
		t.Errorf("--check on a dev build must name the literal remedy; stdout: %s", stdout)
	}
	// No network was touched: a dev build has nothing to resolve against.
	if bytes.Contains(stdout.Bytes(), []byte("up to date")) {
		t.Errorf("--check on a dev build must never claim \"up to date\"; stdout: %s", stdout)
	}
}

// TestRunUpgradeCheckDevJSONCarriesNullBehind pins the machine shape: status
// "unreported" and a NULL behind — never a fabricated boolean.
func TestRunUpgradeCheckDevJSONCarriesNullBehind(t *testing.T) {
	withCLIVersion(t, "dev")
	out, stdout, _ := newTestWriter()
	out.output = "json"

	if code := runUpgrade(out, globals{}, []string{"--check"}); code != exitOK {
		t.Fatalf("upgrade --check -o json on a dev build = %d, want exitOK; stdout: %s", code, stdout)
	}
	got := stdout.String()
	if !strings.Contains(got, `"status": "unreported"`) && !strings.Contains(got, `"status":"unreported"`) {
		t.Errorf("--check json must carry status \"unreported\"; stdout: %s", got)
	}
	if !strings.Contains(got, `"behind": null`) && !strings.Contains(got, `"behind":null`) {
		t.Errorf("--check json must carry a null behind (no reading taken); stdout: %s", got)
	}
}

// TestRunUpgradeDevMutationStillRefuses: the MUTATING path is a different
// question ("replace this binary"), it genuinely cannot be honoured on a dev
// build, and its refusal text is the right instruction — both stay put.
func TestRunUpgradeDevMutationStillRefuses(t *testing.T) {
	withCLIVersion(t, "dev")
	out, _, stderr := newTestWriter()
	if code := runUpgrade(out, globals{}, nil); code != exitUsage {
		t.Errorf("bare upgrade on a dev build = %d, want exitUsage", code)
	}
	if !bytes.Contains(stderr.Bytes(), []byte(upgradeDevBuildRefusal)) {
		t.Errorf("the dev refusal text must be preserved verbatim; stderr: %s", stderr)
	}
}

func TestRunUpgradeUnknownFlag(t *testing.T) {
	withCLIVersion(t, "0.0.1")
	out, _, _ := newTestWriter()
	if code := runUpgrade(out, globals{}, []string{"--bogus"}); code != exitUsage {
		t.Errorf("runUpgrade --bogus = %d, want %d", code, exitUsage)
	}
}

func TestRunUpgradeHelpToStdout(t *testing.T) {
	// --help is an explicit request: usage → stdout, exit 0, nothing on stderr
	// (parity with migrate/seed/make/tinker/doctor). No network is touched.
	withCLIVersion(t, "0.0.1")
	out, stdout, stderr := newTestWriter()
	if code := runUpgrade(out, globals{help: true}, nil); code != exitOK {
		t.Fatalf("upgrade --help = %d, want exitOK", code)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("usage: bp upgrade")) {
		t.Errorf("help should print usage to stdout; stdout: %s", stdout)
	}
	if stderr.Len() != 0 {
		t.Errorf("--help must not write to stderr; stderr: %s", stderr)
	}
}

func TestRunUpgradeCheckYAML(t *testing.T) {
	// -o yaml is now honored (was json-only): --check emits a yaml doc.
	withCLIVersion(t, "0.0.2")
	srv := fakeReleaseTree(t, "cli-v0.0.2", nil) // same version → not behind
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)
	out, stdout, _ := newTestWriter()
	out.output = "yaml"
	if code := runUpgrade(out, globals{}, []string{"--check"}); code != exitOK {
		t.Fatalf("--check up-to-date = %d, want exitOK (stdout: %s)", code, stdout)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("current:")) {
		t.Errorf("-o yaml should emit a yaml doc with a current: key; stdout: %s", stdout)
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
