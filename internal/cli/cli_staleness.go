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
//
// ── THE SAME READING ANSWERS A SECOND, DIFFERENT QUESTION ────────────────────
//
// A RELEASE binary (cliVersion "1.21.0", not "dev") is commit-stamped by exactly
// the same -ldflags (Makefile:104 COMMIT), so this reading is available to it
// too — and for a release binary it measures something the release channel
// cannot see. "up to date" on the release leg means ONE thing: `cliVersion ==
// the newest cli-v* tag`. It does NOT mean the binary carries the CLI code. When
// nobody has cut a tag, the newest release drifts behind origin/main and every
// operator on it is told `up_to_date: true` while the gap grows. Measured on
// this tree 2026-09-16: cli-v1.21.0 (2026-09-03) is 181 commits / 301 changed
// files behind origin/main under internal/cli.
//
// channelStaleness below is that second question. Its remedy is deliberately NOT
// `bp upgrade` — the operator ALREADY RUNS the newest release, so upgrading is a
// no-op. Only a new cli-v* tag clears it, and that is an owner action.
//
// SCOPE, stated so nobody over-reads it: this reading needs a checkout. A
// `curl | sh` stranger with no barkpark repo gets ok=false and keeps the
// release-channel verdict. Reaching THAT population requires a signal from
// outside the binary (a server-side verdict); this file cannot and does not
// claim to cover it.

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

// buildCommitFreshness takes the reading for the process working directory.
func buildCommitFreshness() (onbCLICheck, bool) {
	return buildCommitFreshnessIn("")
}

// commitDrift is ONE reading of the installed build commit against origin/main,
// held in structured form so the two callers can render DIFFERENT remedies from
// the same facts. Changed == 0 means the binary carries every internal/cli
// change origin/main has.
type commitDrift struct {
	SHA     string // resolved build commit
	Head    string // short origin/main
	Built   string // " (built <date>)" or ""
	Changed int    // files under cliStalenessPathspec the binary lacks
}

// facts renders the remedy-free half of the verdict: what was built, from where,
// and how far origin/main has moved. Every caller prefixes/suffixes its own
// remedy; none of them may restate the facts differently.
func (d commitDrift) facts() string {
	return "this bp was built from " + d.SHA + d.Built +
		"; origin/main is at " + d.Head + " with " + cliStaleChangeCount(d.Changed) +
		" under " + cliStalenessPathspec + "/ it does not carry"
}

// readCommitDrift is the testable core: it reports the installed build commit
// against origin/main for internal/cli, in the checkout rooted at dir. ok=false
// means no sound reading could be taken and the caller must stay on UNREPORTED.
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
func readCommitDrift(dir string) (commitDrift, bool) {
	var d commitDrift

	sha := buildCommitSHA(cliCommit)
	if sha == "" {
		return d, false
	}
	if !gitOK(dir, "cat-file", "-e", sha+"^{commit}") {
		return d, false
	}
	if !gitOK(dir, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main") {
		return d, false
	}
	base, ok := gitOut(dir, "merge-base", sha, "refs/remotes/origin/main")
	if !ok || base == "" {
		return d, false
	}
	// DIVERGED: neither commit contains the other.
	if !gitOK(dir, "merge-base", "--is-ancestor", sha, "refs/remotes/origin/main") &&
		!gitOK(dir, "merge-base", "--is-ancestor", "refs/remotes/origin/main", sha) {
		return d, false
	}
	head, ok := gitOut(dir, "rev-parse", "--short", "refs/remotes/origin/main")
	if !ok {
		return d, false
	}
	changed, ok := gitOut(dir, "diff", "--name-only", base, "refs/remotes/origin/main", "--", cliStalenessPathspec)
	if !ok {
		return d, false
	}

	d.SHA = sha
	d.Head = head
	if cliDate != "" {
		d.Built = " (built " + cliDate + ")"
	}
	if changed != "" {
		d.Changed = len(strings.Split(changed, "\n"))
	}
	return d, true
}

// buildCommitFreshnessIn renders readCommitDrift as the DEV-BUILD verdict: the
// remedy is a rebuild from this checkout, because a dev binary has no release to
// upgrade to.
func buildCommitFreshnessIn(dir string) (onbCLICheck, bool) {
	c := onbCLICheck{Installed: cliVersion}
	d, ok := readCommitDrift(dir)
	if !ok {
		return c, false
	}
	if d.Changed > 0 {
		c.Status = onbCLIBehind
		c.UpToDate = onbBool(false)
		c.Detail = "STALE — " + d.facts() + ". Refresh it with `" + onbCLIDevRemedy + "`"
		return c, true
	}
	c.Status = onbCLIUpToDate
	c.UpToDate = onbBool(true)
	c.Detail = "built from " + d.SHA + d.Built + "; origin/main (" + d.Head + ") carries no " +
		cliStalenessPathspec + "/ change this binary lacks"
	return c, true
}

// onbCLIChannelRemedy is the ONE move that clears a channel-stale verdict.
// It is deliberately NOT `bp upgrade`: in this state the operator already runs
// the newest published release, so upgrading fetches the same bytes back. Only a
// new cli-v* tag moves the channel, and cutting one is an OWNER action.
const onbCLIChannelRemedy = "cut the next cli-v<semver> tag — `bp upgrade` cannot clear this, because you already run the newest published release"

// channelStaleness answers: is the RELEASE CHANNEL itself stale under this
// binary's feet? It is consulted ONLY on the leg where the release comparison
// was about to return up-to-date, and it speaks ONLY when it has a real contrary
// reading — so it can never manufacture a "behind" out of an absence, and it
// goes permanently silent the moment a tag carrying the code is cut.
//
// latest is the release the channel resolved to; it is carried through so the
// receipt still reports which release the operator is on.
func channelStaleness(latest string) (onbCLICheck, bool) {
	d, ok := readCommitDrift("")
	if !ok || d.Changed == 0 {
		return onbCLICheck{}, false
	}
	return onbCLICheck{
		Installed: cliVersion,
		Latest:    latest,
		Status:    onbCLIBehind,
		UpToDate:  onbBool(false),
		Detail: "CHANNEL STALE — you run the newest published release (" + latest +
			") and it is behind the code: " + d.facts() + ". " + onbCLIChannelRemedy,
	}, true
}

// cliStaleChangeCount renders "1 change" / "N changes".
func cliStaleChangeCount(n int) string {
	if n == 1 {
		return "1 change"
	}
	return itoa(n) + " changes"
}
