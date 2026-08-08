# Re-derivation recipes — wave 23 merge-gate clearing proof (2026-08-08)

Verifier: merge-gate-clearing-proof. Read-only except this file.

## The gate's verdict on #10720 / #10722

    gh pr checks 10720 | head -3
    gh pr checks 10722 | head -3
    # both: "PR references an active task  fail" + "Re-land advisory  fail"; every other required context passes.

    gh run view --job 93088571339 --log | grep '##\[error\]'
    # ##[error]pr-task-gate: FAIL: no task reference found on the PR (add a 'Task: <doc_id>' line to the PR description)

## Why the slice's OWN task id will NOT clear it yet

    curl -sS https://guerrilla.barkpark.cloud/v1/data/doc/production/task/dr-w21-s3-cloud-status-carries-the-commit \
      | python3 -c "import json,sys;d=json.load(sys.stdin)['result'];print(d['lifecycle_status'],d['claim']['worker'],d['claim']['expired_at'])"
    # open None 2026-08-08T05:05:00.630290Z   (PR opened 09:52:48Z → lapsed BEFORE open)

    TASK_ID=dr-w21-s3-cloud-status-carries-the-commit PR_OPENED_AT=2026-08-08T09:52:48Z bash scripts/pr-task-gate.sh; echo rc=$?
    # FAIL ... had ALREADY lapsed 17267s before this PR was opened ... rc=1

## The acceptance arm, proven live

    TASK_ID=dr-w22-s2-the-box-remembers PR_OPENED_AT=2026-08-08T09:52:48Z bash scripts/pr-task-gate.sh; echo rc=$?
    # PASS: ... in_progress, claimed by 'epic-builder-the-box-stops-reporting-a-constant-obser'  rc=0

## Trailer grammar (bare id — NO backticks; reland-check.yml has no backtick arm)

    PR_BODY="$(printf 'Task: dr-w21-s3-cloud-status-carries-the-commit\n')" bash scripts/pr-task-gate.sh --extract-task-id

## Live required set (4, enforce_admins true)

    gh api repos/FRIKKern/barkpark/branches/main/protection -q '(.required_status_checks.checks[]|.context), .enforce_admins.enabled'

## #10129 — its gates DID run and were green

    gh pr view 10129 --json statusCheckRollup -q '[.statusCheckRollup[]|.conclusion]|group_by(.)|map({(.[0]):length})'
    git merge-tree --write-tree --name-only origin/main 514ff5c6f664a7b1af6dfc7342eafafc0700d8a6
    # 5 content conflicts incl. internal/cli/cloud_status_cmd.go — the same file #10720 edits.
