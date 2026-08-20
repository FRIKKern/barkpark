# Re-derivation: does "Elixir gate" render on an internal/cli-only PR?

Question (PDS wave 29, V12): does the required context `Elixir gate` render on a PR
that touches only `internal/cli/**`, or does it report "is expected" and deadlock?
And is the Go suite a required context?

## 1. The live required set (2 contexts, enforce_admins on)

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{strict:.required_status_checks.strict, enforce_admins:.enforce_admins.enabled, contexts:.required_status_checks.contexts}'

Observed 2026-07-31: `{"contexts":["Elixir gate","PR references an active task"],"enforce_admins":true,"strict":false}`

No repository rulesets add to it:

    gh api repos/FRIKKern/barkpark/rulesets --jq '.[] | "\(.id) \(.name) \(.target) \(.enforcement)"'

Observed: empty.

## 2. It renders — measured on three merged internal/cli-only PRs

    for pr in 8520 8518 8413; do
      sha=$(gh pr view $pr --json headRefOid --jq .headRefOid)
      echo "== PR $pr $sha"
      gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs" --paginate \
        --jq '.check_runs[] | "\(.name) :: \(.conclusion)"' | sort
    done

`Elixir gate :: success` on all three, with every Elixir leaf `skipped`
(`Test (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }}) :: skipped`).
Mechanism: `.github/workflows/elixir.yml` has `on: pull_request:` with NO
workflow-level `paths:` key; the always-running `changes` dispatcher gates the
expensive jobs at JOB level, and `elixir-gate` is `if: always()`.

NOTE on method: `gh api .../check-runs` without `--paginate` returns only 30 rows
and silently truncates — that truncation made `go vet + test` LOOK absent on 8520.
Always `--paginate`.

## 3. The Go suite is NOT required

`go vet + test` (workflow `go-tests.yml`, which IS workflow-level paths-filtered on
`**/*.go`) rendered `success` on 8520/8518/8413 but is absent from the required
contexts above. `scripts/bp-merge.sh` polls only required contexts. So an
`internal/cli`-only PR merges over a red Go suite; wave 29 must run `go test ./...`
itself.

## 4. Committed spec vs live protection: DRIFT (advisory red)

    git show origin/main:.github/required-checks.json | jq -r '.protection.required_status_checks.checks[].context'

Emits 4: `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task`.
Live carries 2 — hence `Required-check spec drift (advisory) :: failure` on PR 8520
(it was `success` on the older PR 8413). Advisory, so it blocks nothing. If the spec
is applied mid-wave, `Cloud gate` and `Console gate` become required — both already
rendered `success` on 8520 and 8518, so an internal/cli-only PR still cannot deadlock.
