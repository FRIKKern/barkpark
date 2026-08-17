# cch-w73 straggler #11901 verdict — re-derivation recipe (2026-08-17)

PR #11901 "feat(cli): bp cloud site create renders the readable-types menu the plane ships (D863)".
Head at verify time: `a65f4066c4d963e85790c74bf815fb85b1ae982e`. Base: main.

## Claim: OPEN + mergeable, required checks green, 5-file fence intact

Re-derive state, merge status, and file set:

    gh pr view 11901 --json state,mergedAt,mergeable,mergeStateStatus,headRefOid,files

Expect: state=OPEN, mergedAt=null, mergeable=MERGEABLE, mergeStateStatus=UNSTABLE,
files = exactly these 5 (no more):
  cloud/test/barkpark_cloud/payload_key_set_census_test.exs
  internal/cli/cloud_site_cmd.go
  internal/cli/cloud_site_cmd_test.go
  internal/cli/errors.go
  internal/cloudclient/client.go

## Claim: the 4 branch-protection required checks all pass on the head

Required set on main (derive, don't assume):

    gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks --jq '.contexts'
    # => ["Elixir gate","PR references an active task","Cloud gate","Console gate"]

Their conclusions on the head:

    gh api repos/{owner}/{repo}/commits/a65f4066c4d963e85790c74bf815fb85b1ae982e/check-runs \
      --paginate --jq '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|{name,conclusion}'
    # all four => "success"

## Note: UNSTABLE = non-required reds present, do NOT block merge

Non-required failing checks on this head (informational, not in the required set):
gofmt drift ceiling (blocking), gofmt -l (advisory), Doc budgets + anchors,
Required-check spec gate, Required-check spec drift (advisory) — none touch the 5 fenced
files; none are branch-protection contexts. At verify time a few matrix jobs were still
queued/in_progress (doctor-matrix, deploy-reliability mutation matrix, bin/barkpark
up/stop selftest) — also non-required.
