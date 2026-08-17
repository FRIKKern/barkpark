<!-- doc-tier: cold | canonical-for: reseed-preflight-verifier-recipe-2026-08-17 | budget: 800tok -->

# Re-seed preflight re-derivation (scaffy-wave 2026-08-17)

Verifier [reseed-preflight]. Proves the Decide-time re-seed (D95 precedent) can execute without surprise.
Baseline: origin/main HEAD a6535504204df39850cb1d08316b5ffb25eb983b.

## (a) State unchanged — still exactly 2 console rows drifted

    go run ./scaffy/seed --check; echo exit=$?

Expect: exit 1, "20/22 MATCH, 2 DRIFT", DRIFT rows =
barkpark--console-helper--js (local e2874330 / served 5e117c4f)
barkpark--console-hook-zones--js (local c46c32cd / served e405a3e1).
No other row drifted → no concurrent re-seed happened.

## (b) Token can write — admin tier

    bp whoami -o json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["auth_tier"],d["active"],d["token_present"],d["reachable"])'

Expect: admin True True True. Server https://guerrilla.barkpark.cloud, dataset production.

## (c) Payloads + E3 tag wall — all tags published

    go run ./scaffy/seed
    python3 -c "import json,hashlib;[print(f,hashlib.sha256(json.load(open(f'scaffy/seed/out/{f}.json'))['source'].encode()).hexdigest()[:8],[t['tag'] for t in json.load(open(f'scaffy/seed/out/{f}.json'))['tags']]) for f in ['barkpark--console-helper--js','barkpark--console-hook-zones--js']]"

Expect: console-helper source_sha e2874330 tags [cloud-console,spa,scaffold];
console-hook-zones source_sha c46c32cd tags [cloud-console,scaffold].
Emitted source shas == LOCAL side of drift table → re-seed direction local→served, payloads carry drifted content.

Tag wall (union {cloud-console, spa, scaffold}):

    for t in cloud-console spa scaffold; do bp doc get tag "$t" -o json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["_id"],"_draft="+str(d["_draft"]),"pub="+d.get("_publishedId",""))'; done

Expect all three: _draft=False, _publishedId set. No tag would 422 the atomic batch. E3 wall CLEAR.

## Verdict

Re-seed is safe to execute at Decide: state unchanged (2 rows), admin token writes, all 3 tags published. Zero 422 risk.
