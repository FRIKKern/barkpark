# Re-derivation recipe — census reader live reachability (wave 22 verify, 2026-08-08)

Verifier assignment `census-reader-live`. Every row below is a command that re-derives
the fact from scratch. As-of instant for all live readings: **2026-08-08T08:29:51Z**
(window pinned client-side by the verb: 2026-08-01T08:29:51Z → 2026-08-08T08:29:51Z).

## 0. The installed `bp` cannot run this proof

The binary at `/Users/pelle/.local/bin/bp` was built from LOCAL main, which is
**659 commits behind origin/main** and does not contain
`internal/cli/cloud_deploy_census_cmd.go` at all.

    bp cloud deployments -o table
    # bp: unknown cloud command "deployments" (run `bp cloud -h` for usage)   EXIT=2

Build a fresh one from origin/main WITHOUT touching the checkout:

    D=$(mktemp -d) && git archive origin/main | tar -x -C "$D" \
      && (cd "$D" && CC=/usr/bin/clang CGO_ENABLED=0 go build -o ./bpfresh ./cmd/barkpark)
    "$D"/bpfresh cloud deployments -o table

(`CGO_ENABLED=0` is required: the `cc` alias shadows the compiler and cgo fails
with `error: unknown option '-E'`.)

## 1. Live HTTP status of both census routes

    TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    F=2026-08-01T08:30:30Z; T=2026-08-08T08:30:30Z
    curl -s -o /dev/null -w "%{http_code}\n" "https://api.barkpark.cloud/v1/deploy-ledger/census?from=$F&to=$T" -H "Authorization: Bearer $TOKEN"   # 200
    curl -s -o /dev/null -w "%{http_code}\n" "https://api.barkpark.cloud/v1/deploy-ledger/census?from=$F&to=$T"                                      # 401
    curl -s        -w "  HTTP %{http_code}\n" "https://api.barkpark.cloud/v1/operator/deploy-ledger/census?from=$F&to=$T" -H "Authorization: Bearer $TOKEN"
    # {"error":"forbidden","scope":"platform","required":"platform_operator"}  HTTP 403

The 403 on the operator route with the SAME credential that gets 200 on the team
route is the non-admin reachability proof: this token is not a platform operator.

## 2. `-o json` is a verbatim server passthrough

    git show origin/main:internal/cli/cloud_deploy_census_cmd.go | sed -n '/func emitDeployCensusRaw/,/^}/p'
    # case "json": fmt.Fprintln(out.stdout, strings.TrimRight(string(census.Raw), "\n"))

Key-set equality against the raw curl body:

    python3 -c "import json;a=json.load(open('/tmp/census.json'));b=json.load(open('/tmp/t1.json'));print(sorted(a)==sorted(b))"   # True

## 3. `coalesced_attempts` reaches a human ONLY through `-o json`

    git grep -n "oalesced" origin/main -- internal/cloudclient   # (no match: no struct field)
    "$D"/bpfresh cloud deployments -o table | grep -c "coalesced_attempts"   # 0

Its live value is `{"value":null,"refused":true,"since":"2026-08-07T10:02:23Z"}`.

## 4. The delivery reader is BUILT and the server sends nothing

    "$D"/bpfresh cloud deployments -o table | grep -A1 "^delivery"
    # delivery — how long content waited to reach the web
    #   NOT MEASURED — this control plane sends no delivery census. ...
    python3 -c "import json;print('delivery' in json.load(open('/tmp/census.json')))"   # False

The fix is BUILT AND UNPUSHED:

    git log --oneline -1 e0e1f9db1
    # e0e1f9db1 fix(cloud): the TEAM census route carries a team-scoped delivery node
    git ls-remote --heads origin | grep -c dr-w21   # 0
    gh pr list --search dr-w21 --state all --json number   # []

## 5. `bp cloud` has NO manifest — dispatch is a hard-coded Go switch

    bp capabilities -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(sorted({r[0] for r in d['commands']}))"
    # 150 rows, 26 verbs, 'cloud' NOT among them (this manifest is the CONTENT server)
    git show origin/main:internal/cli/hetzner_cmd.go | sed -n '/^func runCloud(/,/^}/p'
