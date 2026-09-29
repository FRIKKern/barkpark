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
#
# EVERY ✓ HERE FOLLOWS A READ-BACK, never a transport echo. `curl -fsS` exiting
# 0 proves a request was accepted, not that a record exists: a 2xx over an empty
# write would have printed the same tick. So each step POSTs, then GETs the
# state it just claimed to have produced and asserts the state is THERE; a read
# that cannot be performed is a named failure, never a silent zero.
# (docs/decisions/success-claim-census.md · pds-bl-place-directory-install-echoes-transport)
set -eu

SERVER="${BARKPARK_SERVER:-http://localhost:4000}"
TOKEN="${BARKPARK_API_TOKEN:-barkpark-dev-token}"
DATASET="${BARKPARK_DATASET:-production}"
DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n  ✗ %s\n' "$*" >&2; exit 1; }
post() { # post <url> <file>
  curl -fsS -X POST "$1" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@$2"
}
get() { # get <url> — the read-back arm; authenticated, body on stdout
  curl -fsS "$1" -H "Authorization: Bearer ${TOKEN}"
}
# Whitespace-insensitive substring test over a captured body.
squash() { printf '%s' "$1" | tr -d ' \n\t\r'; }

say "1/3 · Install the place schema → ${SERVER}/v1/schemas/${DATASET}"
post "${SERVER}/v1/schemas/${DATASET}" "${DIR}/schemas/place.json" \
  || fail "schema upsert: POST ${SERVER}/v1/schemas/${DATASET} failed. Nothing was installed."

SCHEMA_URL="${SERVER}/v1/schemas/${DATASET}/place"
SCHEMA_BODY="$(get "$SCHEMA_URL" 2>/dev/null || true)"
if [ -z "$SCHEMA_BODY" ]; then
  fail "CANNOT READ: the POST was accepted but GET ${SCHEMA_URL} returned nothing (transport failure or 404). The upsert is UNPROVEN — no success tick."
fi
case "$(squash "$SCHEMA_BODY")" in
  *'"name":"place"'*)
    printf '\n  ✓ schema read back at %s — the type named place is present\n' "$SCHEMA_URL" ;;
  *)
    fail "the POST was accepted but GET ${SCHEMA_URL} does not report a type named 'place'. A 2xx over an empty write; the schema is NOT installed." ;;
esac

say "2/3 · Seed sample places → ${SERVER}/v1/data/mutate/${DATASET}"
EXPECTED="$(grep -o '"createOrReplace"' "${DIR}/seed-places.json" | wc -l | tr -d ' ')"
[ "$EXPECTED" -gt 0 ] || fail "CANNOT READ: ${DIR}/seed-places.json declares 0 createOrReplace mutations — refusing to claim a seed nobody can measure."
post "${SERVER}/v1/data/mutate/${DATASET}" "${DIR}/seed-places.json" \
  || fail "seed: POST ${SERVER}/v1/data/mutate/${DATASET} failed. Nothing was written."

# createOrReplace writes the DRAFT row (docs/api-v1.md §6), so the read-back uses
# ?perspective=raw — a `published` read legitimately returns 0 here and would
# make an honest install look broken.
SEED_URL="${SERVER}/v1/data/query/${DATASET}/place?perspective=raw&limit=1000"
SEED_BODY="$(get "$SEED_URL" 2>/dev/null || true)"
if [ -z "$SEED_BODY" ]; then
  fail "CANNOT READ: the mutate POST was accepted but GET ${SEED_URL} returned nothing (transport failure or 404). The ${EXPECTED} seeds are UNPROVEN — no success tick."
fi
SEEDED="$(printf '%s' "$SEED_BODY" | grep -o '"_id"' | wc -l | tr -d ' ')"
if [ "$SEEDED" -lt "$EXPECTED" ]; then
  fail "the mutate POST was accepted but the read-back at ${SEED_URL} sees ${SEEDED} place document(s), not the ${EXPECTED} sent. A 2xx over a write that did not persist."
fi
printf '\n  ✓ places read back: %s of %s seeded documents visible at %s\n' "$SEEDED" "$EXPECTED" "$SEED_URL"

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
