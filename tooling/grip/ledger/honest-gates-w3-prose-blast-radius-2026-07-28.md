# Re-derivation recipes — Honest Gates W3 verify: prose blast radius & unreachables (2026-07-28)

All probes read-only. Run from the repo root unless stated.

## R1 — the repo's OWN canonical protection recipe cannot bootstrap (404)

`docs/ops/merge-gates.md:212` prescribes a PATCH to
`branches/main/protection/required_status_checks`. That sub-resource is a
CHILD of protection, so it 404s while protection does not exist.

```bash
gh api -X PATCH repos/FRIKKern/barkpark/branches/main/protection/required_status_checks \
  --input - <<'JSON' 2>&1 | head -3
{"checks": [{"context": "PR references an active task", "app_id": 15368}]}
JSON
```
Expect: `{"message":"Branch not protected", ... "status":"404"}`.
Bootstrap must be `PUT .../branches/main/protection` with the FULL body
(required_status_checks + enforce_admins + required_pull_request_reviews +
restrictions, nullable ones explicitly null); the doc's PATCH is the
*subsequent-edit* verb only.

## R2 — merge-gates.md is a canonical doc whose budget cannot fail

```bash
head -1 docs/ops/merge-gates.md          # declares "budget: 800tok"
wc -c docs/ops/merge-gates.md            # 24797
grep -c merge-gates scripts/check-doc-budgets.sh   # 0
bash scripts/check-doc-budgets.sh >/dev/null; echo $?   # 0 (PASS)
```

## R3 — MUTATION: adding the cap reds doc-gates on the same PR (guard+fix trap)

```bash
S=/tmp/cdb2.sh
sed -e 's|^REPO_ROOT=.*|REPO_ROOT=/Volumes/SATECHI/github/barkpark|' \
    -e 's|^docs/ops/PROD_OPS.md 6000$|docs/ops/PROD_OPS.md 6000\ndocs/ops/merge-gates.md 3200|' \
    scripts/check-doc-budgets.sh > $S
bash $S 2>&1 | grep -E 'merge-gates|check-doc-budgets:'; bash $S >/dev/null 2>&1; echo "exit=$?"
```
Expect: `FAIL: docs/ops/merge-gates.md is 24797B, cap is 3200B`, exit=1.
(The REPO_ROOT sed is required: the script derives REPO_ROOT from `dirname $0`,
so a scratchpad copy otherwise reports every gated file "missing".)

## R4 — the stale gate name census

```bash
git grep -c 'Elixir Test' | awk -F: '{s+=$2} END {print s}'   # 253 occurrences
git grep -l 'Elixir Test' | wc -l                              # 68 files
git grep -l 'Elixir Test' -- .claude/workflows | wc -l          # 48 charters
git grep -n 'Elixir Test' -- .claude/agents connectors docs     # felix.md:44, connectors/README.md:189, merge-gates.md:100
```
`docs/ops/merge-gates.md:100` is the ONLY site that debunks the name
("There is no check called \"Elixir Test\" — that name is folklore").

## R5 — the fleet's written merge verb (tracked sites)

```bash
git grep -n -e 'gh pr merge' -e '\-\-admin' -- '*.md' '*.sh' '*.yml'
```
Load-bearing site: `.claude/workflows/bp-loop-ledger.md:43` —
"This repo does NOT allow gh auto-merge — poll checks + `gh pr merge --squash --admin`
once the required Elixir Test job passes". Two names wrong at once.
`scripts/bp-vercel-quick-setup.sh` hits are `--admin-token`, unrelated.

## R6 — the out-of-repo file no worktree and no CI can reach

```bash
grep -n -e admin -e 'TRUE blocking gates' \
  /Users/pelle/.claude/projects/-Volumes-SATECHI-github-barkpark/memory/always-merge-prs.md
cd /Users/pelle/.claude/projects/-Volumes-SATECHI-github-barkpark/memory && git rev-parse --show-toplevel
```
Expect line 15 `add \`--admin\` to override and merge now`, line 16 the stale
four-name list, and toplevel `/Users/pelle` — a DIFFERENT repo from
`/Volumes/SATECHI/github/barkpark`. Lead action, not a builder slice.

## R7 — repo merge flags + admin reachability

```bash
gh api repos/FRIKKern/barkpark --jq '{allow_auto_merge, allow_squash_merge, allow_update_branch, admin: .permissions.admin}'
```
Expect `{"admin":true,"allow_auto_merge":false,"allow_squash_merge":true,"allow_update_branch":false}`.

## R8 — the Vercel statuses are app-less legacy commit statuses

```bash
gh api repos/FRIKKern/barkpark/commits/$(git rev-parse origin/main)/status \
  --jq '.statuses[] | "\(.context) :: \(.state) :: app=\(.creator.login)"'
```
Expect `Vercel – demo :: failure :: app=null` and `Vercel – barkpark :: failure :: app=null`
(EN DASH U+2013). Already owned by open task `gr-blk-vercel-checks-ungoverned`.

## R9 — the direct-push producer inside the epic-cycle itself

```bash
grep -n 'git push\|pull --rebase' .claude/workflows/bp-epic-cycle.workflow.js | head
grep -n 'Docs-only commits' .claude/workflows/bp-epic-cycle-epic-memory-plan.md
```
Lines 726–727 instruct Decide to commit the charter + ledger rows and push
straight to `main`; the memory plan states the licence outright.
