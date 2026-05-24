#!/usr/bin/env bash
# Production smoke test for the media platform (Phases 1–5).
set -euo pipefail

TOKEN="${BARKPARK_TOKEN:-barkpark-dev-token}"
BASE="${BARKPARK_BASE:-http://89.167.28.206}"
AUTH=(-H "Authorization: Bearer $TOKEN")

pass=0
fail=0

ok() { echo "✓ $1"; pass=$((pass + 1)); }
bad() { echo "✗ $1"; fail=$((fail + 1)); }

# 1x1 PNG
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
echo "$PNG_B64" | base64 -d > /tmp/bp-smoke-test.png

echo "=== Upload ==="
UPLOAD=$(curl -sf -X POST "$BASE/media/upload" "${AUTH[@]}" -F "file=@/tmp/bp-smoke-test.png;type=image/png")
MEDIA_ID=$(echo "$UPLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
FILENAME=$(echo "$UPLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin)['filename'])")
echo "id=$MEDIA_ID"
sleep 1

echo ""
echo "=== v1 detail + delivery URLs ==="
DETAIL=$(curl -sf "$BASE/v1/media/production/$MEDIA_ID?appendRequestSecret=true" "${AUTH[@]}")
if echo "$DETAIL" | python3 -c "
import json,sys
d=json.load(sys.stdin)['result']
assert d.get('thumbnailUrl'), 'no thumbnailUrl'
assert d.get('previewUrl'), 'no previewUrl'
assert d.get('originalUrl'), 'no originalUrl'
assert 'thumb' in (d.get('renditions') or {}), 'no thumb rendition'
print('urls ok')
"; then ok "v1 detail + delivery URLs"; else bad "v1 detail + delivery URLs"; fi

echo ""
echo "=== Search ==="
SEARCH=$(curl -sf "$BASE/v1/media/production/search?limit=5" "${AUTH[@]}")
TOTAL=$(echo "$SEARCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['total'])")
if [ "$TOTAL" -ge 1 ]; then ok "search total=$TOTAL"; else bad "search total=$TOTAL"; fi

echo ""
echo "=== Collections ==="
COLL_ID="smoke-col-$(date +%s)"
curl -sf -X POST "$BASE/v1/data/mutate/production" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"mutations\":[{\"create\":{\"_type\":\"mediaCollection\",\"_id\":\"$COLL_ID\",\"title\":\"Smoke Folder\",\"kind\":\"folder\",\"slug\":\"$COLL_ID\"}},{\"publish\":{\"id\":\"$COLL_ID\",\"type\":\"mediaCollection\"}}]}" > /dev/null

if curl -sf -X POST "$BASE/v1/media/production/collections/$COLL_ID/members" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"assetId\":\"$MEDIA_ID\"}" > /dev/null; then
  ok "add collection member"
else
  bad "add collection member"
fi

ASSETS=$(curl -sf "$BASE/v1/media/production/collections/$COLL_ID/assets" "${AUTH[@]}")
COUNT=$(echo "$ASSETS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']['hits']))")
if [ "$COUNT" -ge 1 ]; then ok "collection assets count=$COUNT"; else bad "collection assets"; fi

echo ""
echo "=== Share link ==="
SHARE=$(curl -sf -X POST "$BASE/v1/media/production/collections/$COLL_ID/share" "${AUTH[@]}")
TOKEN_SHARE=$(echo "$SHARE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['token'])")
PUBLIC=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/v1/media/production/share/$TOKEN_SHARE")
if [ "$PUBLIC" = "200" ]; then ok "public share link"; else bad "public share HTTP $PUBLIC"; fi

echo ""
echo "=== Governance ==="
if curl -sf -X POST "$BASE/v1/media/production/$MEDIA_ID/checkout" "${AUTH[@]}" > /dev/null; then
  ok "checkout"
else bad "checkout"; fi
if curl -sf -X POST "$BASE/v1/media/production/$MEDIA_ID/undo-checkout" "${AUTH[@]}" > /dev/null; then
  ok "undo-checkout"
else bad "undo-checkout"; fi

echo ""
echo "=== Serve + rendition ==="
ORIG=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/media/files/2026/05/$FILENAME")
THUMB=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/media/renditions/$MEDIA_ID/thumb")
if [ "$ORIG" = "200" ]; then ok "serve original"; else bad "serve original HTTP $ORIG"; fi
if [ "$THUMB" = "200" ]; then ok "serve thumb rendition"; else bad "serve thumb HTTP $THUMB"; fi

# cleanup
curl -sf -X DELETE "$BASE/v1/media/production/collections/$COLL_ID/share" "${AUTH[@]}" > /dev/null 2>&1 || true
curl -sf -X DELETE "$BASE/media/$MEDIA_ID" "${AUTH[@]}" > /dev/null || true

echo ""
echo "=== SMOKE: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
