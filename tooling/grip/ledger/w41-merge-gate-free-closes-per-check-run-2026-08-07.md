# Wave 41 verify — the six merge-gated rows, checked per CHECK-RUN (2026-08-07)

Written by the wave-41 verifier `merge-gate-free-closes`. No commits, no bp mutations.
Re-derivation recipes only. `origin/main` at time of measurement = `8ae30b34bfc858184f6f1702a2dce57843903987`.

## The mapping the assignment's SHAs actually are

The six SHAs handed to me are **squash-merge commits on `main`**, not PR heads. The criteria say
"green on **its head**", which is the PR head. Both were measured.

| Row | PR | head SHA | merge SHA | ancestor of origin/main |
|---|---|---|---|---|
| cch-w37-s1-invalid-precedence-details-win | #9917 | `bbfddf03cb72d14c56564a2d0eedfbafda4b8fe8` | `d5bbd6c36` | ANCESTOR |
| cch-w37-s2-six-refusals-name-their-authority | #9918 | `3ae56ee169350dd599a8d21c98fd98728dbb232b` | `7b5e54b5d` | ANCESTOR |
| cch-w37-s4-binding-census-add-and-remove | #9920 | `877bcb3edb0d7126e1097f2b579a57a604fbbd51` | `9e39c60c0` | ANCESTOR |
| cch-w37-s6-operator-console-stops-checking-forever | #9922 | `d5fcf226aa04c2be85f40a8ef414820c3579aa7e` | `62b5847ed` | ANCESTOR |
| cch-w39-s4-the-registration-sweep-stops-greening-… | #10007 | `74e6ba6c4d8e858fdb8ace97ce62b7cdb687bdcb` | `64a1f5969` | ANCESTOR |
| cch-w39-s5-the-spec-gate-packet-is-refreshed-… | #10008 | `bb8923c4957a27c777ce4bb7972b9fde30b17233` | `3df1c0830` | ANCESTOR |

Re-derive the mapping:

    gh pr view <N> --json headRefOid,mergeCommit,mergedAt,state
    git merge-base --is-ancestor <mergeSHA> origin/main && echo ANCESTOR || echo NOT

## Per-check-run, never a rollup

    for c in bbfddf03cb72d14c56564a2d0eedfbafda4b8fe8 3ae56ee169350dd599a8d21c98fd98728dbb232b \
             877bcb3edb0d7126e1097f2b579a57a604fbbd51 d5fcf226aa04c2be85f40a8ef414820c3579aa7e \
             74e6ba6c4d8e858fdb8ace97ce62b7cdb687bdcb bb8923c4957a27c777ce4bb7972b9fde30b17233; do
      echo "== $c"
      gh api repos/:owner/:repo/commits/$c/check-runs --paginate \
        --jq '.check_runs[] | "\(.conclusion)\t\(.name)"' | sort
    done

Result: on all six PR heads, ZERO `failure` and ZERO `cancelled`/`timed_out` check-runs.
The gate each criterion names is `success` on its own head:

- #9917 / #9920 / #9922 name **Console gate** → `success` on `bbfddf03c`, `877bcb3ed`, `d5fcf226a`.
- #9918 names **Cloud gate** → `success` on `3ae56ee16`.
- #10007 names **Required-check spec gate** → `success` on `74e6ba6c4`.
- #10008 names only "merged to main" (no gate clause) → merge SHA `3df1c0830` is an ancestor.

## Non-vacuity (the green had to be produced by the right thing)

`Console gate` is documented in its own log to go green when nothing was dispatched
(`::notice title=Console gate: green — nothing ran::`). So each green was checked against the
jobs beneath it:

- `bbfddf03c`, `3ae56ee16`, `877bcb3ed`, `d5fcf226a`: `Console client unit harness` = success and
  `CSSOM parity` = success (NOT skipped) → console work really ran.
- `3ae56ee16`: `Cloud control-plane (test) (27.0, 1.18.1)` = success → the cloud suite really ran.
- `74e6ba6c4`: the spec gate's own job log ends
  `required-checks: 128 passed, 0 failed (hermetic — the API stage was skipped)` —
  the 128 is the slice's own post-change total, so the gate exercised the changed script.

      gh api repos/:owner/:repo/actions/jobs/92748010504/logs | tail -25

## The one RED, and why it does not touch any criterion

`9e39c60c0` (the MERGE commit of #9920) carries `failure  Console gate` and
`failure  CSSOM parity (authored CSS vs browser)`. That is `main` post-merge, not the PR head.
Cause, read from job `92737576278`:

    ##[error]The instrument refused to measure (exit 2) — an ENVIRONMENT fault, not a stylesheet
    defect. app.css was never parsed and NO parity claim is being made about it.

An environment refusal (Chrome bring-up), not a CSS defect — and it self-healed: `d5bbd6c36` and
`3df1c0830`, both later `main` heads, are `success` on both contexts, and `88b30a246` (#10018,
"a browser that never started stops reading as a CSS defect") landed the fix.

    gh api repos/:owner/:repo/actions/jobs/92737576278/logs | grep -iE "error|refused"

## Post-merge check-run absence is real here

`64a1f5969` (#10007) and `eeefcff34` (#9963) have `total_count = 0` check-runs. Absence of a
post-merge run is NOT a failed run; the criteria are head-scoped, so nothing is owed.

    gh api repos/:owner/:repo/commits/64a1f5969/check-runs --jq '.total_count'   # 0

## Server-read criterion state (bp, read at verify time)

| Row | met / total | unmet indices |
|---|---|---|
| cch-w37-s1 | 9/10 | [10] merge gate |
| cch-w37-s2 | 9/10 | [10] merge gate |
| cch-w37-s4 | 11/12 | [12] merge gate |
| cch-w37-s6 | 9/10 | [10] merge gate |
| cch-w39-s5 | 10/11 | [11] merge gate |
| cch-w39-s4 | 8/10 | **[9] PR-body severity** + [10] merge gate |

    bp task get <slug> -o json | python3 -c "import json,sys;d=json.load(sys.stdin);ac=d['doc']['content']['acceptance_criteria'];print([i+1 for i,x in enumerate(ac) if not x.get('met')])"

cch-w39-s4's criterion 9 is ALSO payable — the sentence exists in #10007's body:

    gh pr view 10007 --json body --jq .body | grep -n "HONEST SEVERITY"
    44:**HONEST SEVERITY, unchanged.** `grep -rn registration-deadlock-sweep` over `*.md *.yml *.sh`
    45:finds zero workflow or script callers. No merge reads this exit code — the victim is a human

Charter line 103 governs the stamp: MERGE-GATED criteria are stamped by the LEAD by hand
(`autostamp_merge_gate` only fires on `merge_gate: true`, which this epic's criteria do not carry).
