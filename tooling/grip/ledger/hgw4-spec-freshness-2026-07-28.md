# Re-derivation recipes — hgw4 spec-freshness (2026-07-28, pre-PUT)

Run every one of these IMMEDIATELY before the protection PUT. All are point-in-time.

## R1 — the required set is still exactly two names at app_id 15368

    scripts/required-checks-generate.sh \
      --sha cff46a985a9db9aeb51c2431ff7dccde5aa5aaf2 \
      --sha 26b85be517bb9ea65a1ebaf6f312c9213f4cd4ab \
      --sha 22f62b2a831012e47449e0a742eb54fc9901bd7f \
      --main-window 4 \
    | jq -c '.protection.required_status_checks.checks'
    jq -c '.protection.required_status_checks.checks' .github/required-checks.json

Both must print:
`[{"context":"Elixir gate","app_id":15368},{"context":"PR references an active task","app_id":15368}]`

## R2 — the sampled shas all postdate the aggregator shim

    gh api repos/FRIKKern/barkpark/commits/2c7f864eb --jq .commit.committer.date   # 2026-07-27T22:44:48Z
    for s in <sha>...; do gh api repos/FRIKKern/barkpark/commits/$s --jq .commit.committer.date; done

## R3 — the silent stale-sha downgrade (MUST reproduce as a tripwire)

    scripts/required-checks-generate.sh --sha cff46a985a9db9aeb51c2431ff7dccde5aa5aaf2 \
      --sha 4f80c43303ee16e390ef9b2ad8122f88d92c4fe9 --main-window 4 \
      | jq -c '.protection.required_status_checks.checks'

Emits ONE name, exit 0, empty stderr. The generator has no floor flag
(`grep -n '^\s*--[a-z-]*)' scripts/required-checks-generate.sh` — nine flags, none of them
`--expect`/`--min-checks`). The floor must be an EXTERNAL assertion:

    test "$(jq '.protection.required_status_checks.checks|length' <gen>)" -eq 2

## R4 — main-green reading (three-state honest rule)

    SHA=$(gh api "repos/FRIKKern/barkpark/actions/runs?branch=main&event=push&per_page=100" \
      --jq '[.workflow_runs[]|select(.name=="elixir" and .status=="completed" and .conclusion!="cancelled" and .conclusion!="skipped")][0].head_sha')
    gh api "repos/FRIKKern/barkpark/commits/$SHA/check-runs?per_page=100" --paginate \
      --jq '.check_runs[]|select(.name=="Elixir gate")|.conclusion'

## R5 — fence scan over all open PRs

    for n in $(gh pr list --state open --limit 40 --json number -q '.[].number'); do
      gh pr view $n --json files -q '.files[].path' \
        | grep -E 'elixir\.yml|pr-task-gate|required-checks|bp-loop-ledger|honest-gates' \
        | sed "s/^/PR$n /"
    done

## R6 — Vercel legacy statuses cannot enter the spec

    gh api repos/FRIKKern/barkpark/commits/<head>/status --jq '.statuses[]|"\(.context) \(.state)"'
    # => "Vercel – barkpark failure" / "Vercel – demo failure" — statuses feed only.
    grep -n 'SOURCE_FEED=' scripts/required-checks-generate.sh        # check_runs (line 77)
    grep -ic vercel .github/required-checks.json                       # 0
