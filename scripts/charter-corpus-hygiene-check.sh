#!/usr/bin/env bash
# Charter-corpus marker hygiene. Enforces docs/decisions/0008-charter-corpus-marker-hygiene.md.
#
# The ruling is scrub-forward + one redaction, NOT a blanket rewrite. This guard
# is therefore TWO arms with different shapes, because the two halves of the
# ruling have different baselines:
#
#   ARM A — zero baseline, WHOLE TRACKED TREE.
#     The gyldendal.no address was redacted out of all 4 files that held it, so
#     the repo baseline for that marker is ZERO. A zero baseline needs no
#     exclusion list: any occurrence anywhere is new, and reds. This is the
#     redact-worst half, and it is the only marker that can be enforced this way.
#
#   ARM B — scrub-forward on NEW charters only.
#     The other five markers exist in ~342 tracked files today; banning them
#     outright would red on the corpus the ruling deliberately declined to
#     rewrite. So ARM B bans them in charter files that DID NOT EXIST at the
#     baseline commit. The grandfathered set is computed at runtime from
#     `git ls-tree $BASELINE` — a PREDICATE over a path set, never a
#     hand-maintained file list, so it cannot drift behind the corpus.
#
# DELIBERATE EXCLUSIONS, stated here rather than left silent (ruling §"The cost"):
#   tooling/grip/ledger/**      append-only evidence commons; a dated row must
#                               quote what it observed. Rewriting one falsifies a
#                               past measurement. (Same tree docs-anchors-check.sh
#                               prunes structurally, for the same stated reason.)
#   scripts/measurements/**     captured runs — evidence, same class as above.
#   .omx/**, .tmp-bp89/**       nested-checkout scratch, not authored content.
#   pre-baseline .claude/workflows/*.md   the existing charters: append-only
#                               ruling logs whose D-/GR- rows quote measurements
#                               taken ON the named box.
# ARM A overrides every one of these: a zero-baseline marker is banned in the
# evidence trees too, because nothing there carries it any more.
#
# Markers are written as PATTERNS, not as the literals they catch — the email
# arms match any local-part on the two domains (so a new address on the same
# domain also reds), and the host arms match the /24 each box sits in (so a
# sibling host reds too). That is both broader coverage and the reason this file
# does not itself re-publish an address or a host.
set -uo pipefail

BASELINE="${CHARTER_HYGIENE_BASELINE:-a5c5486163a16b16956ab20a7c5932650f5fd05c}"
ROOT="${CHARTER_HYGIENE_ROOT:-}"
if [ -n "$ROOT" ]; then cd "$ROOT" || exit 2; else
  cd "$(git rev-parse --show-toplevel)" || exit 2
fi

FAIL=0

# --- marker patterns ----------------------------------------------------------
ZERO_BASELINE_PAT='[A-Za-z0-9._%+-]+@gyldendal\.no'
FORWARD_PAT='[A-Za-z0-9._%+-]+@guerrilla\.no|\b89\.167\.28\.[0-9]{1,3}\b|\b157\.180\.90\.[0-9]{1,3}\b|\b178\.105\.92\.[0-9]{1,3}\b|barkpark_indx'

SELF='scripts/charter-corpus-hygiene-check.sh'

# --- ARM A: zero baseline, whole tracked tree ---------------------------------
# `git grep` walks TRACKED files only — the row is about the tracked corpus, and
# this keeps node_modules/_build/deps out without a prune list.
A_HITS=$(git grep -nIE "$ZERO_BASELINE_PAT" -- . 2>/dev/null | grep -v "^$SELF:" || true)
if [ -n "$A_HITS" ]; then
  echo "FAIL: [arm A] a gyldendal.no address is back in the tracked corpus."
  echo "      Its baseline is ZERO (docs/decisions/0008). Redact it; do not allowlist it."
  printf '%s\n' "$A_HITS" | sed 's/^/      /'
  FAIL=1
else
  echo "ok:   [arm A] zero-baseline marker absent from the whole tracked tree"
fi

# --- ARM B: the five remaining markers, on NEW charters only ------------------
if ! git cat-file -e "${BASELINE}^{commit}" 2>/dev/null; then
  echo "FAIL: [arm B] baseline commit $BASELINE is not in this checkout."
  echo "      This guard cannot establish what is grandfathered, so it refuses to"
  echo "      pass silently. Use actions/checkout with fetch-depth: 0."
  exit 1
fi

GRANDFATHERED=$(git ls-tree -r --name-only "$BASELINE" -- .claude/workflows/ 2>/dev/null || true)
CURRENT=$(git ls-files -- '.claude/workflows/*.md' 2>/dev/null || true)

NEW_CHARTERS=$(comm -13 <(printf '%s\n' "$GRANDFATHERED" | sort) <(printf '%s\n' "$CURRENT" | sort))
NEW_COUNT=$(printf '%s\n' "$NEW_CHARTERS" | grep -c . || true)

B_HITS=''
if [ "$NEW_COUNT" -gt 0 ]; then
  # -- separator stops a pathspec that looks like a flag; xargs-free to survive spaces
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    h=$(grep -nIE "$FORWARD_PAT" -- "$f" 2>/dev/null || true)
    [ -n "$h" ] && B_HITS="${B_HITS}${f}:${h}"$'\n'
  done <<< "$NEW_CHARTERS"
fi

if [ -n "$B_HITS" ]; then
  echo "FAIL: [arm B] a NEW charter carries an infrastructure marker."
  echo "      Charters authored after the baseline must use placeholders"
  echo "      (<prod-ip>, <operator-email>, <ssh-key-path>). See docs/decisions/0008."
  printf '%s' "$B_HITS" | sed 's/^/      /'
  FAIL=1
else
  echo "ok:   [arm B] $NEW_COUNT charter(s) added since baseline, none carries a marker"
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "charter-corpus-hygiene: FAILED"
  exit 1
fi
echo ""
echo "charter-corpus-hygiene: PASS"
