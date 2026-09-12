#!/usr/bin/env bash
# claim-health-selftest.sh — prove claim-health.sh DISCRIMINATES, both arms,
# and prove each check would RED if disarmed (task-f79e39f4992749a5 c1 + c3).
#
# A reader that returns everything passes a one-arm test. A check that reads
# nothing passes everything. So every arm here has a mutation twin: the check
# is run against data engineered to make it fire, and again against the same
# data with the discriminator (or the reconciliation) REMOVED, and the run
# fails unless the first fired and the second did not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/claim-health.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n     %s\n' "$1" "${2:-}"; }

row() { # doc_id worker session origin
  printf '{"doc_id":"%s","content":{"claim":{"worker":"%s","epoch":1%s%s}}}' \
    "$1" "$2" \
    "$( [ -n "$3" ] && printf ',"session":"%s"' "$3" )" \
    "$( [ -n "$4" ] && printf ',"session_origin":"%s"' "$4" )"
}

# ── FIXTURE: two sessions of ONE lane, each holding one row, no collision ────
cat > "$TMP/two.json" <<EOF
[$(row task-aaa lead-cli s_1111111111111111 s_1111111111111111),
 $(row task-bbb lead-cli s_2222222222222222 s_2222222222222222)]
EOF
# The SAME fixture with the discriminator removed — the pre-fix ledger.
cat > "$TMP/two-disarmed.json" <<EOF
[$(row task-aaa lead-cli "" ""), $(row task-bbb lead-cli "" "")]
EOF

# ARM 1 — TWO IDENTITIES IN ONE LANE, each write attributed to the right one.
A="$("$CH" --worker lead-cli --from-file "$TMP/two.json" --session s_1111111111111111 --json)"
B="$("$CH" --worker lead-cli --from-file "$TMP/two.json" --session s_2222222222222222 --json)"
a_ids="$(printf '%s' "$A" | python3 -c 'import json,sys;print(",".join(r["doc_id"] for r in json.load(sys.stdin)["attributed"]))')"
b_ids="$(printf '%s' "$B" | python3 -c 'import json,sys;print(",".join(r["doc_id"] for r in json.load(sys.stdin)["attributed"]))')"
if [ "$a_ids" = "task-aaa" ] && [ "$b_ids" = "task-bbb" ]; then
  ok "arm 1: two sessions of lane lead-cli attributed correctly (s_1111->task-aaa, s_2222->task-bbb)"
else
  bad "arm 1: two sessions of one lane" "s_1111 saw [$a_ids], s_2222 saw [$b_ids]"
fi

# ARM 1 MUTATION — strip claim.session. The reader must NOT still attribute:
# with no discriminator it can only return the whole lane, which is the exact
# pre-fix behaviour this row exists to end.
M="$("$CH" --worker lead-cli --from-file "$TMP/two-disarmed.json" --session s_1111111111111111 --json)"
m_ids="$(printf '%s' "$M" | python3 -c 'import json,sys;print(",".join(r["doc_id"] for r in json.load(sys.stdin)["attributed"]))')"
m_un="$(printf '%s' "$M" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["unattributed"]))')"
if [ -z "$m_ids" ] && [ "$m_un" = "2" ]; then
  ok "arm 1 mutation: discriminator removed -> 0 attributed, 2 rows named UNATTRIBUTED (no silent pass)"
else
  bad "arm 1 mutation" "attributed=[$m_ids] unattributed=$m_un — a disarmed reader still attributed"
fi

# ARM 2 — ONE IDENTITY TWICE returns the SAME set. A reader whose answer moves
# between two reads of one identity is not attributing, it is guessing.
A2="$("$CH" --worker lead-cli --from-file "$TMP/two.json" --session s_1111111111111111 --json)"
if [ "$A" = "$A2" ]; then
  ok "arm 2: one identity read twice returned a byte-identical set (no collision reported)"
else
  bad "arm 2: one identity twice" "the two reads differ"
fi

# POSITIVE CONTROL — the alarm can fire on data it does not own. Same reader,
# a row whose last writer is NOT its origin.
cat > "$TMP/collide.json" <<EOF
[$(row task-ccc lead-cli s_2222222222222222 s_1111111111111111)]
EOF
"$CH" --worker lead-cli --from-file "$TMP/collide.json" >"$TMP/c.out" 2>&1; rc=$?
if [ "$rc" = 3 ] && grep -q "SESSION COLLISION task-ccc" "$TMP/c.out"; then
  ok "positive control: a same-lane two-session lease is REPORTED (exit 3, names task-ccc)"
else
  bad "positive control: collision" "exit=$rc out=$(cat "$TMP/c.out")"
fi

# NEGATIVE CONTROL — it must stay SILENT when the sessions genuinely match, or
# it is an alarm nobody will keep.
"$CH" --worker lead-cli --from-file "$TMP/two.json" >"$TMP/q.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && ! grep -q "SESSION COLLISION" "$TMP/q.out"; then
  ok "negative control: matching sessions stay silent (exit 0)"
else
  bad "negative control" "exit=$rc out=$(cat "$TMP/q.out")"
fi

# COLLISION MUTATION — strip the discriminator from the colliding row. The
# alarm must go quiet, proving the report was READ OFF THE FIELD and is not a
# constant the check prints regardless.
cat > "$TMP/collide-disarmed.json" <<EOF
[$(row task-ccc lead-cli "" "")]
EOF
"$CH" --worker lead-cli --from-file "$TMP/collide-disarmed.json" >"$TMP/cd.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && ! grep -q "SESSION COLLISION" "$TMP/cd.out"; then
  ok "collision mutation: field removed -> alarm goes quiet (the report reads the field, not a constant)"
else
  bad "collision mutation" "exit=$rc out=$(cat "$TMP/cd.out")"
fi

# ── HELD-FILE RECONCILIATION, BOTH DIRECTIONS ───────────────────────────────
printf 'task-bbb\ntask-zzz  # a row this worker no longer holds\n' > "$TMP/held.txt"
"$CH" --worker lead-cli --from-file "$TMP/two.json" --held "$TMP/held.txt" >"$TMP/h.out" 2>&1; rc=$?
if [ "$rc" = 3 ] \
   && grep -q "HELD-FILE GAP task-aaa" "$TMP/h.out" \
   && grep -q "HELD-FILE STALE task-zzz" "$TMP/h.out"; then
  ok "held file: BOTH directions named (task-aaa claimed but unprotected; task-zzz protected but not held)"
else
  bad "held file both directions" "exit=$rc out=$(cat "$TMP/h.out")"
fi

# HELD-FILE MUTATION — disarm the reconciliation by not passing --held. The
# same claimed-but-unprotected row must then go UNDETECTED, which is precisely
# the measured failure (task-f0e49432f1653c2f) and proves the check, not the
# fixture, is what catches it.
"$CH" --worker lead-cli --from-file "$TMP/two.json" >"$TMP/hm.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && ! grep -q "HELD-FILE GAP" "$TMP/hm.out"; then
  ok "held-file mutation: reconciliation disarmed -> the gap goes undetected (the check is what finds it)"
else
  bad "held-file mutation" "exit=$rc out=$(cat "$TMP/hm.out")"
fi

# HELD-FILE POSITIVE CONTROL — a file that agrees with the ledger is silent.
printf 'task-aaa\ntask-bbb\n' > "$TMP/held-ok.txt"
"$CH" --worker lead-cli --from-file "$TMP/two.json" --held "$TMP/held-ok.txt" >"$TMP/ho.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && ! grep -q "HELD-FILE" "$TMP/ho.out"; then
  ok "held-file negative control: an agreeing file is silent (exit 0)"
else
  bad "held-file negative control" "exit=$rc out=$(cat "$TMP/ho.out")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
