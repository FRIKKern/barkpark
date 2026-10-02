#!/usr/bin/env bash
# Production smoke test for the media platform (Phases 1–5).
#
# PRINCIPAL GATE (task-226f1718bb56d489, 2026-09-11). Until this slice the only
# thing between `bash scripts/media-smoke.sh` and a REAL write on the PROD box
# was the operator's shell: BASE defaults to http://89.167.28.206 and TOKEN to
# whatever $BARKPARK_TOKEN happens to hold. The FIRST judgement this script made
# was the upload POST's own status — by which time the write had landed. A
# stale-but-valid token wrote prod media, silently and successfully.
#
# So before the first write the run now asserts, in this order:
#
#   1. the PARSED hostname of $BASE equals the host this smoke DECLARES
#      ($MEDIA_SMOKE_EXPECT_HOST, default 89.167.28.206 — the same box $BASE
#      defaults to, so the default pairing is coherent and any OTHER target must
#      be named deliberately on BOTH variables). Asserted BEFORE any request, so
#      an undeclared host is never even probed. A substring match would not do:
#      `case $BASE in *89.167*` also accepts http://89.167.28.206.evil.example.
#   2. the credential's auth_tier, read off GET $BASE/v1/capabilities with the
#      very bearer the writes will carry, is a WRITING tier. /v1/capabilities
#      answers a read-only caller perfectly well, so the refusal is made on the
#      receipt's SHAPE, never on its rc — the stance of
#      scripts/demo-living-values.sh's `"auth_tier":"admin"` check and of
#      scripts/cmux-smoke.sh's whoami gate (PR #17717).
#
# Both refusals and the positive control are proven OFFLINE:
#
#   scripts/media-smoke.sh --selftest
#
# EXIT: 0 pass · 1 an assertion FAILED · 2 usage · 3 REFUSED (principal gate) ·
#       4 CANNOT READ (the capabilities receipt could not be taken or parsed).
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bp-curl.sh"   # 429 backoff, shared (task-ca8fffa7ca885413)
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/principal-gate.sh"  # writing-tier + declared-host (task-226f1718bb56d489)

SELFTEST=0
case "${1:-}" in
  --selftest) SELFTEST=1 ;;
  "") : ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac

TOKEN="${BARKPARK_TOKEN:-barkpark-dev-token}"
BASE="${BARKPARK_BASE:-http://89.167.28.206}"
AUTH=(-H "Authorization: Bearer $TOKEN")

# The host this smoke DECLARES. Overridable so a local or staging box can be
# named — but never silently: an unset override means the prod media box, and a
# mismatch is a refusal, not a warning.
EXPECT_HOST="${MEDIA_SMOKE_EXPECT_HOST:-89.167.28.206}"

refuse()      { printf 'REFUSED: %s\n' "$*" >&2; exit 3; }
cannot_read() { printf 'CANNOT READ: %s\n' "$*" >&2; exit 4; }

pass=0
fail=0

ok() { echo "✓ $1"; pass=$((pass + 1)); }
bad() { echo "✗ $1"; fail=$((fail + 1)); }

# =============================================================================
# --selftest — the principal gate, proven OFFLINE (task-226f1718bb56d489).
#
# Three arms, each a full re-exec of THIS script against a FAKE curl that
# records every request it is given (METHOD + URL) to a log file. The assertion
# that matters is never the exit code alone: it is the exit code BESIDE the
# recorded argv. A gate that refused AFTER issuing the upload would show rc!=0
# and a POST in the log, and that is precisely the failure this harness exists
# to catch — so the refusing arms assert ZERO recorded POSTs, and the POSITIVE
# CONTROL asserts the opposite, that the first POST IS reached on a good
# principal. Without that control a script that refused unconditionally would
# pass both refusing arms and the suite would prove nothing.
#
# Each arm also asserts its OWN PRECONDITION — whether the capabilities probe
# argv is present — so a child that died before ever reaching the gate cannot
# pass as a vacuous zero. `lib/bp-curl.sh` invokes `curl` BY NAME (`command
# curl`), which is what makes the stub reachable; no network, no token.
# =============================================================================
selftest() {
  local root st_pass=0 st_fail=0
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  st_ok()  { echo "  ✓ $1"; st_pass=$((st_pass + 1)); }
  st_bad() { echo "  ✗ $1"; st_fail=$((st_fail + 1)); }

  # arm LABEL TIER BASE_URL DECLARED_HOST EXPECT_WRITES(yes|no) EXPECT_RC(zero|nonzero) PROBE_REACHED(yes|no)
  arm() {
    local label="$1" tier="$2" base="$3" declared="$4" want_writes="$5" want_rc="$6" probe="$7"
    local bin log out rc=0 n
    bin="$(mktemp -d "${TMPDIR:-/tmp}/ms-selftest.XXXXXX")"
    log="$bin/argv.log"; out="$bin/run.out"
    : >"$log"

    # THE FAKE curl. It RECORDS FIRST and answers second, so a request that
    # reaches it is in the log even when the answer is a failure. It speaks
    # bp-curl's contract: body to the -o file, http_code on stdout.
    cat >"$bin/curl" <<FAKE
#!/usr/bin/env bash
dest=""; url=""; method="GET"; prev=""
for a in "\$@"; do
  case "\$prev" in -o|--output) dest="\$a" ;; -X|--request) method="\$a" ;; esac
  case "\$a" in http://*|https://*) url="\$a" ;; esac
  prev="\$a"
done
printf '%s %s\n' "\$method" "\$url" >> "$log"
case "\$url" in
  */v1/capabilities) body='{"auth_tier":"$tier"}' ;;
  *) body='{"id":"fake-id","filename":"fake.png","result":{"thumbnailUrl":"u","previewUrl":"u","originalUrl":"u","renditions":{"thumb":{}},"total":1,"hits":[{}],"token":"share-tok"}}' ;;
esac
[ -n "\$dest" ] && printf '%s' "\$body" > "\$dest"
printf '200'
exit 0
FAKE
    chmod +x "$bin/curl"

    env -i PATH="$bin:/usr/bin:/bin" HOME="$bin" TMPDIR="$bin" \
        BARKPARK_BASE="$base" BARKPARK_TOKEN="selftest-token" \
        MEDIA_SMOKE_EXPECT_HOST="$declared" \
        bash "$root/scripts/media-smoke.sh" >"$out" 2>&1 || rc=$?

    n="$(/usr/bin/grep -c '^POST ' "$log" 2>/dev/null || true)"
    case "$want_rc" in
      nonzero) if [ "$rc" -ne 0 ]; then st_ok "$label: exit $rc (non-zero)"; else st_bad "$label: exit 0 — the gate did NOT refuse"; fi ;;
      zero)    st_ok "$label: exit $rc (a fake curl cannot complete the live smoke; the write-reached assertion below is this arm's subject)" ;;
    esac
    case "$want_writes" in
      no)  if [ "$n" -eq 0 ]; then st_ok "$label: ZERO write requests recorded (read back from the fixture's own log)"; else st_bad "$label: $n POST(s) recorded — the refusal came TOO LATE"; fi ;;
      yes) if [ "$n" -gt 0 ]; then st_ok "$label: $n write request(s) recorded — the first POST IS reached on a good principal"; else st_bad "$label: ZERO writes recorded — the gate refuses unconditionally, so the refusing arms prove nothing"; fi ;;
    esac
    if [ "$want_rc" = nonzero ]; then
      if /usr/bin/grep -q '^REFUSED: ' "$out"; then st_ok "$label: the refusal NAMES itself on stderr (REFUSED:)"; else st_bad "$label: exited non-zero with no REFUSED: line"; fi
    fi
    # THE PRECONDITION, asserted rather than assumed: a child that died before
    # it ever reached the gate would ALSO record zero writes — a vacuous pass.
    case "$probe" in
      yes) if /usr/bin/grep -q '^GET .*/v1/capabilities$' "$log"; then st_ok "$label: the capabilities receipt WAS taken (probe argv recorded) — this arm reached the gate"; else st_bad "$label: no capabilities probe in the log — the child died earlier, so this arm measured nothing"; fi ;;
      no)  if /usr/bin/grep -q '^GET .*/v1/capabilities$' "$log"; then st_bad "$label: the capabilities probe ran — this arm must refuse on the HOST, before any request"; else st_ok "$label: refused on the declared host before ANY request (no probe argv at all)"; fi ;;
    esac
    rm -rf "$bin"
  }

  echo "=== media-smoke --selftest: the principal gate, offline ==="
  echo ""
  echo "--- arm 1: WRONG TIER (auth_tier=none, declared host matches) ---"
  arm "wrong-tier"  "none"  "http://media.declared.test" "media.declared.test" no  nonzero yes
  echo ""
  echo "--- arm 2: UNDECLARED HOST (writing tier, BASE points somewhere else) ---"
  arm "wrong-host"  "admin" "http://evil.example"        "media.declared.test" no  nonzero no
  echo ""
  echo "--- arm 3: SUBSTRING LOOKALIKE (a *host* match would accept this one) ---"
  arm "host-lookalike" "admin" "http://media.declared.test.evil.example" "media.declared.test" no nonzero no
  echo ""
  echo "--- arm 4: POSITIVE CONTROL (auth_tier=admin, declared host) ---"
  arm "good-principal" "admin" "http://media.declared.test" "media.declared.test" yes zero yes
  echo ""
  echo "=== SELFTEST: $st_pass passed, $st_fail failed ==="
  [ "$st_fail" -eq 0 ]
}

if [ "$SELFTEST" = "1" ]; then
  selftest
  exit $?
fi

# =============================================================================
# THE PRINCIPAL GATE — mandatory, and FIRST. Nothing below it has written yet:
# the first write is the upload POST in the "=== Upload ===" block.
# =============================================================================
echo "=== Principal gate ==="
pg_host_matches "$EXPECT_HOST" "$BASE" || refuse "BARKPARK_BASE is '$BASE' (host '$(pg_url_host "$BASE")'), but this smoke declares host '$EXPECT_HOST'. It uploads media, mutates production documents, mints a share link and checks an asset out — it will not do that to a server it was not pointed at. Set BARKPARK_BASE and MEDIA_SMOKE_EXPECT_HOST together, deliberately. Nothing has been written."
GATE_TIER="$(pg_capabilities_tier "$BASE" "$TOKEN")" || cannot_read "GET $BASE/v1/capabilities did not answer with a parseable receipt, so this run cannot know whose media library it is about to write. Nothing has been written."
pg_writer_tier "$GATE_TIER" || refuse "the credential in \$BARKPARK_TOKEN resolves to auth_tier=\"${GATE_TIER:-<absent>}\" on $BASE, which is not a writing tier. Note that /v1/capabilities answers a read-only caller too — this refusal is made on the receipt's SHAPE, not on its status. Nothing has been written."
ok "principal gate: auth_tier=$GATE_TIER (writing) · host=$(pg_url_host "$BASE") == declared $EXPECT_HOST"

# 1x1 PNG
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
echo "$PNG_B64" | base64 -d > /tmp/bp-smoke-test.png

echo "=== Upload ==="
UPLOAD=$(bp_curl_body -s -X POST "$BASE/media/upload" "${AUTH[@]}" -F "file=@/tmp/bp-smoke-test.png;type=image/png")
MEDIA_ID=$(echo "$UPLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
FILENAME=$(echo "$UPLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin)['filename'])")
echo "id=$MEDIA_ID"
sleep 1

echo ""
echo "=== v1 detail + delivery URLs ==="
DETAIL=$(bp_curl_body -s "$BASE/v1/media/production/$MEDIA_ID?appendRequestSecret=true" "${AUTH[@]}")
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
SEARCH=$(bp_curl_body -s "$BASE/v1/media/production/search?limit=5" "${AUTH[@]}")
TOTAL=$(echo "$SEARCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['total'])")
if [ "$TOTAL" -ge 1 ]; then ok "search total=$TOTAL"; else bad "search total=$TOTAL"; fi

echo ""
echo "=== Collections ==="
COLL_ID="smoke-col-$(date +%s)"
bp_curl_body -s -X POST "$BASE/v1/data/mutate/production" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"mutations\":[{\"create\":{\"_type\":\"mediaCollection\",\"_id\":\"$COLL_ID\",\"title\":\"Smoke Folder\",\"kind\":\"folder\",\"slug\":\"$COLL_ID\"}},{\"publish\":{\"id\":\"$COLL_ID\",\"type\":\"mediaCollection\"}}]}" > /dev/null

if bp_curl_body -s -X POST "$BASE/v1/media/production/collections/$COLL_ID/members" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"assetId\":\"$MEDIA_ID\"}" > /dev/null; then
  ok "add collection member"
else
  bad "add collection member"
fi

ASSETS=$(bp_curl_body -s "$BASE/v1/media/production/collections/$COLL_ID/assets" "${AUTH[@]}")
COUNT=$(echo "$ASSETS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']['hits']))")
if [ "$COUNT" -ge 1 ]; then ok "collection assets count=$COUNT"; else bad "collection assets"; fi

echo ""
echo "=== Share link ==="
SHARE=$(bp_curl_body -s -X POST "$BASE/v1/media/production/collections/$COLL_ID/share" "${AUTH[@]}")
TOKEN_SHARE=$(echo "$SHARE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['token'])")
PUBLIC=$(bp_curl_code -s -o /dev/null "$BASE/v1/media/production/share/$TOKEN_SHARE")
if [ "$PUBLIC" = "200" ]; then ok "public share link"; else bad "public share HTTP $PUBLIC"; fi

echo ""
echo "=== Governance ==="
if bp_curl_body -s -X POST "$BASE/v1/media/production/$MEDIA_ID/checkout" "${AUTH[@]}" > /dev/null; then
  ok "checkout"
else bad "checkout"; fi
if bp_curl_body -s -X POST "$BASE/v1/media/production/$MEDIA_ID/undo-checkout" "${AUTH[@]}" > /dev/null; then
  ok "undo-checkout"
else bad "undo-checkout"; fi

echo ""
echo "=== Serve + rendition ==="
ORIG=$(bp_curl_code -s -o /dev/null "$BASE/media/files/2026/05/$FILENAME")
THUMB=$(bp_curl_code -s -o /dev/null "$BASE/media/renditions/$MEDIA_ID/thumb")
if [ "$ORIG" = "200" ]; then ok "serve original"; else bad "serve original HTTP $ORIG"; fi
if [ "$THUMB" = "200" ]; then ok "serve thumb rendition"; else bad "serve thumb HTTP $THUMB"; fi

# cleanup
bp_curl_body -s -X DELETE "$BASE/v1/media/production/collections/$COLL_ID/share" "${AUTH[@]}" > /dev/null 2>&1 || true
bp_curl_body -s -X DELETE "$BASE/media/$MEDIA_ID" "${AUTH[@]}" > /dev/null || true

echo ""
echo "=== SMOKE: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
