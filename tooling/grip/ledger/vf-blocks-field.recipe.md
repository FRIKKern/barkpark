# Re-derivation recipe — vf-blocks-field (jarl paper blocks-field truth)

Claim: on the live jarl instance, `paper.blocks` (top level) is non-empty and
byte-equal to `paper.body.blocks`; both endpoints agree; `?fields=` projection
is what makes top-level `blocks` look EMPTY.

```sh
# 1. doc endpoint — both fields present, equal
curl -s https://jarl.barkpark.cloud/v1/data/doc/production/paper/velkommen-til-jarl-no \
 | python3 -c "import json,sys;d=json.load(sys.stdin)['result'];print(len(d.get('blocks') or []),len((d.get('body') or {}).get('blocks') or []),json.dumps(d['blocks'],sort_keys=True)==json.dumps(d['body']['blocks'],sort_keys=True))"
# expect: 11 11 True

# 2. query endpoint — same doc, same numbers
curl -s https://jarl.barkpark.cloud/v1/data/query/production/paper \
 | python3 -c "import json,sys;d=json.load(sys.stdin)['result']['documents'][0];print(d['_id'],len(d.get('blocks') or []),len((d.get('body') or {}).get('blocks') or []))"
# expect: velkommen-til-jarl-no 11 11

# 3. ?fields= IS honoured on the DOC endpoint (system fields always returned)
curl -s 'https://jarl.barkpark.cloud/v1/data/doc/production/paper/velkommen-til-jarl-no?fields=title,description' \
 | python3 -c "import json,sys;print(sorted(json.load(sys.stdin)['result'].keys()))"
# expect: ['_createdAt','_draft','_id','_publishedId','_rev','_type','_updatedAt','description','title']

# 4. jarl consumes the UNPROJECTED doc — no fields= anywhere in the client
git -C /Users/frikkjarl/Documents/GitHub/jarl-website grep -n "fields=" origin/main -- src/content/
# expect: no output
```

Verified 2026-07-31. Public reads (no Authorization header needed).
