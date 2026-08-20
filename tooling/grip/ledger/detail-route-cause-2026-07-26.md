# Re-derivation recipes — CLICK beat (detail route) root cause, search-ember, 2026-07-26

Verifier lane: `detail-route-cause`. Every row is one literal command that re-derives the fact.

| # | Fact | Rerun |
|---|---|---|
| 1 | get-document.ts uses the FLAT client (`scopePrefix('')`) — it is NOT double-scoped | `git show origin/main:templates/search-starter/lib/barkpark-client.ts \| tail -5` |
| 2 | Doubled scope reproduces the exact LAND error body (`document not found`) | `curl -s 'https://guerrilla.barkpark.cloud/w/default/p/default/w/default/p/default/v1/data/search/production?q=wave&engine=indx&limit=1'` |
| 3 | Detail route for a REAL paper is HTTP 200 with real content (CLICK is not dead) | `curl -s -o /dev/null -w '%{http_code}\n' 'https://guerrilla.barkpark.cloud/sites/search-ember/d/paper/mechanical-spacing-doctrine'` |
| 4 | PortableDoc DOES render live (`bp-paper-surface` present) | `curl -s 'https://guerrilla.barkpark.cloud/sites/search-ember/d/paper/mechanical-spacing-doctrine' \| grep -o 'bp-paper-surface' \| head -1` |
| 5 | Some papers carry NO `blocks` → MetaCard dumps raw `Body html` | `bp doc get paper search-template-wave-9-2026-07-26 -o json \| python3 -c "import sys,json;print(sorted(json.load(sys.stdin).keys()))"` |
| 6 | mediaAsset is NOT a queryable type upstream → 404 → thrown → red error panel | `curl -s -o /dev/null -w '%{http_code}\n' 'https://guerrilla.barkpark.cloud/v1/data/query/production/mediaAsset?limit=1'` |
| 7 | Soft-404 is Next's own streamed 200, NOT Caddy: a no-route path 404s properly | `curl -sI 'https://guerrilla.barkpark.cloud/sites/search-ember/zzz' \| head -1` |
| 8 | Even a type rejected BEFORE any fetch still returns 200 | `curl -s -o /dev/null -w '%{http_code}\n' 'https://guerrilla.barkpark.cloud/sites/search-ember/d/zzztype/foo'` |
| 9 | Deployed site is single-type (`paper`), 551 docs — not 2705 tasks | `curl -s 'https://guerrilla.barkpark.cloud/sites/search-ember/api/find?q=%20&browse=1&engine=postgres' \| python3 -c "import sys,json;d=json.load(sys.stdin);print(d['total'],d['facets']['type'])"` |
| 10 | Deployed DATASET is `production` (not `docs`) | `curl -s 'https://guerrilla.barkpark.cloud/v1/data/search/production?q=wave&engine=postgres&limit=1' \| head -c 120` |
