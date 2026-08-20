# PR board re-take — deploy-reliability wave 10 verify (2026-08-07 ~04:46Z)

Re-derivation recipes. Repo slug is `FRIKKern/barkpark` (`repos/barkpark/barkpark` 404s).

## Required contexts on main (exactly four)

    gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks.contexts'
    # ["Elixir gate","PR references an active task","Cloud gate","Console gate"]

## Full board

    gh pr list --state open --limit 40 --json number,title,mergeable,mergeStateStatus,headRefOid \
      --jq '.[]|[.number,.mergeable,.mergeStateStatus,(.title[0:50])]|@tsv'

## Per-PR required-context matrix

    for pr in 9887 10054 10083 10084 10085 10086 10087 10088 10014 10015 10019 9976 10069; do
      sha=$(gh pr view $pr --json headRefOid --jq .headRefOid); echo "== #$pr $sha"
      gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs?per_page=100" \
        --jq '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|[.name,.status,.conclusion]|@tsv' | sort -u
    done

## #9887's Console gate is ABSENT because the run never dispatched

    gh api repos/FRIKKern/barkpark/actions/runs/31120806862 \
      --jq '[.status,.conclusion,.run_attempt,.created_at,.name,.head_sha]|@tsv'
    # queued <null> 1 2026-08-06T16:43:08Z console-harness aa19dcca…
    gh api repos/FRIKKern/barkpark/actions/runs/31120806862/jobs --jq '.jobs|length'   # 0

Not D102 re-run deletion: run_attempt=1. A re-run DID happen on that head, but for the
`cloud` workflow (run 31120806865, run_attempt=2, success):

    gh api "repos/FRIKKern/barkpark/actions/runs?head_sha=aa19dcca3a5a8f2f6edd014e9369c3a5f5c263c2&per_page=100" \
      --jq '.workflow_runs[]|[.name,.status,.conclusion,.run_attempt,.created_at,.id]|@tsv'

## Queue diagnostic undercount (naive vs paginated)

    gh api "repos/FRIKKern/barkpark/actions/runs" --jq '[.workflow_runs[]|select(.status=="queued")]|length'      # 0
    gh api "repos/FRIKKern/barkpark/actions/runs?status=queued&per_page=100" --paginate --jq '.workflow_runs[].id' | sort -u | wc -l  # 6

Oldest queued run: 29988818645, pr-task-gate, created 2026-07-23T07:38:15Z, run_attempt=9.

## Where `Console gate` is produced

    git grep -n "name: Console gate" origin/main -- .github/workflows/console-harness.yml
    # origin/main:.github/workflows/console-harness.yml:737

Job id `console-gate` (line 708), `needs: [changes, console-unit, cssom-parity,
tier-floor-render, overflow-guard, path-escape]` (line 739). A literal string, NOT
templated. The survey's `grep -rn 'Console gate' .github/` found nothing because the
primary checkout is 534 commits BEHIND origin/main and its copy of the file is 136
lines vs origin/main's 926:

    git rev-list --count HEAD..origin/main          # 534
    wc -l .github/workflows/console-harness.yml     # 136
    git show origin/main:.github/workflows/console-harness.yml | wc -l   # 926

## Task-gate red on #9976 / #10069 — one shared root cause

    bp task get task-fb4fb869490b4213 -o json | python3 -c "import sys,json;print(json.load(sys.stdin)['doc']['claim'])"
    # epoch 23, previous_worker 'epic-cycle-decide', expired_at 2026-08-07T00:47:00.246986Z

Gate logs (job ids from the check-run html_url):

    gh api repos/FRIKKern/barkpark/actions/jobs/92750486509/logs | grep 'pr-task-gate: FAIL'   # #9976
    gh api repos/FRIKKern/barkpark/actions/jobs/92766191140/logs | grep 'pr-task-gate: FAIL'   # #10069

`open_lead` = claim.expired_at − PR.created_at (scripts/pr-task-gate.sh:214-216, 292-293).
9976 created 01:19:09Z → −1929s (log says 1928). 10069 created 03:34:46Z → −10066s (log
says 10065). Both arithmetic-consistent with epoch 23's expired_at.
