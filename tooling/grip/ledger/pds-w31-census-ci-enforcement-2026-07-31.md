# PDS w31 — does the Go hetzner census run in a REQUIRED CI gate? (re-derivation recipe)

Verified 2026-07-31 against origin/main `8b2018bc0`.

VERDICT: the census tests RUN (go-tests.yml, `go test -race ./...`, no skip guards)
but the job `go vet + test` is NOT a required status check, so a red does not block a merge.

    # 1. the workflow's PR path filter — `**/*.go` matches internal/cli/*.go
    git show origin/main:.github/workflows/go-tests.yml | sed -n '40,50p'

    # 2. the census/live-fixture tests carry NO skip guard (empty output == no guard)
    git show origin/main:internal/cli/hetzner_res_census_test.go   | grep -n 't\.Skip\|go:build\|Getenv'
    git show origin/main:internal/cli/hetzner_live_fixtures_test.go | grep -n 't\.Skip\|go:build\|Getenv'

    # 3. it really executed on a cli-only PR head (#8647 f1a45a0c8): success, 2m30s
    gh api "repos/FRIKKern/barkpark/commits/f1a45a0c82bb1e312cacf901262f723b131e88ba/check-runs?per_page=100" \
      -q '.check_runs[]|select(.name=="go vet + test")|[.conclusion,.started_at,.completed_at]|@tsv'

    # 4. THE HOLE — only two contexts are required, and `go vet + test` is not one
    gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.contexts'
    #   ["Elixir gate","PR references an active task"]

    # 5. and it is not listed in the spec's exclusions either (so it is unaccounted, not waived)
    python3 -c "import json;print([e['context'] for e in json.load(open('.github/required-checks.json'))['exclusions']])"

    # 6. MEASURED consequence: a merged PR whose go-tests concluded failure
    gh run list --workflow=go-tests.yml --status=failure --limit 15 \
      --json databaseId,headBranch,headSha,conclusion -q '.[]|[.databaseId,.headBranch,.headSha[0:9]]|@tsv'
    #   29565137087  main  d94f2774a   -> PR #3910, merged 2026-07-17
    git merge-base --is-ancestor d94f2774a origin/main && echo on-main

    # 7. the OPEN prior-art row is a DIFFERENT census (the shell ledger instrument), still unwired
    git grep -c 'pds-ledger-census' origin/main -- .github   # exit 1, no hits
