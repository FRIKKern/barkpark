# w31 verifier — main gate + fence re-derivation recipes (2026-08-09)

Every row below is a single command that re-derives one fact from scratch.
Recorded by the wave-31 `main-gate-and-fence` verifier. Not committed by the verifier.

## 1. Is main's own Elixir gate concluded or jammed?

```sh
gh api repos/:owner/:repo/commits/$(git rev-parse origin/main)/check-runs --paginate \
  -q '.check_runs[]|"\(.name) => \(.conclusion // .status) | started=\(.started_at) completed=\(.completed_at)"' | sort -u
```

Observed 2026-08-09T16:08Z on `aa1267c11d3278e8de45024ad63b3b6b2a0925ea`:
`Elixir gate => success | started=2026-08-09T15:58:53Z completed=2026-08-09T15:58:56Z`.
NOT jammed. Merge (15:42:43Z) → gate concluded 16.2 min later.

## 2. The four required contexts

```sh
gh api repos/:owner/:repo/branches/main/protection -q '.required_status_checks.checks'
```

`Elixir gate`, `PR references an active task`, `Cloud gate`, `Console gate`.
(The task gate is PR-only; it never appears on a main-head check-run list.)

## 3. Are the seven wave-30 PRs beneath main's head?

```sh
for n in 11318 11319 11320 11321 11322 11209 11294; do
  c=$(gh pr view $n --json mergeCommit -q .mergeCommit.oid)
  git merge-base --is-ancestor $c origin/main && echo "$n $c ANCESTOR" || echo "$n $c NOT-ancestor"
done
```

All seven ANCESTOR. Note branch tips are NOT ancestors (squash merge) — never test ancestry on the head branch.

## 4. Fence scan — open PRs touching the wave's files

```sh
gh pr list --state open --limit 100 --json number,headRefName,files \
  -q '.[] | . as $p | ($p.files[].path) as $f | select($f|test("error_json|crown-reconcile|deploy_ledger")) | "\($p.number) \($p.headRefName) :: \($f)"' | sort -u
```

Only #10129 and #10400, both on `cloud/lib/barkpark_cloud/deploy_ledger.ex`, both CONFLICTING/DIRTY since 2026-08-07.
Zero open PRs on `error_json.ex` or `crown-reconcile.*`.

## 5. Live-branch scan (catches work with no PR)

```sh
for b in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -v 'origin/main$'); do
  d=$(git diff --name-only origin/main...$b | grep -E 'error_json\.ex|crown-reconcile|deploy_ledger\.ex')
  [ -n "$d" ] && echo "$b :: $d"
done
gh pr list --head "<branch>" --state all --json number,state
```

14 branches hit; 13 map to MERGED PRs (squash residue), one to CLOSED-unmerged #10014.

## 6. Which fenced paths actually exist on origin/main

```sh
for f in api/lib/barkpark_web/controllers/error_json.ex \
         cloud/lib/barkpark_cloud/deploy_ledger.ex \
         cloud/lib/barkpark_cloud/sites/deploy_ledger.ex \
         scripts/crown-reconcile.sh .github/workflows/crown-reconcile.yml; do
  git cat-file -e origin/main:$f 2>/dev/null && echo "EXISTS $f" || echo "ABSENT $f"
done
```

`cloud/lib/barkpark_cloud/sites/deploy_ledger.ex` is ABSENT — the path both charter and brief cite.

## 7. The three foreign advisory reds, and their real cause

```sh
SHA=$(git rev-parse origin/main)
gh api repos/:owner/:repo/commits/$SHA/check-runs --paginate \
  -q '.check_runs[]|select(.conclusion=="failure")|"\(.name) \(.html_url)"'
gh api repos/:owner/:repo/actions/jobs/<job-id>/logs | grep -iE 'error|drift|STALE'
```

- `Sobelow static analysis …` — pre-existing on the previous main head too; findings are in
  `lib/barkpark_web/router.ex`, `lib/barkpark/codelists/editeur.ex`, `lib/barkpark/content/validation.ex`.
  Declared advisory at `.github/workflows/security.yml:225`.
- `served-catalog drift audit (advisory)` — `20/22 MATCH, 2 DRIFT`
  (`barkpark--console-helper--js`, `barkpark--console-hook-zones--js`); still red AFTER #11333.
- `Stale verdict watch` — reds because CONFLICTING PRs assert green required verdicts main moved past.
  It names 22 PRs including #10129 and #10400. Self-inflicted by open stale PRs, not by any builder.

## 8. The charter you read locally is not the charter

```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n 'D516'
wc -l .claude/workflows/bp-deploy-reliability-charter.md
git status --porcelain .claude/workflows/bp-deploy-reliability-charter.md
```

Origin copy: 10578 lines, D516 at line 10326. Local copy: 10506 lines, UNTRACKED (`??`), no D516 at all.
Local HEAD `0789ab90a` has DIVERGED from origin/main (49 local-only / 790 origin-only commits).
Read the charter through `git show origin/main:…` and branch worktrees off `origin/main`, never off local HEAD.
