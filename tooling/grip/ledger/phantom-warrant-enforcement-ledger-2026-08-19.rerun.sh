#!/usr/bin/env bash
# phantom-warrant-enforcement-ledger-2026-08-19.rerun.sh
#
# RE-DERIVES every counted figure the companion ledger states, and EXITS 1 when
# one has drifted.
#
# WHY THIS EXISTS, AND WHY IT READS THE LEDGER RATHER THAN CARRYING THE NUMBERS
# ITSELF. A figure with no producer goes stale in its own commit. If this script
# hard-coded the counts it would agree with itself forever while the ledger rots
# beside it, which is the exact failure the ledger is about. So the numbers live
# in ONE place — the ledger's FIGURES block — and this script only ever
# re-derives and compares. Mutate a number in the ledger and this reds; that
# mutation proof is recorded in the commit message body, not merely asserted.
#
# THE FOUR PROPERTIES A GATE MUST HAVE, AND HOW THIS ONE GETS THEM
#   1. It can FAIL.        Mutation-proven, both directions (figure and absence).
#   2. It cannot pass VACUOUSLY. A missing or empty FIGURES block is exit 1, not
#      "nothing to check" — an absence must never read as a pass.
#   3. Its population is STATED. Every check prints derived-vs-stated, so a green
#      is legible rather than merely quiet.
#   4. It names WHAT to do on a red. Drift is usually the world moving, not the
#      ledger lying; the message says re-derive and republish, not "fix the code".
#
# USAGE
#   bash tooling/grip/ledger/phantom-warrant-enforcement-ledger-2026-08-19.rerun.sh
#   … --selftest    prove the comparator can fail, without touching the ledger
#
# Runs from the repo root. Read-only: it never writes, never calls the network,
# and never touches a deployed box.

set -uo pipefail

LEDGER_DIR="tooling/grip/ledger"
LEDGER="${LEDGER_DIR}/phantom-warrant-enforcement-ledger-2026-08-19.md"

RED=0
CHECKS=0

fail() { printf 'DRIFT  %s\n' "$1"; RED=1; }
okline() { printf 'ok     %s\n' "$1"; }

# ── the comparator ─────────────────────────────────────────────────────────
# Every check funnels through here so the output shape is uniform and no call
# site can quietly skip the comparison.
compare() {
  local key="$1" derived="$2" stated="$3"
  CHECKS=$((CHECKS + 1))
  if [ -z "$stated" ]; then
    fail "$(printf '%-34s stated=<ABSENT>  derived=%s  — the FIGURES block has no line for this key' "$key" "$derived")"
    return
  fi
  if [ "$derived" = "$stated" ]; then
    okline "$(printf '%-34s %s' "$key" "$derived")"
  else
    fail "$(printf '%-34s stated=%s  derived=%s' "$key" "$stated" "$derived")"
  fi
}

stated_for() {
  # Reads one `key = value` line out of the ledger's FIGURES block. Prints
  # nothing when absent, which compare() treats as a DRIFT rather than a pass.
  [ -f "$LEDGER" ] || return 0
  awk -v want="$1" '
    /^<!-- FIGURES/      { inblock = 1; next }
    inblock && /^-->/    { inblock = 0; next }
    inblock {
      line = $0
      sub(/#.*$/, "", line)
      n = index(line, "=")
      if (n == 0) next
      k = substr(line, 1, n - 1); v = substr(line, n + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k == want) { print v; exit }
    }
  ' "$LEDGER"
}

# ── selftest: prove the comparator discriminates ───────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  echo "SELFTEST — the comparator must accept an agreement and refuse a mismatch."
  RED=0
  compare "selftest/agree" "7" "7"
  [ "$RED" -eq 0 ] || { echo "SELFTEST FAILED: an agreement was reported as drift."; exit 1; }
  compare "selftest/differ" "7" "8"
  [ "$RED" -eq 1 ] || { echo "SELFTEST FAILED: a mismatch did NOT red."; exit 1; }
  RED=0
  compare "selftest/absent" "7" ""
  [ "$RED" -eq 1 ] || { echo "SELFTEST FAILED: an ABSENT stated value did not red — the gate could pass vacuously."; exit 1; }
  echo "SELFTEST PASSED: agreement ok, mismatch reds, absence reds."
  exit 0
fi

# ── preconditions, asserted rather than assumed ────────────────────────────
if [ ! -f "$LEDGER" ]; then
  echo "FATAL: ledger not found at $LEDGER (run from the repo root)." >&2
  exit 1
fi
if [ ! -f ".github/required-checks.json" ]; then
  echo "FATAL: .github/required-checks.json not found (run from the repo root)." >&2
  exit 1
fi
if ! grep -q '^<!-- FIGURES' "$LEDGER"; then
  echo "FATAL: $LEDGER carries no FIGURES block. This gate would check nothing," >&2
  echo "       and checking nothing must never be reported as a pass." >&2
  exit 1
fi

echo "re-deriving against the working tree at $(git rev-parse --short HEAD 2>/dev/null || echo '<no git>')"
echo

# ── A. merge authority ─────────────────────────────────────────────────────
d_required=$(python3 -c '
import json
j = json.load(open(".github/required-checks.json"))
c = j["protection"]["required_status_checks"]["checks"]
print(len(c))
')
compare "required_contexts" "$d_required" "$(stated_for required_contexts)"

d_exclusions=$(python3 -c '
import json
print(len(json.load(open(".github/required-checks.json")).get("exclusions") or []))
')
compare "exclusion_rows" "$d_exclusions" "$(stated_for exclusion_rows)"

d_workflows=$(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | wc -l | tr -d ' ')
compare "workflow_files" "$d_workflows" "$(stated_for workflow_files)"

# ── B. the canonical index ─────────────────────────────────────────────────
# Section 8's five extensions are the REAL declarations. A bare grep also
# catches prose citations in charters and cards, which would pad the ledger —
# so both are stated, and they are different numbers on purpose.
d_canon_all=$(git grep -h "@canonical capability:" -- . | wc -l | tr -d ' ')
compare "canonical_grep_occurrences" "$d_canon_all" "$(stated_for canonical_grep_occurrences)"

d_canon_real=$(git grep -h "@canonical capability:" -- '*.ex' '*.exs' '*.go' '*.ts' '*.tsx' | wc -l | tr -d ' ')
compare "canonical_declarations" "$d_canon_real" "$(stated_for canonical_declarations)"

# ── C. the doctrine surface ────────────────────────────────────────────────
d_claude=$(awk '
  /^#+[ \t]*Golden Rules/  { sec = 1; next }
  /^#+[ \t]*Past Mistakes/ { sec = 1; next }
  /^#+[ \t]/               { sec = 0 }
  sec && /^[0-9]+\./       { n++ }
  END { print n + 0 }
' CLAUDE.md)
compare "claude_md_numbered_claims" "$d_claude" "$(stated_for claude_md_numbered_claims)"

# ── D. stratum B's own enforcer ────────────────────────────────────────────
# INVOCATIONS, not mentions. A mention-shaped grep answers a different question:
# on 2026-09-08 the file carried 8 mentions — 2 path-filter entries, 4 comment
# prose lines, and 2 invocations, one of which is --selftest. Counting mentions
# would report drift 1 -> 8 that does not exist.
d_anchors=$(git grep -h -E '(^|[[:space:];&|(])(bash|sh|\./)[[:space:]]*scripts/docs-anchors-check\.sh' \
              -- '.github/workflows/*.yml' '.github/workflows/*.yaml' \
            | grep -v -- '--selftest' | grep -vc '^[[:space:]]*#' )
compare "docs_anchors_real_invocations" "$d_anchors" "$(stated_for docs_anchors_real_invocations)"

# ── verdict ────────────────────────────────────────────────────────────────
echo
echo "checks run: $CHECKS"
if [ "$CHECKS" -eq 0 ]; then
  echo "FATAL: zero checks ran. A gate that checks nothing is not a green." >&2
  exit 1
fi

if [ "$RED" -ne 0 ]; then
  cat >&2 <<'EOM'

RED — at least one stated figure no longer matches the tree.

WHAT THIS USUALLY MEANS: the world moved, not the ledger lied. These are
denominators over a live repo; workflows get added, @canonical markers get
stamped, exclusion rows accumulate. The remedy is to RE-DERIVE and republish
the ledger's FIGURES block together with any prose that quotes the old number
— NOT to change the code to match a stale figure.

Print the derived values above, update the FIGURES block, and re-read the
surrounding prose: a count usually appears twice, once as data and once as an
argument, and only the first one is mechanically checked.
EOM
  exit 1
fi

echo "GREEN — every stated figure re-derives."
exit 0
