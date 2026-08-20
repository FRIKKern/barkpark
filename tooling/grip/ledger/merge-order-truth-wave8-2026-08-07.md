# Re-derivation recipes — S0 merge-order truth, wave 8 (2026-08-07 ~00:55–01:01Z)

Verifier lane `merge-order-truth`. Every row is a single command that re-derives one fact
from scratch. Nothing here is quoted from a charter or a handoff.

## Queue state

```sh
# The four PRs the handoff named. Two are already MERGED.
for n in 9887 9888 9959 9960; do gh pr view $n --json number,state,mergeStateStatus,mergeable,headRefOid -q '[.number,.state,.mergeStateStatus,.mergeable,.headRefOid]|@tsv'; done
# NOTE: mergeStateStatus is computed lazily — the FIRST call after a fetch returns
# UNKNOWN/UNKNOWN. Call once, sleep 3, call again, or you will record a false unknown.

# Whole open queue, one line each
gh pr list --state open --limit 40 --json number,title,mergeStateStatus -q '.[]|[.number,.mergeStateStatus,.title[0:70]]|@tsv' | sort -n
```

## What is actually required to merge

```sh
gh api repos/:owner/:repo/branches/main/protection --jq '{contexts:.required_status_checks.contexts, enforce_admins:.enforce_admins.enabled, reviews:.required_pull_request_reviews}'
# -> ["Elixir gate","PR references an active task","Cloud gate","Console gate"], enforce_admins true, reviews null
```

## Per-sha check-runs (never the `gh run list` rollup)

```sh
gh api "repos/:owner/:repo/commits/<FULL_SHA>/check-runs?per_page=100" --jq '.check_runs[]|[.name,.status,.conclusion]|@tsv' | sort
# Required-only projection:
gh api "repos/:owner/:repo/commits/<FULL_SHA>/check-runs?per_page=100" --jq '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|[.name,.status,.conclusion]|@tsv'|sort
```

## #9887 — BLOCKED by an ABSENT context, not a red one

```sh
gh api repos/:owner/:repo/commits/aa19dcca3a5a8f2f6edd014e9369c3a5f5c263c2/status --jq '{state,total:.total_count}'   # -> pending, 0
gh pr view 9887 --json statusCheckRollup -q '.statusCheckRollup[]|.name'|grep -ci console                                # -> 0
gh run list --branch loop-epic/the-triage-ladder-lands-eleven-rungs-bp--0 --limit 20 --json workflowName,status,conclusion -q '.[]|[.workflowName,.status,.conclusion]|@tsv'
gh api repos/:owner/:repo/actions/runs/31120806862 --jq '{status,run_attempt,created_at,run_started_at,updated_at}'
gh api repos/:owner/:repo/actions/runs/31120806862/jobs --jq '.total_count'                                             # -> 0
```

## #9959 — BLOCKED by a REFUSAL wearing a defect's exit code

```sh
gh api "repos/:owner/:repo/actions/runs/31134365822/jobs?per_page=50" --jq '.jobs[]|[.name,.conclusion,.id]|@tsv'
# The ONLY honest line in a job log is the emitted ##[error]; the case-arm echoes are
# script SOURCE and contain both "REFUSED" and "DEFECT" on every run. Grep the emitted one:
gh api repos/:owner/:repo/actions/jobs/92732939072/logs | grep -E '^[^ ]*Z ##\[error\]' | cut -c30-140
```

## Chrome bring-up flake on main itself

```sh
gh run list --workflow console-harness --branch main --limit 40 --json conclusion -q '.[].conclusion' | sort | uniq -c
gh run list --workflow console-harness --branch main --limit 40 --json createdAt,databaseId,headSha,conclusion -q '.[]|select(.conclusion=="failure")|[.createdAt,.databaseId,.headSha[0:8]]|@tsv'
# Cancelled runs are concurrency-group kills, NOT outcomes — divide by completed, not by 40.
```

## #9955 vs #9922 — conflict, already realised

```sh
gh pr view 9955 --json files -q '.files[].path' | sort > /tmp/f9955
gh pr view 9922 --json files -q '.files[].path' | sort > /tmp/f9922
comm -12 /tmp/f9955 /tmp/f9922            # -> all 6 files; the file sets are IDENTICAL
gh pr view 9922 --json state,mergedAt,mergeCommit -q '[.state,.mergedAt,.mergeCommit.oid]|@tsv'
git merge-tree --write-tree origin/main $(gh pr view 9955 --json headRefOid -q .headRefOid) | grep CONFLICT
# `git merge-base --is-ancestor <9922 head> origin/main` returns rc=1 — 9922 was
# SQUASH-merged, so its head sha is never an ancestor. Use .mergeCommit.oid, not headRefOid,
# whenever you ask "did this land".
```

## D101/D102 provenance (the charter as it really is on origin, not the dirty local copy)

```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n '\*\*D101'   # -> line 2195, it EXISTS
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '2195,2235p'
# The working-tree copy is modified (git status: M) and its line numbers differ by ~82.
```
