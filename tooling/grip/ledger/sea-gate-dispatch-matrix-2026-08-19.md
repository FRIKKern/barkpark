# sibling-ETS-atomicity — CI dispatch matrix, re-derived at build time (2026-08-19)

Anchor: origin/main = d99cb95d0fd9e9640ccffebf34bc9effe4ffcf86.
Local `scripts/` and `.github/workflows/` proven byte-identical to origin/main first
(`git diff --stat origin/main -- scripts/ .github/workflows/` → empty), so the local
run IS the origin/main run.

## The four REQUIRED contexts (live, not the spec file)

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{strict:.required_status_checks.strict, checks:[.required_status_checks.checks[]|.context], enforce_admins:.enforce_admins.enabled}'
    # {"checks":["Elixir gate","PR references an active task","Cloud gate","Console gate"],"enforce_admins":true,"strict":false}

## The matrix (the dispatchers call these EXACT commands — same source of truth)

    for p in <fence paths>; do
      printf '%s\n' "$p" | bash scripts/cloud-path-escape-check.sh   --match cloud
      printf '%s\n' "$p" | bash scripts/console-path-escape-check.sh --match console
      printf '%s\n' "$p" | bash scripts/elixir-path-escape-check.sh  --match compile
      printf '%s\n' "$p" | bash scripts/elixir-path-escape-check.sh  --match test
    done

NOTE: `elixir-path-escape-check.sh --match elixir` is INVALID — exits 2,
`unknown path set 'elixir' (want compile|test)`. The brief's MUST-RUN line carried it.

| path | cloud | console | elx-compile | elx-test |
|---|---|---|---|---|
| cloud/lib/barkpark_cloud/accounts/two_factor_rate_limiter.ex | true | **true** | false | false |
| cloud/lib/barkpark_cloud/device_auth/rate_limiter.ex | true | **true** | false | false |
| cloud/test/barkpark_cloud/device_auth_test.exs | true | **false** | false | false |
| cloud/test/barkpark_cloud/accounts/two_factor_rate_limiter_test.exs | true | **false** | false | false |
| api/lib/barkpark_web/controllers/tasks_controller.ex | false | false | true | true |
| api/lib/barkpark_web/request_stats.ex | false | false | true | true |
| api/test/barkpark_web/controllers/graph_controller_test.exs | false | false | true | true |

## Confirmed: CONSOLE_PATHS still contains `cloud/lib/**`

    bash scripts/console-path-escape-check.sh --print-set console   # 14th line: cloud/lib/**

and it is DELIBERATE, not drift (scripts/console-path-escape-check.sh:149-160, wave 30 S1):
"`cloud/lib/**` IS THE WHOLE DIRECTORY, AND IT HAS TO BE … The cost is real and
accepted — the console harness now runs on any control-plane edit."
`cloud/test/**` is NOT in the set; only `cloud/test/barkpark_cloud/web/**` is.

## Empirical confirmation on real pull_request heads (not merge commits)

Merge commits to main are useless here: the dispatcher prints "event … is not a
pull_request — the console path set is true" and runs EVERYTHING. Measure on PR heads.

api-only PR #12579 head 3d6c8b7530f492d41916bee3f177e4abfb6ba949:
  console-harness: Billing tier floor / Console client unit / CSSOM parity / Overflow guard = ALL skipped; Console gate = success
  cloud.yml:       Cloud control-plane (test) + (compile + format) = skipped; Cloud gate = success
  elixir.yml:      Test / Prod compile / Validation perf = success; Elixir gate = success

cloud-only PR head 6e6ce52ec970ec9484d49a60bfeff83a310665cf (cloud/lib/…/azure/pricing.ex + cloud/test/…):
  console-harness: Billing tier floor / Overflow guard / Console client unit / CSSOM parity = ALL **success (ran)**
  cloud.yml:       compile + test = success
  elixir.yml:      Format / Test / Prod compile / Validation perf = ALL skipped; Elixir gate = success

    hs=$(gh pr view <n> --json headRefOid --jq .headRefOid)
    rid=$(gh api "repos/FRIKKern/barkpark/actions/workflows/console-harness.yml/runs?head_sha=$hs&event=pull_request&per_page=1" --jq '.workflow_runs[0].id')
    gh api "repos/FRIKKern/barkpark/actions/runs/$rid/jobs?per_page=50" --jq '.jobs[]|"\(.conclusion)\t\(.name)"'

## Cost, measured

Console gate needs [changes, console-unit, cssom-parity, tier-floor-render,
overflow-guard, path-escape]. FOUR are `if: needs.changes.outputs.console == 'true'`;
THREE of those drive real Chrome (`CHROME: /usr/bin/google-chrome` in cssom-parity,
tier-floor-render, overflow-guard). console-unit is browserless.
Observed cloud-only PR leaf times: 0/1/2/0 min. Console harness wall-clock on recent
main heads: 3-6 min (one 23 min outlier at cd75286b7).

## Stability of this matrix

No open PR edits any of cloud-/console-/elixir-path-escape-check.sh or
.github/required-checks.json (swept all 60 open PRs). The two open PRs touching
console-harness.yml are #10155 (adds a job `needs: [console-gate]` DOWNSTREAM of the
aggregator — no new required leaf) and #10085 (CONFLICTING, so its workflows never run).
The gate-wiring wave has NOT moved the dispatch inputs.

## All three ratchets green on this tree (pre-edit baseline)

    bash scripts/cloud-path-escape-check.sh   --check   # OK: every repo-root read from cloud/lib + cloud/test is dispatched on.
    bash scripts/console-path-escape-check.sh --check   # OK: every repo-root read from cloud/priv/static is dispatched on.
    bash scripts/elixir-path-escape-check.sh  --check   # OK: every repo-root read from api/lib + api/test is dispatched on.
