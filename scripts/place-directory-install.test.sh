#!/usr/bin/env bash
# Hermetic behavioral regression for templates/place-directory/install.sh's
# SUCCESS-CLAIM postcondition (pds-bl-place-directory-install-echoes-transport).
#
# The defect this pins: the installer used to print `✓ schema upserted` and
# `✓ places written` off `post … && printf …`, i.e. off `curl -fsS` exiting 0.
# That is a TRANSPORT echo — a 2xx over a write that persisted nothing printed
# exactly the same two ticks (docs/decisions/success-claim-census.md, "Shell").
#
# No network, no writes outside an isolated $TMP: a fake `curl` shadowing the
# real one on a PATH-only bin dir serves canned bodies per URL and appends every
# invocation's argv to $DANGER_LOG. Arms:
#   A. 2xx to every POST, EMPTY state to every read-back  -> non-zero exit, and
#      the failure NAMES the missing state (no ✓ anywhere).
#   B. 2xx to every POST, the state PRESENT on read-back  -> exit 0, both ✓.
#   C. read-back itself unreadable (HTTP 404 -> curl -f)  -> non-zero exit with a
#      distinct CANNOT READ line: a failed read is never byte-identical to a zero.
#   D. MUTATION: the pre-fix `post … && printf ✓` shape, run against arm A's very
#      fixture, exits 0 and prints both ticks. Same fixture, old shape green, new
#      shape red — that is what makes arm A a detector rather than a wish.
# Every arm asserts its FIXTURE first (the shim ran; the expected URLs are in the
# argv log) so a setup that silently died cannot pass as a green.
#
# Templated on scripts/install-cli.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUBJECT="$REPO/templates/place-directory/install.sh"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

[ -f "$SUBJECT" ] || { echo "CANNOT READ: $SUBJECT is missing"; exit 2; }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; find "$TMP" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

FAKE="$TMP/fakebin"
mkdir -p "$FAKE"

# ── The fake curl. MODE (env) picks the read-back fixture; POSTs always 2xx, in
# every mode — the whole point is that the transport says yes while the state
# says nothing. Every call's argv is appended to $DANGER_LOG.
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
url=""; is_post=0
for a in "$@"; do
  case "$a" in
    -X) ;;
    POST) is_post=1 ;;
    http*) [ -z "$url" ] && url="$a" ;;
  esac
done
echo "curl($MODE) post=$is_post $url" >> "$DANGER_LOG"

if [ "$is_post" = 1 ]; then
  # Accepted. A record? Nobody said that.
  case "$url" in
    *"/v1/schemas/"*) echo '{"name":"place","title":"Place"}' ;;
    *"/v1/data/mutate/"*) echo '{"transactionId":"deadbeef","results":[]}' ;;
    *) echo '{}' ;;
  esac
  exit 0
fi

# ── read-backs (GET)
case "$MODE:$url" in
  empty:*"/v1/schemas/"*)          echo '{"_schemaVersion":1,"schemas":[]}'; exit 0 ;;
  empty:*"/v1/data/query/"*)       echo '{"result":[],"count":0}'; exit 0 ;;
  unreadable:*"/v1/schemas/"*)     exit 22 ;;   # curl -f on an HTTP 404
  unreadable:*"/v1/data/query/"*)  exit 22 ;;
  present:*"/v1/schemas/"*)        echo '{"_schemaVersion":1,"schema":{"name": "place","title":"Place"}}'; exit 0 ;;
  present:*"/v1/data/query/"*)
    # 12 documents, matching seed-places.json's 12 createOrReplace mutations.
    printf '{"result":['
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [ "$i" = 1 ] || printf ','
      printf '{"_id":"place-%s","_type":"place","status":"published"}' "$i"
    done
    printf '],"count":12}\n'
    exit 0 ;;
esac
echo '{}'
exit 0
EOF
chmod +x "$FAKE/curl"

run_installer() { # $1 = MODE, $2 = script to run, $3 = out file, $4 = argv log
  env -i PATH="$FAKE:/usr/bin:/bin" HOME="$TMP" \
    MODE="$1" DANGER_LOG="$4" \
    BARKPARK_SERVER="http://server.invalid" \
    BARKPARK_API_TOKEN="tok" BARKPARK_DATASET="ds" \
    /bin/sh "$2" > "$3" 2>&1
  echo $?
}

EXPECTED_SEEDS="$(grep -o '"createOrReplace"' "$REPO/templates/place-directory/seed-places.json" | wc -l | tr -d ' ')"
echo "FIXTURE: seed-places.json declares $EXPECTED_SEEDS createOrReplace mutations"
check "the seed fixture is non-trivial (>0 mutations)" '[ "$EXPECTED_SEEDS" -gt 0 ]'

# ══ ARM A — 2xx everywhere, empty state on read-back ════════════════════════
echo
echo "ARM A · POSTs 2xx, read-backs EMPTY -> must FAIL, naming the missing state"
LOG_A="$TMP/a.log"; OUT_A="$TMP/a.out"; : > "$LOG_A"
RC_A="$(run_installer empty "$SUBJECT" "$OUT_A" "$LOG_A")"
# FIXTURE FIRST: the shim ran, and it ran on the URL whose state we care about.
check "A fixture: the fake curl was invoked" '[ -s "$LOG_A" ]'
check "A fixture: the schema POST reached the shim" 'grep -q "post=1 http://server.invalid/v1/schemas/ds" "$LOG_A"'
check "A fixture: a schema READ-BACK (GET) reached the shim" 'grep -q "post=0 http://server.invalid/v1/schemas/ds/place" "$LOG_A"'
# VERDICT
check "A: the installer exits non-zero" '[ "$RC_A" != 0 ]'
check "A: it prints NO success tick" '! grep -q "✓" "$OUT_A"'
check "A: the failure names the schema read-back URL" 'grep -q "/v1/schemas/ds/place" "$OUT_A"'
check "A: the failure names the missing type" 'grep -q "place" "$OUT_A" && grep -qi "not report a type\|NOT installed" "$OUT_A"'
sed 's/^/    A| /' "$OUT_A"

# ══ ARM B — the state is really there ══════════════════════════════════════
echo
echo "ARM B · POSTs 2xx, read-backs report the STATE -> must SUCCEED with ticks"
LOG_B="$TMP/b.log"; OUT_B="$TMP/b.out"; : > "$LOG_B"
RC_B="$(run_installer present "$SUBJECT" "$OUT_B" "$LOG_B")"
check "B fixture: the fake curl was invoked" '[ -s "$LOG_B" ]'
check "B fixture: the seed read-back used perspective=raw" 'grep -q "post=0 .*perspective=raw" "$LOG_B"'
check "B fixture: the mutate POST reached the shim" 'grep -q "post=1 http://server.invalid/v1/data/mutate/ds" "$LOG_B"'
check "B: the installer exits 0" '[ "$RC_B" = 0 ]'
check "B: the schema tick is a READ-BACK claim" 'grep -q "✓ schema read back" "$OUT_B"'
check "B: the seed tick reports measured vs sent" 'grep -q "✓ places read back: 12 of '"$EXPECTED_SEEDS"'" "$OUT_B"'
check "B: no ✗ failure line" '! grep -q "✗" "$OUT_B"'
sed 's/^/    B| /' "$OUT_B"

# ══ ARM C — the read-back itself cannot be performed ════════════════════════
echo
echo "ARM C · read-back unreadable (HTTP 404) -> distinct CANNOT READ, non-zero"
LOG_C="$TMP/c.log"; OUT_C="$TMP/c.out"; : > "$LOG_C"
RC_C="$(run_installer unreadable "$SUBJECT" "$OUT_C" "$LOG_C")"
check "C fixture: the schema read-back was attempted" 'grep -q "post=0 http://server.invalid/v1/schemas/ds/place" "$LOG_C"'
check "C: the installer exits non-zero" '[ "$RC_C" != 0 ]'
check "C: a failed read is NOT byte-identical to a zero (CANNOT READ line)" 'grep -q "CANNOT READ" "$OUT_C"'
check "C: no success tick" '! grep -q "✓" "$OUT_C"'
check "C's message differs from A's (read failure != empty state)" '! cmp -s "$OUT_A" "$OUT_C"'
sed 's/^/    C| /' "$OUT_C"

# ══ ARM D — MUTATION: put the transport echo back, arm A must go green ═════
echo
echo "ARM D · MUTATION: the pre-fix 'post … && printf ✓' shape on arm A's fixture"
MUT="$TMP/install-prefix.sh"
# Verbatim shape of origin/main lines 19-33 before this change.
cat > "$MUT" <<'PREFIX'
#!/bin/sh
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
PREFIX
# The pre-fix script resolves its payloads relative to its own dir; give it the
# real ones so the only difference from the subject is the CLAIM shape.
mkdir -p "$TMP/schemas"
cp "$REPO/templates/place-directory/schemas/place.json" "$TMP/schemas/place.json"
cp "$REPO/templates/place-directory/seed-places.json" "$TMP/seed-places.json"
LOG_D="$TMP/d.log"; OUT_D="$TMP/d.out"; : > "$LOG_D"
RC_D="$(run_installer empty "$MUT" "$OUT_D" "$LOG_D")"
check "D fixture: the same empty-state shim served the mutation" 'grep -q "curl(empty)" "$LOG_D"'
check "D fixture: the mutation issued both POSTs" '[ "$(grep -c "post=1" "$LOG_D")" = 2 ]'
check "D fixture: the mutation issued NO read-back GET" '[ "$(grep -c "post=0" "$LOG_D")" = 0 ]'
check "D (RED without the fix): the pre-fix shape exits 0 on the empty fixture" '[ "$RC_D" = 0 ]'
check "D (RED without the fix): it prints '✓ schema upserted' over an empty store" 'grep -q "✓ schema upserted" "$OUT_D"'
check "D (RED without the fix): it prints '✓ places written' over an empty store" 'grep -q "✓ places written" "$OUT_D"'
check "D vs A: the SAME fixture greens the old shape and reds the new one" '[ "$RC_D" = 0 ] && [ "$RC_A" != 0 ]'
sed 's/^/    D| /' "$OUT_D"

echo
if [ "$fails" -eq 0 ]; then
  echo "place-directory-install.test.sh: ALL CHECKS PASSED"
  exit 0
fi
echo "place-directory-install.test.sh: $fails CHECK(S) FAILED"
exit 1
