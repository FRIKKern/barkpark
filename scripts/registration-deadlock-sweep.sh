#!/usr/bin/env bash
#
# registration-deadlock-sweep.sh — before a required context goes live, ask the
# only question that matters about the PRs already in flight: does registering
# this name take a PR that GitHub would merge RIGHT NOW and make it unmergeable?
#
# WHY THIS IS NOT "does every open PR render the four contexts"
# ------------------------------------------------------------
# That one-sided test is the obvious one and it is wrong, measurably. Run it on
# this repo today and it refuses on #6086, #6057 and #2907 — three PRs that are
# CONFLICTING/DIRTY, whose merge refs are stale, and which therefore render
# almost nothing at all. They are ALREADY deadlocked, on the `Elixir gate` that
# has been required since 2026-07-28. Registering `Console gate` and `Cloud gate`
# changes nothing about them: they cannot merge before someone rebases, and the
# rebase is what makes every new context render. A guard that counts them as
# casualties never goes green, so it never permits a flip, so it gets bypassed —
# and a guard that is always bypassed is not a guard.
#
# THE PREDICATE IS THEREFORE TWO-SIDED. A PR is a casualty only when BOTH hold:
#
#   (A) it is mergeable AND currently unblocked — GitHub would merge it now, or
#       would merge it as soon as its checks finish;
#   (B) at least one NEWLY proposed context is ABSENT from its head's actual
#       check runs.
#
# Fail (A) and the flip did not break anything that was not already broken. Fail
# (B) and the new contexts report, so the flip is a no-op for that PR.
#
# "NEWLY" IS LOAD-BEARING
# -----------------------
# Only contexts the candidate spec adds over `origin/main`'s can newly deadlock
# anything. A context that is already required and already absent is a live red
# with a live owner; re-reporting it here would drown the one signal this script
# exists to produce.
#
# IT READS CHECK RUNS, IT DOES NOT SIMULATE THEM (D133)
# ----------------------------------------------------
# The tempting shortcut is to look at main's workflow tree, work out which paths
# the PR touches, and predict which jobs will fire. That prediction is wrong for
# exactly the PRs that matter: a PR whose merge ref is stale runs the workflow
# tree AT ITS BASE, not at main's, so a job that main says always runs may not
# exist at that head at all. The only honest source is `GET /commits/<head
# sha>/check-runs`, which is what actually happened.
#
# FAIL-CLOSED
# -----------
# An unreadable PR list, an unreadable check-run feed, or a PR whose mergeability
# GitHub has not computed yet exits 2. A sweep that could not look is never a
# sweep that found nothing — and the UNKNOWN case is not hypothetical: the first
# live run of this script hit nine of nine.
#
# AND AN ALL-SKIPPED SWEEP IS THE SAME FAILURE WEARING A DIFFERENT STATE (D422).
# Measured 2026-08-06 against this repo, twice, six minutes apart, byte-identical:
# thirteen open PRs, THIRTEEN `skip` rows, `casualties: 0`, `NO CASUALTY`, exit 0
# — side (B) was never asked about a single head. Eight of the thirteen were
# MERGEABLE/BLOCKED, which is not a rare alignment: BLOCKED is the state every
# open PR passes through while any required check is in flight. So the verdict is
# now REPORTED WITH ITS COVERAGE, and an evaluated set of zero is exit 2.
#
# AND A CANDIDATE THAT PROPOSES NOTHING NEW IS THE SAME FAILURE ONE BRANCH OVER.
# The all-skip fix above hardened the path where PRs WERE listed. It left the
# path where none ever are: when the candidate's context set already equals the
# baseline's, this script short-circuits before the PR feed exists — no `gh`
# call, no head, no counters — and returns 0. Measured on 2026-08-07 against
# `main`'s own committed spec: rc 0, TWO lines of output, and `grep -c 'PARTIAL
# COVERAGE\|evaluated'` on that output = 0. That is exactly the run a human
# produces by executing the flip packet's steps OUT OF ORDER — sweeping AFTER
# the spec PR has merged, when the candidate and the baseline are the same file
# — and the exit-code channel cannot tell it apart from "I examined every head
# and found no casualty". So the run now prints NO COVERAGE naming what was not
# examined, and `--require-new-context` — which anyone authorizing a flip should
# pass — turns it into a refusal. It is opt-in for the reason the coverage
# refusal is partial: a bare sweep on a branch that did not touch the spec is a
# legitimate no-op, and a guard that can never pass gets bypassed.
#
# EXIT CODES
#   0  no casualty — every unblocked, mergeable PR this sweep could EVALUATE
#      renders every newly proposed context. When some PRs were skipped, the
#      verdict says so on its own line. ALSO 0: the candidate proposes nothing
#      new, in which case NOTHING was examined and the run says NO COVERAGE —
#      pass --require-new-context to make that case exit 2 instead.
#   1  at least one casualty — registering now would newly deadlock a PR that
#      GitHub would merge today
#   2  the sweep could not be evaluated — including the case where every open PR
#      was skipped, so the "no casualty" finding rests on no evidence at all, and
#      the case where the candidate proposes no new context under
#      --require-new-context
#
# USAGE
#   scripts/registration-deadlock-sweep.sh
#   scripts/registration-deadlock-sweep.sh --spec <candidate.json>
#   scripts/registration-deadlock-sweep.sh --ref-rev origin/main
#   scripts/registration-deadlock-sweep.sh --require-new-context   # authorizing a flip
#   scripts/registration-deadlock-sweep.sh --ref-file <baseline.json>   # harness
#   scripts/registration-deadlock-sweep.sh --prs <file.json> --fixture-dir <dir>

set -euo pipefail

# `RC_REPO_ROOT` exists for ONE caller: scripts/required-checks.test.sh writes a
# MUTATED copy of this file into its own tmpdir to prove the two-sided predicate
# is load-bearing, and a copy outside the tree resolves neither the check-runs
# lib nor the git baseline. It is a test seam, not a bypass — every refusal this
# script makes still comes from the real feed.
REPO_ROOT="${RC_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=scripts/lib/check-runs.sh
. "$REPO_ROOT/scripts/lib/check-runs.sh"

REPO="${RC_REPO:-FRIKKern/barkpark}"
SPEC="$REPO_ROOT/.github/required-checks.json"
SPEC_PATH=".github/required-checks.json"
REF_REV="origin/main"
# --ref-file is a HARNESS SEAM, exactly like the floor's --reference (which
# scripts/required-checks.test.sh §12 uses for the same reason). The DEFAULT is
# and stays `git show origin/main:` — a baseline read from the worktree is the
# file the PR is rewriting, so it would make every proposed context look
# already-required and the sweep would never refuse. §16 asserts that default by
# reading this file, so pointing --ref-file at the worktree cannot become the
# quiet norm.
REF_FILE=""
PR_LIMIT=100
PRS_FILE=""
FIXTURE_DIR=""
UNKNOWN_RETRIES=6
UNKNOWN_BACKOFF=5
# OFF by default, and the default is the concession — see the header. ON is the
# setting for the only caller that matters: a human about to authorize a
# required-context flip, who needs "nothing new to sweep" to be a refusal rather
# than the same green a full sweep prints.
REQUIRE_NEW_CONTEXT=0

fail() { echo "FAIL: $*" >&2; exit 2; }

contexts_of() { # <json on stdin>
  jq -r '.protection.required_status_checks.checks[]?.context // empty' | LC_ALL=C sort -u
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) SPEC="$2"; shift 2 ;;
      --ref-rev) REF_REV="$2"; shift 2 ;;
      --ref-file) REF_FILE="$2"; shift 2 ;;
      --spec-path) SPEC_PATH="$2"; shift 2 ;;
      --repo) REPO="$2"; shift 2 ;;
      --limit) PR_LIMIT="$2"; shift 2 ;;
      --prs) PRS_FILE="$2"; shift 2 ;;
      --unknown-retries) UNKNOWN_RETRIES="$2"; shift 2 ;;
      --unknown-backoff) UNKNOWN_BACKOFF="$2"; shift 2 ;;
      --fixture-dir) FIXTURE_DIR="$2"; shift 2 ;;
      --require-new-context) REQUIRE_NEW_CONTEXT=1; shift ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done

  [ -f "$SPEC" ] || fail "no candidate spec at $SPEC"
  jq -e . "$SPEC" >/dev/null 2>&1 || fail "$SPEC is not valid JSON"

  local proposed baseline new_ctx
  proposed="$(contexts_of < "$SPEC")"
  [ -n "$proposed" ] || fail "the candidate spec proposes ZERO contexts — nothing to sweep, and that is a defect not a pass"

  local ref_json ref_label
  if [ -n "$REF_FILE" ]; then
    [ -f "$REF_FILE" ] || fail "no baseline file at $REF_FILE"
    ref_json="$(cat "$REF_FILE")"
    ref_label="$REF_FILE"
  else
    ref_json="$(git -C "$REPO_ROOT" show "$REF_REV:$SPEC_PATH" 2>&1)" \
      || fail "cannot read $REF_REV:$SPEC_PATH — without the baseline every context looks new. On a CI runner the remote-tracking ref often does not exist at all (actions/checkout fetches the PR ref, not origin/main); \`git fetch --no-tags --depth=1 origin main\` first, or pass --ref-file for a harness run."
    ref_label="$REF_REV:$SPEC_PATH"
  fi
  jq -e . <<<"$ref_json" >/dev/null 2>&1 || fail "the baseline is not valid JSON — refusing to sweep against an unreadable reference"
  baseline="$(printf '%s' "$ref_json" | contexts_of)"
  [ -n "$baseline" ] || fail "the baseline requires ZERO contexts — that is an unreadable reference, not an empty one, and it would make EVERY proposed context look new"

  new_ctx="$(comm -23 <(printf '%s\n' "$proposed") <(printf '%s\n' "$baseline") | grep . || true)"

  echo "registration-deadlock-sweep: repo=$REPO candidate=$SPEC baseline=$ref_label"
  if [ -z "$new_ctx" ]; then
    echo "the candidate proposes no context that $REF_REV does not already require — nothing can be NEWLY deadlocked."
    if [ "$REQUIRE_NEW_CONTEXT" -eq 1 ]; then
      fail "the candidate proposes no context that $ref_label does not already require, so this sweep listed no PR, read no head's check runs, and evaluated 0 of them — side (B), does this head render the newly proposed context, was never asked. Under --require-new-context that is exit 2 and not a pass: 'nothing can be NEWLY deadlocked' is a statement about the candidate's shape, never a finding about the open PRs, and it is what this command prints when the spec has ALREADY merged and the sweep is being run after the registration it was supposed to authorize. Sweep the candidate BEFORE it merges, or authorize the flip on per-head check-run evidence gathered by hand and say in writing that this sweep did NOT support it."
    fi
    # THE COPY FENCE (D386, and this wave's D438): this line STATES the absence
    # and stops. It does not tell the operator to re-run, to re-order the packet,
    # or to pass the flag — advice attached to a diagnosis nobody asked for is
    # the thing that gets skimmed past. The sentence exists so that there IS a
    # line to quote, and so that quoting it is visibly the wrong thing to paste
    # under an authorization.
    echo "NO COVERAGE: this run listed no pull request, read no head's check runs, and evaluated 0 of them — side (B), does a head render the newly proposed context, was never asked about anything."
    exit 0
  fi
  echo "newly proposed context(s):"
  printf '%s\n' "$new_ctx" | sed 's/^/  + /'
  echo

  # ── the PR feed ──
  #
  # `mergeable: UNKNOWN` IS NOT A SKIP, AND THIS WAS MEASURED, NOT IMAGINED.
  # GitHub computes mergeability in a background job and INVALIDATES EVERY OPEN
  # PR's answer whenever the base branch moves. On the first run of this script
  # against a live repo, a PR had just landed and all nine open PRs came back
  # `UNKNOWN/UNKNOWN` — every one of them failed side (A), every one printed
  # `skip`, and the sweep exited 0 having evaluated NOTHING. A green that means
  # "I could not see" is the exact failure this whole epic is about. So UNKNOWN
  # is polled (asking for the field is what schedules the computation) and, if it
  # persists, it is exit 2: the sweep could not be evaluated.
  local prs attempt=0
  if [ -n "$PRS_FILE" ]; then
    [ -f "$PRS_FILE" ] || fail "no PR fixture at $PRS_FILE"
    prs="$(cat "$PRS_FILE")"
  else
    while :; do
      prs="$(gh pr list --repo "$REPO" --state open --limit "$PR_LIMIT" \
               --json number,headRefOid,mergeable,mergeStateStatus,isDraft,title 2>/dev/null)" \
        || fail "cannot list open PRs — a sweep that could not look is not a sweep that found nothing"
      local unknown
      unknown="$(jq -r '[.[] | select((.mergeable // "UNKNOWN") == "UNKNOWN") | .number] | join(" ")' <<<"$prs")"
      [ -n "$unknown" ] || break
      attempt=$((attempt + 1))
      [ "$attempt" -le "$UNKNOWN_RETRIES" ] || break
      echo "  mergeability not computed yet for PR(s) $unknown — re-asking ($attempt/$UNKNOWN_RETRIES)" >&2
      sleep "$UNKNOWN_BACKOFF"
    done
  fi
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs" || fail "the PR feed is not an array"

  # The refusal itself lives OUTSIDE the retry loop so it covers the fixture path
  # too — otherwise the one branch the test harness can drive is the one branch
  # that cannot express this failure.
  local unresolved
  unresolved="$(jq -r '[.[]
      | select(((.mergeable // "UNKNOWN") == "UNKNOWN") or ((.mergeStateStatus // "UNKNOWN") == "UNKNOWN"))
      | .number] | join(" ")' <<<"$prs")"
  [ -z "$unresolved" ] || fail "mergeability is UNKNOWN for PR(s) $unresolved — that is 'GitHub has not computed it yet', never 'not affected'. Classifying it as a skip is how this sweep returns a green that means 'I could not see'. Re-run in a minute."

  printf '%-7s %-11s %-14s %-13s %s\n' "PR" "MERGEABLE" "STATE" "VERDICT" "DETAIL"
  printf '%-7s %-11s %-14s %-13s %s\n' "-------" "-----------" "--------------" "-------------" "------"

  local casualties=0 swept=0 evaluated=0 skipped=0 n head mergeable state draft rows rc missing ctx verdict detail
  # THE SKIP REASONS ARE NOT ONE REASON, AND REPORTING THEM AS ONE IS HOW THE
  # ALL-SKIP GREEN STAYED INVISIBLE. Every row above used to read "not currently
  # mergeable-and-unblocked", so a DRAFT (#8465 — will not merge until a human
  # marks it ready; nothing about it changes if we wait) and a PR held by a check
  # still running (#9827 — TRANSIENT; the same sweep run twenty minutes later
  # evaluates it) printed the same sentence. They are different findings: the
  # first is a stable exclusion, the second is a measurement taken too early.
  local skip_draft=0 skip_dirty=0 skip_blocked=0 skip_other=0 reason
  while IFS=$'\t' read -r n head mergeable state draft; do
    [ -n "$n" ] || continue
    swept=$((swept + 1))

    # ── side (A): would GitHub merge this today? ──
    # BLOCKED is deliberately NOT unblocked: it is already stopped by a required
    # check or a review, so a new context cannot be what stops it. BEHIND and
    # UNSTABLE are: strict is false, so BEHIND merges, and UNSTABLE is a
    # non-required red or a run still in flight.
    local unblocked=0
    if [ "$mergeable" = "MERGEABLE" ] && [ "$draft" != "true" ]; then
      case "$state" in
        CLEAN|UNSTABLE|BEHIND|HAS_HOOKS) unblocked=1 ;;
      esac
    fi

    if [ "$unblocked" -eq 0 ]; then
      skipped=$((skipped + 1))
      if [ "$draft" = "true" ]; then
        reason="skip:draft"
        skip_draft=$((skip_draft + 1))
        detail="DRAFT — GitHub will not merge it until a human marks it ready; a STABLE exclusion, re-running later does not change it"
      elif [ "$mergeable" != "MERGEABLE" ]; then
        reason="skip:conflicting"
        skip_dirty=$((skip_dirty + 1))
        detail="$mergeable/$state — already deadlocked on its own base; the rebase that unsticks it is also what makes every new context render"
      elif [ "$state" = "BLOCKED" ]; then
        reason="skip:blocked"
        skip_blocked=$((skip_blocked + 1))
        detail="BLOCKED by an existing required check or review — often TRANSIENT (a required run still in flight parks every open PR here), so this row is a measurement taken early, not a finding"
      else
        reason="skip:other"
        skip_other=$((skip_other + 1))
        detail="$mergeable/$state — not currently mergeable-and-unblocked; the flip cannot newly deadlock it"
      fi
      printf '%-7s %-11s %-14s %-13s %s\n' "#$n" "$mergeable" "$state" "$reason" "$detail"
      continue
    fi
    evaluated=$((evaluated + 1))

    # ── side (B): do the NEW contexts actually render on its head? ──
    rc=0
    rows="$(check_runs_rows "$REPO" "$head" "$FIXTURE_DIR")" || rc=$?
    [ "$rc" -eq 0 ] || fail "cannot read check runs for #$n head $head — fail-closed"

    missing=""
    while IFS= read -r ctx; do
      [ -n "$ctx" ] || continue
      check_runs_present "$rows" "$ctx" || missing="${missing:+$missing, }$ctx"
    done <<EOF
$new_ctx
EOF

    if [ -n "$missing" ]; then
      verdict="REFUSE"; detail="head ${head:0:9} does NOT render: $missing"
      casualties=$((casualties + 1))
    else
      verdict="ok"; detail="head ${head:0:9} renders every newly proposed context"
    fi
    printf '%-7s %-11s %-14s %-13s %s\n' "#$n" "$mergeable" "$state" "$verdict" "$detail"
  done <<EOF
$(jq -r '.[] | [ (.number|tostring), .headRefOid, (.mergeable // "UNKNOWN"), (.mergeStateStatus // "UNKNOWN"), (.isDraft|tostring) ] | @tsv' <<<"$prs")
EOF

  echo
  echo "swept $swept open PR(s); evaluated $evaluated, skipped $skipped (draft $skip_draft, conflicting $skip_dirty, already-blocked $skip_blocked, other $skip_other); casualties: $casualties"

  # ── THE COVERAGE REFUSAL, AND WHY IT IS ARGUED ON COVERAGE AND NOT ON A COUNT ──
  #
  # The cheap version of this guard is `[ "$evaluated" -gt 0 ]`. It is not enough,
  # and the measurement says so: on 2026-08-06 this repo had thirteen open PRs and
  # the live sweep evaluated ZERO. A count check goes green the moment ONE PR is
  # non-draft, mergeable and unblocked — one head examined, twelve unexamined, and
  # the footer would still say `NO CASUALTY` in the voice of a full sweep. The
  # thing that authorizes a required-context flip is COVERAGE, so coverage is what
  # this script reports on every run: evaluated/skipped/swept, broken out by
  # reason, next to the verdict, so `NO CASUALTY` can never again be read as
  # "every open PR was checked" when it means "the one PR I could see was fine".
  #
  # Exit 2 is therefore the floor case — evaluated NOTHING — not the whole story.
  # A partial sweep still exits 0, because refusing every partial sweep would make
  # the guard unpassable (BLOCKED is the normal state of a PR with a check in
  # flight) and an unpassable guard gets bypassed. It says PARTIAL out loud
  # instead, and the operator carries that sentence into the flip decision.
  if [ "$evaluated" -eq 0 ]; then
    fail "this sweep evaluated 0 of $swept open PR(s) — every row was skipped (draft $skip_draft, conflicting $skip_dirty, already-blocked $skip_blocked, other $skip_other), so side (B) — does this head render the newly proposed context? — was never asked about a single head. 'casualties: 0' here is not a finding, it is an empty set: a green that means 'I could not see' is the exact failure this whole epic is about. Re-run when at least one PR is out of the blocked/draft state, or authorize the flip on per-head check-run evidence gathered by hand and say in writing that this sweep did NOT support it."
  fi

  if [ "$casualties" -gt 0 ]; then
    echo
    echo "REFUSING THE FLIP. Each REFUSE row above is a PR GitHub would merge today and that" >&2
    echo "registration would stop, with a context its head never publishes — the permanent" >&2
    echo "'is expected.' that no re-run and no --admin can clear (D18). Rebase or re-run those" >&2
    echo "heads until the new contexts render, then sweep again." >&2
    exit 1
  fi
  if [ "$skipped" -gt 0 ]; then
    echo "NO CASUALTY among the $evaluated of $swept open PR(s) this sweep could evaluate: each renders every newly proposed context."
    echo "PARTIAL COVERAGE: $skipped PR(s) were skipped and say nothing either way. Quote this line, not just the verdict, wherever the flip is authorized."
  else
    echo "NO CASUALTY: every mergeable, currently-unblocked PR already renders every newly proposed context."
  fi
  exit 0
}

main "$@"
