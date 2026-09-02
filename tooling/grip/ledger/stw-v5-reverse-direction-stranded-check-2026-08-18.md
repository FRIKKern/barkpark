<!-- doc-tier: cold | canonical-for: none | budget: 2000tok -->
# V5 reverse-direction stranded-DONE re-derivation recipes (search-template audit, 2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Read-only audit note. Re-derive every claim from origin/main (186 commits ahead of local a6535504) + live bp.

## Denominator + near-complete set
```
bp task get search-template-epic-goal -o json > epic.json
# counts: 72 done / 38 open / 6 considering / 1 cancelled of 117 children
python3 - <<'PY'
import json;d=json.load(open('epic.json'))
for x in d['children']:
    if x['lifecycle_status']=='open':
        cp=x.get('criteria_progress') or {};m,t=cp.get('met'),cp.get('total')
        if isinstance(m,int) and isinstance(t,int) and t>0 and m==t-1: print(x['doc_id'],f'{m}/{t}')
PY
```
Near-complete (one-short) OPEN rows = 8, NOT the wish's stated 10:
stw1-react-preview-publish 4/5, stw9-backlog-graph-server-honesty 6/7,
stw9-backlog-ws-dataset-validation 4/5, stw9-backlog-bpgraph-identity-tripwire 7/8,
stw9-backlog-doctype-readback 5/6, stw9-backlog-provision-indx 4/5,
stw10-template-copy-unknown-dataset 0/1, stw12-copy-honesty-content-lock 7/8.

## Mechanical reverse-direction (open at met==total) — ZERO
Same script, `m==t` branch => no rows. No open row mechanically stranded-DONE.

## Per-row unmet-criterion type
```
bp task get <id> -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc']['content'];[print(c['criterion']) for c in d['acceptance_criteria'] if not c['met']]"
```
7/8 unmet crits are un-dischargeable-offline live-seals (HUMAN-GATED npm publish; or
MERGE-GATED requiring live token GET /v1/graph, live WS join, live `bp cloud site status`,
live chunk fetch, or live GET /v1/templates). => correctly OPEN, not stranded.

## The ONE offline-satisfiable candidate: stw10-template-copy-unknown-dataset (0/1)
Crit: "All four template files name the unknown_dataset join refusal instead of joins-green-count-0."
```
for f in templates/search-starter/.env.example templates/search-starter/next.config.mjs \
         templates/search-starter/lib/config.ts templates/astro-search-starter/src/finder/lib/config.ts; do
  git show origin/main:$f | grep -in "unknown_dataset\|joins green\|count=0"; done
```
=> all four STILL describe old "joins green / count=0 forever" symptom; ZERO unknown_dataset.
Code landed (SearchChannel refusal on origin/main) but the copy task was never built:
```
git grep -in unknown_dataset origin/main -- api/lib/barkpark_web/channels/search_channel.ex
# :96  {:dataset,_} -> {:error, %{reason: "unknown_dataset"}}
```
=> stw10 is legitimately-owed OPEN work, NOT stranded-DONE.

## Cancelled draft: drafts.stw1-basepath-redirect-fix (3/3 met)
`bp task get drafts.stw1-basepath-redirect-fix -o json` => persistent server 500 (3 request_ids).
Cancellation note unreadable directly. Intentional-fold backed by: (a) `drafts.` namespace,
(b) it is "round 2" of a basePath live-proof, (c) its subject landed on origin/main:
```
git grep -in "basePath\|handle_path\|follows redirect" origin/main -- deploy/site-deploy-node.sh
# BARKPARK_SITE_BASEPATH / handle_path / HEALTH probe follows redirects
```
=> content delivered via live deploy engine; draft folded as superseded. Intentional.

## VERDICT
Reverse-direction stranded-DONE count = 0. All 8 near-complete open rows correctly open;
cancelled draft intentionally folded. Nothing to move. No reopen manufactured.
