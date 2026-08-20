# Re-derivation recipes — sites-embed-cohort-live-run (wave 17 verify, 2026-08-07)

Token used: `cloud_token` from `~/.config/barkpark/config.json` (a REAL non-admin
session — it 403s on the operator census, 200s on the team routes).

```bash
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")

# 1. This session is NOT a platform operator (the reachability finding)
curl -s -w "HTTP %{http_code}\n" -H "Authorization: Bearer $TOK" \
  https://api.barkpark.cloud/v1/operator/deploy-ledger/census
# -> HTTP 403 {"error":"forbidden","scope":"platform","required":"platform_operator"}

# 2. The SAME session gets 200 on the team-scoped sites list, embed included
curl -s -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/sites \
 | python3 -c "import json,sys,collections;d=json.load(sys.stdin);print(collections.Counter((s.get('last_deployment') or {}).get('status','ABSENT') for s in d['sites']))"

# 3. The embed keyset (honesty law, D24/D173): status/trigger/inserted_at/updated_at
curl -s -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/sites \
 | python3 -c "import json,sys;d=json.load(sys.stdin);print(set(tuple(sorted((s.get('last_deployment') or {}).keys())) for s in d['sites']))"

# 4. The CLI does NOT read the embed — N+1 over /v1/sites/:id/deployments
bp sites -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(sorted((d['sites'][0].get('last_deployment') or {}).keys()))"
# -> ['id','image_tag','inserted_at','status']   (different keyset => different data path)

# 5. Human table (tty default; piped defaults to json — force it)
bp sites -o table

# 6. The COST fields ARE reachable to the same non-admin session
SITE=7c2025a5-4181-46df-8b00-6151fe3da9d4   # slug "search"
curl -s -H "Authorization: Bearer $TOK" \
  "https://api.barkpark.cloud/v1/sites/$SITE/deployments?limit=200" \
 | python3 -c "import json,sys,collections;d=json.load(sys.stdin);deps=d['deployments'];print(sorted(deps[0].keys()));print(collections.Counter(x['status'] for x in deps));print('with became_live_at',sum(1 for x in deps if x.get('became_live_at')))"
```

Cohort is TIME-VARYING: two runs ~5 min apart gave
`live 8 / failed 2 / deferred 1 / building 1 / ABSENT 1` then
`live 10 / failed 2 / ABSENT 1`. Re-run (2) twice to reproduce.
