#!/usr/bin/env bash
# format-drift-ceiling.sh — shrink-only ratchet on api/ Elixir format drift.
#
# WHY THIS EXISTS (honest-gates charter D10/D11).
# The elixir.yml `Format` job carries `continue-on-error: true`. A gate that
# cannot fail does not hold a line — it GROWS its population: 87 -> 91 -> 92
# -> 94 unformatted files across 48h, three timestamps, while every run
# concluded `success`. Deleting the job destroys the only signal that makes
# promotion verifiable; requiring it today reds 100% of merges. The third
# option is this ceiling: the drifted set becomes a COMMITTED ROSTER that CI
# forbids growing. The population can then only shrink.
#
# THE DEP-ERROR TRAP (charter D3). Exit code can NEVER discriminate a
# dependency failure from a real verdict — measured live, `mix` exits 1 in
# all four of {dep-missing format, real format drift, dep-missing test, real
# test failure}. A harness that reads $? alone reports a dep error as "zero
# files drifted" and certifies a broken checkout as clean. Only stdout text
# discriminates, so `Unknown dependency` / `Unchecked dependencies` are
# treated here as a HARD ERROR, never as a count.
#
# THE PATH-ANCHORING TRAP. `mix format --check-formatted` prints the drifted
# paths as ABSOLUTE header lines, but it may also print diff bodies whose
# text contains relative-looking path fragments. A naive
# `grep -oE '(lib|test)/...'` over the whole output over-counts (measured:
# 97 vs the true 92). Anchor on the absolute prefix of the api/ directory.
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_DIR="$REPO_ROOT/api"
BASELINE_FILE="$REPO_ROOT/.format-drift-ceiling"

die() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -d "$API_DIR" ] || die "api/ not found at $API_DIR"
[ -f "$BASELINE_FILE" ] || die ".format-drift-ceiling is missing — the ceiling has no baseline to compare against"

# --- read the committed baseline -------------------------------------------
# Format: a `count: N` line (the ceiling) plus one repo-relative-to-api/ path
# per line for every file currently permitted to be drifted. Blank lines and
# `#` comments ignored.
CEILING="$(sed -n 's/^count:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$BASELINE_FILE" | head -1)"
[ -n "$CEILING" ] || die ".format-drift-ceiling has no 'count: N' line"

ROSTER="$(mktemp)"
DRIFTED="$(mktemp)"
RAW="$(mktemp)"
trap 'rm -f "$ROSTER" "$DRIFTED" "$RAW"' EXIT

grep -v '^[[:space:]]*#' "$BASELINE_FILE" \
  | grep -v '^[[:space:]]*count:' \
  | sed 's/[[:space:]]*$//' \
  | grep -v '^$' \
  | sort -u > "$ROSTER"

ROSTER_N="$(wc -l < "$ROSTER" | tr -d ' ')"
if [ "$ROSTER_N" != "$CEILING" ]; then
  die ".format-drift-ceiling is self-inconsistent: 'count: $CEILING' but $ROSTER_N paths are listed. Fix the file — the count and the roster must agree."
fi

# --- measure current drift --------------------------------------------------
cd "$API_DIR" || die "cannot cd into $API_DIR"
mix format --check-formatted > "$RAW" 2>&1
MIX_STATUS=$?

# D3: text discriminates, exit code does not. Check this BEFORE trusting the
# count — a dep failure produces zero path matches, which would otherwise
# read as a perfectly clean tree.
if grep -qE 'Unknown dependency|Unchecked dependencies' "$RAW"; then
  echo "FAIL: mix could not resolve dependencies — this is NOT a verdict on formatting." >&2
  echo "      Run 'mix deps.get' in api/ and re-run. Raw mix output:" >&2
  sed 's/^/      | /' "$RAW" >&2
  exit 1
fi

grep -oE "^.*${API_DIR}/(lib|test)/[A-Za-z0-9_/.-]+\.exs?" "$RAW" \
  | grep -oE "${API_DIR}/(lib|test)/[A-Za-z0-9_/.-]+\.exs?" \
  | sed "s#^${API_DIR}/##" \
  | sort -u > "$DRIFTED"

COUNT="$(wc -l < "$DRIFTED" | tr -d ' ')"

# A non-zero exit with no parsed paths and no dep marker means mix failed for
# a reason we do not understand. Never call that zero.
if [ "$MIX_STATUS" -ne 0 ] && [ "$COUNT" -eq 0 ]; then
  echo "FAIL: 'mix format --check-formatted' exited $MIX_STATUS but named no files — unrecognised failure, refusing to report a count of zero." >&2
  sed 's/^/      | /' "$RAW" >&2
  exit 1
fi

# --- the ratchet ------------------------------------------------------------
NEW="$(comm -23 "$DRIFTED" "$ROSTER")"

if [ -n "$NEW" ]; then
  NEW_N="$(printf '%s\n' "$NEW" | grep -c '^')"
  echo "FAIL: files drifted out of format that are NOT on the committed ceiling roster:" >&2
  # shellcheck disable=SC2001  # per-LINE prefixing of a multi-line string; ${//} substitutes globally, not per line
  echo "$NEW" | sed 's#^#      api/#' >&2
  echo "" >&2
  echo "      The ceiling is shrink-only. Run in api/:" >&2
  echo "        mix format $(echo "$NEW" | tr '\n' ' ')" >&2

  # A gate must say what it means. One or two off-roster files is ordinary new
  # drift. A DOZEN at once, in a PR that did not touch a dozen files, is almost
  # certainly a formatter-version disagreement — and a reader who cannot tell
  # those two apart learns to dismiss this check, which is the precise failure
  # this ratchet exists to end. So the gate names the hypothesis itself.
  if [ "$NEW_N" -ge 10 ]; then
    echo "" >&2
    echo "      NOTE: $NEW_N files at once is a lot. If your PR did not touch them," >&2
    echo "      suspect a FORMATTER VERSION disagreement, not new drift. This roster" >&2
    echo "      is generated on CI's pinned Elixir (see .github/workflows/elixir.yml);" >&2
    echo "      a different local Elixir can reformat the same source differently." >&2
    echo "      Check 'elixir --version' against the pin before formatting anything." >&2
    echo "      The remedy is to REGENERATE .format-drift-ceiling on the pinned" >&2
    echo "      toolchain — never to add continue-on-error to this job." >&2
  fi
  exit 1
fi

if [ "$COUNT" -gt "$CEILING" ]; then
  echo "FAIL: $COUNT drifted files exceeds the ceiling of $CEILING." >&2
  exit 1
fi

if [ "$COUNT" -lt "$CEILING" ]; then
  echo "ok:   $COUNT drifted files, ceiling is $CEILING."
  echo "notice: the population shrank — LOWER the ceiling to $COUNT and drop the now-formatted"
  echo "        paths from .format-drift-ceiling, so the ground you gained is held."
  comm -13 "$DRIFTED" "$ROSTER" | sed 's#^#        - api/#'
  exit 0
fi

echo "ok:   $COUNT drifted files, exactly at the ceiling of $CEILING. No new drift."
exit 0
