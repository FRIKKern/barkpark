package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// defaultReleaseRepo is the GitHub repo whose cli-v* releases own
// releases/latest (the npm pipeline creates no GitHub Releases — see
// .github/workflows/cli-release.yml).
const defaultReleaseRepo = "https://github.com/FRIKKern/barkpark"

// Stable release components are bounded to uint32 so the Go resolver and the
// jq-based doctor can validate and order them identically on every platform.
// Real CLI versions are tiny; the bound exists to reject hostile/accidental
// numeric overflow rather than silently coercing it during comparison.
const maxStableVersionComponent = 1<<32 - 1

// installerOneLiner is printed when the install dir is not writable. Never
// escalate from inside the binary — the user re-runs the installer with sudo.
const installerOneLiner = "curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sudo sh"

// releaseRepoBase resolves the release REPO ROOT. BARKPARK_CLI_RELEASE_BASE
// here names a GitHub-shaped release tree root — `<base>/releases/latest`
// must redirect to the latest tag and assets live under
// `<base>/releases/download/cli-v<ver>/`. (The installer's same-named env var
// points at an asset DIRECTORY instead; upgrade needs the tree to discover
// the latest version.)
func releaseRepoBase() string {
	if v := os.Getenv("BARKPARK_CLI_RELEASE_BASE"); v != "" {
		return strings.TrimRight(v, "/")
	}
	return defaultReleaseRepo
}

// upgradeExecutable resolves the running binary's real path (through
// symlinks, so the same-dir temp file lands on the same filesystem and
// rename(2) stays atomic). A var so tests can stub it instead of replacing
// the test binary.
var upgradeExecutable = func() (string, error) {
	p, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(p)
}

// latestReleaseVersion resolves the newest released CLI version. It prefers
// the GitHub Releases API (which lists every tag, so a cli-v* is always
// findable) and falls back to the /releases/latest redirect only when the API
// call fails. The API is preferred because this repo ALSO cuts build-<sha>
// server-artifact releases that carry no bp assets — one of those can own the
// releases/latest slot and 404 every unpinned resolve. install-cli.sh:27-38
// learned the same lesson; this mirrors it so `bp upgrade` and the installer
// resolve the same version.
func latestReleaseVersion(base string) (string, error) {
	if ver, err := latestReleaseVersionAPI(base); err == nil {
		return ver, nil
	}
	return latestReleaseVersionRedirect(base)
}

// releaseAPIURL maps the release-tree root to its GitHub Releases API list
// endpoint: github.com/OWNER/REPO → api.github.com/repos/OWNER/REPO/releases.
// Any other host (a test server, a mirror) is asked for /releases?per_page=30
// directly, so the API code path stays exercisable without api.github.com.
func releaseAPIURL(base string) string {
	if u, err := url.Parse(base); err == nil && u.Host == "github.com" {
		return "https://api.github.com/repos" + strings.TrimRight(u.Path, "/") + "/releases?per_page=30"
	}
	return strings.TrimRight(base, "/") + "/releases?per_page=30"
}

// latestReleaseVersionAPI lists the newest releases and returns the highest
// cli-v* version, skipping drafts, prereleases (cli-v1.2.0-rc.1), and non-cli
// tags (build-<sha> server artifacts) — matching the public installer feed.
func latestReleaseVersionAPI(base string) (string, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(releaseAPIURL(base))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("releases API returned HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	var releases []struct {
		TagName    string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
	}
	if err := json.Unmarshal(body, &releases); err != nil {
		return "", err
	}
	best := ""
	var bestParts []uint64
	for _, r := range releases {
		if r.Draft || r.Prerelease {
			continue
		}
		ver, ok := strings.CutPrefix(r.TagName, "cli-v")
		if !ok {
			continue
		}
		parts, ok := parseStableVersion(ver)
		if !ok { // skip prerelease, malformed, and overflowing cli-v* tags
			continue
		}
		if best == "" || compareStableVersions(parts, bestParts) > 0 {
			best = ver
			bestParts = parts
		}
	}
	if best == "" {
		return "", fmt.Errorf("releases API listed no cli-v* release")
	}
	return best, nil
}

// latestReleaseVersionRedirect resolves the newest released CLI version WITHOUT
// the GitHub API (no rate-limit JSON, no auth): GET <base>/releases/latest and
// read the redirect Location — its final path segment is the tag
// (cli-v1.0.1). Prereleases never win because GitHub's latest endpoint
// skips them. Used as the fallback when the API path fails.
func latestReleaseVersionRedirect(base string) (string, error) {
	client := &http.Client{
		Timeout: 10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse // capture Location, do not follow
		},
	}
	resp, err := client.Get(base + "/releases/latest")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 300 || resp.StatusCode >= 400 {
		return "", fmt.Errorf("no release found at %s/releases/latest (HTTP %d) — has a cli-v* release been published?", base, resp.StatusCode)
	}
	loc := resp.Header.Get("Location")
	if loc == "" {
		return "", fmt.Errorf("redirect from %s/releases/latest carried no Location", base)
	}
	u, err := url.Parse(loc)
	if err != nil {
		return "", fmt.Errorf("bad redirect Location %q: %v", loc, err)
	}
	tag := path.Base(u.Path)
	ver, ok := strings.CutPrefix(tag, "cli-v")
	if !ok {
		return "", fmt.Errorf("latest release tag %q is not a cli-v* tag", tag)
	}
	if _, ok := parseStableVersion(ver); !ok {
		return "", fmt.Errorf("latest release tag %q is not a numeric dotted stable cli-v* tag", tag)
	}
	return ver, nil
}

// parseStableVersion accepts the same release grammar as doctor.sh:
// one or more dot-separated decimal components, with no prerelease/build
// suffixes and every component fitting in uint32. The explicit bound keeps
// ordering portable and prevents malformed overflow from masking a real
// published stable release.
func parseStableVersion(version string) ([]uint64, bool) {
	if version == "" {
		return nil, false
	}
	parts := strings.Split(version, ".")
	parsed := make([]uint64, len(parts))
	for i, part := range parts {
		if part == "" {
			return nil, false
		}
		for _, ch := range part {
			if ch < '0' || ch > '9' {
				return nil, false
			}
		}
		n, err := strconv.ParseUint(part, 10, 32)
		if err != nil || n > maxStableVersionComponent {
			return nil, false
		}
		parsed[i] = n
	}
	return parsed, true
}

func compareStableVersions(a, b []uint64) int {
	for i := 0; i < len(a) || i < len(b); i++ {
		var na, nb uint64
		if i < len(a) {
			na = a[i]
		}
		if i < len(b) {
			nb = b[i]
		}
		if na < nb {
			return -1
		}
		if na > nb {
			return 1
		}
	}
	return 0
}

// compareVersions orders two semver-ish strings: -1 when a < b, 0 when
// equal, 1 when a > b. Numeric dotted cores compare part-wise (missing
// parts are 0); a release outranks its own prereleases (1.1.0 > 1.1.0-rc.1);
// two prereleases on the same core compare per-identifier (numeric
// identifiers numerically, so rc.10 > rc.2), and a longer prerelease
// outranks a shorter prefix (alpha < alpha.1).
func compareVersions(a, b string) int {
	coreA, preA, _ := strings.Cut(a, "-")
	coreB, preB, _ := strings.Cut(b, "-")
	pa := strings.Split(coreA, ".")
	pb := strings.Split(coreB, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		na, nb := 0, 0
		if i < len(pa) {
			na, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			nb, _ = strconv.Atoi(pb[i])
		}
		if na != nb {
			if na < nb {
				return -1
			}
			return 1
		}
	}
	switch {
	case preA == preB:
		return 0
	case preA == "": // release > prerelease
		return 1
	case preB == "":
		return -1
	}
	ia := strings.Split(preA, ".")
	ib := strings.Split(preB, ".")
	for i := 0; i < len(ia) && i < len(ib); i++ {
		if ia[i] == ib[i] {
			continue
		}
		na, errA := strconv.Atoi(ia[i])
		nb, errB := strconv.Atoi(ib[i])
		if errA == nil && errB == nil { // both numeric: compare numerically
			if na < nb {
				return -1
			}
			return 1
		}
		if ia[i] < ib[i] {
			return -1
		}
		return 1
	}
	// All compared identifiers equal: the longer prerelease ranks higher.
	if len(ia) < len(ib) {
		return -1
	}
	if len(ia) > len(ib) {
		return 1
	}
	return 0
}

// fetchToFile downloads url into dst (creating it 0600). Returns the HTTP
// error for non-2xx.
func fetchToFile(client *http.Client, rawURL, dst string) error {
	resp, err := client.Get(rawURL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("download failed from %s (HTTP %d)", rawURL, resp.StatusCode)
	}
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

// fetchString downloads url into memory (checksums.txt is tiny).
func fetchString(client *http.Client, rawURL string) (string, error) {
	resp, err := client.Get(rawURL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("download failed from %s (HTTP %d)", rawURL, resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return string(b), err
}

// checksumFor extracts the sha256 for asset from checksums.txt content
// (`<hash>  <name>` lines, the sha256sum/shasum format).
func checksumFor(sums, asset string) (string, error) {
	for _, line := range strings.Split(sums, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[1] == asset {
			return fields[0], nil
		}
	}
	return "", fmt.Errorf("checksums.txt has no entry for %s", asset)
}

// performUpgrade downloads bp-<GOOS>-<GOARCH> for version latest from base's
// release tree, verifies its sha256 against the release's checksums.txt, and
// atomically renames it over exePath. The temp file lives in exePath's own
// directory so the final rename(2) never crosses filesystems.
func performUpgrade(base, latest, exePath string) error {
	asset := "bp-" + runtime.GOOS + "-" + runtime.GOARCH
	dlBase := base + "/releases/download/cli-v" + latest
	// Header-timeout-only transfer client (shared with the media-upload path): a
	// slow-but-alive binary download must not be killed by a 120s wall-clock cap.
	// fetchString stays safe via its 1MB LimitReader.
	client := newTransferClient()

	sums, err := fetchString(client, dlBase+"/checksums.txt")
	if err != nil {
		return err
	}
	expected, err := checksumFor(sums, asset)
	if err != nil {
		return err
	}

	tmp := filepath.Join(filepath.Dir(exePath), fmt.Sprintf(".bp.new.%d", os.Getpid()))
	if err := fetchToFile(client, dlBase+"/"+asset, tmp); err != nil {
		os.Remove(tmp)
		return err
	}

	f, err := os.Open(tmp)
	if err != nil {
		os.Remove(tmp)
		return err
	}
	h := sha256.New()
	_, err = io.Copy(h, f)
	f.Close()
	if err != nil {
		os.Remove(tmp)
		return err
	}
	actual := hex.EncodeToString(h.Sum(nil))
	if actual != expected {
		os.Remove(tmp)
		return fmt.Errorf("checksum mismatch for %s — refusing to install (expected %s, got %s)", asset, expected, actual)
	}

	if err := os.Chmod(tmp, 0o755); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, exePath); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// upgradeDevBuildRefusal is the dev-build refusal for the MUTATING path. The
// instruction is the right one and stays verbatim.
const upgradeDevBuildRefusal = "bp upgrade: this is a dev build (go build); upgrade via git pull + make cli-build"

// runUpgrade is the `bp upgrade` builtin: self-update from the cli-v*
// GitHub Releases. --check reports current vs latest without touching the
// binary (exit 1 when behind). Refuses on dev builds (no release to compare
// against). Honors BARKPARK_CLI_RELEASE_BASE (release-tree root).
//
// The two dev-build paths answer two DIFFERENT questions and must not be
// conflated. Bare `bp upgrade` asks "replace this binary" — impossible for a dev
// build, so it refuses at exitUsage. `bp upgrade --check` asks "how fresh am I?"
// — the honest answer is that no reading can be taken, which is exactly what
// `bp doctor --onboarding` now reports (Status onbCLIUnreported, ok unchanged,
// exit 0). An unknown is not a failure, so --check reports it and exits 0 too:
// the same fact must not produce contradicting verdicts on two surfaces.
func runUpgrade(out *writer, g globals, args []string) int {
	check := false
	for _, a := range args {
		switch a {
		case "--check":
			check = true
		default:
			out.userErr("unknown upgrade flag %q", a)
			out.errf("usage: bp upgrade [--check] [-o json|yaml]")
			return exitUsage
		}
	}
	if g.help {
		// Explicit --help goes to stdout and exits 0 (parity with the other
		// built-ins: migrate/seed/make/tinker/doctor).
		out.outf("usage: bp upgrade [--check] [-o json|yaml]")
		out.outf("  self-update bp from the latest cli-v* GitHub release")
		out.outf("  --check   print current vs latest only; exit 1 when behind")
		out.outf("            a dev build reports status=unreported and exits 0 —")
		out.outf("            it cannot be compared, so no verdict is claimed")
		return exitOK
	}

	if cliVersion == "dev" {
		if check {
			// Freshness is UNREPORTED, not "up to date" and not "behind" — the
			// same tri-state the onboarding receipt renders for this binary.
			if !out.emitStructured(map[string]any{
				"current": cliVersion,
				"latest":  "",
				"behind":  nil,
				"status":  onbCLIUnreported,
			}) {
				out.outf("bp %s — freshness UNREPORTED: a dev build (go build) has no release to compare against; refresh it with `%s`", cliVersion, onbCLIDevRemedy)
			}
			return exitOK
		}
		out.errf("%s", upgradeDevBuildRefusal)
		return exitUsage
	}

	base := releaseRepoBase()
	latest, err := latestReleaseVersion(base)
	if err != nil {
		out.errf("bp upgrade: %v", err)
		return exitGeneric
	}
	behind := compareVersions(cliVersion, latest) < 0

	if check {
		// `status` carries the same vocabulary the onboarding receipt uses, so a
		// reader gets one word meaning one thing on both surfaces.
		status := onbCLIUpToDate
		if behind {
			status = onbCLIBehind
		}
		if !out.emitStructured(map[string]any{"current": cliVersion, "latest": latest, "behind": behind, "status": status}) {
			if behind {
				out.outf("bp %s — latest is %s (run 'bp upgrade')", cliVersion, latest)
			} else {
				out.outf("bp is up to date (%s)", cliVersion)
			}
		}
		if behind {
			return exitGeneric
		}
		return exitOK
	}

	exePath, err := upgradeExecutable()
	if err != nil {
		out.errf("bp upgrade: cannot resolve own binary path: %v", err)
		return exitGeneric
	}

	if !behind {
		if !out.emitStructured(map[string]any{"current": cliVersion, "latest": latest, "updated": false, "path": exePath}) {
			out.outf("bp is up to date (%s)", cliVersion)
		}
		return exitOK
	}

	if err := performUpgrade(base, latest, exePath); err != nil {
		if os.IsPermission(err) {
			out.errf("bp upgrade: %s is not writable.", exePath)
			out.errf("Re-run the installer with elevated rights:")
			out.errf("  %s", installerOneLiner)
			return exitGeneric
		}
		out.errf("bp upgrade: %v", err)
		return exitGeneric
	}

	if !out.emitStructured(map[string]any{"current": cliVersion, "latest": latest, "updated": true, "path": exePath}) {
		out.outf("upgraded bp %s → %s (%s)", cliVersion, latest, exePath)
	}
	return exitOK
}
