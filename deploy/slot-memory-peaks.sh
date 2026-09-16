#!/usr/bin/env bash
# slot-memory-peaks.sh — sample and PERSIST the blue/green slots' cgroup memory
# peaks, so a census cannot silently lose a restarted slot.
#
# WHY THIS EXISTS (the defect it closes)
# -------------------------------------
# systemd's `MemoryPeak` / `MemorySwapPeak` are PER INVOCATION: they reset every
# time the unit starts, and a STOPPED unit reads 0 (or `[not set]`). Both are
# true of a blue/green box by construction — every deploy stops one slot and
# starts the other. So any census built on a live `systemctl show` reads
#
#     barkpark-slot@blue  MemorySwapPeak=0          <- stopped, not "never swapped"
#     barkpark-slot@green MemorySwapPeak=1397293875 <- this invocation only
#
# and reports a fleet-wide swap peak that is "whatever the last restart left
# behind". That is not a measurement, it is a sampling artefact, and every
# number derived from it (a proposed bound, a headroom claim, a regression
# check) inherits it.
#
# The fix is a MONOTONIC FOLD held outside the unit's lifetime: sample the live
# counters, take max(stored, live) per unit, and write the result to a state
# file on disk. A restart drops the live counter to 0; max() keeps the stored
# all-time peak. The state file survives the unit, the deploy, and the reboot.
#
# WHAT IT DOES NOT DO — READ THIS BEFORE YOU SET A BOUND
# -----------------------------------------------------
# This script MEASURES. It sets no resource directive and writes no unit file.
# That is deliberate: the deploy-reliability charter's D118 rules that
# `MemorySwapMax` ON THE SERVING SLOT IS FORBIDDEN — the serving BEAM is the
# box's designated global-OOM victim, and a cgroup bound makes it die sooner, at
# a boundary, instead of later, at the kernel's choosing. D118 names the
# per-build transient units (`bp-site-build-*.service`) as the only sanctioned
# place for a memory lever. Nothing here contradicts that, and nothing here may
# be used to route around it.
#
# THE PLACEMENT DECISION, IF A SLOT BOUND IS EVER UNPARKED (arithmetic, not taste)
# -------------------------------------------------------------------------------
# It belongs on the PARENT SLICE, `system-barkpark\x2dslot.slice`, never on the
# per-slot unit. A blue/green cutover runs BOTH BEAMs at once (8m30s of overlap
# measured on guerrilla), so a per-UNIT cap of V permits 2V against ONE swapfile:
#
#     swapfile                       2,047 MB
#     green slot MemorySwapPeak      1,332.6 MB
#     candidate ratchet  1332.6*1.05 1,399.2 MB  -> 1,400 MB
#     per-UNIT at 1,400 MB, cutover  2,800 MB    -> 137% of the swapfile. UNSOUND.
#     per-SLICE at 1,400 MB          1,400 MB    -> 68.4% of the swapfile,
#                                                   647 MB left for non-slot demand.
#
# One number, both slots, cutover-safe. This is the written decision the row
# `dr-bl-w6-memoryswapmax-not-memoryhigh` asked for; the SETTING of it stays
# refused under D118. The peak this script persists is the input that decision
# would need, and it is the reason the input has to be persisted at all.
#
# USAGE
#     bash deploy/slot-memory-peaks.sh --sample      # fold live counters into the state
#     bash deploy/slot-memory-peaks.sh --report      # print the persisted census
#     bash deploy/slot-memory-peaks.sh --self-test   # offline proof (fake systemctl)
#
# Environment (dev + self-test knobs only; a box uses the defaults):
#     BARKPARK_SLOT_PEAKS_STATE   state file path (default /opt/barkpark/.slots/memory-peaks.tsv)
#     BARKPARK_SLOT_PEAKS_UNITS   space-separated units to sample
set -euo pipefail

STATE_FILE="${BARKPARK_SLOT_PEAKS_STATE:-/opt/barkpark/.slots/memory-peaks.tsv}"
# The slice is sampled alongside the slots on purpose: during a cutover it is
# the only counter that sees BOTH BEAMs at once, which is exactly the quantity
# the placement decision above turns on.
DEFAULT_UNITS='barkpark-slot@blue.service barkpark-slot@green.service system-barkpark\x2dslot.slice'
UNITS="${BARKPARK_SLOT_PEAKS_UNITS:-$DEFAULT_UNITS}"

# systemd prints an unset/unsupported counter as the u64 max, or as the literal
# `[not set]`. Both mean "no reading", and neither is a peak — folding either in
# would pin every unit at 18 exabytes forever.
U64_MAX='18446744073709551615'

log() { printf '%s\n' "$*" >&2; }

# numeric_or_zero <raw> — normalise one systemctl property value to a count of
# bytes we are willing to fold. Anything that is not a plain decimal, and the
# u64 sentinel, read as 0 (= "contributes nothing"), never as a peak.
numeric_or_zero() {
  case "$1" in
    '' | *[!0-9]* ) printf '0' ;;
    "$U64_MAX"    ) printf '0' ;;
    *             ) printf '%s' "$1" ;;
  esac
}

max_of() {
  # max_of <a> <b> — decimal max, both already normalised.
  if [ "$1" -ge "$2" ] 2>/dev/null; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# show_prop <unit> <property> — one systemctl property, empty on any failure.
# A unit that does not exist is not an error here: a box that has never run the
# green slot must still produce a census.
#
# NO PIPE, DELIBERATELY. This read
#
#     { systemctl show "$1" -p "$2" 2>/dev/null || true; } | sed -n "s/^$2=//p" | head -n1
#
# until 2026-09-16, and `head -n1` is a TRUNCATING reader: it closes the pipe
# after the first line, the producer takes SIGPIPE, and under this script's
# `set -o pipefail` the pipeline's status becomes 141 — a `set -e` abort that
# has nothing to do with the property being read. `scripts/pipefail-sigpipe-scan.sh`
# flags exactly that shape at HIGH confidence, and it was the site that broke
# the ratchet (113 -> 114).
#
# The remedy removes the pipe instead of masking its status: capture once, match
# in the shell. The EXTRACTED VALUE IS UNCHANGED and that is the whole point —
# the first line whose prefix is `<property>=`, with that prefix stripped, and
# the empty string when systemctl fails, does not know the unit, or does not
# report the property. ARM 10 of --self-test pins each of those behaviours.
show_prop() {
  local raw line
  raw=$(systemctl show "$1" -p "$2" 2>/dev/null) || raw=''
  [ -n "$raw" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$2="*) printf '%s\n' "${line#"$2"=}"; return 0 ;;
    esac
  done <<<"$raw"
  return 0
}

state_lookup() {
  # state_lookup <unit> <column-index> — read one persisted field, empty if the
  # unit has no row yet.
  [ -f "$STATE_FILE" ] || return 0
  awk -F'\t' -v u="$1" -v c="$2" '$1 == u { print $c; exit }' "$STATE_FILE"
}

cmd_sample() {
  local dir tmp unit
  dir=$(dirname "$STATE_FILE")
  mkdir -p "$dir"
  tmp="${STATE_FILE}.tmp.$$"
  : >"$tmp"

  for unit in $UNITS; do
    local live_peak live_swap invocation active stored_peak stored_swap stored_inv samples
    live_peak=$(numeric_or_zero "$(show_prop "$unit" MemoryPeak)")
    live_swap=$(numeric_or_zero "$(show_prop "$unit" MemorySwapPeak)")
    invocation=$(show_prop "$unit" InvocationID)
    active=$(show_prop "$unit" ActiveState)
    [ -n "$invocation" ] || invocation='-'
    [ -n "$active" ] || active='unknown'

    stored_peak=$(numeric_or_zero "$(state_lookup "$unit" 3)")
    stored_swap=$(numeric_or_zero "$(state_lookup "$unit" 4)")
    stored_inv=$(state_lookup "$unit" 5)
    samples=$(numeric_or_zero "$(state_lookup "$unit" 8)")

    # THE FOLD. This max() is the whole mechanism: it is what makes a restart
    # (live counter -> 0) and a stop (live counter -> 0) lossless. Replace it
    # with a plain assignment and the state file becomes a slow copy of the
    # same sampling artefact the live read already is.
    local all_peak all_swap restarted
    all_peak=$(max_of "$stored_peak" "$live_peak")
    all_swap=$(max_of "$stored_swap" "$live_swap")

    restarted='no'
    if [ -n "$stored_inv" ] && [ "$stored_inv" != '-' ] && [ "$stored_inv" != "$invocation" ]; then
      restarted='yes'
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$unit" "$active" "$all_peak" "$all_swap" "$invocation" "$live_peak" "$live_swap" \
      "$((samples + 1))" >>"$tmp"

    if [ "$restarted" = 'yes' ]; then
      log "slot-memory-peaks: $unit restarted (invocation changed); all-time swap peak held at $all_swap bytes"
    fi
  done

  mv "$tmp" "$STATE_FILE"
  cmd_report
}

cmd_report() {
  if [ ! -f "$STATE_FILE" ]; then
    log "slot-memory-peaks: no state at $STATE_FILE — run --sample first"
    return 1
  fi
  printf 'unit\tactive\tpeak_alltime\tswap_peak_alltime\tinvocation\tpeak_this_invocation\tswap_peak_this_invocation\tsamples\n'
  cat "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Offline self-test. No systemd, no box: a fake `systemctl` on PATH replays a
# scripted lifetime (running -> restart -> stopped) and the assertions read the
# persisted state. Every assertion is shown non-vacuous by MUTATING the engine.
# ---------------------------------------------------------------------------
CHECKS=0
FAILURES=0
check() {
  # check <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

selftest_fake_systemctl() {
  # Writes a fake `systemctl` that answers from $FAKEDIR/<unit>.props.
  cat >"$FAKEDIR/systemctl" <<'FAKE'
#!/usr/bin/env bash
# fake systemctl: `systemctl show <unit> -p <prop>` -> lookup in a props file.
unit=""
prop=""
while [ $# -gt 0 ]; do
  case "$1" in
    show) : ;;
    -p) prop="$2"; shift ;;
    *) [ -z "$unit" ] && unit="$1" ;;
  esac
  shift
done
f="$BARKPARK_FAKE_SYSTEMD_DIR/$(printf '%s' "$unit" | tr '/\\' '__').props"
[ -f "$f" ] || exit 1
sed -n "s/^$prop=/$prop=/p" "$f"
FAKE
  chmod +x "$FAKEDIR/systemctl"
}

selftest_set_unit() {
  # selftest_set_unit <unit> <active> <peak> <swappeak> <invocation>
  local f
  f="$BARKPARK_FAKE_SYSTEMD_DIR/$(printf '%s' "$1" | tr '/\\' '__').props"
  {
    printf 'ActiveState=%s\n' "$2"
    printf 'MemoryPeak=%s\n' "$3"
    printf 'MemorySwapPeak=%s\n' "$4"
    printf 'InvocationID=%s\n' "$5"
  } >"$f"
}

selftest_col() {
  # selftest_col <unit> <column> — read a field back from the persisted state.
  awk -F'\t' -v u="$1" -v c="$2" '$1 == u { print $c; exit }' "$STATE_FILE"
}

# Drives one full lifetime against whatever copy of this script $ENGINE names,
# and returns the persisted all-time swap peak for the green slot.
selftest_drive_lifetime() {
  local engine="$1"
  rm -f "$STATE_FILE"
  # 1. green running, swap peak 1,332.6 MB (the guerrilla reading).
  selftest_set_unit 'barkpark-slot@green.service' active 767557632 1397293875 INV-A
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@green.service' \
    bash "$engine" --sample >/dev/null 2>&1
  # 2. THE RESTART. New invocation, counters reset to 0 — exactly what a deploy
  #    does, and exactly the read that loses the peak without the fold.
  selftest_set_unit 'barkpark-slot@green.service' active 0 0 INV-B
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@green.service' \
    bash "$engine" --sample >/dev/null 2>&1
  selftest_col 'barkpark-slot@green.service' 4
}

cmd_selftest() {
  local root
  root=$(mktemp -d)
  # shellcheck disable=SC2064  # $root must expand now, not at trap time.
  trap "rm -rf '$root'" EXIT
  FAKEDIR="$root/bin"
  BARKPARK_FAKE_SYSTEMD_DIR="$root/units"
  export BARKPARK_FAKE_SYSTEMD_DIR
  mkdir -p "$FAKEDIR" "$BARKPARK_FAKE_SYSTEMD_DIR"
  STATE_FILE="$root/peaks.tsv"
  selftest_fake_systemctl

  local self
  self="${BASH_SOURCE[0]}"

  # --- ARM 1: the peak SURVIVES a restart -----------------------------------
  check 'a pre-restart swap peak survives the restart' \
    '1397293875' "$(selftest_drive_lifetime "$self")"

  # --- ARM 2: the same arm REDS when the fold is reverted -------------------
  # A verification that cannot fail proves nothing, so the mutation is run:
  # replace the monotonic max with the live read and assert the peak is LOST.
  local mutant="$root/mutant.sh"
  sed 's|^ *all_swap=.*max_of.*$|    all_swap="${live_swap}"|' "$self" >"$mutant"
  local mutated
  mutated=$(grep -c '^    all_swap="\${live_swap}"$' "$mutant" || true)
  check 'the mutation actually applied (the fold line was found)' '1' "$mutated"
  check 'reverting the fold LOSES the pre-restart peak (arm 1 is non-vacuous)' \
    '0' "$(selftest_drive_lifetime "$mutant")"

  # --- ARM 3: a STOPPED slot does not clobber the stored peak ---------------
  # The failed blue slot reads MemorySwapPeak=0 because it is stopped. That is
  # the read the row named; it must be quiet, not destructive.
  rm -f "$STATE_FILE"
  selftest_set_unit 'barkpark-slot@blue.service' active 900000000 800000000 INV-C
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@blue.service' bash "$self" --sample >/dev/null 2>&1
  selftest_set_unit 'barkpark-slot@blue.service' inactive 0 0 INV-C
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@blue.service' bash "$self" --sample >/dev/null 2>&1
  check 'a stopped slot reading 0 keeps the stored swap peak' \
    '800000000' "$(selftest_col 'barkpark-slot@blue.service' 4)"
  check 'a stopped slot reading 0 keeps the stored RSS peak' \
    '900000000' "$(selftest_col 'barkpark-slot@blue.service' 3)"
  check 'the stopped state is recorded, not hidden' \
    'inactive' "$(selftest_col 'barkpark-slot@blue.service' 2)"
  check 'the live (this-invocation) reading is reported separately from the all-time one' \
    '0' "$(selftest_col 'barkpark-slot@blue.service' 7)"

  # --- ARM 4: the QUIET arm — a lower live reading changes nothing ----------
  # The fold must not be a ratchet that also moves DOWN, and a re-sample of an
  # unchanged unit must leave the peaks alone (only the sample count moves).
  selftest_set_unit 'barkpark-slot@blue.service' active 10 20 INV-C
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@blue.service' bash "$self" --sample >/dev/null 2>&1
  check 'a LOWER live reading does not lower the stored swap peak' \
    '800000000' "$(selftest_col 'barkpark-slot@blue.service' 4)"
  check 'the sample count still advances' '3' "$(selftest_col 'barkpark-slot@blue.service' 8)"

  # --- ARM 5: the u64 sentinel and `[not set]` are not peaks ----------------
  rm -f "$STATE_FILE"
  selftest_set_unit 'barkpark-slot@green.service' active "$U64_MAX" '[not set]' INV-D
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@green.service' bash "$self" --sample >/dev/null 2>&1
  check 'the u64 sentinel is not folded in as an 18-exabyte peak' \
    '0' "$(selftest_col 'barkpark-slot@green.service' 3)"
  check '`[not set]` is not folded in as a peak' \
    '0' "$(selftest_col 'barkpark-slot@green.service' 4)"

  # --- ARM 6: a unit systemd does not know at all is survivable -------------
  rm -f "$STATE_FILE"
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@nosuch.service' bash "$self" --sample >/dev/null 2>&1
  check 'an unknown unit still produces a census row' \
    'unknown' "$(selftest_col 'barkpark-slot@nosuch.service' 2)"

  # --- ARM 7: the slice is sampled by default -------------------------------
  # The cutover quantity is the SLICE's, and a default that omitted it would
  # make the placement decision above unmeasurable on a real box.
  local slice_in_defaults='no'
  case "$DEFAULT_UNITS" in
    *'system-barkpark\x2dslot.slice'*) slice_in_defaults='yes' ;;
  esac
  check 'the parent slice is in the default unit set' 'yes' "$slice_in_defaults"

  # --- ARM 8: --report refuses rather than printing an empty census ---------
  rm -f "$STATE_FILE"
  local rc=0
  BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" bash "$self" --report >/dev/null 2>&1 || rc=$?
  check '--report with no state exits non-zero instead of printing nothing' '1' "$rc"

  # --- ARM 10: show_prop's EXTRACTION, pinned behaviour-by-behaviour --------
  # show_prop lost its `| sed | head -n1` pipeline on 2026-09-16 (the head was a
  # truncating reader: SIGPIPE -> 141 under pipefail). A fix that silenced the
  # scanner by changing WHAT the function returns would be worse than the red,
  # so each of the four behaviours the old pipeline had is asserted directly,
  # against the fake systemctl, and then shown non-vacuous by a mutation.
  rm -f "$STATE_FILE"
  selftest_set_unit 'barkpark-slot@green.service' active 767557632 1397293875 INV-A
  check 'show_prop strips the property prefix and returns the bare value' \
    'INV-A' "$( PATH="$FAKEDIR:$PATH"; show_prop 'barkpark-slot@green.service' InvocationID )"
  check 'show_prop returns empty for a property the unit does not report' \
    '' "$( PATH="$FAKEDIR:$PATH"; show_prop 'barkpark-slot@green.service' NoSuchProperty )"
  check 'show_prop returns empty (not an error) when systemctl does not know the unit' \
    '' "$( PATH="$FAKEDIR:$PATH"; show_prop 'barkpark-slot@nosuch.service' ActiveState )"

  # A value that itself contains `=`, and a property reported TWICE: the old
  # `sed | head -n1` kept the first line whole after the first `=`; so must this.
  {
    printf 'ActiveState=active\n'
    printf 'InvocationID=first=WITH=EQUALS\n'
    printf 'InvocationID=second\n'
  } >"$BARKPARK_FAKE_SYSTEMD_DIR/barkpark-slot@multi.service.props"
  check 'show_prop keeps a value containing `=` intact and takes only the FIRST match' \
    'first=WITH=EQUALS' "$( PATH="$FAKEDIR:$PATH"; show_prop 'barkpark-slot@multi.service' InvocationID )"

  # The mutation: drop the prefix strip. If the four checks above were vacuous
  # this would still read back clean; it must not.
  local spmutant="$root/show-prop-mutant.sh"
  sed 's|\${line#"\$2"=}|${line}|' "$self" >"$spmutant"
  local sp_mutated
  sp_mutated=$(grep -c 'printf .* "\${line}"; return 0' "$spmutant" || true)
  check 'the show_prop mutation actually applied (the prefix-strip was found)' '1' "$sp_mutated"
  rm -f "$STATE_FILE"
  PATH="$FAKEDIR:$PATH" BARKPARK_SLOT_PEAKS_STATE="$STATE_FILE" \
    BARKPARK_SLOT_PEAKS_UNITS='barkpark-slot@green.service' \
    bash "$spmutant" --sample >/dev/null 2>&1
  check 'dropping the prefix strip CORRUPTS the extracted value (ARM 10 is non-vacuous)' \
    'InvocationID=INV-A' "$(selftest_col 'barkpark-slot@green.service' 5)"

  # --- ARM 9: the published count is READ BACK ------------------------------
  # deploy/README.md publishes this engine's check count in prose. Direction
  # matters and is the same as the site engines': the README number is the
  # ASSERTED value and the RUN is the truth, so this guard only ever READS the
  # README — a guard that learned its expected value from the thing it guards
  # would be inert. It is the LAST check, so the number it compares against is
  # this run's total INCLUDING itself. Skips when the README is absent (a box
  # may ship the engine without the docs tree).
  local readme readme_hits readme_count
  readme="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)/README.md"
  if [ ! -f "$readme" ]; then
    printf 'skip README count guard: no %s\n' "$readme"
  else
    local re='deploy/slot-memory-peaks\.sh --self-test[^0-9]{1,12}[0-9]+ checks'
    readme_hits=$(grep -oE "$re" "$readme" | wc -l | tr -d ' ')
    if [ "$readme_hits" != 1 ]; then
      check "README carries exactly ONE count anchor (found $readme_hits; restore \`deploy/slot-memory-peaks.sh --self-test ... <N> checks\` on ONE line)" \
        '1' "$readme_hits"
    else
      readme_count=$(grep -oE "$re" "$readme" | sed -E 's/.*[^0-9]([0-9]+) checks$/\1/')
      check "deploy/README.md's published count matches this run (README says $readme_count; the RUN is the truth — update the README in the SAME commit)" \
        "$((CHECKS + 1))" "$readme_count"
    fi
  fi

  printf '\n%d checks, %d failures\n' "$CHECKS" "$FAILURES"
  [ "$FAILURES" -eq 0 ]
}

case "${1:---report}" in
  --sample)    cmd_sample ;;
  --report)    cmd_report ;;
  --self-test) cmd_selftest ;;
  -h | --help)
    sed -n '/^# USAGE/,/^# *BARKPARK_SLOT_PEAKS_UNITS/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    log "slot-memory-peaks: unknown argument '$1' (--sample | --report | --self-test)"
    exit 2
    ;;
esac
