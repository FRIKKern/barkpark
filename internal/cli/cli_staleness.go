package cli

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// ── Dev-build freshness from the BUILD COMMIT ────────────────────────────────
//
// A "dev" bp is two different binaries wearing one word, and conflating them is
// what let a week-old fleet binary report freshness as UNREPORTED:
//
//   1. UNSTAMPED — a bare `go build`. cliCommit is empty, there is no provenance
//      at all, and UNREPORTED is the only honest answer.
//   2. COMMIT-STAMPED — `make cli-install` with VERSION unset. cliVersion is
//      still "dev" (Makefile: `VERSION ?= dev`), but cliCommit/cliDate ARE
//      injected via -ldflags, so the binary knows exactly which tree built it.
//
// Case 2 is the fleet's case, and it is COMPARABLE: the same comparison
// scripts/doctor.sh has always made — installed commit vs origin/main, over the
// Go inputs — can be made in-process, which puts the verdict on `bp whoami`,
// the surface agents actually read. Nothing here touches the network; every
// call is a local git read against the checkout bp was invoked from.
//
// The scope is internal/cli: a stale bp is a stale CLI, and narrowing the
// pathspec to the code that IS the CLI keeps an unrelated api/ or web/ commit
// from crying stale at a binary that is in fact current.
//
// The tri-state is NOT widened. A reading taken here is a real reading and gets
// the existing vocabulary (onbCLIBehind / onbCLIUpToDate); anything that cannot
// be resolved — no checkout, no origin/main, no shared ancestry, a DIVERGED
// binary — returns ok=false and falls back to the honest UNREPORTED leg. An
// absence is never laundered into a verdict.

// cliStalenessTimeout bounds the git reads. whoami is a hot, always-run,
// always-exit-0 surface: a hung or pathological repo must degrade to UNREPORTED,
// never hang the command.
const cliStalenessTimeout = 3 * time.Second

// cliStalenessPathspec is the code whose drift makes a bp binary stale.
const cliStalenessPathspec = "internal/cli"

// buildCommitSHA is the bare hex prefix of the -ldflags commit stamp. A dirty
// build stamps e.g. "2a8b147ee-dirty-purpose"; only the leading hex run is a
// commit git can resolve. Returns "" when there is no usable SHA — which is
// case 1 above, and the caller must then report UNREPORTED.
func buildCommitSHA(stamp string) string {
	i := 0
	for i < len(stamp) {
		c := stamp[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			i++
			continue
		}
		break
	}
	if i < 7 {
		return ""
	}
	return stamp[:i]
}

// gitOut runs one git read in dir and returns its trimmed stdout. dir == ""
// means the process working directory.
func gitOut(dir string, args ...string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), cliStalenessTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(out)), true
}

// gitOK runs one git predicate in dir and reports whether it exited 0.
func gitOK(dir string, args ...string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), cliStalenessTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	return cmd.Run() == nil
}

// devBuildCommitFreshness takes the reading for the process working directory.
func devBuildCommitFreshness() (onbCLICheck, bool) {
	return devBuildCommitFreshnessIn("")
}

// devBuildCommitFreshnessIn is the testable core: it reports the installed
// build commit against origin/main for internal/cli, in the checkout rooted at
// dir. ok=false means no sound reading could be taken and the caller must stay
// on UNREPORTED.
//
// The guard ORDER is load-bearing and mirrors scripts/doctor.sh's, for the same
// reasons documented there:
//   - no stamp            → no provenance, no reading
//   - commit not in repo   → cannot diff a commit this checkout does not have
//   - origin/main absent   → the compare target is missing; a bare merge-base
//     here false-GREENS, because the swallowed error leaves an empty diff
//   - no merge-base        → no shared ancestry to compare across
//   - DIVERGED             → the binary carries commits main never saw, so it
//     does not merely predate main and `make cli-install` from this same
//     checkout would reinstall it; that is doctor.sh's territory, not a
//     freshness verdict, so no reading is claimed
//
// The diff is taken from the MERGE-BASE, not from the build commit: a binary
// built AHEAD of origin/main with unpushed CLI commits has merge-base ==
// origin/main, so its diff is empty and it correctly reads current. A bare
// `git diff <build commit> origin/main` would false-RED that case.
func devBuildCommitFreshnessIn(dir string) (onbCLICheck, bool) {
	c := onbCLICheck{Installed: cliVersion}

	sha := buildCommitSHA(cliCommit)
	if sha == "" {
		return c, false
	}
	if !gitOK(dir, "cat-file", "-e", sha+"^{commit}") {
		return c, false
	}
	if !gitOK(dir, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main") {
		return c, false
	}
	base, ok := gitOut(dir, "merge-base", sha, "refs/remotes/origin/main")
	if !ok || base == "" {
		return c, false
	}
	// DIVERGED: neither commit contains the other.
	if !gitOK(dir, "merge-base", "--is-ancestor", sha, "refs/remotes/origin/main") &&
		!gitOK(dir, "merge-base", "--is-ancestor", "refs/remotes/origin/main", sha) {
		return c, false
	}
	head, ok := gitOut(dir, "rev-parse", "--short", "refs/remotes/origin/main")
	if !ok {
		return c, false
	}
	changed, ok := gitOut(dir, "diff", "--name-only", base, "refs/remotes/origin/main", "--", cliStalenessPathspec)
	if !ok {
		return c, false
	}

	built := ""
	if cliDate != "" {
		built = " (built " + cliDate + ")"
	}
	if changed != "" {
		n := len(strings.Split(changed, "\n"))
		c.Status = onbCLIBehind
		c.UpToDate = onbBool(false)
		c.Detail = "STALE — this bp was built from " + sha + built +
			"; origin/main is at " + head + " with " + cliStaleChangeCount(n) +
			" under " + cliStalenessPathspec + "/ it does not carry. Refresh it with `" + onbCLIDevRemedy + "`"
		return c, true
	}
	c.Status = onbCLIUpToDate
	c.UpToDate = onbBool(true)
	c.Detail = "built from " + sha + built + "; origin/main (" + head + ") carries no " +
		cliStalenessPathspec + "/ change this binary lacks"
	return c, true
}

// cliStaleChangeCount renders "1 change" / "N changes".
func cliStaleChangeCount(n int) string {
	if n == 1 {
		return "1 change"
	}
	return itoa(n) + " changes"
}
