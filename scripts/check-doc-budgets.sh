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
# The committed onramp doc. Kept as its OWN name because DOC_BUDGETS_ONRAMP_DOC
# repoints $ONRAMP_DOC at a temp fixture during --selftest, and header discovery
# below must go on skipping the REAL CODEX.md in that run too — otherwise the
# harness's own override silently enrols a file the onramp arm already governs,
# and discovery double-counts the span the onramp arm deliberately excludes.
ONRAMP_DOC_DEFAULT="docs/setup/CODEX.md"
ONRAMP_DOC="${DOC_BUDGETS_ONRAMP_DOC:-$ONRAMP_DOC_DEFAULT}"
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
  # PRESERVE THE STATUS. On bash 3.2 a plain `trap ... EXIT` RESETS the exit
  # code after a fatal `set -u` abort: the harness printed "unbound variable"
  # having run ZERO arms and still exited 0 — a tripwire that cannot fail,
  # inside the tripwire built to catch exactly that. (An ordinary `set -e`
  # failure still exited 1, which is why this hid.) Arm k7 pins it.
  # THE HARNESS MUST BE ABLE TO FAIL. A plain `trap ... EXIT` let a fatal
  # `set -u` abort exit 0: bash 3.2 has ALREADY reset $? to 0 by the time the
  # trap runs, so no trap can recover the status — measured, three ways. The
  # harness printed "unbound variable" having run ZERO arms and still reported
  # success: a tripwire that cannot fail, inside the tripwire built to catch
  # exactly that. (An ordinary `set -e` failure did exit 1, which is why it
  # hid.) So completion is asserted POSITIVELY instead: the sentinel is set on
  # the last line before the PASS, and anything that leaves it unset while
  # claiming 0 exits 70. Arm k7 pins it.
  SELFTEST_COMPLETED=0
  trap 'dw_rc=$?; rm -rf "$TMP";
        if [ "$SELFTEST_COMPLETED" != 1 ] && [ "$dw_rc" -eq 0 ]; then
          echo "check-doc-budgets --selftest: FAILED — the harness exited before" \
               "reaching its end while claiming success (a fatal abort, e.g. an" \
               "unbound variable, whose status bash 3.2 resets to 0). NO arm verdict" \
               "above can be trusted."
          exit 70
        fi
        exit $dw_rc' EXIT

  # NO NESTED HARNESS. Arm k7 runs a COPY of this script with --selftest, and
  # without this the copy would reach its own k7 and spawn another — unbounded
  # recursion that HANGS CI instead of reporting. k7 works because the line it
  # injects sits between the trap above and this guard, so the copy aborts
  # before it can recurse; the guard is what makes that a design rather than a
  # coincidence, and it is why a k7 whose injection silently stopped applying
  # would exit 2 here rather than fork forever.
  if [ "${DOC_BUDGETS_SELFTEST_ACTIVE:-0}" = "1" ]; then
    echo "check-doc-budgets --selftest: refusing to nest inside another --selftest"
    SELFTEST_COMPLETED=1
    exit 2
  fi
  export DOC_BUDGETS_SELFTEST_ACTIVE=1
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
  # Plant the DISCOVERY corpus, derived from this script's own literals so the
  # fixture can never go stale against them. Without it the CONTROL run reds on
  # the discovery floor and no arm below is attributable.
  #   - one file per FREEZE row, at a path the freeze table names, carrying a
  #     1tok header (cap 4B) so it is genuinely OVER its header and the freeze
  #     branch is the branch under test;
  #   - enough plain 1000tok-header docs to reach DISCOVERY_MIN.
  selftest_freeze_rows=0
  while read -r plant_path _plant_bytes; do
    [ -n "$plant_path" ] || continue
    selftest_freeze_rows=$((selftest_freeze_rows + 1))
    mkdir -p "$caps_root/$(dirname "$plant_path")"
    printf '%s\n' "<!-- doc-tier: agent | canonical-for: freeze-fixture-$selftest_freeze_rows | budget: 1tok -->" \
      > "$caps_root/$plant_path"
  done < <(sed -n '/^done <<.FREEZE.$/,/^FREEZE$/p' "$SELF" | grep -E '^[A-Za-z].* [0-9]+$')
  selftest_docs_floor=$(grep -E '^GATED_DOCS_FLOOR=[0-9]+$' "$SELF" | head -1 | cut -d= -f2)
  selftest_caps_literal=$(grep -E '^CAPS_ROWS_EXPECTED=[0-9]+$' "$SELF" | head -1 | cut -d= -f2)
  selftest_discovery_min=$((selftest_docs_floor - selftest_caps_literal))
  plant_i="$selftest_freeze_rows"
  while [ "$plant_i" -lt "$selftest_discovery_min" ]; do
    plant_i=$((plant_i + 1))
    printf '%s\n' "<!-- doc-tier: agent | canonical-for: discovery-fixture-$plant_i | budget: 1000tok -->" \
      > "$caps_root/docs/discovery-fixture-$plant_i.md"
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


  # k0: the freeze literal agrees with the committed freeze table. Same reason
  #     as j0 — if these drift, every assertion below is about a number nobody
  #     maintains.
  freeze_rows_in_table=$(sed -n '/^done <<.FREEZE.$/,/^FREEZE$/p' "$SELF" | grep -cE '^[A-Za-z].* [0-9]+$' || true)
  freeze_expected_literal=$(grep -E '^FREEZE_ROWS_EXPECTED=[0-9]+$' "$SELF" | head -1 | cut -d= -f2)
  [ "$freeze_rows_in_table" = "$freeze_expected_literal" ] \
    || fail_selftest "FREEZE_ROWS_EXPECTED=$freeze_expected_literal but the freeze table holds $freeze_rows_in_table row(s)"

  # k1: DISCOVERY GOES DARK. This is the arm that matters most: discovery walks
  #     a COMPUTED set, so unlike a heredoc it can be emptied by a bad find, a
  #     renamed directory, or a cd — and a loop over nothing prints no FAIL at
  #     all. Kill both find roots; the floor must REFUSE, not merely mention it.
  #     The probe ALSO empties the FREEZE table and zeroes its literal. Without
  #     that, blinding discovery orphans all 39 freeze rows, the stale-row arm
  #     reds first, and this arm passes on someone else's refusal: measured —
  #     with the floor's FAIL=1 replaced by FAIL=0 the selftest still printed
  #     PASS. An arm has to red for its OWN reason or it certifies nothing.
  sed -e "s|^      find docs -name '\*\.md' -not -path 'docs/cli/fixtures/\*'$|      true|" \
      -e "s|^      find scripts -maxdepth 1 -name '\*\.md'$|      true|" \
      -e "s|^FREEZE_ROWS_EXPECTED=[0-9]*$|FREEZE_ROWS_EXPECTED=0|" \
      "$SELF" \
    | awk 'BEGIN { drop = 0 }
           /^done <<.FREEZE.$/ { print; drop = 1; next }
           /^FREEZE$/          { print; drop = 0; next }
           drop == 0           { print }' > "$caps_probe"
  grep -q "^      find docs -name " "$caps_probe" \
    && fail_selftest "the discovery-blinding step did not remove the docs find — this arm would have proven nothing"
  [ "$(sed -n '/^done <<.FREEZE.$/,/^FREEZE$/p' "$caps_probe" | grep -cE '^[A-Za-z].* [0-9]+$' || true)" -eq 0 ] \
    || fail_selftest "the discovery-blinding step did not also empty the FREEZE table — the stale-row arm would red first and this arm would prove nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "DARK header discovery exited $caps_rc, expected 1 — the floor prints but does not REFUSE, so a discovery loop over NOTHING would still exit 0"
  case "$caps_out" in
    *"($expected_literal capped + 0 discovered), floor is $selftest_docs_floor"*) ;;
    *) fail_selftest "DARK header discovery did not print \`($expected_literal capped + 0 discovered), floor is $selftest_docs_floor\` — the floor is gone, so discovery can verdict on nothing and pass" ;;
  esac

  # k2: a doc OVER its own header budget must RED, naming the header. Planted
  #     as a FIXTURE (not a script mutation) because that is the real shape:
  #     someone grows a doc whose header nobody was reading.
  cp "$SELF" "$caps_probe"
  printf '%s\n' "<!-- doc-tier: agent | canonical-for: overbudget-fixture | budget: 1tok -->" \
    > "$caps_root/docs/discovery-overbudget-fixture.md"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  rm -f "$caps_root/docs/discovery-overbudget-fixture.md"
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "a doc OVER its declared header budget exited $caps_rc, expected 1 — the header is still decoration"
  case "$caps_out" in
    *"docs/discovery-overbudget-fixture.md is"*"its own header declares 1tok = 4B"*) ;;
    *) fail_selftest "an over-header doc did not print its \`header declares 1tok = 4B\` FAIL line — the red came from something other than the discovery arm" ;;
  esac

  # k3: a FROZEN doc that GROWS must RED. Shrink the first freeze row's number
  #     to 1 (row count unchanged, file present) so the only red is the freeze
  #     ratchet. Without this arm the freeze table is a blank cheque.
  awk 'BEGIN { intab = 0; done_shrink = 0 }
       /^done <<.FREEZE.$/ { print; intab = 1; next }
       /^FREEZE$/          { intab = 0; print; next }
       intab == 1 && done_shrink == 0 && $0 ~ /^[A-Za-z].* [0-9]+$/ { $NF = 1; print; done_shrink = 1; next }
       { print }' "$SELF" > "$caps_probe"
  sed -n '/^done <<.FREEZE.$/,/^FREEZE$/p' "$caps_probe" | grep -qE '^[A-Za-z][^ ]* 1$' \
    || fail_selftest "the freeze-shrinking step did not produce a 1-byte freeze row — this arm would have proven nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "a GROWN frozen doc exited $caps_rc, expected 1 — the freeze ratchet is disarmed and frozen debt can grow"
  case "$caps_out" in
    *"frozen at 1B — a frozen doc may not grow"*) ;;
    *) fail_selftest "a GROWN frozen doc did not print its \`frozen at 1B\` FAIL line — the red came from something other than the freeze ratchet" ;;
  esac

  # k4: a frozen doc that has come back UNDER its header must RED too, telling
  #     the author to DELETE the row. Without this the freeze list only ever
  #     grows, and a paid debt keeps buying slack forever.
  cp "$SELF" "$caps_probe"
  selftest_first_frozen=$(sed -n '/^done <<.FREEZE.$/,/^FREEZE$/p' "$SELF" | grep -E '^[A-Za-z].* [0-9]+$' | head -1 | cut -d' ' -f1)
  printf '%s\n' "<!-- doc-tier: agent | canonical-for: freeze-fixture-paid | budget: 1000tok -->" \
    > "$caps_root/$selftest_first_frozen"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  printf '%s\n' "<!-- doc-tier: agent | canonical-for: freeze-fixture-1 | budget: 1tok -->" \
    > "$caps_root/$selftest_first_frozen"
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "a PAID frozen doc exited $caps_rc, expected 1 — the freeze list can never be made to shrink"
  case "$caps_out" in
    *"$selftest_first_frozen is"*"now fits its own 1000tok header"*) ;;
    *) fail_selftest "a PAID frozen doc did not print its \`now fits its own\` FAIL line — nothing forces a settled freeze row out of the table" ;;
  esac

  # k5: a freeze row naming a doc discovery never reaches must RED. That row is
  #     a number that can no longer fail — the exact shape this whole arm exists
  #     to refuse, reappearing inside its own remedy.
  awk 'BEGIN { intab = 0; done_swap = 0 }
       /^done <<.FREEZE.$/ { print; intab = 1; next }
       /^FREEZE$/          { intab = 0; print; next }
       intab == 1 && done_swap == 0 && $0 ~ /^[A-Za-z].* [0-9]+$/ { $1 = "docs/no-such-frozen-doc-planted-by-selftest.md"; print; done_swap = 1; next }
       { print }' "$SELF" > "$caps_probe"
  grep -q '^docs/no-such-frozen-doc-planted-by-selftest.md ' "$caps_probe" \
    || fail_selftest "the freeze path-swapping step did not swap a row — this arm would have proven nothing"
  # The orphaned fixture must stop being a SECOND red, or this arm passes on
  # someone else's refusal: with its 1tok header it would fall straight into the
  # over-header branch the moment its freeze row is swapped away, and the stale
  # diagnostic would print while nothing here refused. Measured: with the stale
  # check's FAIL=1 replaced by a no-op the selftest still printed PASS. Widen
  # its header for the duration so the ONLY red is the stale row.
  printf '%s\n' "<!-- doc-tier: agent | canonical-for: freeze-fixture-orphan | budget: 1000tok -->" \
    > "$caps_root/$selftest_first_frozen"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  printf '%s\n' "<!-- doc-tier: agent | canonical-for: freeze-fixture-1 | budget: 1tok -->" \
    > "$caps_root/$selftest_first_frozen"
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "a STALE freeze row exited $caps_rc, expected 1 — dead freeze rows accumulate unnoticed"
  case "$caps_out" in
    *"freeze row 'docs/no-such-frozen-doc-planted-by-selftest.md"*"matched no discovered doc"*) ;;
    *) fail_selftest "a STALE freeze row did not print its \`matched no discovered doc\` FAIL line — the red came from something else" ;;
  esac

  # k6: a freeze row ADDED without bumping the literal must RED. Note the
  #     asymmetry with the CAPS table, and it is why there is no freeze-DARK
  #     arm: a dark CAPS heredoc is fail-OPEN (it verdicts on nothing and exits
  #     0), while a dark FREEZE heredoc is fail-SAFE — all 39 frozen docs
  #     immediately fall back to header*4, which every one of them exceeds, so
  #     the gate reds loudly on its own. The direction that can go quiet is a
  #     row appearing without review, so that is the direction pinned here.
  #     The added row DUPLICATES the first one, so lookup (first match wins) is
  #     unchanged and the row count is the ONLY thing that differs.
  selftest_dup_freeze=$(sed -n '/^done <<.FREEZE.$/,/^FREEZE$/p' "$SELF" | grep -E '^[A-Za-z].* [0-9]+$' | head -1)
  awk -v add="$selftest_dup_freeze" '
       { print }
       /^done <<.FREEZE.$/ && !done_add { print add; done_add = 1 }' "$SELF" > "$caps_probe"
  [ "$(sed -n '/^done <<.FREEZE.$/,/^FREEZE$/p' "$caps_probe" | grep -cE '^[A-Za-z].* [0-9]+$' || true)" -eq $((freeze_expected_literal + 1)) ] \
    || fail_selftest "the freeze row-adding step did not add a row — this arm would have proven nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "an UNPINNED extra freeze row exited $caps_rc, expected 1 — freeze rows can be added without review"
  case "$caps_out" in
    *"freeze table walked $((freeze_expected_literal + 1)) row(s), expected $freeze_expected_literal"*) ;;
    *) fail_selftest "an UNPINNED extra freeze row did not print its row-count FAIL line — the freeze table's row ratchet is gone" ;;
  esac

  # k7: THE HARNESS ITSELF MUST BE ABLE TO FAIL. A fatal abort in the selftest —
  #     an unbound variable in setup, before a single arm runs — must not exit 0.
  #     Injected immediately after the trap, so the probe dies having proven
  #     nothing; the only acceptable answer is a non-zero exit.
  awk '{ print }
       /^  export DOC_BUDGETS_SELFTEST_ACTIVE=1$/ && !done_inject { print "  : \"$dw_unbound_planted_by_selftest\""; done_inject = 1 }' \
      "$SELF" > "$caps_probe"
  grep -q 'dw_unbound_planted_by_selftest' "$caps_probe" \
    || fail_selftest "the unbound-variable injection did not apply — this arm would have proven nothing"
  set +e
  # ACTIVE=0 so the copy gets PAST the nesting guard and reaches the injected
  # line; its own export then re-arms the guard, so the copy's k7 (if it ever
  # ran) would be refused at depth 2. One level, by construction.
  caps_out="$(DOC_BUDGETS_SELFTEST_ACTIVE=0 bash "$caps_probe" --selftest 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 70 ] \
    || fail_selftest "a selftest that ABORTED on an unbound variable exited $caps_rc, expected 70 — the EXIT trap is resetting the status, so this harness can die having run zero arms and still report PASS. Its output was: $(printf '%s' "$caps_out" | tail -2 | tr '\n' ' ')"

  # k8: an exemption row ADDED without bumping its pin must RED. An exemption
  #     list is the one table here whose growth is silent by nature — nothing
  #     downstream notices a file that simply stops being verdicted — so the
  #     count is the only thing standing between one argued exception and a
  #     drawer of them. The added row DUPLICATES the existing one, so lookup is
  #     unchanged and the count is the ONLY difference.
  ao_expected_literal=$(grep -E '^APPEND_ONLY_ROWS_EXPECTED=[0-9]+$' "$SELF" | head -1 | cut -d= -f2)
  ao_dup_row=$(sed -n "/^done <<.APPEND_ONLY.$/,/^APPEND_ONLY$/p" "$SELF" | grep -E '^[A-Za-z].*\.md$' | head -1)
  awk -v add="$ao_dup_row" '
       { print }
       /^done <<.APPEND_ONLY.$/ && !done_add { print add; done_add = 1 }' "$SELF" > "$caps_probe"
  [ "$(sed -n "/^done <<.APPEND_ONLY.$/,/^APPEND_ONLY$/p" "$caps_probe" | grep -cE '^[A-Za-z].*\.md$' || true)" -eq $((ao_expected_literal + 1)) ] \
    || fail_selftest "the exemption row-adding step did not add a row — this arm would have proven nothing"
  set +e
  caps_out="$(bash "$caps_probe" 2>&1)"
  caps_rc=$?
  set -e
  [ "$caps_rc" -eq 1 ] \
    || fail_selftest "an UNPINNED extra append-only exemption exited $caps_rc, expected 1 — files can be exempted from the byte gate without review"
  case "$caps_out" in
    *"append-only exemption table walked $((ao_expected_literal + 1)) row(s), expected $ao_expected_literal"*) ;;
    *) fail_selftest "an UNPINNED extra exemption did not print its row-count FAIL line — the exemption list can grow quietly" ;;
  esac

  SELFTEST_COMPLETED=1
  echo "check-doc-budgets --selftest: PASS (25 arms: pristine, in-span plant," \
       "re-pin, marker relocation, span cap, missing golden, no markers, bad arg," \
       "span-cap clamp both directions, retired env var inert, caps green control," \
       "caps-table dark, caps-table unpinned row, over-cap file, missing capped" \
       "file, freeze literal pin, DISCOVERY DARK, over-header doc, grown frozen" \
       "doc, paid frozen doc, stale freeze row, unpinned freeze row, harness" \
       "aborts non-zero, unpinned exemption row — every" \
       "probe arm asserts the EXIT CODE and its own message)"
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
CAPS_ROWS_EXPECTED=36
CAPS_ROWS_WALKED=0
CAPS_PATHS=""
if [ "$SPAN_ONLY" != "1" ]; then
while read -r path cap; do
  [ -z "$path" ] && continue
  CAPS_ROWS_WALKED=$((CAPS_ROWS_WALKED + 1))
  CAPS_PATHS="$CAPS_PATHS$path
"
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
docs/contracts/canonical-impl-markers.md 3000
docs/contracts/sheets-engine.md 2600
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


# --- header-discovered caps: the declared budget IS the cap -----------------
#
# THE HOLE THIS CLOSES. Everything above is an EXPLICIT path list. A doc that
# is not on it declares `budget: <N>tok` in its G1 header and nothing reads
# that number — measured on the tree this arm shipped against: 89 spine docs
# carried a header no gate enforced, `scripts/*.md` (17 of them) among them.
# The header LOOKED like a cap and was decoration, which is the vacuous-green
# shape this gate exists to refuse.
#
# THE DERIVATION, applied here and nowhere else in this script: a declared
# budget of N tokens is N * DOC_BUDGET_BYTES_PER_TOKEN bytes. Four is the
# repo's stated convention (docs/ops/merge-gates.md: "at the repo's ~4B/tok
# convention") and it is what the hand-written contract rows already encode —
# bokbasen 1500tok/6000B, onix-field-map 1400/5600, webhook-realtime 800/3200,
# schema-v2 1800/7200. So NO second per-path number is introduced: the number
# already in the doc's own header becomes the cap, and an author who wants a
# bigger cap must argue for it in the header where a reviewer reads it.
#
# PRECEDENCE — an explicit rule always wins, and only ever downward:
#   1. a row in the CAPS table above  -> that row binds; discovery skips the
#      file. Several rows are TIGHTER than the header (docs/api-v1.md 3500tok
#      would allow 14000B and the row says 14000; AGENTS.md 150tok/600B and the
#      row says 700). The table is the reviewed number; discovery never
#      loosens it.
#   2. docs/cards/*.md                -> the 7-card arm below binds (2400B and
#      the count of exactly 7). Discovery skips cards so that arm stays the one
#      authority on them. NOTE, honestly: six of the seven card headers declare
#      LESS than 2400B (cli.md 450tok = 1800B against a 2377B file), so their
#      headers remain under-declared. Reconciling card headers with the card
#      rule is separate work, filed rather than smuggled in here.
#   3. $ONRAMP_DOC                    -> the pinned-span arm binds.
#   4. everything else discovered     -> header * 4, or a FREEZE row.
#
# `doc-tier: cold` IS EXEMPT, deliberately. The doc contract defines cold as
# retired — "never load; git history is the archive". A byte budget buys agent
# context, so on a doc no agent is allowed to load it buys nothing: capping the
# 158 cold records (mostly tooling/grip/ledger/*.md and dated fire records)
# would spend review friction on files whose only remaining job is to sit still.
# Their headers stay declarative and this is the sentence that says so, rather
# than leaving a reader to infer it from an absence.
#
# SCOPE is the doc spine, matching what docs-anchors-check.sh §4 already
# requires a header ON, plus scripts/*.md (this arm's originating finding).
# It is deliberately NOT every .md in the repo: .claude/workflows/*-charter.md
# and tooling/grip/ledger/*.md carry headers, are not agent-loaded spine, and
# sweeping them in would have made this a 105-file freeze instead of a 39.
DOC_BUDGET_BYTES_PER_TOKEN=4

# A FLOOR OVER THE UNION, not a pin on discovery alone. Discovery walks a
# COMPUTED set, so its failure mode is going dark and verdicting on nothing
# while the script still prints PASS — exactly what blinding the CAPS heredoc
# did (35 size verdicts to 7, still PASS). A floor catches that.
#
# It counts CAPPED + DISCOVERED together because enrolling a doc in the CAPS
# table MOVES it out of discovery: the two sets partition the same population,
# so the sum is invariant under exactly the edit people make most often. Pinned
# on discovery alone, this number would red on every unrelated PR that adds a
# caps row — and a gate that reds for unrelated churn gets its literal bumped
# reflexively until it discriminates nothing. Lower it only alongside a
# deliberate deletion or retiering of spine docs.
#
# Cards and $ONRAMP_DOC are out of the sum on purpose: the card arm pins its own
# count at exactly 7, and the onramp doc is a single named path.
GATED_DOCS_FLOOR=118

DISCOVERY_HEADER_RE='^<!-- doc-tier: (agent|human|cold) \| canonical-for: [A-Za-z0-9._-]+ \| budget: [0-9]+tok -->'

# Docs ALREADY over header*4 on the day discovery landed. They are pinned at
# their MEASURED size, so the gate is green on the shipped tree and the debt
# cannot get worse — and NOT by raising anyone's header, which would be the
# never-raise-a-cap violation wearing a different hat.
#
# THIS LIST MAY ONLY SHRINK. Two arms enforce that: a frozen doc that GROWS
# reds, and a frozen doc that has come back UNDER its header budget also reds,
# telling you to delete its row. So paying a debt is not optional bookkeeping —
# the gate refuses until the row is gone.
FREEZE_ROWS_EXPECTED=38

# APPEND-ONLY RECORDS. A byte ceiling on a file that grows by design is a gate
# in front of the thing it is supposed to protect: docs/ops/break-glass-log.md
# says of ITSELF that it is "the procedure at the top, the append-only record at
# the bottom", so freezing it would red this gate on every incident entry, at
# the exact moment nobody should be arguing with CI. It is counted as REACHED
# and adjudicated — it just gets no size verdict, and the run says so by name.
#
# THIS IS NOT A GENERAL ESCAPE HATCH, and the count is pinned because an
# exemption list is the classic tripwire that stops discriminating once it
# grows: the eighth entry is waved through by the seven above it. An addition
# needs the same argument this one carries — the FILE ITSELF must declare that
# it is an append-only record — plus the two-line friction of bumping the pin.
APPEND_ONLY_ROWS_EXPECTED=1

FREEZE_ROWS_WALKED=0
FREEZE_TABLE=""
DISCOVERY_WALKED=0
DISCOVERY_SEEN=""
if [ "$SPAN_ONLY" != "1" ]; then
while read -r fz_path fz_bytes; do
  [ -z "$fz_path" ] && continue
  FREEZE_ROWS_WALKED=$((FREEZE_ROWS_WALKED + 1))
  FREEZE_TABLE="$FREEZE_TABLE$fz_path $fz_bytes
"
done <<'FREEZE'
docs/api/error-envelope-migration.md 2645
docs/cli/error-exit-table.md 20911
docs/cli/HANDBOOK.md 13979
docs/cli/m0-decisions.md 5334
docs/contracts/cycle-fleet.md 7497
docs/contracts/dispatch-areas.md 5782
docs/contracts/roster-reading.md 7384
docs/contracts/tui-render-doctrine.md 3920
docs/decisions/0001-sdk-envelope.md 2179
docs/decisions/0002-npm-dist-tag.md 5221
docs/decisions/0003-sync-tags.md 3674
docs/decisions/0005-pr-body-criteria.md 3113
docs/decisions/deferred.md 3892
docs/media/DISCOVERY.md 2445
docs/ops/backup-dr.md 5735
docs/ops/barkpark-cloud-go-live.md 10564
docs/ops/bokbasen-go-live.md 5153
docs/ops/connectors-deploy.md 10694
docs/ops/github-sync.md 8693
docs/ops/mcp-serve-validation.md 13209
docs/ops/npm-rollback-playbook.md 11433
docs/ops/vercel-dns-connect.md 12390
docs/plugins/codelists-byo.md 2081
docs/search/ROADMAP.md 2809
docs/setup/CLAUDE-CODE.md 12444
docs/setup/cloud-login.md 6290
docs/setup/CURSOR.md 7579
docs/setup/personal-local.md 5169
docs/setup/REMOTE.md 7457
docs/setup/SETUP.md 12185
docs/snippets/README.md 1975
docs/spec/bokbasen-api-contract.md 39908
docs/studio/user-guide.md 4913
docs/studio/web-components.md 3676
docs/swarm/oban-substrate.md 5931
docs/swarm/personal-access-tokens.md 6925
docs/swarm/subscription-billing.md 7317
docs/swarm/teams-invitations.md 4937
FREEZE

APPEND_ONLY_ROWS_WALKED=0
APPEND_ONLY_TABLE=""
while read -r ao_path; do
  [ -z "$ao_path" ] && continue
  APPEND_ONLY_ROWS_WALKED=$((APPEND_ONLY_ROWS_WALKED + 1))
  APPEND_ONLY_TABLE="$APPEND_ONLY_TABLE$ao_path
"
done <<'APPEND_ONLY'
docs/ops/break-glass-log.md
APPEND_ONLY
  if [ "$APPEND_ONLY_ROWS_WALKED" -ne "$APPEND_ONLY_ROWS_EXPECTED" ]; then
    echo "FAIL: the append-only exemption table walked $APPEND_ONLY_ROWS_WALKED row(s)," \
         "expected $APPEND_ONLY_ROWS_EXPECTED. An exemption list that can grow without" \
         "review stops discriminating; bump the pin in the same edit, in front of a reviewer."
    FAIL=1
  else
    echo "ok:   append-only exemption table walked all $APPEND_ONLY_ROWS_WALKED row(s)"
  fi
  if [ "$FREEZE_ROWS_WALKED" -ne "$FREEZE_ROWS_EXPECTED" ]; then
    echo "FAIL: the freeze table walked $FREEZE_ROWS_WALKED row(s), expected $FREEZE_ROWS_EXPECTED." \
         "Either it went dark (a broken heredoc freezes NOTHING and every frozen doc" \
         "silently falls back to a header budget it does not meet), or you paid a debt" \
         "and must lower FREEZE_ROWS_EXPECTED to match."
    FAIL=1
  else
    echo "ok:   freeze table walked all $FREEZE_ROWS_WALKED frozen row(s)"
  fi

  while IFS= read -r dpath; do
    if [ ! -f "$dpath" ]; then continue; fi
    dhead=$(head -n 1 "$dpath")
    printf '%s\n' "$dhead" | grep -Eq "$DISCOVERY_HEADER_RE" || continue
    # cold is exempt — see the block comment above
    case "$dhead" in *"doc-tier: cold"*) continue ;; esac
    # precedence: an explicit rule wins
    case "
$CAPS_PATHS" in *"
$dpath
"*) continue ;; esac
    case "$dpath" in docs/cards/*) continue ;; esac
    if [ "$dpath" = "$ONRAMP_DOC" ] || [ "$dpath" = "$ONRAMP_DOC_DEFAULT" ]; then continue; fi

    DISCOVERY_WALKED=$((DISCOVERY_WALKED + 1))
    DISCOVERY_SEEN="$DISCOVERY_SEEN$dpath
"
    case "
$APPEND_ONLY_TABLE" in
      *"
$dpath
"*)
        echo "ok:   $dpath EXEMPT — an append-only record carries no byte ceiling (still reached and counted)"
        continue
        ;;
    esac
    dtok=$(printf '%s\n' "$dhead" | sed -E 's/.*budget: ([0-9]+)tok.*/\1/')
    dcap=$((dtok * DOC_BUDGET_BYTES_PER_TOKEN))
    dsize=$(wc -c < "$dpath" | tr -d ' ')
    dfrozen=$(printf '%s' "$FREEZE_TABLE" | awk -v p="$dpath" '$1 == p { print $2; exit }')

    if [ -n "$dfrozen" ]; then
      if [ "$dsize" -le "$dcap" ]; then
        echo "FAIL: $dpath is ${dsize}B and now fits its own ${dtok}tok header (${dcap}B) —" \
             "DELETE its row from the FREEZE table and lower FREEZE_ROWS_EXPECTED." \
             "The freeze list may only shrink; a paid debt left in it re-buys slack nobody needs."
        FAIL=1
      elif [ "$dsize" -gt "$dfrozen" ]; then
        echo "FAIL: $dpath is ${dsize}B, frozen at ${dfrozen}B — a frozen doc may not grow." \
             "$REMEDY, toward its ${dtok}tok header budget (${dcap}B). Do NOT raise the freeze" \
             "number and do NOT raise the header; both are the cap-raise this gate refuses."
        FAIL=1
      else
        echo "ok:   $dpath ${dsize}B <= ${dfrozen}B (FROZEN — owes $((dfrozen - dcap))B against its ${dtok}tok header)"
      fi
    elif [ "$dsize" -gt "$dcap" ]; then
      echo "FAIL: $dpath is ${dsize}B, its own header declares ${dtok}tok = ${dcap}B —" \
           "$REMEDY. Do NOT raise the header to fit: the header IS the cap here," \
           "so editing it is raising the cap."
      FAIL=1
    else
      echo "ok:   $dpath ${dsize}B <= ${dcap}B (header ${dtok}tok x $DOC_BUDGET_BYTES_PER_TOKEN)"
    fi
  done < <(
    {
      find docs -name '*.md' -not -path 'docs/cli/fixtures/*'
      find scripts -maxdepth 1 -name '*.md'
      for surface in CLAUDE.md AGENTS.md api/CLAUDE.md js/CLAUDE.md web/AGENTS.md; do
        if [ -f "$surface" ]; then echo "$surface"; fi
      done
    } 2>/dev/null | sed 's|^\./||' | sort -u
  )

  GATED_DOCS_REACHED=$((CAPS_ROWS_WALKED + DISCOVERY_WALKED))
  if [ "$GATED_DOCS_REACHED" -lt "$GATED_DOCS_FLOOR" ]; then
    echo "FAIL: the budget gate reached $GATED_DOCS_REACHED gated doc(s)" \
         "($CAPS_ROWS_WALKED capped + $DISCOVERY_WALKED discovered), floor is $GATED_DOCS_FLOOR." \
         "Either discovery went dark (it verdicts on NOTHING and this gate still exits 0)," \
         "or spine docs were deleted and the floor must be lowered deliberately."
    FAIL=1
  else
    echo "ok:   budget gate reached $GATED_DOCS_REACHED gated doc(s)" \
         "($CAPS_ROWS_WALKED capped + $DISCOVERY_WALKED discovered, floor $GATED_DOCS_FLOOR)"
  fi

  # A freeze row naming nothing discovery reached is a row that can never red:
  # the file was deleted, renamed, retiered to cold, or given a CAPS row, and
  # the freeze number quietly stopped meaning anything.
  FREEZE_STALE=0
  while read -r fz_path fz_bytes; do
    [ -z "$fz_path" ] && continue
    case "
$DISCOVERY_SEEN" in
      *"
$fz_path
"*) ;;
      *)
        echo "FAIL: freeze row '$fz_path $fz_bytes' matched no discovered doc —" \
             "it was deleted, renamed, retiered to cold, or given a CAPS row." \
             "A freeze row nothing reaches is a number that can never red; remove it."
        FAIL=1
        FREEZE_STALE=1
        ;;
    esac
  done <<FREEZE_CHECK
$FREEZE_TABLE
FREEZE_CHECK
  if [ "$FREEZE_STALE" -eq 0 ]; then
    echo "ok:   every freeze row still names a discovered doc"
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

# --- router headroom floor: the two surface routers keep room to be CORRECTED --
# A cap-only gate is GREEN at 9998/10000. That is not a healthy doc, it is a
# FROZEN one: root CLAUDE.md sat at 9998B and api/CLAUDE.md at 6499B on
# origin/main, and in that state every subsequent correction — a plugin roster
# that undercounted by five, a "CI-enforced" claim the required set denies — was
# blocked on bytes rather than on judgment.
#
# THIS ARM IS AN EARLY WARNING FOR "CANNOT BE CORRECTED", NOT A SECOND GROWTH
# CAP. The cap already governs growth; this says the file still has room for the
# next fix, and it should fire only when that is genuinely in doubt. So the
# floors are deliberately LOW — a few hundred bytes, roughly one corrected
# sentence — rather than set just under whatever the file happens to measure
# today. A floor tuned tight to the current size reds on the next honest edit
# and teaches authors to route around the gate, which is worse than no gate:
# these are the documents an owner rewrites in place (the Golden Rules are being
# revised as this lands), and a warning that cries on every such edit stops being
# read. Leave real slack between the floor and the file.
#
# These two files earn a floor and the other cap rows do not: they are the
# surface routers every agent loads, so they are where a correction is most
# urgent and least postponable. Raising a cap to buy floor is not a fix and the
# doc contract forbids it outright — split content to its owning doc instead.
check_headroom() {
  # $1 = path, $2 = byte cap, $3 = minimum free bytes
  local path="$1" cap="$2" floor="$3" size free
  if [ ! -f "$path" ]; then
    echo "FAIL: $path is missing (headroom-gated file must exist)"
    FAIL=1
    return
  fi
  size=$(wc -c < "$path" | tr -d ' ')
  free=$((cap - size))
  if [ "$free" -lt "$floor" ]; then
    echo "FAIL: $path has ${free}B of headroom under its ${cap}B cap, floor is ${floor}B." \
         "That is too full to absorb the next correction. Do NOT raise the cap — split" \
         "the least load-bearing section to its owning doc and leave a one-line pointer."
    FAIL=1
  else
    echo "ok:   $path headroom ${free}B >= ${floor}B (${size}B of ${cap}B)"
  fi
}

check_headroom CLAUDE.md 10000 200
check_headroom api/CLAUDE.md 6500 150

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "check-doc-budgets: FAILED — $REMEDY"
  exit 1
fi
echo "check-doc-budgets: PASS"
