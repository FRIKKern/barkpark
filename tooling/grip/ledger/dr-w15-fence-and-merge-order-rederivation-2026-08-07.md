# dr-w15 — fence & merge-order re-derivation recipes (2026-08-07)

Every row below re-derives a wave-15 verify claim from scratch. Run from repo root.
`origin/main` is fetched fresh first: `git fetch origin main`.

## 1. cch wave 47 — paper unciteable, zero slices filed, fence lives on PR #10355 only

```sh
bp paper view cloud-console-hardening-wave-47-2026-08-07 2>&1 | head -5
# => bp: read paper ... failed: status 422: {"error":{"code":"semantic_empty"}}

bp search query "cch-w47" --limit 40 -o json | python3 -c "import sys,json;print(json.load(sys.stdin)['count'])"
# => 1   (the ONE hit is the deploy-reliability wave-15 paper, not a cch task)

for t in cch-w47-s1 cch-w47-s2 cch-w47-s6; do bp search query "$t" --limit 5 -o json \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['count'])"; done
# => 0 0 0

git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c 'cch-w47'
# => 0   (wave 47 is NOT on main)

gh pr view 10355 --json mergeable,mergeStateStatus,files \
  --jq '{m:.mergeable,mss:.mergeStateStatus,files:[.files[].path]}'
# => MERGEABLE / BLOCKED, 2 files: the cch charter + a tooling/grip ledger row
git ls-remote --heads origin | grep -ci 'cch-w47'
# => 0   (no slice branches)
```

## 2. #10129 — conflict set, and the ladder collision is a DELETION not an insertion

```sh
git fetch origin refs/pull/10129/head:pr10129 --force
git merge-tree --write-tree origin/main pr10129 2>&1 | grep -E 'CONFLICT|Auto-merging'
# 6 CONFLICTs: attention_order.json, cloud_status_cmd.go, cloud_status_cmd_test.go,
#   attention_order_cases.json, client.go, semrole.go
# CLEAN: deploy_ledger.ex, router.ex, deploy_ledger_test.exs  <- D224 verbatim

git show origin/main:cloud/priv/static/__fixtures__/attention_order.json
# ranks 5,6,7 = strained, filling, unreported ; 11 rungs
git show pr10129:cloud/priv/static/__fixtures__/attention_order.json
# 10 rungs; strained/filling/unreported ABSENT; deploys_failing=5, unmetered=9
git log origin/main --oneline -1 -S'"filling"' -- internal/cli/cloud_status_cmd.go
# c2eecb66d ... the eleven-rung ladder ... (#9887)  <- landed AFTER #10129 was cut
```

## 3. #10304 — blocked by a LAPSED CLAIM, and `edited` re-fires the gate

```sh
gh pr view 10304 --json mergeable,mergeStateStatus,statusCheckRollup \
  --jq '{m:.mergeable,mss:.mergeStateStatus,failing:[.statusCheckRollup[]|select(.conclusion=="FAILURE")|.name]}'
# => MERGEABLE / BLOCKED / ["PR references an active task"]
gh run view 31184686254 --log | grep 'pr-task-gate: FAIL'
# => task 'task-fb4fb869490b4213' is 'open': the claim by 'epic-cycle-decide-w13' had
#    ALREADY lapsed 3469s before this PR was opened
sed -n '41,57p' .github/workflows/pr-task-gate.yml
# => types: [opened, synchronize, reopened, edited]   <- `edited` is load-bearing
```
Fix is a RE-CLAIM plus an event that re-fires (`synchronize` OR `edited`); a plain
Actions **re-run** cannot clear it, and `PR_OPENED_AT` is `created_at`, which no
re-fire moves — so re-claiming AFTER the PR was opened does not satisfy the
PR-relative lease predicate either. Close+reopen resets nothing (`created_at` is
immutable); the armed paths are a fresh PR or admin break-glass.

## 4. D163 / D170 say NOTHING about @classes — the ban is wave-plan slice prose

```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md > /tmp/charter.md
grep -n '@classes' /tmp/charter.md
# 759  (D43 — routing the unknown tail into UNCLASSIFIED is refused)
# 2727 (a conflict inventory)
# 2900 (wave-9 round law)
# 3125 (WAVE 10 PLAN, slice S1 file fence)
# 3370 (WAVE 11 PLAN, slice S4 file fence)
sed -n '3197,3216p' /tmp/charter.md   # D163 = censoring/identifiability estimator. No @classes.
sed -n '3336,3346p' /tmp/charter.md   # D170 = declined list (a)-(g). No @classes.
```
The only DURABLE constraint on `@classes` is **D43**: `@classes` rows ARE the failure
numerator, so adding a class moves the published rate.

## 5. The cross-surface attention fixture is asserted from ONE side only

```sh
git grep -n 'attention_order' origin/main -- ':!*.md'
# every hit is Go (internal/cli/**). ZERO JS/Elixir consumer.
git show origin/main:cloud/priv/static/app.js | grep -n 'strained\|filling'
# => (no output)   console classifyBp is NINE rungs; the fixture says ELEVEN
git show origin/main:cloud/priv/static/app.js | sed -n '5520,5524p'
# ATTENTION_RANK = { ... unreported: 5, behind: 6, removing: 7, provisioning: 8, ok: 9 }
```

## 6. /v1/capabilities does not know about site deploys

```sh
git grep -ln 'SITE_DEPLOY_APPLY\|site_deploy_apply' origin/main -- api/ cloud/
# capabilities_controller.ex is NOT in the list
git show origin/main:api/lib/barkpark_web/controllers/capabilities_controller.ex | wc -l   # 137
```
