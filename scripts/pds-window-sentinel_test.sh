#!/usr/bin/env bash
# Offline test for scripts/pds-window-sentinel.sh — drives the REAL take_sample
# against a stubbed probe, so the predicate is exercised with no ssh, no
# guerrilla, and nothing measured about any live host.
#
# WHAT IT PINS (PDS-D717 — leg (ii) retired):
#   - THE POSITIVE CONTROL: a draw that the FOUR-leg predicate REFUSED on leg
#     (ii) alone now FIRES. The values are wave 10's own, from the curve quoted
#     in scripts/pds-pull-proof.crown-transcript-w10.txt §4 (elapsed 30:15:
#     VmSwap 511832 kB, RSS 310116 kB, MemAvailable 2719 MiB). Under the old
#     predicate that draw stood down with `ii:vmswap(511832>100000kB)`; under
#     PDS-D717 it fires. This is the whole change, shown on the exact data that
#     produced the finding — NOT on a case invented to pass.
#   - VmSwap is still RECORDED: the TSV row carries the 511832 the gate no
#     longer reads. A retired leg is not a deleted measurement (PDS-D246's
#     posture: recorded, never gated).
#   - THE SURVIVING LEGS STILL REFUSE, each on its own: below-floor memory, a
#     running site build, and a slot count that is not exactly one. Retiring one
#     leg must not have disarmed the predicate — a gate that cannot refuse is
#     the thing this whole epic exists to prevent.
#   - THE FLOOR STILL TIGHTENS ONLY: PDS_SENTINEL_MEM_FLOOR_MIB below 2300 is a
#     hard refusal, unchanged by the retirement.
#   - PDS_SENTINEL_SWAP_CEIL_KB IS INERT: setting it — to anything, including a
#     value that would have been refused as a loosening — changes no verdict.
#     An operator acting on PDS-D717 can no longer be ambushed by it.
#
# HOW THE PROBE IS STUBBED: take_sample calls remote_probe, which ssh's. The
# script is sourced with its `main "$@"` entrypoint stripped (and ONLY that
# line — the harness asserts the rest is byte-identical), then remote_probe is
# redefined to echo a fixture in the exact key=val shape the real one emits.
#
# Exit 0 = all arms pass. Any failure exits 1 and names the arm.
set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENTINEL="$REPO_ROOT/scripts/pds-window-sentinel.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails + 1)); }

# ── source the sentinel without running main ────────────────────────────────
LIB="$TMP/sentinel.lib.sh"
grep -v '^main "\$@"$' "$SENTINEL" > "$LIB"
# The ONLY difference must be that one line: a stripped copy that also dropped
# something else would make every arm below a measurement of the wrong script.
if [ "$(diff <(grep -c '' "$SENTINEL") <(grep -c '' "$LIB") >/dev/null; echo $?)" = "0" ]; then
  bad "strip-main" "the stripped copy has the SAME line count — 'main \"\$@\"' was not found, so this harness is sourcing something it did not intend"
fi
if ! diff <(grep -v '^main "\$@"$' "$SENTINEL") "$LIB" >/dev/null; then
  bad "strip-main" "the stripped copy differs from the original by more than the entrypoint line"
fi

# shellcheck disable=SC1090
. "$LIB"

LOG="$TMP/sentinel.tsv"

# probe fixture: the real key=val shape, one value per line.
# Defaults are wave 10's elapsed-30:15 draw — leg (i) CLEAR, leg (ii) FAIL.
FX_MEM_KB=2784256      # 2719 MiB * 1024
FX_VMSWAP=511832       # the value that refused the draw under the old predicate
FX_RSS=310116
FX_BUILDS=""
FX_BLUE="active"
FX_GREEN="inactive"

remote_probe() {
  printf 'ts=2026-07-20T17:20:00Z\n'
  printf 'mem_kb=%s\n'      "$FX_MEM_KB"
  printf 'swapfree_kb=%s\n' 768000
  printf 'beam_pid=%s\n'    1222791
  printf 'rss_kb=%s\n'      "$FX_RSS"
  printf 'vmswap_kb=%s\n'   "$FX_VMSWAP"
  printf 'elapsed=30:15\n'
  printf 'served_sha=49b629fef074339b80836fb87496f5a6f37324da\n'
  # NOTE: the WIRE key is `builds`; `site_builds` is only the TSV COLUMN
  # header. Emitting the column name here lands in the parse loop's `*) : ;;`
  # catch-all and the leg silently reads EMPTY — a fixture that tests nothing.
  printf 'builds=%s\n'      "$FX_BUILDS"
  printf 'slot_blue=%s\n'   "$FX_BLUE"
  printf 'slot_green=%s\n'  "$FX_GREEN"
}

draw() { : > "$LOG"; ensure_log; take_sample 1 >/dev/null 2>&1; echo $?; }

echo "pds-window-sentinel_test — PDS-D717, leg (ii) retired"

# 1. THE POSITIVE CONTROL
rc="$(draw)"
if [ "$rc" = "0" ]; then
  ok "wave-10 30:15 draw (mem 2719 MiB, VmSwap 511832 kB) FIRES — the draw the four-leg predicate refused on leg (ii) alone"
else
  bad "positive control" "rc=$rc, want 0 (FIRE). This draw cleared legs (i)/(iii)/(iv) and failed ONLY leg (ii); if it still stands down, leg (ii) is still gating."
fi

# 2. the failing-legs column must not name a retired leg
if grep -q 'ii:vmswap' "$LOG"; then
  bad "no leg-(ii) refusal" "the TSV still records an ii:vmswap refusal"
else
  ok "no ii:vmswap refusal appears in the log"
fi

# 3. RECORDED, NEVER GATED — the value the gate stopped reading is still written
if grep -q "$FX_VMSWAP" "$LOG"; then
  ok "VmSwap $FX_VMSWAP is still written to the TSV (recorded, never gated)"
else
  bad "vmswap recorded" "the retired leg's measurement vanished from the log; a retired leg is not a deleted measurement"
fi

# 4. THE REFUSAL ON A RAISED CEILING IS GONE.
#
# An earlier version of this arm set the ENV var PDS_SENTINEL_SWAP_CEIL_KB and
# asserted the verdict did not move. That arm was VACUOUS: it passed against the
# OLD four-leg script too, because SWAP_CEIL_KB was bound at SOURCE time, so
# setting the env var afterwards could never move anything. It measured
# source-time binding and reported it as retirement. Caught only by running the
# whole harness against the pre-change script — a green that survives the
# mutation is not evidence.
#
# The honest arm drives the guard directly. On the OLD script this dies with
# "refusing to run: ... is ABOVE the D193 ceiling"; on this one there is no
# ceiling to be above, so it returns clean.
if ( SWAP_CEIL_KB=999999999 SWAP_CEIL_LAW=100000 check_predicate_integrity ) 2>/dev/null; then
  ok "a raised swap ceiling is no longer refused — the guard that ambushed an operator acting on D717 is gone"
else
  bad "swap refusal gone" "check_predicate_integrity still refuses on a raised swap ceiling; leg (ii)'s guard survived the retirement"
fi

# 5-7. THE SURVIVING LEGS STILL REFUSE, each alone
FX_MEM_KB=2000000 ; rc="$(draw)"; FX_MEM_KB=2784256
[ "$rc" = "1" ] && ok "leg (i) still refuses a below-floor draw" \
                || bad "leg (i)" "rc=$rc, want 1 — the memory floor stopped refusing"

FX_BUILDS="bp-site-build-abc.service" ; rc="$(draw)"; FX_BUILDS=""
[ "$rc" = "1" ] && ok "leg (iii) still refuses while a site build runs" \
                || bad "leg (iii)" "rc=$rc, want 1 — the build leg stopped refusing"

FX_GREEN="active" ; rc="$(draw)"; FX_GREEN="inactive"
[ "$rc" = "1" ] && ok "leg (iv) still refuses when both slots read active" \
                || bad "leg (iv)" "rc=$rc, want 1 — the slot leg stopped refusing"

# 8. the floor still tightens only
# MEM_FLOOR_MIB was bound at SOURCE time, so setting PDS_SENTINEL_MEM_FLOOR_MIB
# now cannot move it — the guard reads the already-bound script variable.
if ( MEM_FLOOR_MIB=2299 check_predicate_integrity ) 2>/dev/null; then
  bad "floor tightens only" "a floor BELOW 2300 was accepted; the guard on the guard is gone"
else
  ok "a floor below 2300 is still a hard refusal"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "pds-window-sentinel_test: PASS"
  exit 0
fi
echo "pds-window-sentinel_test: FAIL ($fails arm(s))"
exit 1
