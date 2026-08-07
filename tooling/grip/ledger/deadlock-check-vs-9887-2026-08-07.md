# Re-derivation recipes — deadlock-check vs #9887, queue diagnostic (2026-08-07 ~04:35–04:42Z)

Verifier lane `deadlock-check-vs-9887`, deploy-reliability wave 10. No commits made by me; Decide commits this file.

## 0. THE TRAP THAT ALMOST SANK THIS LANE — read first

The primary checkout is **534 commits behind origin/main** and its `.github/required-checks.json`
carries `enforced=false` with **2** contexts. origin/main carries `enforced=true` with **4**.
Running the mandated command as written against the working tree yields a **vacuous EXIT 0**.
Always extract both files from `origin/main` before running.

    git rev-list --count HEAD..origin/main            # -> 534
    git show origin/main:.github/required-checks.json | jq -r '.enforced, (.protection.required_status_checks.checks[].context)'

## 1. The detector ALREADY names the missing context (origin/main version)

    D=$(mktemp -d)
    git show origin/main:scripts/required-checks-verify.sh > $D/rcv.sh
    git show origin/main:.github/required-checks.json     > $D/spec.json
    bash $D/rcv.sh --deadlock --spec $D/spec.json --sha aa19dcca3; echo "EXIT=$?"

Expected (2026-08-07 04:37Z), on stderr, EXIT=3:

    DEADLOCK: the committed spec requires context(s) that head aa19dcca3 never rendered.
             missing: Console gate

## 2. The default sampling is why nothing reported it

    bash $D/rcv.sh --deadlock --spec $D/spec.json; echo "EXIT=$?"
    #   ok     every required context appears in the 36 name(s) rendered on 9abb5f0bb...   EXIT=0

`recent_pr_head()` samples a recently MERGED PR (here #10082). `.github/workflows/required-checks-drift.yml`
deliberately passes no `--sha` in its `--ci` step. So the guard is green while #9887 is bricked.

## 3. Mutation control (proves clause 1 is not shape-passing)

Feed the stale 2-context local spec augmented to the live 4 -> same `missing: Console gate`, EXIT 3:

    jq '.protection.required_status_checks.checks += [{"context":"Cloud gate","app_id":15368},{"context":"Console gate","app_id":15368}]' \
      .github/required-checks.json > $D/live4.json
    bash scripts/required-checks-verify.sh --spec $D/live4.json --sha aa19dcca3; echo "EXIT=$?"

## 4. Queue diagnostic — strict inequality, never a pinned pair

    gh api 'repos/FRIKKern/barkpark/actions/runs' --jq '[.workflow_runs[]|select(.status=="queued")]|length'
    gh api 'repos/FRIKKern/barkpark/actions/runs?status=queued&per_page=100' --paginate --jq '.workflow_runs[]|.id' | wc -l

Three samples 04:36Z / 04:40Z / 04:41Z: FORM_A = 0, 0, 0 ; FORM_B = 6, 6, 6.
Assert `FORM_B > FORM_A`, never `0 vs 6`.

## 5. #9887's Console gate is ABSENT-BECAUSE-ZOMBIED, not rerun-deleted

    gh api repos/FRIKKern/barkpark/actions/runs/31120806862 --jq '{name,status,conclusion,run_attempt,created_at,head_sha}'
    gh api repos/FRIKKern/barkpark/actions/runs/31120806862/jobs --jq '.jobs|length'

-> console-harness, status=queued, conclusion=null, run_attempt=1, created 2026-08-06T16:43:08Z,
head_sha aa19dcca3a5a8f2f6edd014e9369c3a5f5c263c2 ; jobs = 0. Never dispatched.
Oldest queued run in the repo: pr-task-gate, created 2026-07-23T07:38:15Z — 15 days.

## 6. No queued-run query exists in the repo

    git grep -nE 'select\(\.status *== *"queued"\)' origin/main   # rc=1, absent
    git grep -n 'status=queued' origin/main                       # 3 hits, all unrelated (cloud deploy enqueue prose)
