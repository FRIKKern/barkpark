#!/usr/bin/env bash
# check-doc-budgets.sh — CI byte-gates for the doc spine (strategy §5 + A6).
#
# Every cap below is BINDING. On overflow the remedy is documented in the
# failure message: split to the owning contract/runbook or retire content —
# never raise the cap.
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.
#
# Usage:
#   scripts/check-doc-budgets.sh                       # check (CI + merge gate)
#   scripts/check-doc-budgets.sh --regen-onramp-golden # re-pin the onramp span
#   scripts/check-doc-budgets.sh --selftest            # tripwire: prove the gate
#                                                      # REDs on planted bloat
#   scripts/check-doc-budgets.sh --span-only           # the onramp arm alone
#                                                      # (harness use; skips the
#                                                      # fixed caps + card count)
# Exit codes: 0 pass · 1 a budget (or the onramp span pin) failed · 2 bad usage.
#
# NOTHING IN THE ENVIRONMENT CAN LOOSEN THIS GATE. --span-only is an argument,
# not an env var, and DOC_BUDGETS_ONRAMP_SPAN_CAP may only LOWER the span cap.
# Both are pinned by --selftest arms (h) and (i).

set -euo pipefail

# Resolve THIS script's own absolute path BEFORE the cd below. --selftest
# re-invokes the real gate ~14 times as `bash "$SELF"`, and a relative $0
# (`cd scripts && bash check-doc-budgets.sh --selftest`) stops resolving the
# moment we cd to REPO_ROOT — every arm then dies with "No such file or
# directory", a FALSE RED on a legitimate invocation.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(dirname "$(dirname "$SELF")")"
cd "$REPO_ROOT"

# Overridable so --selftest can point the onramp arm at a temp tree and prove
# the pin REDs without planting anything in the real checkout.
ONRAMP_DOC="${DOC_BUDGETS_ONRAMP_DOC:-docs/setup/CODEX.md}"
ONRAMP_GOLDEN="${DOC_BUDGETS_ONRAMP_GOLDEN:-scripts/onramp-span.golden}"
# The excluded span is itself capped: without this, the golden becomes the new
# laundering channel (regenerate it and any amount of bloat is blessed). 4000B
# against a measured 2836B span leaves ~1.2KB of headroom — that headroom IS
# the residual, and the honest closer for it is a Go assertion that the golden
# still contains agentsMDCanonicalBody (out of this script's fence; filed as
# follow-up cgsi-s6-followup-golden-go-assertion).
#
# THE OVERRIDE CAN ONLY TIGHTEN. DOC_BUDGETS_ONRAMP_SPAN_CAP exists so a harness
# can prove the cap bites; letting it RAISE the cap would make one env var in a
# workflow silently bless unbounded span growth — the exact class this gate was
# hardened against. A value above the committed default is clamped back down.
ONRAMP_SPAN_CAP_DEFAULT=4000
ONRAMP_SPAN_CAP="${DOC_BUDGETS_ONRAMP_SPAN_CAP:-$ONRAMP_SPAN_CAP_DEFAULT}"
case "$ONRAMP_SPAN_CAP" in
  ''|*[!0-9]*) ONRAMP_SPAN_CAP="$ONRAMP_SPAN_CAP_DEFAULT" ;;
esac
if [ "$ONRAMP_SPAN_CAP" -gt "$ONRAMP_SPAN_CAP_DEFAULT" ]; then
  ONRAMP_SPAN_CAP="$ONRAMP_SPAN_CAP_DEFAULT"
fi

# 1 = run ONLY the onramp arm (used by --selftest so each planted red is
# attributable to the span pin and not to some unrelated cap). It is an ARGUMENT
# (--span-only), never an environment variable: as `DOC_BUDGETS_SPAN_ONLY=1` it
# skipped ~45 fixed caps AND the 7-card count and still printed a PASS at exit 0,
# so a single job-level `env:` entry — far from the step it disarms — blanked
# most of this gate. As an argument it must appear in the workflow step itself,
# where a reviewer reads it next to the command.
SPAN_ONLY=0

MODE=check
case "${1:-}" in
  "") ;;
  --selftest) MODE=selftest ;;
  --regen-onramp-golden) MODE=regen ;;
  --span-only) SPAN_ONLY=1 ;;
  *)
    echo "check-doc-budgets: unknown argument '$1'" >&2
    echo "usage: check-doc-budgets.sh [--selftest|--regen-onramp-golden|--span-only]" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "check-doc-budgets: too many arguments" >&2
  echo "usage: check-doc-budgets.sh [--selftest|--regen-onramp-golden|--span-only]" >&2
  exit 2
fi

FAIL=0
REMEDY="split to the owning contract/runbook or retire content — never raise the cap"

check_cap() {
  # $1 = path, $2 = byte cap
  local path="$1" cap="$2" size
  if [ ! -f "$path" ]; then
    echo "FAIL: $path is missing (budget-gated file must exist)"
    FAIL=1
    return
  fi
  size=$(wc -c < "$path" | tr -d ' ')
  if [ "$size" -gt "$cap" ]; then
    echo "FAIL: $path is ${size}B, cap is ${cap}B — $REMEDY"
    FAIL=1
  else
    echo "ok:   $path ${size}B <= ${cap}B"
  fi
}

ONRAMP_BEGIN_LN=0
ONRAMP_END_LN=0

onramp_bounds() {
  # $1 = path. Sets ONRAMP_BEGIN_LN / ONRAMP_END_LN, or prints a FAIL line and
  # returns 1. Markers are whole-line-anchored (grep -x): the file also MENTIONS
  # both markers inline in prose (CODEX.md L125), and a loose/substring match
  # would resolve the span to the wrong lines entirely. Exactly one begin/end
  # pair, begin before end — anything else fails LOUD, because a broken pair
  # silently changes what the budget measures.
  local path="$1" begin_ct end_ct
  begin_ct=$(grep -c -x -- '<!-- barkpark:onramp:begin -->' "$path" || true)
  end_ct=$(grep -c -x -- '<!-- barkpark:onramp:end -->' "$path" || true)
  if [ "$begin_ct" -ne 1 ] || [ "$end_ct" -ne 1 ]; then
    echo "FAIL: $path must carry exactly ONE whole-line onramp marker pair" \
         "(found begin=$begin_ct end=$end_ct) —" \
         "the budget exclusion is span-anchored and refuses to guess"
    return 1
  fi
  ONRAMP_BEGIN_LN=$(grep -n -x -- '<!-- barkpark:onramp:begin -->' "$path" | cut -d: -f1)
  ONRAMP_END_LN=$(grep -n -x -- '<!-- barkpark:onramp:end -->' "$path" | cut -d: -f1)
  if [ "$ONRAMP_BEGIN_LN" -ge "$ONRAMP_END_LN" ]; then
    echo "FAIL: $path onramp markers are out of order" \
         "(begin L$ONRAMP_BEGIN_LN, end L$ONRAMP_END_LN)"
    return 1
  fi
  return 0
}

regen_onramp_golden() {
  # Re-pin the excluded span. REVIEW THE DIFF: a red from the pin below must be
  # cleared by reading what changed inside the markers, never by running this
  # and committing the result unread — that is exactly the laundering the pin
  # exists to stop.
  if ! onramp_bounds "$ONRAMP_DOC"; then
    echo "check-doc-budgets --regen-onramp-golden: FAILED — cannot resolve the span"
    return 1
  fi
  sed -n "$((ONRAMP_BEGIN_LN + 1)),$((ONRAMP_END_LN - 1))p" "$ONRAMP_DOC" > "$ONRAMP_GOLDEN"
  echo "regenerated $ONRAMP_GOLDEN ($(wc -c < "$ONRAMP_GOLDEN" | tr -d ' ')B) from $ONRAMP_DOC — READ THE DIFF"
}

check_cap_minus_onramp_span() {
  # $1 = path, $2 = byte cap. Like check_cap, but the onramp marker span —
  # the lines from `<!-- barkpark:onramp:begin -->` through
  # `<!-- barkpark:onramp:end -->` inclusive — does NOT count against the cap:
  # that block is a verbatim copy of the `bp onramp agents-md` canonical body,
  # so it cannot be trimmed to make budget.
  #
  # That premise is CHECKED here, not assumed. Counting and ordering the markers
  # is not enough: the span's CONTENT was unpinned, so three plausible note
  # lines inserted just inside the begin marker took CODEX.md from 11,151B to
  # 14,406B — and 34KB of filler took it to 45,191B — while this gate printed
  # the byte-IDENTICAL counted size and passed. TestOnrampAgentsMdWrapperParity
  # cannot see that: it is strings.Contains over the body WITHOUT the markers,
  # so it is insertion-blind and position-blind by construction.
  #
  # So the span is pinned byte-identically to $ONRAMP_GOLDEN, and capped. One
  # mechanism closes both exploit shapes (in-span insertion AND relocating a
  # marker to swallow prose), because either one changes the excluded bytes.
  local path="$1" cap="$2" size span counted span_bytes bad=0
  if [ ! -f "$path" ]; then
    echo "FAIL: $path is missing (budget-gated file must exist)"
    FAIL=1
    return
  fi
  if [ ! -f "$ONRAMP_GOLDEN" ]; then
    echo "FAIL: $ONRAMP_GOLDEN is missing — the onramp span pin cannot be checked"
    FAIL=1
    return
  fi
  if ! onramp_bounds "$path"; then
    FAIL=1
    return
  fi
  size=$(wc -c < "$path" | tr -d ' ')
  span=$(sed -n "${ONRAMP_BEGIN_LN},${ONRAMP_END_LN}p" "$path" | wc -c | tr -d ' ')
  counted=$((size - span))

  # (1) the excluded span is itself capped — the exclusion is not a blank cheque
  if [ "$span" -gt "$ONRAMP_SPAN_CAP" ]; then
    echo "FAIL: $path onramp span is ${span}B, span cap is ${ONRAMP_SPAN_CAP}B —" \
         "the exclusion is bounded on purpose; shrink the onramp body," \
         "do not widen the exclusion"
    FAIL=1
    bad=1
  fi

  # (2) the excluded span is byte-identical to the committed golden
  if ! sed -n "$((ONRAMP_BEGIN_LN + 1)),$((ONRAMP_END_LN - 1))p" "$path" \
       | cmp -s - "$ONRAMP_GOLDEN"; then
    span_bytes=$(sed -n "$((ONRAMP_BEGIN_LN + 1)),$((ONRAMP_END_LN - 1))p" "$path" | wc -c | tr -d ' ')
    echo "FAIL: $path onramp span (L$((ONRAMP_BEGIN_LN + 1))-L$((ONRAMP_END_LN - 1)), ${span_bytes}B)" \
         "does NOT match $ONRAMP_GOLDEN ($(wc -c < "$ONRAMP_GOLDEN" | tr -d ' ')B) —" \
         "budget-exempt bytes must be the verbatim onramp body. If the onramp body" \
         "legitimately changed, READ the diff, then re-pin with" \
         "scripts/check-doc-budgets.sh --regen-onramp-golden"
    FAIL=1
    bad=1
  fi

  # (3) the original cap, on everything outside the span
  if [ "$counted" -gt "$cap" ]; then
    echo "FAIL: $path is ${counted}B outside the onramp span (${size}B raw), cap is ${cap}B — $REMEDY"
    FAIL=1
  elif [ "$bad" -eq 0 ]; then
    echo "ok:   $path ${counted}B outside the onramp span (${size}B raw, ${span}B span <= ${ONRAMP_SPAN_CAP}B, pinned) <= ${cap}B"
  fi
}

if [ "$MODE" = regen ]; then
  regen_onramp_golden
  exit 0
fi

# --- self-test tripwire ------------------------------------------------------
# Mirrors scripts/tenant-scope-check.sh --selftest: stand up a COPY of the
# onramp-bearing doc in a temp dir, pin it, then prove the span arm REDs on each
# exploit shape. Plants nothing in the real checkout. Runs the onramp arm only
# (--span-only) so every red below is attributable to the pin.
if [ "$MODE" = selftest ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  PRISTINE="$TMP/pristine.md"
  cp "$ONRAMP_DOC" "$PRISTINE"

  export DOC_BUDGETS_ONRAMP_DOC="$TMP/CODEX.md"
  export DOC_BUDGETS_ONRAMP_GOLDEN="$TMP/onramp-span.golden"

  fail_selftest() { echo "check-doc-budgets --selftest: FAILED — $*"; exit 1; }

  cp "$PRISTINE" "$DOC_BUDGETS_ONRAMP_DOC"
  bash "$SELF" --regen-onramp-golden >/dev/null

  # (0) pristine, pinned tree passes
  bash "$SELF" --span-only >/dev/null 2>&1 || fail_selftest "a pristine pinned tree did not pass"

  # (a) three plausible note lines INSIDE the span, no marker moved → must RED
  awk '{ print }
       $0 == "<!-- barkpark:onramp:begin -->" && !planted {
         print "";
         print "> Codex note: prefer the MCP surface when it is available.";
         print "> Codex note: see the internal runbook before editing this block.";
         planted = 1
       }' "$PRISTINE" > "$DOC_BUDGETS_ONRAMP_DOC"
  if bash "$SELF" --span-only >/dev/null 2>&1; then
    fail_selftest "prose inserted INSIDE the onramp span did NOT red the gate"
  fi

  # (b) the SAME plant, legitimately re-pinned → must PASS (the reviewed path)
  bash "$SELF" --regen-onramp-golden >/dev/null
  bash "$SELF" --span-only >/dev/null 2>&1 || fail_selftest "a re-pinned (regenerated golden) span did NOT pass"

  # (c) the end marker relocated to EOF, swallowing the rest of the doc → RED
  cp "$PRISTINE" "$DOC_BUDGETS_ONRAMP_DOC"
  bash "$SELF" --regen-onramp-golden >/dev/null
  grep -v -x -- '<!-- barkpark:onramp:end -->' "$PRISTINE" > "$DOC_BUDGETS_ONRAMP_DOC"
  printf '%s\n' '<!-- barkpark:onramp:end -->' >> "$DOC_BUDGETS_ONRAMP_DOC"
  if bash "$SELF" --span-only >/dev/null 2>&1; then
    fail_selftest "relocating the end marker to EOF did NOT red the gate"
  fi

  # (d) span padded past the span cap AND the golden regenerated → still RED.
  #     This is the bound on the golden-as-laundering-channel: re-pinning blesses
  #     content, never unbounded SIZE.
  awk '{ print }
       $0 == "<!-- barkpark:onramp:begin -->" && !planted {
         for (i = 0; i < 40; i++)
           print "filler filler filler filler filler filler filler filler";
         planted = 1
       }' "$PRISTINE" > "$DOC_BUDGETS_ONRAMP_DOC"
  bash "$SELF" --regen-onramp-golden >/dev/null
  if bash "$SELF" --span-only >/dev/null 2>&1; then
    fail_selftest "a golden larger than the span cap did NOT red the gate"
  fi

  # (e) the golden deleted → RED (the pin cannot be disarmed by removing it)
  cp "$PRISTINE" "$DOC_BUDGETS_ONRAMP_DOC"
  bash "$SELF" --regen-onramp-golden >/dev/null
  rm -f "$DOC_BUDGETS_ONRAMP_GOLDEN"
  if bash "$SELF" --span-only >/dev/null 2>&1; then
    fail_selftest "a MISSING golden did NOT red the gate"
  fi
  bash "$SELF" --regen-onramp-golden >/dev/null

  # (f) both markers removed → RED (pair check, unchanged behaviour)
  grep -v -x -e '<!-- barkpark:onramp:begin -->' -e '<!-- barkpark:onramp:end -->' \
    "$PRISTINE" > "$DOC_BUDGETS_ONRAMP_DOC"
  if bash "$SELF" --span-only >/dev/null 2>&1; then
    fail_selftest "a doc with ZERO onramp markers did NOT red the gate"
  fi

  # (g) an unknown argument exits 2, not 0
  rc=0
  bash "$SELF" --zzz-nonsense >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail_selftest "an unknown argument exited $rc, expected 2"

  # (h) THE OVERRIDE CANNOT BE LOOSENED. Re-run arm (d)'s over-cap span with the
  #     span cap raised through the environment: the clamp must pull it back to
  #     the committed default and the gate must still RED. Without the clamp one
  #     `env:` line blesses an onramp span of any size.
  awk '{ print }
       $0 == "<!-- barkpark:onramp:begin -->" && !planted {
         for (i = 0; i < 40; i++)
           print "filler filler filler filler filler filler filler filler";
         planted = 1
       }' "$PRISTINE" > "$DOC_BUDGETS_ONRAMP_DOC"
  bash "$SELF" --regen-onramp-golden >/dev/null
  if DOC_BUDGETS_ONRAMP_SPAN_CAP=99999999 bash "$SELF" --span-only >/dev/null 2>&1; then
    fail_selftest "DOC_BUDGETS_ONRAMP_SPAN_CAP raised the span cap — the clamp is gone"
  fi
  # …and it can still TIGHTEN, so a harness can prove the cap bites.
  cp "$PRISTINE" "$DOC_BUDGETS_ONRAMP_DOC"
  bash "$SELF" --regen-onramp-golden >/dev/null
  if DOC_BUDGETS_ONRAMP_SPAN_CAP=10 bash "$SELF" --span-only >/dev/null 2>&1; then
    fail_selftest "a LOWERED span cap did not red a span above it"
  fi

  # (i) --span-only is an ARGUMENT, never an env var. The retired
  #     DOC_BUDGETS_SPAN_ONLY=1 skipped ~45 fixed caps and the 7-card count while
  #     printing PASS; a full run must now ignore it entirely.
  #     (captured to a variable, never piped: `cmd | grep -q` closes the pipe
  #     early and pipefail then reports the WRITER's SIGPIPE as a failure — the
  #     exit-code trap this wave audits for.)
  env_out=""
  DOC_BUDGETS_SPAN_ONLY=1 bash "$SELF" >"$TMP/env-run.out" 2>&1 \
    || fail_selftest "the full gate did not pass with DOC_BUDGETS_SPAN_ONLY set"
  env_out="$(cat "$TMP/env-run.out")"
  case "$env_out" in
    *"card count is exactly 7"*) ;;
    *) fail_selftest "DOC_BUDGETS_SPAN_ONLY=1 still skipped the card-count section" ;;
  esac

  # (j) THE FIXED-CAPS TABLE CANNOT GO DARK. Every arm above runs --span-only,
  #     which skips the caps loop entirely — so before this arm existed, a blind
  #     CAPS heredoc passed the whole selftest AND the gate. Unlike the others
  #     this one mutates a COPY OF THIS SCRIPT rather than a fixture tree,
  #     because the corpus at risk IS the script's own data table; there is no
  #     tree to plant in.
  #
  #     EVERY ARM HERE ASSERTS IT ACTUALLY BIT, NOT MERELY THAT THE GATE REDDED.
  #     A gate that reds for an unrelated reason would satisfy a bare exit-code
  #     check while testing nothing — so each case greps for its OWN message,
  #     and the blinding step below is verified to have changed the copy before
  #     the copy is ever run.
  #     THE PROBE RUNS AGAINST A PLANTED GREEN ROOT. This script derives
  #     REPO_ROOT from its own location (`dirname $(dirname "$SELF")`), so a
  #     copy under $TMP/caps-root/scripts/ roots at $TMP/caps-root. The root is
  #     planted GREEN from the script's own data — every caps-table path as a
  #     tiny file, exactly 7 cards — and a CONTROL run of the unmutated copy
  #     must exit 0 there. Only then does an exit code carry per-arm signal:
  #     each mutated probe below must exit 1 for its OWN reason AND print its
  #     OWN message. The previous shape captured output through `|| true` and
  #     asserted only the string — which certifies the utterance, not the
  #     refusal: disarm the ratchet's FAIL=1 and the diagnostic still prints
  #     while the gate exits 0 (an exit code that formats rather than refuses).
  caps_root="$TMP/caps-root"
  mkdir -p "$caps_root/scripts" "$caps_root/docs/cards"
  caps_probe="$caps_root/scripts/caps-probe.sh"
  # Plant every caps-table path (2 bytes each, far under every cap), derived
  # from the table itself so the fixture can never go stale against it.
  while read -r fixture_path _fixture_cap; do
    [ -n "$fixture_path" ] || continue
    mkdir -p "$caps_root/$(dirname "$fixture_path")"
    printf 'x\n' > "$caps_root/$fixture_path"
  done < <(sed -n '/^done <<.CAPS.$/,/^CAPS$/p' "$SELF" | grep -E '^[A-Za-z].* [0-9]+$')
  for card_i in 1 2 3 4 5 6 7; do
    printf 'x\n' > "$caps_root/docs/cards/card-$card_i.md"
  done
  # The probe inherits DOC_BUDGETS_ONRAMP_DOC/GOLDEN (absolute, in $TMP);
  # earlier arms mutated that doc, so restore + re-pin before the control run.
  cp "$PRISTINE" "$DOC_BUDGETS_ONRAMP_DOC"
  bash "$SELF" --regen-onramp-golden >/dev/null

  # jc: THE CONTROL — the unmutated copy must be GREEN on the planted root, or
  #     no exit code below is attributable to its mutation.
  cp "$SELF" "$caps_probe"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 0 ] \
    || fail_selftest "the CONTROL probe exited $caps_rc on the planted green root — no mutated probe's exit is attributable. Its last lines: $(printf '%s' "$caps_out" | tail -3 | tr '\n' ' ')"

  # j0: the pinned literal agrees with the committed table. If these ever drift,
  #     every assertion below is about a number nobody maintains.
  # `grep -c` exits 1 on a count of ZERO, and under `set -e` that would kill the
  # harness before it could report — while zero is precisely what arm j1 plants.
  rows_in_table=$(sed -n '/^done <<.CAPS.$/,/^CAPS$/p' "$SELF" | grep -cE '^[A-Za-z].* [0-9]+$' || true)
  expected_literal=$(grep -E '^CAPS_ROWS_EXPECTED=[0-9]+$' "$SELF" | head -1 | cut -d= -f2)
  [ "$rows_in_table" = "$expected_literal" ] \
    || fail_selftest "CAPS_ROWS_EXPECTED=$expected_literal but the table holds $rows_in_table row(s)"

  # j1: blind the table -> the gate must RED, and name the row-count mismatch.
  awk 'BEGIN { drop = 0 }
       /^done <<.CAPS.$/ { print; drop = 1; next }
       /^CAPS$/          { print; drop = 0; next }
       drop == 0         { print }' "$SELF" > "$caps_probe"
  probe_rows=$(sed -n '/^done <<.CAPS.$/,/^CAPS$/p' "$caps_probe" | grep -cE '^[A-Za-z].* [0-9]+$' || true)
  [ "$probe_rows" -eq 0 ] \
    || fail_selftest "the blinding step did not empty the CAPS table (still $probe_rows row(s)) — this arm would have proven nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "a DARK fixed-caps table exited $caps_rc, expected 1 — the diagnostic may still print, but the gate does not REFUSE (the FAIL=1 behind the row-count ratchet is disarmed)"
  case "$caps_out" in
    *"walked 0 row(s), expected $expected_literal"*) ;;
    *) fail_selftest "a DARK fixed-caps table did not print \`walked 0 row(s), expected $expected_literal\` — the row-count ratchet is gone, so an empty CAPS heredoc would verdict on NOTHING and still exit 0" ;;
  esac

  # j2: a row ADDED without bumping the literal must RED too — the ratchet has
  #     to bite in both directions or it is a one-way rubber stamp.
  awk -v add="docs/INDEX.md 1200" '
       { print }
       /^done <<.CAPS.$/ && !done_add { print add; done_add = 1 }' "$SELF" > "$caps_probe"
  probe_rows=$(sed -n '/^done <<.CAPS.$/,/^CAPS$/p' "$caps_probe" | grep -cE '^[A-Za-z].* [0-9]+$' || true)
  [ "$probe_rows" -eq $((expected_literal + 1)) ] \
    || fail_selftest "the row-adding step did not add a row (table has $probe_rows) — this arm would have proven nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "an UNPINNED extra cap row exited $caps_rc, expected 1 — the mismatch prints but the gate does not refuse"
  case "$caps_out" in
    *"walked $((expected_literal + 1)) row(s), expected $expected_literal"*) ;;
    *) fail_selftest "an UNPINNED extra cap row did not print \`walked $((expected_literal + 1)) row(s), expected $expected_literal\` — the ratchet only bites downward, so rows can be added without review" ;;
  esac

  # j3: an OVER-CAP file must RED through check_cap's own primitive. No arm
  #     ever planted one, so check_cap's over-cap FAIL=1 sat outside every
  #     tripwire: disarm it and 13/13 arms still passed while a real over-cap
  #     file sailed through. Shrink the FIRST table row's cap to 1 byte (row
  #     count unchanged, file present at 2 bytes) so the ONLY red is the
  #     over-cap arm.
  awk 'BEGIN { intab = 0; done_shrink = 0 }
       /^done <<.CAPS.$/ { print; intab = 1; next }
       /^CAPS$/          { intab = 0; print; next }
       intab == 1 && done_shrink == 0 && $0 ~ /^[A-Za-z].* [0-9]+$/ { $NF = 1; print; done_shrink = 1; next }
       { print }' "$SELF" > "$caps_probe"
  grep -qE '^[A-Za-z][^ ]* 1$' "$caps_probe" \
    || fail_selftest "the cap-shrinking step did not produce a 1-byte cap row — this arm would have proven nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "an OVER-CAP file exited $caps_rc, expected 1 — check_cap's over-cap FAIL=1 is disarmed (the size line may still print while the gate exits 0)"
  case "$caps_out" in
    *"cap is 1B"*) ;;
    *) fail_selftest "an OVER-CAP file did not print its \`cap is 1B\` FAIL line — the red came from something other than check_cap's over-cap arm" ;;
  esac

  # j4: a MISSING capped file must RED through check_cap's missing-file arm.
  #     Swap the FIRST row's path for one that does not exist (row count
  #     unchanged) so the ONLY red is the missing-file arm.
  awk 'BEGIN { intab = 0; done_swap = 0 }
       /^done <<.CAPS.$/ { print; intab = 1; next }
       /^CAPS$/          { intab = 0; print; next }
       intab == 1 && done_swap == 0 && $0 ~ /^[A-Za-z].* [0-9]+$/ { $1 = "no-such-file-planted-by-selftest.md"; print; done_swap = 1; next }
       { print }' "$SELF" > "$caps_probe"
  grep -q '^no-such-file-planted-by-selftest.md ' "$caps_probe" \
    || fail_selftest "the path-swapping step did not swap a row — this arm would have proven nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "a MISSING capped file exited $caps_rc, expected 1 — check_cap's missing-file FAIL=1 is disarmed"
  case "$caps_out" in
    *"no-such-file-planted-by-selftest.md is missing"*) ;;
    *) fail_selftest "a MISSING capped file did not print its \`is missing\` FAIL line — the red came from something other than check_cap's missing-file arm" ;;
  esac

  echo "check-doc-budgets --selftest: PASS (16 arms: pristine, in-span plant," \
       "re-pin, marker relocation, span cap, missing golden, no markers, bad arg," \
       "span-cap clamp both directions, retired env var inert, caps green control," \
       "caps-table dark, caps-table unpinned row, over-cap file, missing capped" \
       "file — every probe arm asserts the EXIT CODE and its own message)"
  exit 0
fi

# --- fixed caps (path<space>bytes) -----------------------------------------
#
# CAPS_ROWS_EXPECTED IS A COMMITTED LITERAL, AND THAT IS THE WHOLE POINT.
# The rest of this gate fails closed: check_cap REDs on a missing file, and the
# card arm REDs when the glob matches nothing (0 != 7). The CAPS table was the
# one part that could go DARK — empty the heredoc, or break the `while read`,
# and the loop verdicts on nothing while the card arm still prints its 7 lines
# and the script still exits 0. Measured 2026-08-20: blinding the heredoc took
# the gate from 35 `ok:` size verdicts to 7 — every one of the 28 rows below,
# CLAUDE.md and docs/api-v1.md and every contract doc among them, went unchecked
# — and it still printed `check-doc-budgets: PASS`. The 11-arm --selftest passed
# straight through that mutation too: every arm runs --span-only, which skips
# this loop entirely.
#
# Deriving the expected count FROM the table would be vacuous — a blind table
# makes both sides zero and the check agrees with itself. So the number is
# pinned here, by hand. Adding or removing a cap row is therefore a two-line
# edit: the row, and this number. That is intended friction, not an oversight.
CAPS_ROWS_EXPECTED=34
CAPS_ROWS_WALKED=0
if [ "$SPAN_ONLY" != "1" ]; then
while read -r path cap; do
  [ -z "$path" ] && continue
  CAPS_ROWS_WALKED=$((CAPS_ROWS_WALKED + 1))
  check_cap "$path" "$cap"
done <<'CAPS'
CLAUDE.md 10000
api/CLAUDE.md 6500
js/CLAUDE.md 2500
AGENTS.md 700
docs/INDEX.md 1200
docs/contracts/bokbasen.md 6000
docs/contracts/onix-field-map.md 5600
docs/contracts/webhook-realtime.md 3200
docs/contracts/paper-corpus-layers.md 4400
docs/contracts/schema-v2.md 7200
docs/contracts/portable-doc-inline.md 6800
docs/contracts/tenancy.md 8300
docs/contracts/task-claim-lifecycle.md 6000
docs/contracts/close-packet.md 4400
docs/contracts/cloud-object-authz.md 4800
README.md 7400
docs/ops/PROD_OPS.md 6000
docs/ops/merge-gates.md 64000
docs/ops/branch-protection-and-overrides.md 10400

docs/api-v1.md 14000

docs/auth.md 5600
docs/auth-user-sessions.md 16000
docs/setup/QUICKSTART.md 6000
docs/setup/TASK-SYSTEM.md 16000
docs/cheatsheets/bp.md 2400
docs/cheatsheets/tui.md 2400
docs/cheatsheets/tasks.md 2400
docs/cheatsheets/http-api.md 2400
docs/cheatsheets/papers.md 2400
docs/setup/AGENTS-MD.md 3600
docs/setup/AGENT-ONRAMPS.md 11000

docs/decisions/success-claim-census.md 19307

scripts/deploy-reliability-exit-2026-08-10.md 11200
scripts/deploy-reliability-exit-2026-08-17.md 9800
CAPS
  if [ "$CAPS_ROWS_WALKED" -ne "$CAPS_ROWS_EXPECTED" ]; then
    echo "FAIL: the fixed-caps table walked $CAPS_ROWS_WALKED row(s), expected $CAPS_ROWS_EXPECTED." \
         "Either the table went dark (a broken heredoc verdicts on NOTHING and this gate still" \
         "exits 0), or you added/removed a cap row and must bump CAPS_ROWS_EXPECTED to match."
    FAIL=1
  else
    echo "ok:   fixed-caps table walked all $CAPS_ROWS_WALKED budget-gated row(s)"
  fi
fi

# --- CODEX.md: cap applies OUTSIDE the pinned onramp span (D42) -------------
check_cap_minus_onramp_span "$ONRAMP_DOC" 10100

if [ "$SPAN_ONLY" = "1" ]; then
  if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "check-doc-budgets: FAILED (span-only) — $REMEDY"
    exit 1
  fi
  echo "check-doc-budgets: PASS (span-only)"
  exit 0
fi

# --- cards: each <= 2400 B, count must equal exactly 7 (G2, A6) -------------
CARD_COUNT=0
for card in docs/cards/*.md; do
  [ -e "$card" ] || continue
  CARD_COUNT=$((CARD_COUNT + 1))
  check_cap "$card" 2400
done

if [ "$CARD_COUNT" -ne 7 ]; then
  echo "FAIL: docs/cards/ holds $CARD_COUNT cards, hard cap is exactly 7 (G2)." \
       "A new card requires retiring or merging one — $REMEDY"
  FAIL=1
else
  echo "ok:   card count is exactly 7"
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "check-doc-budgets: FAILED — $REMEDY"
  exit 1
fi
echo "check-doc-budgets: PASS"
