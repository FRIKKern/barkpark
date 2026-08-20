# cch-w25 · gate-reach-proof — re-derivation recipes

Verifier lane `gate-reach-proof`, Cloud Console Hardening wave 25, 2026-08-02.
Measured against `origin/main` = `5444aa5e1`. Every row is a command, not a claim.

## R1 — LIVE branch protection carries TWO required contexts, not four

    gh api repos/:owner/:repo/branches/main/protection \
      --jq '{contexts: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled}'
    # => {"contexts":["Elixir gate","PR references an active task"],"enforce_admins":true}

Committed spec disagrees (four):

    git show origin/main:.github/required-checks.json \
      | jq -r '.protection.required_status_checks.checks[].context'
    # => Cloud gate / Console gate / Elixir gate / PR references an active task

The repo's own verifier reds on this:

    bash scripts/required-checks-verify.sh   # exit 1
    #   MISSING from live: Cloud gate (app_id 15368)
    #   MISSING from live: Console gate (app_id 15368)

## R2 — nobody sees it, because the only comparer is advisory

    gh api "repos/:owner/:repo/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
      --jq '.check_runs[]|select(.name|test("Required-check|Cloud gate|Console gate"))|"\(.name) :: \(.conclusion)"'
    # Cloud gate :: success
    # Console gate :: success
    # Required-check spec drift (advisory) :: failure

`.github/workflows/required-checks-drift.yml:115-116` — `name: Required-check
spec drift (advisory)` / `continue-on-error: true`. Failing on every sampled
main head since `#8394` (dcd8c9cef, 2026-07-31) committed the two names.

## R3 — the Elixir gate cannot reach cloud/**

    git show origin/main:.github/workflows/elixir.yml | grep -c cloud     # => 0
    git show origin/main:scripts/elixir-path-escape-check.sh | grep -n "_PATHS='" -A 14
    # ELIXIR_COMPILE_PATHS = api/** design/** + the shim's own 3 files
    # ELIXIR_TEST_ONLY_PATHS = 11 entries, none under cloud/

## R4 — console-harness does NOT dispatch on cloud/lib/**; cloud.yml does

    git show origin/main:scripts/console-path-escape-check.sh | grep -n "CONSOLE_PATHS=" -A 11
    # cloud/priv/static/** + 2 internal goldens + cloud.yml + emit-fence.test.mjs
    # + cloud/test/barkpark_cloud/web/** + required-checks.json + 3 shim files
    git show origin/main:scripts/cloud-path-escape-check.sh | grep -n "CLOUD_PATHS=" -A 7
    # cloud/**  <- covers cloud/lib/**, but "Cloud gate" is not live-required (R1)

## R5 — instrument -> workflow reference census

    for t in overflow-guard breakpoint-sweep modal-oracle font-pin cssom-parity \
             __app.test __css_check smoke.mjs seal-predicate; do
      echo "$t $(git grep -c "$t" origin/main -- .github/ | wc -l)"
    done
    # overflow-guard 1  breakpoint-sweep 1  modal-oracle 0  font-pin 0
    # cssom-parity 1  __app.test 2  __css_check 1  smoke.mjs 3  seal-predicate 1

`modal-oracle.mjs` is referenced by no workflow. `font-pin.mjs` is referenced by
no workflow but is IMPORTED by overflow-guard, breakpoint-sweep and modal-oracle
(`grep -rn font-pin cloud/priv/static/`), so it runs transitively in two of the
three. Running `node __preview__/font-pin.mjs` directly prints nothing and exits
0 — it is a library, and its bare exit 0 is not a pass.

## R6 — baseline green, origin/main, one command per line (no pipes: a pipe eats rc)

    cd cloud/priv/static
    node __app.test.mjs                       # EXIT 0 — pass 776 / fail 0
    node __preview__/smoke.mjs                # EXIT 0 — all 101 scenarios rendered
    node __css_check.mjs                      # EXIT 0 — 870 classes, 95 tokens, 0 errors
    node __preview__/seal-predicate.test.mjs  # EXIT 0 — tests 49 / pass 49
    node __preview__/cssom-parity.mjs         # EXIT 0 — 1284 heads (baseline 1284), 0 MISSES
    node --test __preview__/breakpoint-sweep.test.mjs  # EXIT 0 — pass 51
    node __preview__/breakpoint-sweep.mjs     # EXIT 0 — 25 preludes, 18 boundary widths
    node __preview__/modal-oracle.mjs         # EXIT 0 — 8 states asserted
    OVERFLOW_GUARD_PORT=4471 node __preview__/overflow-guard.mjs   # EXIT 0

`overflow-guard.mjs` on its default port 4199 exits **2** when a foreign
worktree's `serve.mjs` is squatting it ("STALE SERVER on :4199 — served 200836
B, disk holds 200793 B"). That refusal is the instrument working. Override the
port; never kill the neighbour's server.
