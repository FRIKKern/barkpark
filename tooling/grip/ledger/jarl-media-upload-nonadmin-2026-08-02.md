# Re-derivation recipe — non-admin media upload path on jarl.barkpark.cloud

Verified 2026-08-02 (verifier `media-upload-probe`, jarl-innleggene wave).
Claim: a `bpapp_` token with `permissions:["read","write"]` (NOT admin) can
upload, serve, describe (alt text), publish, and delete media end to end.

```bash
ADMIN=$(cat /tmp/jarl_admin_token)          # bp_admin_… , minted out of band
BASE=https://jarl.barkpark.cloud

# 1. mint non-admin read+write token  → 201, token starts bpapp_
TOK=$(curl -s -X POST $BASE/v1/auth/app-tokens \
  -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
  -d '{"email":"pelle@jarl.no","permissions":["read","write"],"label":"verify-upload"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

printf '\x89PNG\r\n\x1a\n...' > tiny.png      # any real PNG, 1x1 is enough

# 2a. flat upload → 201 {id,path,url,assetDocId}
curl -s -X POST $BASE/media/upload -H "Authorization: Bearer $TOK" \
  -F "file=@tiny.png;type=image/png"

# 2b. v1 upload (renditions + mediaAsset doc) → 201
curl -s -X POST $BASE/v1/media/production/upload -H "Authorization: Bearer $TOK" \
  -F "file=@tiny.png;type=image/png"

# 3. serve — ANONYMOUS, no auth header → 200 image/png, byte-identical
curl -s -o got.png $BASE/media/files/<path-from-step-2>
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' \
  $BASE/media/renditions/<id>/thumb          # → 200 image/jpeg (derived server-side)

# 4. alt text / title / description → 200, lands on the DRAFT asset doc
curl -s -X PATCH $BASE/v1/media/production/<id> -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"title":"…","altText":"…","description":"…"}'

# 5. publish the asset doc (REQUIRED: both id AND type, else 400 malformed)
curl -s -X POST $BASE/v1/data/mutate/production -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"mutations":[{"publish":{"id":"asset-<id>","type":"mediaAsset"}}]}'

# 6. cleanup → 200 each; blob GET then 404
curl -s -X DELETE $BASE/v1/media/production/<id>   -H "Authorization: Bearer $TOK"
curl -s -X DELETE $BASE/media/<flat-id>            -H "Authorization: Bearer $TOK"
curl -s -X DELETE $BASE/v1/auth/app-tokens/current -H "Authorization: Bearer $TOK"
```

Negative control (write-gate is real): mint `permissions:["read"]` and POST
`/media/upload` → **403** `{"code":"forbidden","message":"token lacks required
permission"}`. After self-revoke the same upload → **401** `unauthorized`.

Route source: `api/lib/barkpark_web/router.ex` — flat `scope "/media"` +
`pipe_through(:media_mutate)` (`post "/upload"`, `delete "/:id"`), pipeline
defined ~L604 (`RequireBearerOrSessionToken` → `RequireWithinQuota meter: :media`
→ `RequireWritePermission`; **no** `require_admin`). v1 variant: `scope
"/v1/media"` + `:media_mutate`, `post "/:dataset/upload"`.
Multipart field name is literally `file` (`MediaController.upload/2` matches
`%{"file" => upload}`); any other name → 400 "missing 'file' field".
Admin-only in this area is ONLY `put /api/workspaces/:slug/media/blob/*path`
(`[:api, :require_admin]`) — a cross-instance blob-copy primitive, not needed
for authoring.
