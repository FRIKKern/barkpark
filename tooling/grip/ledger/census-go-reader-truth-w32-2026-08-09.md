# Census → Go reader: which keys reach a rendered CLI surface (w32 v5)

Settles the survey contradiction ("zero readers" vs "37 hits"). Both were right about
DIFFERENT TREES: the primary checkout is 799 commits behind origin/main and does not
contain `internal/cli/cloud_deploy_census_cmd.go` at all.

## Re-derive the tree divergence

    cd /Volumes/SATECHI/github/barkpark
    git rev-parse HEAD; git rev-parse origin/main
    git rev-list --count HEAD..origin/main            # 799
    git ls-tree -r --name-only origin/main internal/cli/ | grep -i census
    ls internal/cli/ | grep -i census                 # absent in worktree
    grep -rn "deploy-ledger" internal/ | wc -l        # 0 HERE, 4 files on origin/main
    git grep -c "deploy-ledger" origin/main -- internal/

## Materialise origin/main and run the reader (worktree is unusable for this)

    S=/tmp/om && mkdir -p $S && git archive origin/main | tar -x -C $S
    cd $S && export CC=clang
    go build ./... && go vet ./internal/cli/... && go test ./internal/cli/... -run DeployCensus -v
    go build -o /tmp/bp-om ./cmd/barkpark
    /tmp/bp-om cloud deployments -o table          # human surface
    /tmp/bp-om cloud deployments -o json           # wire envelope

NOTE: the INSTALLED `bp` (commit 0789ab90a) rejects `cloud deployments` as an
unknown command. Any run of this recipe with `bp` instead of `/tmp/bp-om` measures
the stale binary, not the shipped reader.

## Key accounting (22 top-level keys emitted)

    /tmp/bp-om cloud deployments -o json > /tmp/c.json
    python3 -c "import json;d=json.load(open('/tmp/c.json'));print(sorted(d))"
    python3 -c "import json;d=json.load(open('/tmp/c.json'));print(sorted(d['classes'][0]))"
    cd $S && sed -n '1960,2300p' internal/cloudclient/client.go | grep -o 'json:\"[a-z_]*\"' | sort -u
    grep -rni "agency" internal/            # ZERO hits — emitted on 20/20 class rows, read by nothing

DROPPED (emitted, no decoder, no renderer): agency, coalesced_attempts,
completeness, truncated, total_sites.
RENDERED VIA RAW RE-PARSE (not the typed struct): boundaries —
`deployCensusBoundaries(census.Raw)` at cloud_deploy_census_cmd.go:374,666.

## Live numbers this recipe reproduces (7d window, team guerrilla)

    deferral_wait: covered 3321 / pending 8 / unreadable 0 of 3329   (99.76%, NOT 100%)
    delivery p50 6m6s · p95 58h42m19s (p95 does NOT refuse; MAX refuses)
    failure_rate REFUSED — window straddles the 2026-08-05T21:13:50Z settle boundary
    top failing class DOC_ID_EMPTY 722 (BOX_UNREACHABLE is 38, ranked 10th)
