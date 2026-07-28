#!/usr/bin/env bash
# bp-merge.sh — the fleet's merge verb, as one argument-free command.
#
# THIS IS A THIN WRAPPER AND NEVER A REQUIRED DEPENDENCY (honest-gates D55).
#
#   With the required context green, plain `gh pr merge --squash` — no flags at
#   all — merges under `enforce_admins: true`, exit 0 (measured 2026-07-28,
#   mergedAt 12:40:57Z). An agent that never learns this script exists still
#   merges correctly and still respects protection. Nothing here is load-bearing
#   for correctness; it adds a pre-flight and a bounded wait, nothing else. If
#   this file is broken, missing, or you simply do not trust it, run
#   `gh pr merge --squash --delete-branch` by hand and read what gh tells you —
#   gh prints both escape hatches itself when it blocks.
#
# WHAT IT ADDS
#
#   1. DEADLOCK PRE-FLIGHT, FIRST. It calls scripts/required-checks-verify.sh
#      --deadlock (it does NOT reimplement it — D14) before spending a single
#      minute waiting. A head that can never satisfy the required set is named
#      up front instead of after twenty minutes of polling.
#   2. A bounded wait, then a merge on green.
#   3. Over budget: it prints the PR URL and the re-run command and exits
#      non-zero. It does NOT hand off to auto-merge. `allow_auto_merge` stays
#      FALSE (D53: gh forwards `expectedHeadOid` to the enable mutation and
#      GitHub accepts-and-ignores it, so the pin is a placebo, and the flag is
#      unreadable afterwards — write-only safety is not safety).
#   4. Red: it refuses and QUOTES gh's own refusal verbatim.
#
#   It never passes the admin bypass and never queues the merge; the two flags
#   this repo's merge protocol must stop using appear nowhere below except in
#   these comments. The merge is a plain `gh pr merge --squash --delete-branch`.
#
# THE EXIT TABLE IS KEYED ON THE REFUSAL STRING, NEVER THE EXIT CODE (D54)
#
#   Measured on a freshly protected throwaway base: EVERY refusal shape exits 1
#   — deadlock, red, cancelled, pending, plural and gh's own client-side block.
#   The exit code carries no information at all, so the classifier below reads
#   the message. Six arms plus an explicit UNRECOGNISED default that refuses:
#
#     "base branch policy prohibits"      CLIENT_BLOCK  gh blocked locally; the API was never reached
#     "N of M required status checks…"    PLURAL        carries counts and CATEGORIES, never names, and
#                                                       the categories DO NOT SUM ("2 of 2 … : 1 expected."),
#                                                       so it falls through to the set-difference detector
#     "… is expected."                    DEADLOCK      the context never rendered on this head
#     "… is failing."                     RED           RE-RUN FIRST, then investigate (D57)
#     "… is cancelled."                   RERUN         a superseded run, not a code defect
#     "… is in progress."                 WAIT          ABSENT from D38, and the most common real state
#     anything else                       UNRECOGNISED  refuse loudly — NEVER assume green
#
#   The `is failing.` row advises a re-run before any code investigation because
#   `Elixir gate` LAUNDERS cancellation into failure (D57): elixir.yml's
#   aggregator is `if: always()` and its decide() has no `cancelled` arm, so five
#   cancelled upstream jobs conclude `failure` and GitHub refuses the merge with
#   `… is failing.` On a fleet that force-pushes stacked branches daily, a
#   superseded run is indistinguishable from a real bug at the required-context
#   level. Re-run first. It is thirty seconds and it is right most of the time.
#
# EXIT CODES (this script's own; unrelated to gh's, which is always 1)
#   0 merged · 1 refused (see the quoted message) · 2 over budget
#   3 the PRE-FLIGHT or the set-difference detector refused: this head can never
#     go green as it stands (DEADLOCK, or a required context concluded in a
#     state nothing re-reports). Precise scope, stated because it is easy to
#     misread: a DEADLOCK or RERUN learned from GH's OWN refusal string mid-loop
#     exits 1 like every other quoted refusal — 3 means the DETECTOR said so.
#
# USAGE
#   scripts/bp-merge.sh              # no arguments; the PR is derived from HEAD
#   BP_MERGE_BUDGET_SECONDS=2400 scripts/bp-merge.sh
#   BP_MERGE_POLL_SECONDS=15 scripts/bp-merge.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$REPO_ROOT/scripts/required-checks-verify.sh"

BUDGET_SECONDS="${BP_MERGE_BUDGET_SECONDS:-1200}"
POLL_SECONDS="${BP_MERGE_POLL_SECONDS:-30}"

PR_NUMBER=""
PR_URL=""
HEAD_SHA=""

die() { echo "bp-merge: $*" >&2; exit 1; }

# ── the classifier ───────────────────────────────────────────────────────────
# Pure: one string in, one state token out. No I/O, no gh, no clock — this is
# the whole reason scripts/bp-merge.test.sh can drive it over captured fixture
# strings without touching GitHub.
#
# ORDER IS LOAD-BEARING. The plural arm must precede the singular ones: the
# plural forms read `… are expected.` / `… have not succeeded: 1 expected and 1
# failing.` and would otherwise be swallowed by the RED or DEADLOCK arm and
# reported with a confidence the message does not support.
classify_refusal() {
  case "$1" in
    *"base branch policy prohibits"*) printf 'CLIENT_BLOCK\n' ;;
    *"required status checks"*)       printf 'PLURAL\n' ;;
    *"is expected."*)                 printf 'DEADLOCK\n' ;;
    *"is failing."*)                  printf 'RED\n' ;;
    *"is cancelled."*)                printf 'RERUN\n' ;;
    *"is in progress."*)              printf 'WAIT\n' ;;
    *)                                printf 'UNRECOGNISED\n' ;;
  esac
}

# Exactly one named resolving command per state. A state whose advice is "look
# into it" is not advice; if you cannot name the command, the row is not done.
refusal_advice() {
  local state="$1" pr="${2:-<pr>}" sha="${3:-<sha>}"
  case "$state" in
    CLIENT_BLOCK)
      printf 'gh blocked this CLIENT-SIDE from its own read of the base branch policy; the merge API was never called.\n'
      printf 'RESOLVE: gh pr view %s --json mergeStateStatus,mergeable,statusCheckRollup\n' "$pr"
      ;;
    PLURAL)
      printf 'A plural refusal carries COUNTS and CATEGORIES, never names — and the categories DO NOT SUM\n'
      printf '(measured: "2 of 2 required status checks have not succeeded: 1 expected."). At N>1 the set\n'
      printf 'difference against the committed spec is the ONLY way to learn which context is missing (D38).\n'
      printf 'RESOLVE: scripts/required-checks-verify.sh --deadlock --sha %s\n' "$sha"
      ;;
    DEADLOCK)
      printf 'A required context never rendered on this head, so GitHub will report it "expected" forever.\n'
      printf 'RESOLVE: scripts/required-checks-verify.sh --deadlock --sha %s\n' "$sha"
      ;;
    RED)
      printf 'A required context concluded FAILURE — but RE-RUN FIRST, BEFORE reading any code: "Elixir gate"\n'
      printf 'launders cancellation into failure (D57), and on a fleet that force-pushes stacked branches a\n'
      printf 'superseded run is indistinguishable from a real defect at the required-context level.\n'
      printf 'RESOLVE: gh run rerun --failed <run-id>          # gh pr checks %s  prints the run links\n' "$pr"
      ;;
    RERUN)
      printf 'A required context concluded CANCELLED — a superseded run, not a code defect. It blocks with\n'
      printf 'neither "is failing." nor "is expected.", and nothing will ever re-report it on its own.\n'
      printf 'RESOLVE: gh run rerun --failed --repo FRIKKern/barkpark <run-id>\n'
      ;;
    WAIT)
      printf 'A required context is still running. This is the most common state and it is not an error.\n'
      printf 'RESOLVE: gh pr checks %s --watch\n' "$pr"
      ;;
    UNRECOGNISED)
      printf 'UNRECOGNISED REFUSAL. This shape is not in the measured table, so this script refuses to guess —\n'
      printf 'a parser that assumes green on an unknown string is exactly the vacuous pass this epic exists\n'
      printf 'for. Read the quoted message above, then extend the table in scripts/bp-merge.sh.\n'
      printf 'RESOLVE: gh pr merge %s --squash --delete-branch      # by hand, and read what gh says\n' "$pr"
      ;;
    *)
      printf 'internal: refusal_advice called with unknown state %s\n' "$state"
      ;;
  esac
}

# ── everything below needs a real GitHub; the harness never reaches it ───────
resolve_pr() {
  command -v gh >/dev/null 2>&1 || die "gh is not installed — this wrapper is optional; merge by hand."
  local json
  json="$(gh pr view --json number,url,headRefOid,state,isDraft 2>&1)" \
    || die "no pull request for the current branch: $json"
  PR_NUMBER="$(printf '%s' "$json" | jq -r '.number')"
  PR_URL="$(printf '%s' "$json" | jq -r '.url')"
  HEAD_SHA="$(printf '%s' "$json" | jq -r '.headRefOid')"
  [ "$(printf '%s' "$json" | jq -r '.state')" = "OPEN" ] \
    || die "PR #$PR_NUMBER is not OPEN — nothing to merge."
  [ "$(printf '%s' "$json" | jq -r '.isDraft')" = "false" ] \
    || die "PR #$PR_NUMBER is a DRAFT — mark it ready first: gh pr ready $PR_NUMBER"
  echo "bp-merge: PR #$PR_NUMBER  head $HEAD_SHA"
  echo "          $PR_URL"
}

# Pre-flight. Never reimplemented here — this shells out to the one detector
# that already exists, whose exit codes are its contract (D14).
#   0 = every required context rendered · 3 = DEADLOCK · 4 = RE-RUN (cancelled)
preflight() {
  echo "bp-merge: pre-flight — required-checks-verify.sh --deadlock"
  local rc=0
  bash "$VERIFY" --deadlock --sha "$HEAD_SHA" || rc=$?
  case "$rc" in
    0) echo "bp-merge: pre-flight ok — every required context is present on this head." ;;
    3) echo "bp-merge: REFUSED before waiting — the head can never satisfy the required set (named above)." >&2
       exit 3 ;;
    4) echo "bp-merge: REFUSED before waiting — a required context concluded CANCELLED (named above)." >&2
       echo "          Nothing will re-report it on its own. Re-run it, then run this again." >&2
       exit 3 ;;
    *) echo "bp-merge: REFUSED — the deadlock detector could not read its inputs (exit $rc)." >&2
       echo "          An unreadable pre-flight is a refusal, never a skip." >&2
       exit 1 ;;
  esac
}

# A plural refusal names nothing, so ask the detector which context is missing.
resolve_plural() {
  echo "bp-merge: plural refusal — falling through to the set-difference detector to get a NAME." >&2
  local rc=0
  bash "$VERIFY" --deadlock --sha "$HEAD_SHA" >&2 || rc=$?
  case "$rc" in
    3) echo "bp-merge: DEADLOCK (named above) — this head can never go green." >&2; exit 3 ;;
    4) echo "bp-merge: RE-RUN (a required context is CANCELLED, named above)." >&2; exit 3 ;;
    0) return 0 ;;
    *) echo "bp-merge: the detector could not read its inputs (exit $rc) — refusing." >&2; exit 1 ;;
  esac
}

refuse() {
  local state="$1" msg="$2"
  {
    echo
    echo "bp-merge: REFUSED — $state"
    echo "  gh said, verbatim:"
    printf '%s\n' "$msg" | sed 's/^/    /'
    echo
    refusal_advice "$state" "$PR_NUMBER" "$HEAD_SHA" | sed 's/^/  /'
    echo
    echo "  PR: $PR_URL"
  } >&2
  exit 1
}

merge_loop() {
  local deadline=$(( $(date +%s) + BUDGET_SECONDS ))
  local out rc state waited=0
  while :; do
    rc=0
    out="$(gh pr merge "$PR_NUMBER" --squash --delete-branch 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "bp-merge: MERGED #$PR_NUMBER (squash, branch deleted)."
      return 0
    fi
    state="$(classify_refusal "$out")"
    case "$state" in
      WAIT) : ;;
      PLURAL)
        # No names in the message. Ask the detector; if it says the contexts are
        # all present, the plural refusal is pending-or-failing — and the string
        # itself is the only thing that can tell those apart.
        resolve_plural
        case "$out" in
          *failing*) refuse "$state" "$out" ;;
          *)         : ;;
        esac
        ;;
      *) refuse "$state" "$out" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      {
        echo
        echo "bp-merge: OVER BUDGET after ${waited}s (budget ${BUDGET_SECONDS}s). NOT merged, and deliberately NOT queued:"
        echo "  this repo keeps unattended merging switched off (D53), so nothing lands while you are away."
        echo "  gh last said:"
        printf '%s\n' "$out" | sed 's/^/    /'
        echo "  PR: $PR_URL"
        echo "  RESOLVE: scripts/bp-merge.sh        # run it again; or BP_MERGE_BUDGET_SECONDS=2400 scripts/bp-merge.sh"
      } >&2
      exit 2
    fi
    echo "bp-merge: waiting (${waited}s/${BUDGET_SECONDS}s) — $(printf '%s' "$out" | head -1)"
    sleep "$POLL_SECONDS"
    waited=$(( waited + POLL_SECONDS ))
  done
}

main() {
  case "${1:-}" in
    # Print the header block by SHAPE, not by a hard-coded line range: the
    # range version silently truncated --help the moment anyone added a line
    # to a comment above, which is the same class of quiet wrongness this
    # script exists to refuse.
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    "") : ;;
    *) die "this command takes NO arguments (got '$1'); the PR is derived from the current branch." ;;
  esac
  [ -x "$VERIFY" ] || [ -f "$VERIFY" ] || die "missing $VERIFY — the pre-flight cannot run."
  resolve_pr
  preflight
  merge_loop
}

# Sourced by scripts/bp-merge.test.sh to drive the classifier directly. The
# harness must never reach resolve_pr/merge_loop, and this is the seam that
# guarantees it.
if [ "${BP_MERGE_LIB:-0}" != "1" ]; then
  main "$@"
fi
