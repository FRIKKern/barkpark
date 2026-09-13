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
	c, ok := devBuildCommitFreshnessIn(dir)
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
	c, ok := devBuildCommitFreshnessIn(dir)
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
	if _, ok := devBuildCommitFreshnessIn(dir); ok {
		t.Fatalf("an unstamped build must take NO reading — UNREPORTED is the only honest answer")
	}
}

// No origin/main (offline / never fetched) — the compare target is missing, so
// no verdict is claimed. A bare merge-base here would false-GREEN.
func TestDevBuildCommitFreshnessNoOriginMainTakesNoReading(t *testing.T) {
	dir := stalenessRepo(t)
	built := gitIn(t, dir, "rev-parse", "HEAD")
	withStamp(t, built, "")
	if _, ok := devBuildCommitFreshnessIn(dir); ok {
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
	if _, ok := devBuildCommitFreshnessIn(dir); ok {
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

	c := whoamiCLIFreshness()
	if c.Status != onbCLIBehind {
		t.Fatalf("whoami cli status = %q, want %q — whoami is where the fleet reads freshness", c.Status, onbCLIBehind)
	}
	if !strings.Contains(c.Detail, "STALE") {
		t.Fatalf("whoami detail must carry the staleness warning; got %q", c.Detail)
	}
}
