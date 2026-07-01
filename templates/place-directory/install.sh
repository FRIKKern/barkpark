#!/bin/sh
# Place Directory — install the `place` schema and seed sample places into a
# Barkpark dataset, then smoke-test the public read the frontend uses.
#
#   BARKPARK_SERVER=http://localhost:4000 \
#   BARKPARK_API_TOKEN=barkpark-dev-token \
#   BARKPARK_DATASET=production \
#   ./install.sh
#
# Idempotent: the schema upsert and createOrReplace seeds can be re-run safely.
# POSIX sh + curl only.
set -eu

SERVER="${BARKPARK_SERVER:-http://localhost:4000}"
TOKEN="${BARKPARK_API_TOKEN:-barkpark-dev-token}"
DATASET="${BARKPARK_DATASET:-production}"
DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
post() { # post <url> <file>
  curl -fsS -X POST "$1" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@$2"
}

say "1/3 · Install the place schema → ${SERVER}/v1/schemas/${DATASET}"
post "${SERVER}/v1/schemas/${DATASET}" "${DIR}/schemas/place.json" \
  && printf '\n  ✓ schema upserted\n'

say "2/3 · Seed sample places → ${SERVER}/v1/data/mutate/${DATASET}"
post "${SERVER}/v1/data/mutate/${DATASET}" "${DIR}/seed-places.json" \
  && printf '\n  ✓ places written\n'

say "3/3 · Smoke test the public read the frontend uses"
COUNT=$(curl -fsS "${SERVER}/v1/data/query/${DATASET}/place?filter%5Bstatus%5D=published&limit=100" \
  | grep -o '"_id"' | wc -l | tr -d ' ')
printf '  published places visible to the public API: %s\n' "$COUNT"

if [ "$COUNT" = "0" ]; then
  cat <<'NOTE'

  ⚠ 0 published places returned. createOrReplace may have written DRAFTS on your
    Barkpark version (Sanity-style). If so, publish them in Studio
    (api host → /studio → select each place → Publish), or use your publish
    flow, then re-run the smoke test above. The schema + content are in place.
NOTE
else
  printf '\n  ✓ Done. Point the frontend at this server with:\n'
  printf '      NEXT_PUBLIC_FINDER_LANDING=map\n      NEXT_PUBLIC_BARKPARK_API_URL=%s\n      BARKPARK_DATASET=%s\n      LISTINGS_TYPE=place\n' "$SERVER" "$DATASET"
fi
