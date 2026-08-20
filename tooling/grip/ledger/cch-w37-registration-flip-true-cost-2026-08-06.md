# cch-w37 — the fifth required context: re-derivation recipes

Date: 2026-08-06. Baseline: `origin/main` = `bf97452bb38488d04cfbb596c2528a3f34ad5baf`.
Scope: verifier `registration-flip-true-cost`. Nothing was pressed; no API write was made.

Every row below is a command that re-derives the fact from scratch. Run them from a
clean tmpdir seeded with the extraction recipe in row 0.

## 0. seed the tooling from origin/main (all other rows assume this cwd)

    cd $(mktemp -d) && mkdir -p scripts/lib .github
    for f in scripts/registration-deadlock-sweep.sh scripts/lib/check-runs.sh \
             scripts/required-checks-floor.sh scripts/required-checks-apply.sh \
             scripts/required-checks.test.sh .github/required-checks.json; do
      git -C /Volumes/SATECHI/github/barkpark show origin/main:$f > $f
    done
    chmod +x scripts/*.sh
    jq '.protection.required_status_checks.checks += [{"context":"Required-check spec gate","app_id":15368}]
        | .exclusions |= map(select(.context != "Required-check spec gate"))' \
      .github/required-checks.json > cand.json

## 1. the sweep exits 0 having evaluated ZERO PRs

    RC_REPO_ROOT=$PWD bash scripts/registration-deadlock-sweep.sh --spec cand.json \
      --ref-file .github/required-checks.json; echo rc=$?

Expected 2026-08-06: 8 rows, every one `skip`, `casualties: 0`, `rc=0`. The script
refuses an UNKNOWN mergeability feed (line 189) precisely because a green that means
"I could not see" is the defect this epic attacks — but it has no matching refusal for
an all-skipped sweep. Side (B) is never reached, so the pass carries no information.

## 2. side (B), performed by hand — the evidence the sweep declined to gather

    . scripts/lib/check-runs.sh
    for n in 9827 9600 9530 8465 6086 6057 6028 2907; do
      head=$(gh pr view $n --repo FRIKKern/barkpark --json headRefOid -q .headRefOid)
      rows=$(check_runs_rows FRIKKern/barkpark "$head" "")
      if check_runs_present "$rows" "Required-check spec gate"; then
        echo "#$n PRESENT $(printf '%s\n' "$rows" | grep -F 'Required-check spec gate')"
      else echo "#$n ABSENT"; fi
    done

Expected: PRESENT/success on 9827, 9600, 9530, 8465, 6028; ABSENT on 6086, 6057, 2907 —
exactly the three CONFLICTING/DIRTY heads, whose bases predate the job's creation (#8253)
and which are already stopped by the long-required `Elixir gate`.

## 3. no open PR is stopped by this context today

    for n in 9827 9600 9530; do echo "== $n"; gh pr view $n --repo FRIKKern/barkpark \
      --json statusCheckRollup -q '.statusCheckRollup[]
      | select(.conclusion != "SUCCESS" and .conclusion != "SKIPPED")
      | "\(.name)\t\(.status)\t\(.conclusion)"'; done

Expected: #9827 only `Test (Elixir …) IN_PROGRESS` (transient, not a red — its spec gate
is success); #9600 `Elixir gate FAILURE`; #9530 five already-required failures. The
BLOCKED state on all three is owned by contexts that are ALREADY required.

## 4. the S7 replacement trigger, both halves

    . scripts/lib/check-runs.sh
    check_runs_rows FRIKKern/barkpark bf97452bb38488d04cfbb596c2528a3f34ad5baf "" \
      | grep -i 'spec gate'

Expected: `Required-check spec gate  success  completed` on main HEAD. Half two is row 1 —
which fires, but vacuously; row 2 is what actually discharges it.

## 5. the floor, both modes

    bash scripts/required-checks-floor.sh --reference .github/required-checks.json cand.json; echo rc=$?
    bash scripts/required-checks-floor.sh --acknowledge-growth --reference .github/required-checks.json cand.json; echo rc=$?

Expected: rc=2 with `ADDED  Required-check spec gate	15368`, then rc=0 with
`FLOOR OK: superset held; growth ACKNOWLEDGED (--acknowledge-growth), 5 context(s).`
No loss; growth is real and must be acknowledged by a human.

## 6. the dry-run payload touches nothing

    md5 -q cand.json .github/required-checks.json
    RC_REPO_ROOT=$PWD bash scripts/required-checks-apply.sh --spec cand.json --payload
    md5 -q cand.json .github/required-checks.json
    gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.checks[].context'

Expected: identical md5s before and after; live protection still the four contexts
(`Elixir gate`, `PR references an active task`, `Cloud gate`, `Console gate`).

## 7. the blocking gate is hermetic — it cannot compare spec to live

    grep -n 'EVERYTHING ABOVE THIS LINE IS HERMETIC' scripts/required-checks.test.sh
    grep -n 'branches/.*/protection' scripts/required-checks.test.sh

Expected: the hermetic boundary sits at line 873 and every live-protection read is
BELOW it. Consequence for ordering: the PR that grows the spec to five contexts can
merge before the operator PUT without reddening the blocking gate. Only the ADVISORY
`Required-check spec drift` job disagrees during that window.

## 8. the standing cost this registration makes hard

    RE='(no|No|NO|zero|Zero) branch protection|main is NOT PROTECTED|no CI check in this repo can block a merge'
    git -C /Volumes/SATECHI/github/barkpark grep -nIE "$RE" origin/main -- \
      .claude/workflows .github docs scripts tooling/grip/ledger CLAUDE.md | wc -l

Expected 48 raw claim-shape rows on main, all pinned or fenced (hence the gate is
success on main head). Eight of the matching files live under `tooling/grip/ledger/`,
which the section's own comment calls out as append-only with a non-zero standing cost:
a future ledger row that STATES one of those three phrasings arrives UNPINNED and reds
section 18 — which, once registered, is a hard merge block rather than an advisory red.
That is roughly one hand-read pin per wave, and it is the honest recurring price.
This file was written to avoid all three phrasings; it scores zero on the recipe above.
