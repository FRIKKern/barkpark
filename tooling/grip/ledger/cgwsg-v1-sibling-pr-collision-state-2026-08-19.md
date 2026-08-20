# Sibling-PR collision state — re-derivation recipes (2026-08-19, verifier V1)

Anchor: `origin/main` = `bf499f54b63135b8ae078305b83f2b5b2c078877` (the strategy phase
quoted `122fd0df81`; main advanced between phases — re-anchor before quoting).

## 1. The seven PRs: state, mergeability, required-check conclusions
```
for n in 12545 12558 12559 12560 12561 12562 12563; do
  gh pr view $n --json number,state,mergeable,mergeStateStatus,headRefOid \
    -q '"\(.number) \(.state) \(.mergeable)/\(.mergeStateStatus) \(.headRefOid)"'
  sha=$(gh pr view $n --json headRefOid -q .headRefOid)
  gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs?per_page=100" --jq \
    '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|"  REQ \(.name): \(.conclusion)"'
done
```

## 2. main's LIVE required set (the authority, not the committed spec)
```
gh api repos/FRIKKern/barkpark/branches/main/protection \
  --jq '.required_status_checks|{strict:.strict,contexts:.contexts}'
```

## 3. Doc budgets green / Shell harnesses red on main
```
gh api "repos/FRIKKern/barkpark/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
  --jq '.check_runs[]|select(.name|test("Doc budgets|Shell harnesses|spec gate"))|"\(.name): \(.status)/\(.conclusion)"'
gh run list --workflow=shell-harnesses.yml --branch=main --limit=15 \
  --json createdAt,conclusion,headSha,databaseId \
  -q '.[]|"\(.createdAt) \(.headSha[0:10]) \(.conclusion) run=\(.databaseId)"'
gh run view 32070474429 --json jobs -q '.jobs[]|select(.conclusion=="failure")|.name'
```

## 4. Conflict-freedom, without mutating the shared checkout
```
for n in 12545 12558 12559 12560 12561 12562 12563; do
  git fetch -q origin "pull/$n/head:refs/verifier/pr$n" -f
  git merge-tree --write-tree --messages "$(git rev-parse origin/main)" refs/verifier/pr$n >/dev/null; echo "$n rc=$?"
done
# overlap probe (empty output = fully disjoint file sets)
for n in 12545 12558 12559 12560 12561 12562 12563; do
  git diff --name-only origin/main...refs/verifier/pr$n; done | sort | uniq -d
```
Refs live under `refs/verifier/*` — they touch no branch and no worktree.

## 5. Whether a lapsed claim would re-red pr-task-gate on a rebase+push
```
git show origin/main:scripts/pr-task-gate.sh | sed -n '480,500p'   # the `open` branch
bp task get cgsi-s7-tenant-scope-marker   # read claim.expired_at
gh pr view 12563 --json createdAt          # compare: open_lead = expired_at - createdAt
```
`open_lead >= 0` is the PASS condition — measured against the PR's OPEN time, not now.

## 6. Which workflows a Ring-1 edit to required-checks-verify.sh fires
```
git show origin/main:.github/workflows/shell-harnesses.yml | grep -n required-checks-verify
git show origin/main:.github/workflows/required-checks-drift.yml | sed -n '83,90p'   # bare `on: pull_request:` — no paths filter
```
