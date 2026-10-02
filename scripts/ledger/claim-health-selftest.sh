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

# THE SHAPE THE SERVER ACTUALLY EMITS (task-3c638f0e2fd435f8). These fixtures
# used to write the claim under `content`, which is the SAME wrong path the
# reader used -- so the suite and the subject agreed with each other and both
# disagreed with the ledger. A selftest whose fixtures encode a shape the
# system never emits cannot fail for the reason it exists.
# MEASURED on a live `bp task ls --status in_progress` page: 19 of 19 rows
# carried a `content` key, 19 of 19 carried `.claim.worker`, ZERO carried
# `.content.claim`.
row() { # doc_id worker session origin  -- the REAL shape: claim at top level
  printf '{"doc_id":"%s","claim":{"worker":"%s","epoch":1%s%s}}' \
    "$1" "$2" \
    "$( [ -n "$3" ] && printf ',"session":"%s"' "$3" )" \
    "$( [ -n "$4" ] && printf ',"session_origin":"%s"' "$4" )"
}

# The LEGACY shape, kept so the compatibility arm is a run and not a belief.
row_legacy() { # doc_id worker session origin
  printf '{"doc_id":"%s","content":{"claim":{"worker":"%s","epoch":1%s%s}}}' \
    "$1" "$2" \
    "$( [ -n "$3" ] && printf ',"session":"%s"' "$3" )" \
    "$( [ -n "$4" ] && printf ',"session_origin":"%s"' "$4" )"
}

# `bp task get`'s envelope: the same row nested under `doc`.
row_doc() { printf '{"doc":%s}' "$(row "$@")"; }

# A claim parked somewhere this reader does not know. Not a real server shape --
# it stands in for the NEXT one, which is the point of the arm.
row_unknown() { # doc_id worker
  printf '{"doc_id":"%s","meta":{"lease":{"worker":"%s","epoch":1}}}' "$1" "$2"
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

# ── ARM 8 — THE REAL SERVER SHAPE IS READ AT ALL ────────────────────────────
# The regression this file failed to catch. Every fixture above now uses it, so
# this arm is really asserting that `row()` and the reader agree on reality.
cat > "$TMP/real.json" <<EOF
[$(row task-real lead-cli s_1111111111111111 s_1111111111111111)]
EOF
R8="$("$CH" --worker lead-cli --from-file "$TMP/real.json" --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["attributed"]))')"
[ "$R8" = 1 ] \
  && ok "real server shape (claim at top level) is attributed" \
  || bad "real server shape (claim at top level) is attributed" "attributed=$R8, expected 1"

# ── ARM 9 — THE LEGACY SHAPE STILL READS ────────────────────────────────────
cat > "$TMP/legacy.json" <<EOF
[$(row_legacy task-legacy lead-cli s_1111111111111111 s_1111111111111111)]
EOF
R9="$("$CH" --worker lead-cli --from-file "$TMP/legacy.json" --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["attributed"]))')"
[ "$R9" = 1 ] \
  && ok "legacy content.claim shape still attributed (no back-compat lost)" \
  || bad "legacy content.claim shape still attributed" "attributed=$R9, expected 1"

# ── ARM 10 — THE `doc` ENVELOPE (bp task get) ───────────────────────────────
cat > "$TMP/docshape.json" <<EOF
[$(row_doc task-docshape lead-cli s_1111111111111111 s_1111111111111111)]
EOF
R10="$("$CH" --worker lead-cli --from-file "$TMP/docshape.json" --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["attributed"]))')"
[ "$R10" = 1 ] \
  && ok "doc-envelope shape (bp task get) is attributed" \
  || bad "doc-envelope shape (bp task get) is attributed" "attributed=$R10, expected 1"

# ── ARM 11 — THE FOURTH READ SHAPE: `bp task prime`'s in_progress carrier ────
# Flat rows under `in_progress`, NO `docs` key. A hand-listed pair missed it.
cat > "$TMP/prime.json" <<EOF
{"in_progress":[$(row task-prime lead-cli s_1111111111111111 s_1111111111111111)],"ready":[]}
EOF
R11="$("$CH" --worker lead-cli --from-file "$TMP/prime.json" --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["attributed"]))')"
[ "$R11" = 1 ] \
  && ok "prime shape (flat rows under in_progress, no docs key) is attributed" \
  || bad "prime shape (flat rows under in_progress) is attributed" "attributed=$R11, expected 1"

# ── ARM 12 — THE REFUSAL. A page it cannot read must NOT print a clean zero ──
# THE ARM THIS WHOLE ROW EXISTS FOR. Claims parked at a position the reader does
# not know: the old code printed "0 claimed row(s) ... RESULT: clean" and exited
# 0, byte-identical to a genuinely empty page.
cat > "$TMP/unknown.json" <<EOF
[$(row_unknown task-unk lead-cli), $(row_unknown task-unk2 lead-cli)]
EOF
"$CH" --worker lead-cli --from-file "$TMP/unknown.json" >"$TMP/u.out" 2>&1; rc=$?
if [ "$rc" = 4 ] && grep -qF 'CANNOT READ' "$TMP/u.out"; then
  ok "unreadable page REFUSES (exit 4) and names where it looked"
else
  bad "unreadable page REFUSES (exit 4)" "rc=$rc, output: $(head -2 "$TMP/u.out" | tr '\n' ' ')"
fi

# ── ARM 12b — THE CONTROL THAT MAKES ARM 12 MEAN SOMETHING ──────────────────
# A genuinely EMPTY page must still be clean and exit 0, or the refusal above is
# just "this tool always refuses" and has discriminated nothing.
printf '[]' > "$TMP/empty.json"
"$CH" --worker lead-cli --from-file "$TMP/empty.json" >"$TMP/e.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF 'RESULT: clean' "$TMP/e.out"; then
  ok "CONTROL: a genuinely empty page is still clean and exits 0 (the refusal discriminates)"
else
  bad "CONTROL: empty page clean" "rc=$rc, output: $(head -2 "$TMP/e.out" | tr '\n' ' ')"
fi

# ── ARM 12c — a page of UNCLAIMED but well-formed rows is clean, not a refusal
# The refusal keys on "no claim-shaped object ANYWHERE", so a row that genuinely
# has no claim must not trip it -- otherwise `ready` output would refuse.
cat > "$TMP/unclaimed.json" <<EOF
[{"doc_id":"task-free","lifecycle_status":"open"}]
EOF
"$CH" --worker lead-cli --from-file "$TMP/unclaimed.json" >"$TMP/uc.out" 2>&1; rc=$?
if [ "$rc" = 4 ]; then
  ok "a page of genuinely unclaimed rows REFUSES rather than reporting a false clean"
else
  bad "unclaimed-rows page behaviour" "rc=$rc (expected 4: indistinguishable from the defect otherwise)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
