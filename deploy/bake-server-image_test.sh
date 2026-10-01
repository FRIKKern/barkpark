#!/usr/bin/env bash
# bake-server-image_test.sh — the warm-image bake's SKIP decision, offline.
#
# WHY THIS EXISTS. bake-server-image.sh used to skip on code drift alone: a
# bake whose commit matched origin/main, or whose drift touched only
# box-irrelevant paths, exited 0 however old the snapshot was. The snapshot's
# apt index rots with TIME, not with code — a superseded package point-release
# turns an old index into 404s on the next provision (task-3678bc75656f9a41).
# The age ceiling (BAKE_MAX_AGE_DAYS, default 7) makes both skip arms defer to
# the snapshot's age.
#
# HOW. hcloud, curl and flock are stubbed on PATH; the stubs read their
# answers from env vars and record every call in a log. `hcloud server create`
# — the first irreversible step of a real bake — exits 97, so a case that
# DECIDES to bake stops there with a recognisable code and a recorded call,
# and no case can reach a network or a box.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${BAKE_SCRIPT_UNDER_TEST:-$HERE/bake-server-image.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ran=0
pass() { ran=$((ran + 1)); echo "  ok: $1"; }
fail() { ran=$((ran + 1)); fails=$((fails + 1)); echo "  FAIL: $1"; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/hcloud" <<'STUB'
#!/usr/bin/env bash
echo "hcloud $*" >>"$STUB_CALLS"
case "$1 $2" in
  "image list") printf '%s' "$STUB_IMAGES_JSON" ;;
  "server create") exit 97 ;;
  *) exit 0 ;;
esac
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_CALLS"
for a in "$@"; do
  case "$a" in
    */commits/main) printf '{"sha":"%s"}' "$STUB_MAIN_SHA"; exit 0 ;;
    */compare/*) printf '%s' "$STUB_COMPARE_JSON"; exit 0 ;;
  esac
done
exit 22
STUB
cat >"$TMP/bin/flock" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/"*
touch "$TMP/key"

iso_days_ago() {
  python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=int(sys.argv[1]),hours=1)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))' "$1"
}

images_json() { # $1 = created stamp, $2 = commit label
  printf '[{"id":111,"status":"available","created":"%s","labels":{"role":"warm-image","commit":"%s"}}]' "$1" "$2"
}

INERT_COMPARE='{"files":[{"filename":"docs/x.md"},{"filename":"cloud/lib/a.ex"},{"filename":"web/app.tsx"}]}'

# run_case <name> <images_json> <main_sha> <compare_json> [extra env...]
# Sets RC, OUT and CALLS for the assertions that follow.
run_case() {
  local name="$1" imgs="$2" main="$3" cmp="$4"
  shift 4
  : >"$TMP/calls"
  OUT="$(env PATH="$TMP/bin:$PATH" STUB_CALLS="$TMP/calls" STUB_IMAGES_JSON="$imgs" \
    STUB_MAIN_SHA="$main" STUB_COMPARE_JSON="$cmp" \
    BARKPARK_SSH_KEY=stub-key BARKPARK_SSH_KEY_FILE="$TMP/key" BAKE_LOCK_FILE="$TMP/bake.lock" "$@" \
    bash "$SCRIPT" 2>&1)"
  RC=$?
  CALLS="$(cat "$TMP/calls")"
  echo "case: $name (rc=$RC)"
}

baked() { [ "$RC" = 97 ] && printf '%s' "$CALLS" | grep -q '^hcloud server create'; }
skipped() { [ "$RC" = 0 ] && ! printf '%s' "$CALLS" | grep -q '^hcloud server create'; }

# 1. A fresh bake at main's commit: nothing to do (the old behaviour, kept).
run_case "fresh + current" "$(images_json "$(iso_days_ago 1)" abc)" abc "$INERT_COMPARE"
if skipped && printf '%s' "$OUT" | grep -q 'bake is current'; then pass "a 1-day-old current bake is skipped"; else fail "a 1-day-old current bake is skipped — $OUT"; fi

# 2. A fresh bake whose drift is box-irrelevant: still skipped (kept).
run_case "fresh + inert drift" "$(images_json "$(iso_days_ago 1)" abc)" def "$INERT_COMPARE"
if skipped && printf '%s' "$OUT" | grep -q 'box-irrelevant'; then pass "a 1-day-old bake with inert drift is skipped"; else fail "a 1-day-old bake with inert drift is skipped — $OUT"; fi

# 3. THE ROW: an old bake at main's commit is REBAKED.
run_case "old + current" "$(images_json "$(iso_days_ago 10)" abc)" abc "$INERT_COMPARE"
if baked && printf '%s' "$OUT" | grep -q 'rebaking regardless of code drift'; then pass "a 10-day-old current bake is rebaked (age ceiling)"; else fail "a 10-day-old current bake is rebaked (age ceiling) — $OUT"; fi

# 4. THE ROW: an old bake with only inert drift is REBAKED.
run_case "old + inert drift" "$(images_json "$(iso_days_ago 10)" abc)" def "$INERT_COMPARE"
if baked; then pass "a 10-day-old bake with inert drift is rebaked"; else fail "a 10-day-old bake with inert drift is rebaked — $OUT"; fi

# 5. The ceiling boundary: exactly MAX_AGE_DAYS old is stale.
run_case "age == ceiling" "$(images_json "$(iso_days_ago 7)" abc)" abc "$INERT_COMPARE"
if baked; then pass "a bake exactly 7 days old is rebaked"; else fail "a bake exactly 7 days old is rebaked — $OUT"; fi

# 6. The ceiling is configurable: BAKE_MAX_AGE_DAYS=30 keeps a 10-day bake.
run_case "old + raised ceiling" "$(images_json "$(iso_days_ago 10)" abc)" abc "$INERT_COMPARE" BAKE_MAX_AGE_DAYS=30
if skipped; then pass "BAKE_MAX_AGE_DAYS=30 keeps a 10-day-old current bake"; else fail "BAKE_MAX_AGE_DAYS=30 keeps a 10-day-old current bake — $OUT"; fi

# 7. An unreadable `created` is STALE, never a reason to keep a rotting image.
run_case "unreadable age" "$(images_json "not-a-date" abc)" abc "$INERT_COMPARE"
if baked; then pass "an unreadable snapshot age rebakes"; else fail "an unreadable snapshot age rebakes — $OUT"; fi

echo
if [ "$ran" -lt 7 ]; then
  echo "  FAIL: harness non-vacuity — only $ran checks ran (expected 7)"
  fails=$((fails + 1))
fi
echo "checks run: $ran"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
