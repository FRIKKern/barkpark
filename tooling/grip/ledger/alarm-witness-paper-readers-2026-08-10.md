# Re-derivation recipes — paper-readers alarm witness (wave 34)

Every row is a command that re-derives the fact from scratch. No stored values.
All derived over the GitHub REST API because the host's root disk was ENOSPC
(every `Bash` call failed: `ENOSPC: no space left on device` writing the tool's
own output file), so `gh`, `bp` and `git` were unavailable this turn.

## Did the widened guard ever run?

    gh api 'repos/FRIKKern/barkpark/actions/workflows/paper-readers.yml/runs?per_page=8' \
      -q '.workflow_runs[]|[.run_number,.id,.conclusion,.created_at,.head_sha]|@tsv'

Compare the newest `created_at` against the guard's merge instant:

    gh api repos/FRIKKern/barkpark/commits/694366b62e275f0ef779b426dd8f6fc16a446ba9 \
      -q '.commit.committer.date'

If the merge instant is LATER than the newest run, the guard has zero witnesses.

## Which guard was in the tree for a given run?

    gh api repos/FRIKKern/barkpark/actions/runs/<run_id> -q .head_sha
    gh api repos/FRIKKern/barkpark/contents/.github/workflows/paper-readers.yml?ref=<sha> \
      -q '.content' | base64 -d | grep -n 'if:'

## Did the alert step reach the runner?

    gh api repos/FRIKKern/barkpark/actions/runs/<run_id>/jobs \
      -q '.jobs[].steps[]|[.number,.name,.conclusion,.started_at,.completed_at]|@tsv'

`Report failure to a human` = `skipped` means the alarm did not fire.

## Is the cancellation a 30-minute job timeout?

    gh api repos/FRIKKern/barkpark/contents/.github/workflows/paper-readers.yml?ref=<sha> \
      -q .content | base64 -d | grep -n 'timeout-minutes'

then subtract the audit step's `started_at` from its `completed_at` in the jobs
output above. ~29m45s under a `timeout-minutes: 30` job is the timeout.

## Is the alarm routed or unrouted for this key?

    gh issue view 5658 --repo FRIKKern/barkpark \
      --json state,assignees,comments \
      -q '"\(.state) assignees=\(.assignees|length) comments=\(.comments|length)"'
    gh api repos/FRIKKern/barkpark/issues/5658/comments -q '.[]|[.created_at,.user.login]|@tsv'

An OPEN issue with this title forces `file-ci-failure-issue.sh` down its comment
branch, which sets no assignee and no mention:

    gh api repos/FRIKKern/barkpark/contents/scripts/file-ci-failure-issue.sh?ref=main \
      -q .content | base64 -d | sed -n '/if \[ -n "\$existing" \]/,/exit 0 ;;/p'

## Four widened, or five?

    gh api repos/FRIKKern/barkpark/commits/694366b62e275f0ef779b426dd8f6fc16a446ba9 \
      -q '.files[]|[.filename,.additions,.deletions]|@tsv'
    for f in codebase-intel crown-reconcile deploy paper-readers renew-mail-cert; do
      gh api "repos/FRIKKern/barkpark/contents/.github/workflows/$f.yml?ref=main" \
        -q .content | base64 -d | grep -n 'failure()' | sed "s|^|$f:|"
    done
