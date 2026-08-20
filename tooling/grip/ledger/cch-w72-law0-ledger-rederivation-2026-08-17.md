<!-- rerun recipes for wave-72 law0-ledger verify; author: verifier; do not commit (Decide commits) -->

# cch-w72 Law-0 ledger reconciliation — re-derivation recipes (2026-08-17)

## Task states (bp, guerrilla)
- `bp task get cch-w40-s2-a-refusal-copy-census-that-reds-on-an-invented-cause-and-on-a-decayed-pin -o json` → open, claim:null, 0/11 criteria, parent cloud-console-hardening-epic, wave_paper cch-wave-40.
- `bp task get cch-w40-bl-reason-arm-census-authex-arm -o json` → open, claim:null, 0/3, parent epic.
- `bp task get cch-w64-bl-124-typed-wire-codes-have-no-console-reader -o json` → open, claim:null, assignee:null, 0/3, parent epic.

## w71-bl backlog enumeration (all four located, none dropped)
```
python3 - <<'PY'
import urllib.request, json
TOK="<guerrilla admin token>"; SRV="https://guerrilla.barkpark.cloud"
off=0
while True:
    d=json.load(urllib.request.urlopen(urllib.request.Request(
        f"{SRV}/v1/data/query/production/task?limit=100&offset={off}",
        headers={"Authorization":f"Bearer {TOK}"})))["result"]
    for t in d["documents"]:
        if "w71-bl" in t.get("_id",""): print(t["_id"], t.get("lifecycle_status"), t.get("claim"))
    if len(d["documents"])<100: break
    off+=100
PY
```
Yields exactly 4, all open, claim None: bootstrap-vercel-mint-403-raw-dump; platform-host-fourth-normaliser-spelling; domain-settings-get-flatten-refusals; deploy-collapses-refusal-exit-families.

## PR states
`gh pr view <n> --json number,state,mergedAt,mergeStateStatus` for 10083, 11885, 11886, 11887, 11870, 10006.
- 10083 MERGED 2026-08-07T05:25:21Z (w40-s1 crown; landed __reason_arm_census.mjs on main).
- 11886 MERGED 2026-08-17T16:03:45Z (site-create exit families → arms D863 menu rider).
- 11870 MERGED 2026-08-17T16:03:40Z (charter D861-D866; ceiling now D866).
- 11885 OPEN/BLOCKED, 11887 OPEN/BLOCKED, 10006 OPEN/BLOCKED.

## origin/main facts
- `git ls-tree origin/main cloud/priv/static/__reason_arm_census.mjs` → present (s1 shipped it, router.ex-only per its LIMIT 1 header).
- `git ls-tree origin/main cloud/priv/static/__refusal_copy_census.mjs` → absent (w40-s2 not yet built).
- Charter last ledger row on origin/main = D866; "next wave opens at D867" (prose only).
