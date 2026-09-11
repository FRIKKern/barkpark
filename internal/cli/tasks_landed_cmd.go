package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runTaskLanded is the client-side wrapper around the manifest `task landed`
// verb. The POST rides runCommand UNCHANGED; this only RESOLVES the one value a
// caller cannot be trusted to type — the merge sha — and refuses rather than
// guessing when it cannot.
//
// WHY A RESOLVER AT ALL. `content.landed` is the structured row-to-PR link
// (`prs`, `commits`, and the paired `landings`), and the close artifact gate
// now reads it off the row instead of demanding it be retyped into prose. That
// makes the SHA the load-bearing half: a wrong one turns a machine-readable
// merge record into a machine-readable lie, and nothing downstream can tell.
// `.github/workflows/landed-mark.yml` never has this problem because it runs on
// the push and `GITHUB_SHA` IS the merge commit. Every OTHER caller — an
// operator repairing a merge CI missed, a lead crediting a sibling row — is
// typing a sha by hand off a terminal, and the sha that is on screen is almost
// always the BRANCH TIP.
//
// AND THE BRANCH TIP IS NEVER THE ANSWER IN THIS REPO, because it squash-merges.
// Measured on PR #17098 (branch cli/close-time-children), 2026-09-10:
//
//	$ gh api repos/FRIKKern/barkpark/compare/022dc4c44...main --jq .status
//	diverged                     # the branch TIP
//	$ gh api repos/FRIKKern/barkpark/compare/29b6c3e66...main --jq .status
//	ahead                        # mergeCommit.oid
//	$ git merge-base --is-ancestor 022dc4c44 origin/main ; echo $?
//	1
//	$ git merge-base --is-ancestor 29b6c3e66 origin/main ; echo $?
//	0
//
// A squash writes a NEW commit onto main; the branch's own head is on no branch
// anyone keeps, so it is not an ancestor of main and never becomes one. Recorded
// as the landing sha it produces a `content.landed` entry that cannot be
// ancestor-checked by any later reader — the exact "reconstruct it by hand next
// wave" cost the structured field exists to end.
//
// SO: `--pr N` WITHOUT `--commit` resolves N to `mergeCommit.oid` and says on
// stderr that it did. `--commit` given explicitly is passed through untouched —
// this wrapper never overrides a value a caller typed, because the repair cases
// include ones `gh` cannot answer (a PR from a fork whose merge this operator is
// crediting to a different row).
//
// EVERY FAILURE IS A REFUSAL, NEVER A FALLBACK. An unmerged PR, a `gh` that is
// absent or unauthenticated, a PR number that does not resolve — each returns
// exitUsage naming what happened. The tempting fallback (use `headRefOid`, it is
// right there in the same response) is precisely the defect: it would write the
// diverged sha silently, which is worse than writing nothing.
func runTaskLanded(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	pos, flags, err := splitArgs(cmd, tail)
	if err != nil {
		// Let the shared dispatch produce the canonical usage error — one
		// message for a malformed invocation, not two spellings of it.
		return runCommand(out, g, ctx, m, cmd, tail)
	}
	_ = pos

	pr := lastFlagValue(flags, "pr")
	commit := lastFlagValue(flags, "commit")

	if pr == "" || commit != "" {
		return runCommand(out, g, ctx, m, cmd, tail)
	}

	sha, rerr := resolveMergeCommitOID(pr)
	if rerr != nil {
		return useError(out, "usage", rerr.Error(), exitUsage)
	}

	out.errf("note: PR #%s merged as %s — recording mergeCommit.oid, NOT the branch tip (a squash leaves the tip diverged from main forever).", pr, sha)

	return runCommand(out, g, ctx, m, cmd, append(append([]string{}, tail...), "--commit", sha))
}

// lastFlagValue reads the value splitArgs bound for a flag. Last wins, matching
// the request builder, so the wrapper and the POST can never disagree about
// which value was sent.
func lastFlagValue(flags map[string][]string, name string) string {
	vals := flags[name]
	if len(vals) == 0 {
		return ""
	}
	return strings.TrimSpace(vals[len(vals)-1])
}

// ghPRView is the seam the tests replace. Production runs `gh`; a test hands
// back a canned payload, so the resolution logic is exercised without a network
// or a GitHub token.
var ghPRView = func(pr string) ([]byte, error) {
	c, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(c, "gh", "pr", "view", pr, "--json", "number,state,mergedAt,mergeCommit,headRefName,headRefOid")
	return cmd.Output()
}

type ghPR struct {
	Number      int    `json:"number"`
	State       string `json:"state"`
	MergedAt    string `json:"mergedAt"`
	HeadRefName string `json:"headRefName"`
	HeadRefOid  string `json:"headRefOid"`
	MergeCommit *struct {
		OID string `json:"oid"`
	} `json:"mergeCommit"`
}

// resolveMergeCommitOID answers ONE question — which commit on main paid this
// PR — and answers it only when GitHub states the fact outright.
func resolveMergeCommitOID(pr string) (string, error) {
	raw, err := ghPRView(pr)
	if err != nil {
		return "", fmt.Errorf("could not read PR #%s through `gh pr view` (%v) — pass --commit <merge sha> explicitly, or run this where `gh` is installed and authenticated. A landing sha is never guessed", pr, err)
	}

	var p ghPR
	if jerr := json.Unmarshal(raw, &p); jerr != nil {
		return "", fmt.Errorf("could not parse `gh pr view %s --json ...` output (%v) — pass --commit <merge sha> explicitly", pr, jerr)
	}

	if p.MergeCommit == nil || strings.TrimSpace(p.MergeCommit.OID) == "" {
		// NAME THE TIP AND REFUSE IT IN THE SAME BREATH. The operator is
		// looking at that sha; saying "not merged" without saying which sha is
		// NOT the answer invites them to paste it into --commit by hand.
		tip := p.HeadRefOid
		if len(tip) > 10 {
			tip = tip[:10]
		}
		return "", fmt.Errorf("PR #%s has no mergeCommit — it is %s, not merged, so there is no landing sha to record. Its branch tip (%s on %s) is NOT one: a squash never puts the tip on main, so recording it would write a sha no reader can ancestor-check", pr, strings.ToLower(nonEmpty(p.State, "unmerged")), nonEmpty(tip, "unknown"), nonEmpty(p.HeadRefName, "its branch"))
	}

	return strings.TrimSpace(p.MergeCommit.OID), nil
}

func nonEmpty(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}

// errGHUnavailable is the sentinel the unavailable-`gh` test injects.
var errGHUnavailable = fmt.Errorf("exec: \"gh\": executable file not found in $PATH")
