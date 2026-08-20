# Re-derivation recipe — merge-gate classification proof (cch wave 48)

Subject: `docs/ops/merge-gates.md` (canonical-for: merge-gates) tells a reader
that `mix-prod-compile` and `validation-perf` "do not block", while
`.github/required-checks.json` classifies the same two check names
`S3 SUBSUMED: an upstream 'needs' of a required aggregator — the aggregator
already fails when it fails`, and `elixir.yml` proves the aggregator reds.

## 1. The required set (live, four contexts, enforce_admins true, strict false)

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{contexts:.required_status_checks.contexts,strict:.required_status_checks.strict,admins:.enforce_admins.enabled}'

Expect: `{"admins":true,"contexts":["Elixir gate","PR references an active task","Cloud gate","Console gate"],"strict":false}`

## 2. Both jobs ARE needs of the required aggregator

    git show origin/main:.github/workflows/elixir.yml | grep -n 'name: Elixir gate' -A3

Expect `:667  needs: [changes, mix-test, mix-prod-compile, validation-perf, path-escape]`

## 3. The aggregator REDS on either one — mutation, not reading

    d=$(mktemp -d); git show origin/main:.github/workflows/elixir.yml \
      | sed -n '680,758p' | sed 's/^          //' > "$d/decide_body.sh"
    (R_CHANGES=success R_ESCAPE=success R_TEST=success R_PROD=failure R_PERF=success \
     O_COMPILE=true O_TEST=true bash "$d/decide_body.sh"; echo "rc=$?")
    (R_CHANGES=success R_ESCAPE=success R_TEST=success R_PROD=success R_PERF=failure \
     O_COMPILE=true O_TEST=true bash "$d/decide_body.sh"; echo "rc=$?")

Expect `rc=1` from BOTH, each printing
`::error::Elixir gate: at least one upstream job is not in the allow-set`.
The all-success control must print `rc=0` — without it the mutation is vacuous.
(Line range 680-758 is a sha-bound cut; re-locate with `grep -n 'decide "changes'`
if the file moves.)

## 4. The contradicting sentence, and the two the SAME FILE contradicts it with

    git show origin/main:docs/ops/merge-gates.md | sed -n '20,28p;151,157p'

`:154` — "`mix-prod-compile`, `validation-perf` and `format` do not block"
`:22`  — item 3 on mix-prod-compile: "**This is the gate.**"
`:26-28` — item 4 on validation-perf: "Treated as a hard gate … but … nothing
mechanically enforces it."
`format` alone is genuinely advisory (`continue-on-error`, S2 in the spec) — the
sentence is right about one of its three subjects and wrong about two.

    git show origin/main:.github/required-checks.json | grep -n 'S3 SUBSUMED' -B3

## 5. "Elixir gate ABSENT on main shas" is NOT a jam — it is concurrency collapse

    for s in $(git log --format=%H -6 origin/main~1); do printf "%s " "${s:0:9}"; \
      gh api "repos/FRIKKern/barkpark/commits/$s/check-runs?per_page=100" \
      --jq '[.check_runs[]|select(.name=="Elixir gate")|"\(.status)/\(.conclusion)"]|if length==0 then "ABSENT" else .[0] end'; done
    git show origin/main:.github/workflows/elixir.yml | sed -n '70,76p'

`cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}` with a per-ref
concurrency group means queued main pushes COLLAPSE to one run, so intermediate
main shas render no elixir run at all. Absence on a main sha proves nothing
about the gate's health; only a PR head does.

## 6. No charter D-row covers this prose (a fix is not a re-file)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -o 'merge-gates\.md:[0-9]*' | sort -u

Expect exactly `:55 :75 :241 :343` — never `:154`, never items 3/4.
`grep -c 'do not block'` over the charter returns 0.
`docs/ops/merge-gates.md` is already in fence (Wave-2 dispensation, "the gate
ledger's own honesty"), so the slice needs a D-row, not a dispensation.
