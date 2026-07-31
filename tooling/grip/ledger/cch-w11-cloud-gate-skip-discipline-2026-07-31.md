# cch-w11 — Cloud gate vs Console gate: skip discipline, RUN not read (2026-07-31)

Question: does `cloud.yml`'s `cloud-gate` decide() carry Console gate's gate-value
discipline, i.e. does a skip green a required context?

Answer: NO ASYMMETRY. The three decide() bodies (`elixir.yml`, `cloud.yml`,
`console-harness.yml`) are BYTE-IDENTICAL, and both gates FAIL on every
illegitimate skip. `Cloud gate` cannot be greened by a skip.

## Re-derivation

    # 1. pull both aggregators from origin/main (never the worktree)
    git show origin/main:.github/workflows/cloud.yml           > /tmp/cloud.yml
    git show origin/main:.github/workflows/console-harness.yml > /tmp/console.yml
    git show origin/main:.github/workflows/elixir.yml          > /tmp/elixir.yml

    # 2. extract each decide() and prove byte-identity (all 32 lines)
    for f in cloud console elixir; do
      awk '/^          decide\(\) \{/,/^          \}/' /tmp/$f.yml > /tmp/${f}_decide.sh
    done
    diff /tmp/cloud_decide.sh /tmp/console_decide.sh   # exit 0
    diff /tmp/cloud_decide.sh /tmp/elixir_decide.sh    # exit 0

    # 3. RUN the full synthetic matrix (6 results x 4 gate values = 24 cells)
    #    harness sets bad=0, sources the function, calls decide, prints bad
    #    results: success skipped failure cancelled '' bogus
    #    gates:   true false '' NEVER
    #    -> only PASS cells: any success (4), and skipped+gate=false (1). 5/24.
    #    -> skipped+gate=true, skipped+gate='', skipped+gate=NEVER all set bad=1.

    # 4. structural checks
    grep -n "continue-on-error" /tmp/cloud.yml /tmp/console.yml   # comments only
    git grep -n "name: Cloud gate" origin/main -- .github/workflows/     # 1 hit
    git grep -n "name: Console gate" origin/main -- .github/workflows/   # 1 hit
    gh api "repos/:owner/:repo/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
      --jq '.check_runs[].name'   # both gate names render on main's head

## Anchors (origin/main @ e34031104)

- cloud.yml:308-310  `name: Cloud gate` / `if: always()` / needs [changes, compile, test, path-escape]
- cloud.yml:332-363  decide()  ; cloud.yml:342 the illegitimate-skip FAIL line
- cloud.yml:367-370  four decide calls; gates NEVER, NEVER, $O_CLOUD, $O_CLOUD
- console-harness.yml:368-370 name/if/needs; :392-423 decide(); :402 the FAIL line; :428-431 calls
- cloud.yml:183, :225 both matrixed jobs gated on `needs.changes.outputs.cloud`
- console-harness.yml:209, :285 both gated on `needs.changes.outputs.console`

## Reachability note (the case with zero live executions)

`skipped` + gate=`'true'` is defended but arguably UNREACHABLE in these graphs:
`compile`/`test`/`console-unit`/`cssom-parity` each `needs: changes` only, so they
skip only when `changes` fails or is cancelled — and then the dispatcher's outputs
are EMPTY, so the gate value is `''`, not `'true'`. The REACHABLE illegitimate
skip is `skipped` + gate=`''`, and both aggregators set bad=1 on it (the `''`
gate falls through the `[ "$gate" = "false" ]` test). Defence is correct for both
the reachable and the unreachable case.
