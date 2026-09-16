#!/usr/bin/env bash
# pds-charter-anchors-check.sh — PDS-D299 made runnable.
#
# PDS-D299 is law: "ADJUDICATE BY CONTENT; CITED LINE NUMBERS ARE UNTRUSTWORTHY."
# A bare `file.sh:<line>` citation is a SNAPSHOT — it silently stops resolving the next
# time the file grows a line above it, and nothing reds. A CONTENT anchor is a
# PREDICATE: it names bytes that either are in the file or are not, so it can be
# checked by machine on every commit, forever, with no baseline to maintain.
#
# THE ANCHOR FORM, as carried by the charter:
#
#     `<path>`@`<literal>`
#
# e.g.  `scripts/pds-pull-proof.sh`@`spent_now=$((spent + 1))`
#
# RULE (arm A, hard): every anchor must match its file EXACTLY ONCE. Zero hits =
# the citation rotted. Two or more = the citation is ambiguous and a reader
# cannot tell which site the decision means; that is a rotted citation too, just
# one that has not bitten yet.
#
# RULE (arm B, ratchet): the count of surviving LEGACY bare-line citations
# (`pds-pull-proof.sh:NNN`) must not EXCEED the ceiling below. Fewer is progress,
# never a red — a ratchet that fires when the world improves trains people to
# ignore it — but it prints a LOWER-THE-CEILING line so the number cannot drift
# quietly upward behind a stale floor.
#
# Usage: bash scripts/pds-charter-anchors-check.sh [charter-path]
# Exit 0 = every anchor resolves and no new bare citation appeared. Exit 1 = a
# citation no longer resolves; the output names each one.

# shellcheck disable=SC2016  # backticks inside single quotes are literal citation syntax, not expansions
set -uo pipefail

CHARTER="${1:-.claude/workflows/bp-pds-charter.md}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Legacy bare `pds-pull-proof.sh:NNN` citations still in the charter. Lower this
# as decisions are converted to anchors; raising it is the thing arm B refuses.
LEGACY_BARE_CEILING="${PDS_ANCHOR_LEGACY_CEILING:-15}"

if [ ! -f "$CHARTER" ]; then
  printf 'pds-charter-anchors-check: charter not found: %s\n' "$CHARTER" >&2
  exit 2
fi

fails=0
checked=0

# Extract `path`@`literal` pairs. A line may carry more than one; perl walks
# every match on every line rather than the first, and prints them NUL-free on
# one tab-separated line each.
# Parse `path`@`literal` pairs. BOTH halves must sit on ONE line: a line-wrapped
# anchor would otherwise vanish from the parse and be silently unchecked, which
# is the exact failure this script exists to make impossible. So we also count
# the raw joints (a backtick, an @, a backtick) and require that every joint
# produced a parsed pair — an absence is never caught by inspection.
# The literal path `<path>` is the documented placeholder used when the charter
# SHOWS the form; it is parsed, then skipped.
anchors="$(perl -ne 'while (/`([^`\n]+)`\@`([^`\n]+)`/g) { print "$1\t$2\n" }' "$CHARTER")"
joints="$(grep -o '`@`' "$CHARTER" | wc -l | tr -d ' ')"
pairs="$(printf '%s' "$anchors" | grep -c . || true)"

if [ "$joints" -ne "$pairs" ]; then
  printf 'MALFORMED  %s joint(s) of the form `@` but only %s parsed on a single line.\n' "$joints" "$pairs"
  printf '           An anchor was line-wrapped. Keep `<path>`@`<literal>` on ONE line,\n'
  printf '           or it is never checked.\n'
  fails=$((fails + 1))
fi

if [ -n "$anchors" ]; then
  while IFS=$'\t' read -r path literal; do
    [ -n "$path" ] || continue
    [ "$path" = "<path>" ] && continue   # the documented placeholder, not an anchor
    checked=$((checked + 1))
    if [ ! -f "$path" ]; then
      printf 'ROTTED  %s\n        file does not exist; literal: %s\n' "$path" "$literal"
      fails=$((fails + 1))
      continue
    fi
    # -F: the literal is bytes, never a pattern. grep -c counts LINES, which is
    # what we want: an anchor naming a line that appears twice is ambiguous.
    hits="$(grep -cF -- "$literal" "$path")"
    if [ "$hits" -eq 1 ]; then
      continue
    elif [ "$hits" -eq 0 ]; then
      printf 'ROTTED  %s\n        literal no longer present: %s\n' "$path" "$literal"
      fails=$((fails + 1))
    else
      printf 'AMBIGUOUS  %s\n        literal matches %s lines, must match exactly 1: %s\n' "$path" "$hits" "$literal"
      fails=$((fails + 1))
    fi
  done <<< "$anchors"
fi

# Arm B — the legacy bare-citation ratchet.
bare="$(grep -oE 'pds-pull-proof\.sh`?:[0-9]' "$CHARTER" | wc -l | tr -d ' ')"

printf '\n'
printf 'anchors checked ..... %s (arm A: each must resolve to exactly 1 line)\n' "$checked"
printf 'anchors rotted ...... %s\n' "$fails"
printf 'legacy bare cites ... %s (ceiling %s)\n' "$bare" "$LEGACY_BARE_CEILING"

if [ "$bare" -gt "$LEGACY_BARE_CEILING" ]; then
  printf '\nFAIL: a NEW bare `pds-pull-proof.sh:NNN` citation was added (%s > ceiling %s).\n' "$bare" "$LEGACY_BARE_CEILING"
  printf '      PDS-D299 forbids adjudicating by line number. Cite content instead:\n'
  printf '      `scripts/pds-pull-proof.sh`@`<a unique literal from the line you mean>`\n'
  fails=$((fails + 1))
elif [ "$bare" -lt "$LEGACY_BARE_CEILING" ]; then
  printf '\nPROGRESS: legacy bare citations are down to %s. LOWER THE CEILING to %s in this script\n' "$bare" "$bare"
  printf '          so the gain is locked in. This is NOT a failure.\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '\nRESULT: FAIL — %s citation(s) do not resolve.\n' "$fails"
  exit 1
fi

printf '\nRESULT: PASS — every charter content anchor resolves uniquely.\n'
exit 0
