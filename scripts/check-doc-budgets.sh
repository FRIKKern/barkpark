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

  echo "check-doc-budgets --selftest: PASS (11 arms: pristine, in-span plant," \
       "re-pin, marker relocation, span cap, missing golden, no markers, bad arg," \
       "span-cap clamp both directions, retired env var inert)"
  exit 0
fi

# --- fixed caps (path<space>bytes) -----------------------------------------
if [ "$SPAN_ONLY" != "1" ]; then
while read -r path cap; do
  [ -z "$path" ] && continue
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
docs/contracts/schema-v2.md 7200
docs/contracts/portable-doc-inline.md 6800
docs/contracts/tenancy.md 8300
README.md 7400
docs/ops/PROD_OPS.md 6000

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
