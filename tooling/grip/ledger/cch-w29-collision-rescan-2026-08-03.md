# cch-w29 collision re-scan — re-derivation recipes (2026-08-03, ~17:50 CEST)

Scan taken against `origin/main` at `92f91f04339f04f732c616f52bdaaf1faee9eb50`.
The primary checkout `/Volumes/SATECHI/github/barkpark` read `[ahead 48, behind 402]`
at scan time — every fact below is re-derived from `origin/main` or from a live API,
never from the working tree.

## Open PRs and their mergeability

    gh pr list --state open --limit 100 --json number,headRefName,mergeable,updatedAt \
      --jq '.[]|"\(.number) \(.mergeable) \(.headRefName)"'

`mergeable: UNKNOWN` is GitHub not having computed a merge, not a conflict. Settle it locally:

    git fetch -q origin pull/<N>/head
    git merge-tree --write-tree origin/main <headRefOid>; echo "rc=$?"

rc 0 = clean, rc 1 = conflicts (grep `^CONFLICT`), rc 128 = `refusing to merge unrelated histories`.

## Which open PR touches a wave-29 candidate file

    for n in <open PR numbers>; do
      gh pr view $n --json files --jq '.files[].path' \
        | grep -E 'seal-predicate|app\.js|app\.css|overflow-guard|console-harness|usage\.ex|failure_copy|registry\.ex|auto_deploy_worker|notifications/render\.ex|required-checks' \
        | sed "s/^/PR$n /"
    done

## Dirty worktrees (254 of them)

    git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //' | while read w; do
      s=$(git -C "$w" status --porcelain 2>/dev/null | grep -E 'app\.js|app\.css|seal-predicate|overflow-guard|console-harness|usage\.ex|failure_copy|registry\.ex|auto_deploy_worker|render\.ex')
      [ -n "$s" ] && echo "DIRTY $w" && echo "$s"
    done; true

Then age each hit — a dirty worktree whose HEAD predates the wave is dead residue, not a concurrent editor:

    git -C "$w" log -1 --format='%h %ci'; git -C "$w" rev-parse --abbrev-ref HEAD

## "UNMERGED" remote branches are usually squash-merge artifacts

A squash-merged branch is never an ancestor of main. Do not read `--is-ancestor` failure as stranded work.
Two decisive follow-ups:

    gh pr list --head "<branch>" --state all --json number,state,mergedAt
    # and the content test, which is the stronger one:
    git rev-parse origin/main:<path>  origin/<branch>:<path>   # identical blob hash = landed

## Live branch protection (never quote a brief for this)

    gh api repos/{owner}/{repo}/branches/main/protection \
      --jq '{contexts:.required_status_checks.checks, strict:.required_status_checks.strict, enforce_admins:.enforce_admins.enabled}'

## Which slices are coupled to Console gate's leaves

Console gate is the aggregator; its leaves gate on the dispatcher's `console` output, whose
path set is a single declaration:

    git show origin/main:scripts/console-path-escape-check.sh | sed -n '110,125p'
    git show origin/main:.github/workflows/console-harness.yml | grep -n 'needs: \[changes' -B2 -A2

`cloud/lib/**` is NOT in the set — an Elixir-only slice skips `console-unit` and `overflow-guard`
and greens Console gate through the aggregator's `skipped` + `gate='false'` allow-branch.

## Is the gate green on main right now

    gh api repos/{owner}/{repo}/commits/$(git rev-parse origin/main)/check-runs \
      --jq '.check_runs[]|"\(.conclusion // .status)\t\(.name)"' | sort
