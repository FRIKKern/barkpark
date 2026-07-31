# cch-w11 — open-PR deadlock sweep, re-derived at flip time (2026-07-31)

Verifier row. Re-derivation recipes only; no conclusions that the commands do not print.

## R1 — mergeable state, polled until stable (no UNKNOWN)

```
for i in 1 2 3; do gh pr list --state open --json number,mergeable,mergeStateStatus,headRefOid,headRefName \
  -q '.[]|"\(.number) \(.mergeable) \(.mergeStateStatus) \(.headRefOid[0:9]) \(.headRefName)"'; \
  echo "--- attempt $i ---"; sleep 3; done
```

Observed 2026-07-31 (identical on all three attempts, zero UNKNOWN):

    8222 MERGEABLE   UNSTABLE 6a188e5a0 fix/req-0-6-1-advisories
    6086 CONFLICTING DIRTY    7f8ced21c feat/epic-memory-journeys-debrief
    6057 CONFLICTING DIRTY    f3eeab0ea chore/sobelow-baseline-reconcile-2026-07-24
    6028 MERGEABLE   BLOCKED  57fc678c0 claude/bp-mcp-usage-myiq9m
    2907 CONFLICTING DIRTY    154f08f43 worktree-studio-host-vitals-footer

## R2 — per-head rendering of the four proposed contexts + the two live ones

```
for s in $(gh pr list --state open --json headRefOid -q '.[].headRefOid'); do echo "== ${s:0:9}"; \
  gh api "repos/FRIKKern/barkpark/commits/$s/check-runs?per_page=100" \
  --jq '[.check_runs[]|select(.name=="Elixir gate" or .name=="PR references an active task" or .name=="Console gate" or .name=="Cloud gate" or .name=="Required-check spec gate")|"\(.name)=\(.conclusion)"]|unique|join(", ")'; done
```

## R3 — live protection (the base the flip mutates)

```
gh api repos/FRIKKern/barkpark/branches/main/protection \
  --jq '{contexts:.required_status_checks.contexts, strict:.required_status_checks.strict, enforce_admins:.enforce_admins.enabled}'
```

## R4 — MERGE-REF SOURCING: the natural experiment

`spec-gate` (`Required-check spec gate`) reached main only in 650680d57 (#8253),
2026-07-30T23:04:37Z. Eleven merged PR heads have `spec_gate_in_head=0`. Split by
run time across that instant:

```
for s in 76a21d48e 446b4b4c9 1f8568cc0 0dd16f48c 2e7c535a7 ad9c4c025 346af01bb 0c6bd71e2 a52ae49a5 b86182eef 79b94d960; do
  has=$(git show $s:.github/workflows/required-checks-drift.yml 2>/dev/null | grep -c "spec-gate")
  line=$(gh api "repos/FRIKKern/barkpark/commits/$s/check-runs?per_page=100" \
    --jq '[.check_runs[]|select(.name=="Required-check spec gate")|"\(.conclusion)@\(.started_at)"]|join(",")')
  echo "$s spec_gate_in_head=$has rendered=[$line]"; done
```

8/8 heads whose runs started AFTER 23:04:37Z rendered it; 3/3 whose runs started
before (22:24–22:33Z) did not. Head-only sourcing predicts 0/11.

## R5 — the stale-merge-ref corollary (why #8222 is the exception)

```
git fetch origin pull/8222/merge:refs/tmp/pr8222merge --force
git log -1 --format='%H parents=%P' refs/tmp/pr8222merge
git show <parent0>:.github/workflows/required-checks-drift.yml | grep -c spec-gate
```

## R6 — the detector's missing leg

```
sed -n '225,236p' scripts/required-checks-verify.sh   # recent_pr_head: --state merged --limit 20
grep -rln "state open" scripts/ .github/workflows/    # no open-PR sweep exists
```
