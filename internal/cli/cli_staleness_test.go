package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// stalenessRepo builds a throwaway checkout with a real origin/main ref, so the
// verdicts below are taken by git itself and not by a stub that could agree with
// a broken implementation. Returns the repo dir.
func stalenessRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	dir := t.TempDir()
	run := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
		return strings.TrimSpace(string(out))
	}
	write := func(rel, body string) {
		t.Helper()
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("init", "-q", "-b", "main")
	write("internal/cli/run.go", "package cli // v1\n")
	run("add", "-A")
	run("commit", "-q", "-m", "base")
	return dir
}

func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func writeIn(t *testing.T, dir, rel, body string) {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func withStamp(t *testing.T, commit, date string) {
	t.Helper()
	oc, od := cliCommit, cliDate
	cliCommit, cliDate = commit, date
	t.Cleanup(func() { cliCommit, cliDate = oc, od })
}

// A binary built BEFORE an internal/cli change that has since landed on
// origin/main must read BEHIND — the exact fleet case: bp whoami said
// "unreported" while the installed binary was a week of CLI commits stale.
func TestDevBuildCommitFreshnessBehindOnInternalCLIChange(t *testing.T) {
	dir := stalenessRepo(t)
	built := gitIn(t, dir, "rev-parse", "HEAD")

	writeIn(t, dir, "internal/cli/run.go", "package cli // v2\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "cli change")
	head := gitIn(t, dir, "rev-parse", "HEAD")
	gitIn(t, dir, "update-ref", "refs/remotes/origin/main", head)
	headShort := gitIn(t, dir, "rev-parse", "--short", head)

	withStamp(t, built, "2026-09-05T05:41:20Z")
	c, ok := buildCommitFreshnessIn(dir)
	if !ok {
		t.Fatalf("a stamped binary in a checkout that HAS its commit and origin/main must yield a reading; got ok=false")
	}
	if c.Status != onbCLIBehind {
		t.Fatalf("status = %q, want %q — an internal/cli commit landed after this build", c.Status, onbCLIBehind)
	}
	if c.UpToDate == nil || *c.UpToDate {
		t.Fatalf("up_to_date = %v, want a taken reading of false", c.UpToDate)
	}
	if !strings.Contains(c.Detail, "STALE") {
		t.Fatalf("detail must warn STALE where agents read it; got %q", c.Detail)
	}
	// The evidence an agent needs: which commit it runs, which commit main is at.
	for _, want := range []string{built[:9], headShort, "2026-09-05T05:41:20Z", onbCLIDevRemedy} {
		if !strings.Contains(c.Detail, want) {
			t.Fatalf("detail %q is missing %q", c.Detail, want)
		}
	}
}

// CONTROL: the same repo, the same distance in commits, but the new commit does
// NOT touch internal/cli — the binary is current and must NOT be cried stale.
// Without this arm a comparison hard-wired to "behind" would pass the test above.
func TestDevBuildCommitFreshnessCurrentWhenChangeIsOutsideInternalCLI(t *testing.T) {
	dir := stalenessRepo(t)
	built := gitIn(t, dir, "rev-parse", "HEAD")

	writeIn(t, dir, "docs/whatever.md", "unrelated\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "docs only")
	head := gitIn(t, dir, "rev-parse", "HEAD")
	gitIn(t, dir, "update-ref", "refs/remotes/origin/main", head)

	withStamp(t, built, "2026-09-05T05:41:20Z")
	c, ok := buildCommitFreshnessIn(dir)
	if !ok {
		t.Fatalf("want a reading, got ok=false")
	}
	if c.Status != onbCLIUpToDate {
		t.Fatalf("status = %q, want %q — nothing under internal/cli changed", c.Status, onbCLIUpToDate)
	}
	if c.UpToDate == nil || !*c.UpToDate {
		t.Fatalf("up_to_date = %v, want a taken reading of true", c.UpToDate)
	}
}

// An UNSTAMPED build (bare `go build`) has no provenance at all: no reading, so
// the caller stays on the honest UNREPORTED leg. This is the case the tri-state
// doctrine exists for, and it must survive the new comparison.
func TestDevBuildCommitFreshnessUnstampedTakesNoReading(t *testing.T) {
	dir := stalenessRepo(t)
	head := gitIn(t, dir, "rev-parse", "HEAD")
	gitIn(t, dir, "update-ref", "refs/remotes/origin/main", head)

	withStamp(t, "", "")
	if _, ok := buildCommitFreshnessIn(dir); ok {
		t.Fatalf("an unstamped build must take NO reading — UNREPORTED is the only honest answer")
	}
}

// No origin/main (offline / never fetched) — the compare target is missing, so
// no verdict is claimed. A bare merge-base here would false-GREEN.
func TestDevBuildCommitFreshnessNoOriginMainTakesNoReading(t *testing.T) {
	dir := stalenessRepo(t)
	built := gitIn(t, dir, "rev-parse", "HEAD")
	withStamp(t, built, "")
	if _, ok := buildCommitFreshnessIn(dir); ok {
		t.Fatalf("without refs/remotes/origin/main there is nothing sound to compare against")
	}
}

// A DIVERGED binary carries commits main never saw. doctor.sh reds it with a
// different remedy (git pull --rebase); a freshness verdict here would be false
// either way, so no reading is taken.
func TestDevBuildCommitFreshnessDivergedTakesNoReading(t *testing.T) {
	dir := stalenessRepo(t)
	base := gitIn(t, dir, "rev-parse", "HEAD")

	writeIn(t, dir, "internal/cli/run.go", "package cli // main\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "main side")
	gitIn(t, dir, "update-ref", "refs/remotes/origin/main", gitIn(t, dir, "rev-parse", "HEAD"))

	gitIn(t, dir, "checkout", "-q", "-b", "side", base)
	writeIn(t, dir, "internal/cli/run.go", "package cli // side\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "side")
	side := gitIn(t, dir, "rev-parse", "HEAD")

	withStamp(t, side, "")
	if _, ok := buildCommitFreshnessIn(dir); ok {
		t.Fatalf("a DIVERGED binary must not be given a freshness verdict")
	}
}

// buildCommitSHA must survive a dirty stamp ("<sha>-dirty-<label>") and refuse
// anything too short to be a commit.
func TestBuildCommitSHA(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"3f0139ab6", "3f0139ab6"},
		{"2a8b147ee-dirty-purpose", "2a8b147ee"},
		{"", ""},
		{"abc", ""},
		{"unknown", ""},
	} {
		if got := buildCommitSHA(tc.in); got != tc.want {
			t.Fatalf("buildCommitSHA(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// The warning must reach the surface agents read: bp whoami's `cli` leg.
func TestWhoamiCLIFreshnessSurfacesStaleDevBuild(t *testing.T) {
	dir := stalenessRepo(t)
	built := gitIn(t, dir, "rev-parse", "HEAD")
	writeIn(t, dir, "internal/cli/run.go", "package cli // v2\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "cli change")
	gitIn(t, dir, "update-ref", "refs/remotes/origin/main", gitIn(t, dir, "rev-parse", "HEAD"))

	ov := cliVersion
	cliVersion = "dev"
	t.Cleanup(func() { cliVersion = ov })
	withStamp(t, built, "2026-09-05T05:41:20Z")

	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })

	c := whoamiCLIFreshness(nil)
	if c.Status != onbCLIBehind {
		t.Fatalf("whoami cli status = %q, want %q — whoami is where the fleet reads freshness", c.Status, onbCLIBehind)
	}
	if !strings.Contains(c.Detail, "STALE") {
		t.Fatalf("whoami detail must carry the staleness warning; got %q", c.Detail)
	}
}

// ── THE CHANNEL-STALE ARM ────────────────────────────────────────────────────
//
// dr-w10-bl-cli-release-channel-is-stale. Re-measured 2026-09-16 on this tree:
//
//	git rev-list --count cli-v1.21.0..origin/main -- internal/cli   -> 181
//	git diff --name-only cli-v1.21.0 origin/main -- internal/cli|wc -> 301
//
// cli-v1.21.0 was cut 2026-09-03 and is the newest published release. So an
// operator who ran `bp upgrade` today gets a binary that is 181 CLI commits
// behind the code — and the release comparison tells them `up_to_date: true`,
// because that comparison only ever asked "does cliVersion equal the newest
// tag". These three tests fix the polarity: the green must be withheld when a
// real local reading contradicts it, and MUST still be given when it does not.

// stalenessChannelFixture builds a checkout whose origin/main has moved past the
// build commit by one commit under `changedPath`, stamps the binary at the build
// commit, pins cliVersion to `ver`, seeds a FRESH release cache at `latest`
// (so the release leg would otherwise return up-to-date), and chdirs into it.
func stalenessChannelFixture(t *testing.T, changedPath, ver, latest string) {
	t.Helper()
	withTempConfigHome(t)
	withCLIVersion(t, ver)

	dir := stalenessRepo(t)
	built := gitIn(t, dir, "rev-parse", "HEAD")
	writeIn(t, dir, changedPath, "changed\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "post-tag commit")
	gitIn(t, dir, "update-ref", "refs/remotes/origin/main", gitIn(t, dir, "rev-parse", "HEAD"))

	withStamp(t, built, "2026-09-03T12:20:08Z")
	if err := writeReleaseCache(latest); err != nil {
		t.Fatalf("writeReleaseCache: %v", err)
	}

	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })
}

// FIRES-WHEN-IT-SHOULD. Newest published release, and that release is behind the
// code. Revert the channelStaleness call in whoamiCLIFreshness and this test
// gets `up-to-date` / true back and reds.
func TestWhoamiCLIFreshnessRefusesGreenWhenTheChannelItselfIsStale(t *testing.T) {
	stalenessChannelFixture(t, "internal/cli/run.go", "1.21.0", "1.21.0")

	c := whoamiCLIFreshness(nil)
	if c.Status != onbCLIBehind {
		t.Fatalf("status = %q, want %q — matching the newest cli-v tag is not carrying the code", c.Status, onbCLIBehind)
	}
	if c.UpToDate == nil || *c.UpToDate {
		t.Fatalf("up_to_date = %v, want a taken reading of false", c.UpToDate)
	}
	if !strings.Contains(c.Detail, "CHANNEL STALE") {
		t.Fatalf("detail must name the CHANNEL, not the operator's binary; got %q", c.Detail)
	}
	// The remedy is the whole point: `bp upgrade` re-fetches the same bytes.
	if !strings.Contains(c.Detail, "cli-v<semver>") {
		t.Fatalf("detail must name the tag cut as the remedy; got %q", c.Detail)
	}
	if strings.Contains(c.Detail, "run `bp upgrade`") {
		t.Fatalf("detail must NOT send the operator to `bp upgrade` — they already run %s; got %q", c.Latest, c.Detail)
	}
	if c.Latest != "1.21.0" {
		t.Fatalf("latest = %q, want the release still reported so the receipt stays readable", c.Latest)
	}
}

// STAYS-QUIET #1. Same shape, same distance, but the post-tag commit is outside
// internal/cli. Nothing is owed and the green must stand — without this arm a
// hard-wired "behind" would pass the test above.
func TestWhoamiCLIFreshnessKeepsGreenWhenTheChannelCarriesTheCLICode(t *testing.T) {
	stalenessChannelFixture(t, "docs/unrelated.md", "1.21.0", "1.21.0")

	c := whoamiCLIFreshness(nil)
	if c.Status != onbCLIUpToDate {
		t.Fatalf("status = %q, want %q — no internal/cli change landed after this release", c.Status, onbCLIUpToDate)
	}
	if c.UpToDate == nil || !*c.UpToDate {
		t.Fatalf("up_to_date = %v, want true", c.UpToDate)
	}
	if strings.Contains(c.Detail, "CHANNEL STALE") {
		t.Fatalf("a quiet case must not emit the channel warning; got %q", c.Detail)
	}
}

// STAYS-QUIET #2, and it is the SCOPE statement. The drift is real and present,
// but the binary carries NO commit stamp — the `curl | sh` stranger with no
// checkout. No reading can be taken, so no verdict may be manufactured: the leg
// keeps the release-channel answer. This is exactly the population that still
// needs a signal from OUTSIDE the binary (criterion c1, api/ side, not built
// here); this test pins that this change does not pretend to cover them.
func TestWhoamiCLIFreshnessMakesNoChannelClaimWithoutACommitStamp(t *testing.T) {
	stalenessChannelFixture(t, "internal/cli/run.go", "1.21.0", "1.21.0")
	withStamp(t, "", "") // unstamped: a release tarball run outside any checkout

	c := whoamiCLIFreshness(nil)
	if c.Status != onbCLIUpToDate {
		t.Fatalf("status = %q, want %q — with no provenance there is no contrary reading to act on", c.Status, onbCLIUpToDate)
	}
	if strings.Contains(c.Detail, "CHANNEL STALE") {
		t.Fatalf("an absence must never be laundered into a channel verdict; got %q", c.Detail)
	}
}

// The doctor receipt is the OTHER surface that renders this leg, and it takes a
// different (network-bearing) path to the same decision. Revert its
// channelStaleness call and only this test reds.
func TestOnboardingCLIFreshnessRefusesGreenWhenTheChannelItselfIsStale(t *testing.T) {
	stalenessChannelFixture(t, "internal/cli/run.go", "1.21.0", "1.21.0")
	orig := onboardingLatestRelease
	onboardingLatestRelease = func() (string, error) { return "1.21.0", nil }
	t.Cleanup(func() { onboardingLatestRelease = orig })

	c := onboardingCLIFreshness(nil)
	if c.Status != onbCLIBehind || c.UpToDate == nil || *c.UpToDate {
		t.Fatalf("doctor leg = %+v, want behind/false — the resolved release is itself behind internal/cli", c)
	}
	if !strings.Contains(c.Detail, "CHANNEL STALE") {
		t.Fatalf("doctor detail = %q, want the channel verdict", c.Detail)
	}
}
