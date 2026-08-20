# Re-derivation recipe — a main-red watch that loses BOTH ways (cch wave 59, v10-main-red-watch)

Probe only. Nothing here is wired into CI. Every row below was RUN on 2026-08-09
against `FRIKKern/barkpark`; re-run to re-derive.

## R1 — main's required set, from the authority (not a hardcoded copy)

    gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks.contexts'
    # ["Elixir gate","PR references an active task","Cloud gate","Console gate"]

## R2 — the three anchor shas

    for s in f4abf4369 0e9246447 a5260f609; do echo "== $s"; \
      gh api repos/FRIKKern/barkpark/commits/$s/check-runs --paginate \
        --jq '.check_runs[]|select(.name|test("Console gate|Elixir gate|Cloud gate|active task"))|[.name,.status,.conclusion]|@tsv'; done

    == f4abf4369   Elixir/Cloud/Console gate = completed success   (known green)
    == 0e9246447   Cloud gate = completed failure                  (known red, = origin/main tip)
    == a5260f609   (empty)                                         (a 'cancelled' main sha)

`a5260f609` carries **3** check-runs in total (`Break-glass harness` skipped,
`Break-glass watch` success, `go vet + test` success) and **not one** required
context. Re-derive:

    gh api repos/FRIKKern/barkpark/commits/a5260f609/check-runs --paginate --jq '.check_runs|length'   # 3

## R3 — the candidate read (v2), and its verdicts

    REPO=FRIKKern/barkpark; SHA=<sha>
    EXCLUDE='PR references an active task'
    REQ=$(gh api repos/$REPO/branches/main/protection --jq '.required_status_checks.contexts[]' | grep -vxF "$EXCLUDE")
    RUNS=$(gh api repos/$REPO/commits/$SHA/check-runs --paginate --jq '.check_runs[]|[.name,.conclusion]|@tsv')
    printf '%s\n' "$REQ" | while IFS= read -r c; do
      v=$(printf '%s\n' "$RUNS" | awk -F'\t' -v n="$c" '$1==n{print $2}' | tail -1)
      if   [ -z "$v" ];         then echo "  MISSING  $c"
      elif [ "$v" = success ];  then echo "  ok       $c"
      else                           echo "  RED      $c = $v"; fi
    done

    f4abf4369 -> PASS      0e9246447 -> FAIL (RED Cloud gate)
    0239dd4ee -> PASS      a5260f609 -> FAIL (MISSING x3)

It loses both ways: green on two independent known-green shas, red-with-cause on
the red sha, red-as-MISSING on the cancelled sha. A watch that treated
"no failing row found" as a pass would call `a5260f609` green — the vacuous green
this epic abolishes.

## R4 — why the EXCLUDE line is load-bearing (do not delete it)

Without it, the SAME read reds on the KNOWN-GREEN sha:

    f4abf4369:  ok Elixir gate / MISSING 'PR references an active task' / ok Cloud gate / ok Console gate  -> FAIL

`PR references an active task` is PR-scoped and never re-runs post-merge. A watch
over the full required set is a permanent false red. (Independently measured by
dr-bl-w19: absent on 52/52 merge shas.)

## R5 — why the watch must be TIP-scoped, not per-commit

    for s in $(git log --format=%h -25 origin/main); do <R3 read>; done
    # 23 of 25 FAIL; 15 of those fail as MISSING x3

Not a defect — deliberate. `.github/workflows/cloud.yml:28-30`:
"Cancel superseded PR runs, but NEVER cancel main ... Queued main runs collapse
to one." Intermediate commits of a push batch are collapsed away on purpose, so
only main's **tip** is ever expected to carry a verdict.

## R6 — main's actual red, today

    gh run view 31293942162 --log-failed | grep -E 'census_test.exs:[0-9]+|tests, .* failure'
    reader_less_instrument_census_test.exs:657
    reader_less_instrument_census_test.exs:703
    payload_key_set_census_test.exs:1467
    3476 tests, 3 failures

3476, not 3479. And `Sobelow static analysis` is red on main while the required
`Security gate` is **success** — Sobelow is advisory in the rollup, so it blocks
nothing. On PRs #11102-#11106 the only reds are `Cloud gate` + its
`Cloud control-plane (test)` job; Console gate is green on all five.

## OPEN — not proven here

A queued/in-progress required context has `conclusion: null`, which the R3 read
would classify MISSING → a false red on every fresh push. No in-flight run
existed at probe time, so this is UNVERIFIED. Any shipped watch needs a third
WAITING outcome keyed on `.status`, and a test that proves WAITING is neither a
pass nor a scream.
