#!/usr/bin/env bash
# required-checks-floor.sh — the SUPERSET floor for a regenerated spec.
#
# WHY A FLOOR AT ALL (honest-gates D64, D74)
#
# `scripts/required-checks-generate.sh` derives the required set from check runs
# it observed on the sampled heads. That is the right way to build the list —
# and it is also a silent downgrade waiting to happen. Sample two heads where
# one required job happened to be cancelled, and the generator honestly emits a
# SMALLER set. Nothing in the toolchain notices: `--payload` builds, the PUT
# returns 200, `required-checks-verify.sh` compares the spec against live
# protection and both agree, because the spec IS the thing that shrank. A
# one-name spec passes its own verify end to end. That is the shape this script
# refuses.
#
# WHY A COUNT FLOOR IS NOT ENOUGH, and this is the whole reason the script is
# not three lines of `jq length`:
#
#   committed: ["Elixir gate", "PR references an active task"]
#   candidate: ["PR references an active task", "Boundary gate (advisory)"]
#
# Two in, two out. A `>= 2` floor is GREEN on that specimen, and it has swapped
# the repo's only blocking Elixir gate for a check that carries
# continue-on-error and therefore cannot fail. So the comparison is a SET
# comparison, on the pair (context, app_id) — an app_id that drifted to `null`
# means "any app with checks:write may satisfy this name" (D21) and is exactly
# as much of a loss as the name disappearing.
#
# WHY THE REFERENCE COMES FROM `git show origin/main:…` AND NEVER THE WORKTREE
#
# The PR that regenerates the spec REWRITES `.github/required-checks.json`. A
# floor that reads the worktree copy compares the candidate to itself and passes
# unconditionally — a guard that structurally cannot fail, in an epic about
# guards that cannot fail. The reference is therefore read out of git, from the
# branch protection is actually installed on.
#
# GROWTH IS NOT SILENTLY FINE EITHER (D69)
#
# A name the generator newly promotes is a real decision — it becomes a context
# every PR in the repo must render forever, and a job that is green today and
# paths-filtered tomorrow deadlocks the branch. So growth exits NON-ZERO with
# the added names printed, and the caller must pass `--acknowledge-growth` to
# say a human looked. Loss is never acknowledgeable; it is exit 1, always.
#
# EXIT CODES
#   0  candidate ⊇ committed, and no unacknowledged growth
#   1  LOSS — a committed (context, app_id) is missing or weakened. Hard.
#   2  GROWTH — the candidate is a strict superset and nobody acknowledged it
#
# USAGE
#   scripts/required-checks-floor.sh <candidate.json>
#   scripts/required-checks-floor.sh --reference <ref.json> <candidate.json>
#   scripts/required-checks-floor.sh --acknowledge-growth <candidate.json>
#   scripts/required-checks-floor.sh --ref-rev origin/main <candidate.json>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_PATH=".github/required-checks.json"

REF_FILE=""
REF_REV="origin/main"
ACK_GROWTH=0
CANDIDATE=""
QUIET=0

fail() { echo "FAIL: $*" >&2; exit 1; }

# Reading the reference is itself a thing that can fail, and an unreadable
# reference must never degrade into "nothing to compare against, so pass".
read_reference() {
  if [ -n "$REF_FILE" ]; then
    [ -f "$REF_FILE" ] || fail "cannot read reference file $REF_FILE"
    jq -e . "$REF_FILE" >/dev/null 2>&1 || fail "$REF_FILE is not valid JSON"
    cat "$REF_FILE"
    return
  fi
  local out
  out="$(git -C "$REPO_ROOT" show "$REF_REV:$SPEC_PATH" 2>&1)" \
    || fail "cannot read $REF_REV:$SPEC_PATH — the floor has no reference to compare against (failure, never a skip): $out"
  jq -e . <<<"$out" >/dev/null 2>&1 || fail "$REF_REV:$SPEC_PATH is not valid JSON"
  printf '%s' "$out"
}

# The pair, normalized: a missing app_id and an explicit null are the same
# weakening and must compare equal so neither can hide behind the other.
checks_of() {
  jq -S -c '
    .protection.required_status_checks.checks
    // error("no .protection.required_status_checks.checks")
    | map({context: .context, app_id: (.app_id // null)})
    | sort_by(.context, (.app_id | tostring))
  ' 2>/dev/null || fail "input does not carry .protection.required_status_checks.checks"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --reference) REF_FILE="$2"; shift 2 ;;
      --ref-rev) REF_REV="$2"; shift 2 ;;
      --spec-path) SPEC_PATH="$2"; shift 2 ;;
      --acknowledge-growth) ACK_GROWTH=1; shift ;;
      --quiet) QUIET=1; shift ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      -*) fail "unknown argument: $1" ;;
      *) [ -z "$CANDIDATE" ] || fail "exactly one candidate spec, got a second: $1"
         CANDIDATE="$1"; shift ;;
    esac
  done

  [ -n "$CANDIDATE" ] || fail "no candidate spec given (usage: $0 [--reference REF] <candidate.json>)"
  [ -f "$CANDIDATE" ] || fail "cannot read candidate spec $CANDIDATE"
  jq -e . "$CANDIDATE" >/dev/null 2>&1 || fail "$CANDIDATE is not valid JSON"

  local ref want got
  ref="$(read_reference)"
  want="$(printf '%s' "$ref" | checks_of)"
  got="$(checks_of < "$CANDIDATE")"

  # A reference that requires nothing cannot floor anything. Say so rather than
  # returning the vacuous pass.
  [ "$(jq 'length' <<<"$want")" -gt 0 ] \
    || fail "the reference lists ZERO required contexts — there is no floor to hold"
  [ "$(jq 'length' <<<"$got")" -gt 0 ] \
    || fail "the candidate lists ZERO required contexts — a spec that requires nothing cannot fail"

  local lost gained
  lost="$(jq -r --argjson g "$got" '[.[] | select(. as $w | $g | index($w) | not)] | .[] | "\(.context)\t\(.app_id // "null")"' <<<"$want")"
  gained="$(jq -r --argjson w "$want" '[.[] | select(. as $g | $w | index($g) | not)] | .[] | "\(.context)\t\(.app_id // "null")"' <<<"$got")"

  if [ -n "$lost" ]; then
    {
      echo "FLOOR BREACH — the candidate spec is NOT a superset of $( [ -n "$REF_FILE" ] && printf '%s' "$REF_FILE" || printf '%s:%s' "$REF_REV" "$SPEC_PATH" )."
      echo "Every line below is a gate that is live on the protected branch today and would stop being one:"
      printf '%s\n' "$lost" | sed 's/^/  LOST  /'
      echo
      echo "A count floor (>= N) would have PASSED a swap that keeps the count and drops the only blocking gate."
      echo "Regenerate from heads where every required job actually ran, or, if the removal is intended,"
      echo "change the reference on main in a PR that says why — never by letting a sample shrink the set."
    } >&2
    exit 1
  fi

  if [ -n "$gained" ]; then
    {
      echo "FLOOR: the candidate ADDS required context(s). This is a decision, not a detail —"
      echo "every PR in this repo must render these forever, and a job that is green today and"
      echo "paths-filtered tomorrow deadlocks main (D69)."
      printf '%s\n' "$gained" | sed 's/^/  ADDED  /'
    } >&2
    if [ "$ACK_GROWTH" -eq 1 ]; then
      echo "FLOOR OK: superset held; growth ACKNOWLEDGED (--acknowledge-growth), $(jq 'length' <<<"$got") context(s)."
      exit 0
    fi
    echo "Re-run with --acknowledge-growth once a human has decided each added name belongs." >&2
    exit 2
  fi

  [ "$QUIET" -eq 1 ] || echo "FLOOR OK: the candidate holds the floor exactly — $(jq 'length' <<<"$got") context(s), identical on context AND app_id."
  exit 0
}

main "$@"
