#!/usr/bin/env bash
# Offline harness for the DIAGNOSTIC half of
# scripts/pds-live-hetzner-placement-group.sh — the sentence a failed project
# read hands a human, and what the run leaves behind in /tmp.
#
# No credential, no network, not one live write: every arm drives the runner's
# own `--selftest-probe` entry point (which runs the REAL fence_or_refuse and the
# REAL cleanup trap) against a stub `bp` this file writes.
#
# WHAT IT PINS (pds-w31-hzread-swallows-stderr)
#
#   THE DEFECT, REPLAYED. hz_read folds bp's stdout AND stderr into the artifact
#   file (`>"$out" 2>&1`), so when a read fails the file holds bp's actual
#   sentence — `bp: hetzner: rate limited (429)`. Nothing printed it.
#   read_failure_reason could name only the directory:
#
#     the `bp cloud hetzner placement-group list` read exited non-zero
#     (see the artifact dir /tmp/pds-live-w30.41234 for what bp said)
#
#   A human reading CLEANUP UNVERIFIED in a terminal had to go find a /tmp
#   directory to learn WHY the project could not be read. Arms 1-4 below are RED
#   against origin/main's script for exactly that reason, which is also how to
#   run them: pass the old script as $1.
#
#   THE NEEDLE CANNOT BE FAKED. The stub chooses a sentence that appears in no
#   source file in this repo, and the arm demands it in the RUNNER'S output. No
#   hardcoded message can satisfy it — only quoting the receipt can.
#
#   THE ARTIFACT DIR NOW HAS A RULE. It used to accumulate one
#   /tmp/pds-live-w30.<pid> per run, forever, because the dir was the only place
#   the bytes lived. Arms 5-7: a clean exit removes the dir it created, a
#   non-zero exit KEEPS it and prints the path, and a dir handed in from outside
#   is never removed (the --selftest children share the parent's).
#
#   NON-VACUITY. Arm 8 is the positive control: the healthy cleanup path still
#   exits 0 and still says it verified itself. An instrument that started
#   refusing everything would pass arms 1-4 and fail here.
#
# Usage: scripts/pds-live-hetzner-placement-group_test.sh [script-under-test]
# Exit 0 = every arm passed. 1 = at least one arm failed, named.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="${1:-$REPO_ROOT/scripts/pds-live-hetzner-placement-group.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails + 1)); }

[ -f "$SUT" ] || { printf 'pds-live-hetzner-placement-group_test: the gate is pointed at nothing — %s does not exist\n' "$SUT" >&2; exit 1; }
grep -q 'selftest-probe' "$SUT" || { printf 'pds-live-hetzner-placement-group_test: %s has no --selftest-probe entry point — refusing to run arms against a script this harness cannot drive\n' "$SUT" >&2; exit 1; }

# ── the stub bp ─────────────────────────────────────────────────────────────
# It answers the first $STUB_HONEST_READS list reads with ONE reserved-prefix
# group present and degrades every read after that — the shape of a 429 arriving
# BETWEEN the delete and the verify. STUB_SAY is what it screams on stderr, and
# hz_read is what decides whether anybody ever sees it.
STUB="$TMP/bp"
cat >"$STUB" <<'STUBEOF'
#!/bin/sh
C="${STUB_STATE:-/dev/null}"
n=$(cat "$C" 2>/dev/null || echo 0)
case "$*" in
  *"placement-group list"*)
    n=$((n+1)); echo "$n" >"$C"
    if [ "$n" -le "${STUB_HONEST_READS:-1}" ]; then
      printf '{"placement_groups":[{"id":42,"name":"%sORPHAN","type":"spread"}]}\n' "$STUB_PREFIX"
      exit 0
    fi
    case "${STUB_MODE:-clean}" in
      nokey)  echo "${STUB_SAY:-{\"ok\":true}}"; exit 0 ;;
      rcfail) echo "${STUB_SAY:-bp: hetzner: boom}" >&2; exit 1 ;;
      *)      echo '{"placement_groups":[]}'; exit 0 ;;
    esac
    ;;
  *"placement-group delete"*)
    echo '{"ok":true,"action":"delete","confirmed_gone":true}'; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

EMPTY="$TMP/empty-home"; mkdir -p "$EMPTY"
N=0
OUT=""
RC=0

# probe PROBE ART MODE HONEST SAY — sets $OUT (the captured output) and $RC.
# NOT a command substitution: $OUT has to survive into the assertion, and a
# `probe …; rc="$RC"` would set it in a subshell and lose it.
probe() {
  local pr="$1" art="$2" mode="$3" honest="$4" say="$5"
  N=$((N + 1))
  OUT="$TMP/out.$N"
  env -i "PATH=$PATH" "HOME=$EMPTY" "PDS_LIVE_BP=$STUB" "PDS_LIVE_ART=$art" \
      "STUB_STATE=$TMP/counter.$N" "STUB_PREFIX=pds-live-w30-" \
      "STUB_MODE=$mode" "STUB_HONEST_READS=$honest" "STUB_SAY=$say" \
      "$SUT" --selftest-probe "$pr" >"$OUT" 2>&1
  RC=$?
}

# A sentence no file in this repo contains. If it reaches the runner's output it
# was READ BACK OUT OF THE RECEIPT — there is no other route.
SAY_RC='bp: hetzner: rate limited (429) HARNESS-NEEDLE-8831'
SAY_SHAPE='{"ok":true,"trace":"HARNESS-NEEDLE-9942"}'

printf 'pds-live-hetzner-placement-group_test: subject = %s\n' "$SUT"
printf '\nA FAILED READ MUST QUOTE WHAT BP SAID, NOT WHERE TO GO LOOK\n'

probe fence "$TMP/a1" rcfail 0 "$SAY_RC"; rc="$RC"
if [ "$rc" = "3" ] && grep -q 'HARNESS-NEEDLE-8831' "$OUT"; then
  ok "1. fence refusal (rc=3) carries bp's own stderr sentence"
else
  bad "1. fence refusal quotes bp's stderr" "rc=$rc, needle $(grep -c 'HARNESS-NEEDLE-8831' "$OUT") hit(s). Got: $(tr '\n' ' ' <"$OUT" | cut -c1-260)"
fi

probe cleanup "$TMP/a2" rcfail 1 "$SAY_RC"; rc="$RC"
if [ "$rc" != "0" ] && grep -q 'CLEANUP UNVERIFIED' "$OUT" && grep -q 'HARNESS-NEEDLE-8831' "$OUT"; then
  ok "2. CLEANUP UNVERIFIED (rc=$rc) carries bp's own stderr sentence"
else
  bad "2. CLEANUP UNVERIFIED quotes bp's stderr" "rc=$rc, needle $(grep -c 'HARNESS-NEEDLE-8831' "$OUT") hit(s). Got: $(tr '\n' ' ' <"$OUT" | cut -c1-260)"
fi

# The WRONG-SHAPE half is the other return code (2). It already named the law;
# it never showed the body that broke it.
probe fence "$TMP/a3" nokey 0 "$SAY_SHAPE"; rc="$RC"
if [ "$rc" = "3" ] && grep -q 'AN EXIT CODE ALONE IS NOT SUCCESS' "$OUT" && grep -q 'HARNESS-NEEDLE-9942' "$OUT"; then
  ok "3. wrong-shape refusal names the law AND shows the receipt that broke it"
else
  bad "3. wrong-shape refusal shows the receipt" "rc=$rc, needle $(grep -c 'HARNESS-NEEDLE-9942' "$OUT") hit(s). Got: $(tr '\n' ' ' <"$OUT" | cut -c1-260)"
fi

# …and the reason must not be a PATH where a sentence belongs. This is the arm
# that states the defect in its own words rather than only by its symptom.
probe cleanup "$TMP/a4" rcfail 1 "$SAY_RC"; rc="$RC"
if grep -q 'bp said:' "$OUT"; then
  ok "4. the failure reason uses the preflight's own 'bp said:' vocabulary"
else
  bad "4. the failure reason says 'bp said:'" "rc=$rc, got: $(tr '\n' ' ' <"$OUT" | cut -c1-260)"
fi

printf '\nTHE ARTIFACT DIR HAS A RULE INSTEAD OF A PILE\n'

A5="$TMP/a5-green"
probe cleanup "$A5" clean 1 "$SAY_RC"; rc="$RC"
if [ "$rc" = "0" ] && [ ! -d "$A5" ]; then
  ok "5. a clean exit REMOVES the artifact dir it created"
else
  bad "5. clean exit removes its artifact dir" "rc=$rc, dir still present: $([ -d "$A5" ] && echo yes || echo no)"
fi

A6="$TMP/a6-red"
probe cleanup "$A6" rcfail 1 "$SAY_RC"; rc="$RC"
if [ "$rc" != "0" ] && [ -d "$A6" ] && grep -q "artifacts KEPT: $A6" "$OUT"; then
  ok "6. a non-zero exit KEEPS the artifact dir and prints its path"
else
  bad "6. non-zero exit keeps + announces the artifact dir" "rc=$rc, dir present: $([ -d "$A6" ] && echo yes || echo no), announced: $(grep -c 'artifacts KEPT' "$OUT")"
fi

# The one that makes arm 5 safe. --selftest hands its children PDS_LIVE_ART
# pointed at the PARENT'S dir; a child that reaped it would delete the stubs and
# counters the parent is still driving.
A7="$TMP/a7-borrowed"; mkdir -p "$A7"; : >"$A7/parent-owned-file"
probe cleanup "$A7" clean 1 "$SAY_RC"; rc="$RC"
if [ "$rc" = "0" ] && [ -f "$A7/parent-owned-file" ]; then
  ok "7. an artifact dir handed in from outside is NEVER reaped"
else
  bad "7. a borrowed artifact dir survives" "rc=$rc, parent's file present: $([ -f "$A7/parent-owned-file" ] && echo yes || echo no)"
fi

printf '\nTHE POSITIVE CONTROL — a runner that refused everything would pass the above\n'

A8="$TMP/a8"
probe cleanup "$A8" clean 1 "$SAY_RC"; rc="$RC"
if [ "$rc" = "0" ] && grep -q 'cleanup verified by re-read' "$OUT" && grep -q 'confirmed_gone=true' "$OUT"; then
  ok "8. the healthy path still deletes the orphan and still verifies itself at rc=0"
else
  bad "8. healthy cleanup still passes" "rc=$rc, got: $(tr '\n' ' ' <"$OUT" | cut -c1-260)"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'pds-live-hetzner-placement-group_test: PASS (8 arms: 4 diagnostic, 3 artifact-dir, 1 positive control)\n'
  exit 0
fi
printf 'pds-live-hetzner-placement-group_test: FAIL — %s arm(s)\n' "$fails"
exit 1
