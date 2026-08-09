# dr-w26 — ledger stale-open re-derivation recipes (2026-08-09)

Ground: `origin/main` @ `0239dd4ee662dd30c4d8da0c6b9a149638224b1d`. Every row below is a
command that re-derives a claim from scratch. Nothing here is inherited.

## R1 — the open-children gauge over-counts by 2 (draft twins)

    bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys;d=json.load(sys.stdin);ch=d['children'];o=[x for x in ch if x['lifecycle_status']=='open'];print(len(o), [x['doc_id'] for x in o if x['doc_id'].startswith('drafts.')])"

Prints `71 ['drafts.dr-w24-s3-custom-host-cannot-steal-a-url', 'drafts.dr-w24-s5-the-rulings-become-readable']`.
Both draft ids have a PUBLISHED twin also in `children`. Distinct open tasks = **69**.

## R2 — the flagship "close me first" row is NOT closable as written

    bp task get dr-w24-bl-emit-commit-distance-on-the-fleet-row -o json | python3 -m json.tool | grep -A2 criterion
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '9431,9433p'   # C1 SATISFIED
    git show origin/main:internal/cloudclient/client.go | sed -n '166,168p'             # C2 half: tags declared
    git grep -n 'Go.struct_tags(src, "Barkpark")' origin/main -- cloud/test              # C2 pin: ABSENT (rc=1)
    git grep -rn 'schema_allowlist' origin/main -- cloud/                                # C3: ABSENT (rc=1)

C3 names `@schema_allowlist` rows that exist nowhere on main — the Side-C schema arm
(dr-w24-s4) never landed. The row is 1/3, not 3/3.

## R3 — N-1/N does not mean "one stamp away"

    git grep -c 'deploys_failing' origin/main -- .

Hits ONLY `.claude/workflows/bp-deploy-reliability-charter.md` and two `tooling/grip/ledger/*.md`.
Zero code. `dr-w10-s1-verdict-reads-the-deploy-rate` sits at 12/13 with **no bytes on main**.

## R4 — branch → PR → main, per open task

    bp task get <id> -o json | python3 -c "import json,sys,re;c=json.load(sys.stdin)['doc']['claim'] or {};print((c.get('now') or {}).get('text',''))"
    gh pr list -R FRIKKern/barkpark --state all --head "<loop-epic/...>" --json number,state,mergedAt
    git ls-remote --heads origin | grep -F "<branch>"

15 branches named in a live claim have **NO PR and no remote head**: the commits exist only
in a deleted worktree.

## R5 — close-argument shape for the 71 open rows

    bp task get task-fb4fb869490b4213 -o json | python3 -c "
    import json,sys,subprocess,collections
    ids=[x['doc_id'] for x in json.load(sys.stdin)['children'] if x['lifecycle_status']=='open']
    c=collections.Counter()
    for i in ids:
        d=json.loads(subprocess.run(['bp','task','get',i,'-o','json'],capture_output=True,text=True).stdout)['doc'].get('claim') or {}
        c['worker' if d.get('worker') else ('previous_worker' if d.get('previous_worker') else 'no-claim')]+=1
    print(c)"

Result: `{'previous_worker': 56, 'no-claim': 14, 'worker': 1}`.
`bp task close <id> <worker_id> <observed_epoch>` needs BOTH. The 14 no-claim rows carry no
epoch at all — they must be claimed before they can be closed.

## R6 — the 4-minute ledger sweep was not a rubber stamp

    # 48 done rows carry updated_at in 2026-08-07T23:01–23:04Z; min evidence length 173 chars
    git show origin/main:scripts/cloud-path-escape-check.sh | sed -n '172,186p'

Verifies dr-w13-s1's stamped evidence (`deploy/site-deploy-node.sh` inside `CLOUD_PATHS`)
against main. Same command shows `.github/workflows/deploy.yml` is NOT in `CLOUD_PATHS`.
