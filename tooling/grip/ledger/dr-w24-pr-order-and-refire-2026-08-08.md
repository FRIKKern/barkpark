# DR wave 24 — PR order and re-fire risk: re-derivation recipes (2026-08-08)

Settles: "do the five open DR PRs re-fire `PR references an active task` into a RED
if pushed?" Answer: NO. All five PASS the shipped gate right now, run locally
against the real ledger with each PR's real `createdAt`.

## R1 — run the real gate against all five PRs (the decisive proof)

```sh
git show origin/main:scripts/pr-task-gate.sh > /tmp/ptg.sh
for p in 10722 10757 10720 10811 10129; do
  body=$(gh pr view $p --json body --jq .body)
  tid=$(PR_BODY="$body" bash /tmp/ptg.sh --extract-task-id)
  created=$(gh pr view $p --json createdAt --jq .createdAt)
  echo "=== PR #$p task=$tid created=$created"
  TASK_ID="$tid" PR_OPENED_AT="$created" bash /tmp/ptg.sh; echo "exit=$?"
done
```

NOTE: `bash /tmp/ptg.sh <pr-number>` (the form in several briefs) does NOT test
anything — the script takes no positional arg but `--extract-task-id`; with
`TASK_ID` unset it always exits 1 on "no task reference found on the PR".

## R2 — the workflow's own env contract (why R1 is faithful)

```sh
git show origin/main:.github/workflows/pr-task-gate.yml | grep -n -B2 -A4 'PR_OPENED_AT\|EXPECTED_WORKER\|TASK_ID:'
git show origin/main:.github/pr-task-workers.json        # absent => EXPECTED_WORKER="" => no author check
```

## R3 — the ledger claim state each verdict rests on

```sh
for t in dr-w21-s1-both-targets-assert-the-served-commit \
         dr-w21-s5-deploy-selftests-stop-skipping-silently \
         dr-w21-s3-cloud-status-carries-the-commit \
         dr-w23-s4-census-table-stops-hiding \
         dr-w10-s1-verdict-reads-the-deploy-rate; do
  curl -s "https://guerrilla.barkpark.cloud/v1/data/doc/production/task/$t" \
   | python3 -c 'import json,sys;d=json.load(sys.stdin)["result"];print(d["lifecycle_status"],json.dumps(d.get("claim")))'
done
```
Each: lifecycle `open`, `worker: null`, `previous_worker` set, `expired_at` set,
NO `released_at`. That is exactly the gate's open branch (pr-task-gate.sh:363-409).

## R4 — what the one historical RED actually was (not a lease lapse)

```sh
gh run view 31251546546 --log-failed | grep -iE 'pr-task-gate: (FAIL|UNCHECKED|PASS)'
```
=> `FAIL: no task reference found on the PR` — a missing `Task:` trailer, fixed by
a body edit, which the gate's `edited` trigger re-fired green at 11:09-11:10Z.

## R5 — real conflicts today (derive, never quote a charter count)

```sh
for p in 10722 10757 10720 10811 10129; do git fetch origin "pull/$p/head:refs/prtest/$p" -q -f; done
for p in 10722 10757 10720 10811 10129; do
  echo "=== $p"; git merge-tree --write-tree origin/main refs/prtest/$p 2>&1 | grep CONFLICT
done
```

## R6 — conflicts AFTER the proposed merge order (does the order help?)

```sh
base=$(git rev-parse origin/main)
for p in 10722 10757 10720 10811; do
  out=$(git merge-tree --write-tree "$base" refs/prtest/$p); tree=$(echo "$out"|head -1)
  echo "$out" | grep CONFLICT
  base=$(git commit-tree "$tree" -p "$base" -m "merge $p")
done
git merge-tree --write-tree "$base" refs/prtest/10129 2>&1 | grep CONFLICT
```

## R7 — deploy-queue consequence of a burst merge

```sh
git show origin/main:.github/workflows/deploy.yml | sed -n '7,32p'   # on.push.paths + concurrency
git show origin/main:.github/workflows/deploy.yml | sed -n '60,88p'  # changes-job cp/instance regexes
gh pr view <n> --json files --jq '.files[].path'
```

## R8 — 10722 changes deploy.yml's OWN gate scripts; prove they still pass merged

```sh
t=$(git merge-tree --write-tree origin/main refs/prtest/10722|head -1)
c=$(git commit-tree $t -p origin/main -m tmp)
git worktree add -q --detach /tmp/wt10722 $c
(cd /tmp/wt10722 && bash scripts/check-deployyml-filters.sh && bash scripts/check-deploy-smoke.sh)
git worktree remove --force /tmp/wt10722
```

## R9 — which checks actually block

```sh
gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.checks[].context'
```
=> Elixir gate / PR references an active task / Cloud gate / Console gate.
`Re-land advisory (already-landed overlap)` is NOT required — and it is a FALSE
alarm on #10722 and #10720 (R5's merge-tree diffstat shows 415 / 300 net lines).
