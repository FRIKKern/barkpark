#!/usr/bin/env bash
# refute-on-absence-capture-log-check.sh — refuting a match on a device-wide log
# capture, from a CONCURRENT test module, is unsound by construction.
#
# THE DEFECT
# ----------
# `ExUnit.CaptureLog.capture_log/2` mutes the default handler and captures the
# whole Logger device, not one process's output. Its own docs say what follows:
#
#     "Note that when the `async` is set to `true` on `use ExUnit.Case`,
#      messages from other tests might be captured. This is OK as long you
#      consider such cases in your assertions, typically by using the `=~/2`
#      operator to perform PARTIAL matches."
#
# A PRESENCE assert is the considered case: a foreign line cannot make a present
# line absent, so `assert log =~ needle` is sound under concurrency. An ABSENCE
# claim — `refute log =~ needle` — is exactly the case that sentence excludes. A
# module running beside it can only ADD text, and added text can only turn the
# refute red. That is a flake whose cause is another file, which is why it wears
# the "rerun until green" costume so well.
#
# THE THREE-TOKEN CONJUNCTION, AND WHY IT IS NARROW ON PURPOSE
# ------------------------------------------------------------
# A module is flagged only when ALL THREE hold:
#
#     1. it mentions `capture_log`
#     2. it declares `async: true`
#     3. it has at least one line matching `refute[^\n]*log`
#
# The tempting rule is the WIDE one — "no capture_log under async". That rule is
# wrong and expensive: presence asserts under concurrency are sound and common,
# and banning them would cost real coverage to buy nothing. Only the absence
# claim is unsound, so only the absence claim is flagged. The wide-rule control
# is arm (0) of the selftest and it exists to keep this gate honest.
#
# THE BASELINE IS ZERO, NOT A RATCHET. The population was converted to a sound
# shape in the same change that added this check (task-4f7caaab44c132c1), so
# there is nothing to grandfather. A ratchet with an empty allowlist is a zero
# baseline wearing extra machinery.
#
# REFUSE, NEVER DEGRADE. An unreadable or missing scan tree exits 3, distinctly
# from a RED (1). A scanner that reports "clean" for a tree it never opened is
# the failure this gate exists to prevent.
#
# THE FIX, per site, cheapest first:
#   * assert the expected line is PRESENT instead of refuting a foreign one;
#   * or drop `async: true` for the module, with a one-line comment naming the
#     reason — synchronous modules run alone, so the capture is theirs;
#   * do NOT narrow the needle to a fresh UUID and call it done. That makes the
#     collision unlikely, not impossible, and unsound-but-rare is this bug.
#
# Usage:
#   scripts/refute-on-absence-capture-log-check.sh          # check (exit 0/1/3)
#   scripts/refute-on-absence-capture-log-check.sh --list    # every site, file:line
#
# Selftest lives in scripts/refute-on-absence-capture-log-check.test.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so the selftest drives synthetic trees in a temp dir and plants
# nothing in the real source.
SCANDIR="${REFUTE_CAPTURE_LOG_SCANDIR:-$ROOT/api/test}"

if [ ! -d "$SCANDIR" ] || [ ! -r "$SCANDIR" ]; then
  echo "refute-on-absence-capture-log-check: REFUSING — scan tree is not a readable directory:" >&2
  echo "    $SCANDIR" >&2
  echo "  Reporting a clean tree that was never opened is the failure this gate" >&2
  echo "  exists to prevent. Fix the path, or fix the caller." >&2
  exit 3
fi

# Token 1 + token 2: modules mentioning capture_log AND declaring async: true.
# `find | while read` keeps this bash 3.2 clean (no mapfile, no globstar).
scan() {
  find "$SCANDIR" \( -name '*.exs' -o -name '*.ex' \) -type f -print | sort | while read -r f; do
    [ -r "$f" ] || { echo "UNREADABLE	$f"; continue; }
    grep -q 'capture_log' "$f" || continue
    grep -q 'async: true' "$f" || continue
    # Token 3: a refute on the same line as `log`. Emitted as file:line so
    # --list can name the site; the CHECK counts per file only, because a
    # line-anchored pin slides on any insertion above it.
    grep -nE 'refute[^\n]*log' "$f" | while IFS=: read -r n _rest; do
      echo "HIT	$f	$n"
    done
  done
  # The last grep in the loop exits 1 whenever the final file has no hit, and
  # under `set -e` + pipefail that would abort the script with an empty scan —
  # a clean report on a tree that WAS read. Force a deterministic success.
  return 0
}

SCAN_OUT="$(scan || true)"

UNREADABLE="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="UNREADABLE"{print $2}')"
if [ -n "$UNREADABLE" ]; then
  echo "refute-on-absence-capture-log-check: REFUSING — file(s) could not be read:" >&2
  printf '%s\n' "$UNREADABLE" | sed 's/^/    /' >&2
  exit 3
fi

rel() { printf '%s' "${1#$ROOT/}"; }

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"{print $2 ":" $3}' | while read -r line; do
    echo "$(rel "$line")"
  done
  exit 0
fi

rc=0
FILES="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"{print $2}' | sort -u)"
TOTAL=0
if [ -n "$FILES" ]; then
  rc=1
  printf '%s\n' "$FILES" | while read -r f; do
    [ -n "$f" ] || continue
    n="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' -v p="$f" '$1=="HIT" && $2==p' | wc -l | tr -d ' ')"
    echo "RED  $(rel "$f") — $n refute-on-log site(s) in a module that is async: true and uses capture_log" >&2
    printf '%s\n' "$SCAN_OUT" | awk -F'\t' -v p="$f" '$1=="HIT" && $2==p{print "       " $2 ":" $3}' >&2
  done
  TOTAL="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"' | wc -l | tr -d ' ')"
fi

NFILES="$(printf '%s' "$FILES" | grep -c . || true)"
SCANNED="$(find "$SCANDIR" \( -name '*.exs' -o -name '*.ex' \) -type f -print | wc -l | tr -d ' ')"

if [ "$rc" = 0 ]; then
  echo "refute-on-absence-capture-log-check: OK — 0 site(s), baseline 0, $SCANNED file(s) scanned"
else
  {
    echo ""
    echo "  $TOTAL site(s) in $NFILES file(s). Baseline is 0 — there is nothing to grandfather."
    echo "  FIX: assert the expected line is PRESENT, or make the module synchronous"
    echo "       (async: false) with a one-line comment naming the reason. A device-wide"
    echo "       capture cannot support an absence claim while other modules run beside it."
    echo "  This gate does NOT ban capture_log under async — a presence assert is sound."
  } >&2
fi
exit "$rc"
