#!/usr/bin/env bash
# main-gate-watch.sh — main's TIP carries a verdict, or this screams.
#
# WHAT IT IS FOR
#
# main's required `Cloud gate` was `failure` for three consecutive commits and
# NOTHING reported it. Four independent negatives, all measured at the time this
# was written: zero `workflow_run` triggers across all 40 workflows; zero
# notification egress anywhere in .github/workflows; zero GitHub check-run
# consumers in cloud/lib or internal/, so neither the Console nor `bp cloud` can
# render main's gate state; and `gh run list` itself launders the red (a run
# whose Sobelow job concluded `failure` reads `success` at the RUN level).
#
# It is worse than "three commits red". Of the 15 main commits in the window
# f4abf4369..origin/main, TWELVE concluded `cancelled` — no Cloud verdict at
# all, ever. The honest statement is 3 red / 12 UNMEASURED / 0 green.
#
# THEREFORE: A PRESENCE ASSERTION, NOT AN ABSENCE-OF-FAILURE ASSERTION
#
# A watch phrased as "find a failing required row" finds ZERO rows on a
# `cancelled` sha (a5260f609 carries THREE check runs total, none of them a
# required context) and reports GREEN. That vacuous green is the disease. This
# script asserts every watched context is PRESENT **and** green; an ABSENT
# context is MISSING and screams exactly as loudly as a red one.
#
# TIP-SCOPED, NEVER PER-COMMIT
#
# Run per-commit over the last 25 main commits, this read reds on 23 of 25, 15
# of them purely as MISSING — 92% noise, and not 23 defects. cloud.yml's own
# concurrency comment says queued main runs deliberately COLLAPSE to one, so
# intermediate commits of a push batch are never expected to carry a verdict.
# Only main's TIP is. Anything that walks history re-invents the noise.
#
# THE EXCLUSION IS LOAD-BEARING AND IS A NAMED CONSTANT
#
# Branch protection requires four contexts. One of them — `PR references an
# active task` — is PR-scoped and never re-runs after the merge, so a
# four-context watch reds even the KNOWN-GREEN sha f4abf4369 on a MISSING row:
# a permanent false red, muted within a day. It is excluded BY NAME below, so
# the exclusion is auditable rather than an inline filter nobody can find.
#
# THE ROSTER IS DERIVED LIVE, AND UNCLASSIFIED NAMES ARE A FAULT
#
# The required set is read from branch protection at run time, NOT from
# .github/required-checks.json — a watch that reads the committed spec goes
# stale against the live rule and cannot know it. Every live required context
# must be either WATCHED or named in the EXCLUSION; one that is neither is a
# CONFIGURATION FAULT (exit 3), because the alternative is silent: a future
# PR-scoped context would false-red forever, and a newly post-merge-reproducible
# one would be watched by accident with nobody having decided it.
#
# THE THIRD OUTCOME: WAITING
#
# An in-flight context has `conclusion: null` and reads as MISSING under a naive
# `.conclusion != "success"` test — which false-reds every fresh push to main
# for as long as CI takes. WAITING is keyed on `.status` (anything that is not
# `completed`), and it is NEITHER a pass NOR a scream: exit 2.
#
# EXIT CODES  0 = every watched context PRESENT and green
#             1 = SCREAM — at least one watched context RED or MISSING
#             2 = WAITING — at least one still in flight, none red or missing
#             3 = CONFIGURATION FAULT — protection unreadable, or a live
#                 required context that is neither watched nor excluded
#
# USAGE
#   scripts/main-gate-watch.sh
#   scripts/main-gate-watch.sh --repo O/R --branch main
#   # hermetic (the test harness; no network at all):
#   scripts/main-gate-watch.sh --sha <sha> \
#       --protection-file <f> --check-runs-file <f>

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$REPO_ROOT/.github/required-checks.json"

# ── the two named constants ──────────────────────────────────────────────────
# WATCHED: the post-merge-reproducible required contexts. Every one of these is
# rendered by a workflow that runs on `push: main`, so the TIP is expected to
# carry a verdict for each.
WATCHED_CONTEXTS="Cloud gate
Console gate
Elixir gate"

# EXCLUDED: required contexts that are PR-scoped by construction and can never
# render post-merge. Named, one per line, with the reason in the comment above.
# Adding a row here is a DECISION and shows up in a diff; an inline filter would
# not.
EXCLUDED_CONTEXTS="PR references an active task"

PROTECTION_FILE=""
CHECK_RUNS_FILE=""
SHA_OVERRIDE=""
REPO_OVERRIDE=""
BRANCH_OVERRIDE=""

say() { echo "$*"; }
red() { echo "$*" >&2; }

spec_repo()   { [ -f "$SPEC" ] && jq -r '.repo   // empty' "$SPEC" 2>/dev/null || echo ""; }
spec_branch() { [ -f "$SPEC" ] && jq -r '.branch // empty' "$SPEC" 2>/dev/null || echo ""; }

in_list() { # needle, list-on-stdin-style string
  local needle="$1" list="$2" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$list
EOF
  return 1
}

# ── authority 1: the live required set ───────────────────────────────────────
# Prints one context per line, or the single token FORBIDDEN / UNREADABLE.
read_required_contexts() {
  local body
  if [ -n "$PROTECTION_FILE" ]; then
    [ -f "$PROTECTION_FILE" ] || { echo "UNREADABLE"; return 0; }
    body="$(cat "$PROTECTION_FILE")"
  else
    local repo branch
    repo="${REPO_OVERRIDE:-$(spec_repo)}"
    branch="${BRANCH_OVERRIDE:-$(spec_branch)}"
    if [ -z "$repo" ] || [ -z "$branch" ]; then echo "UNREADABLE"; return 0; fi
    body="$(gh api "repos/$repo/branches/$branch/protection" 2>&1)" || {
      if grep -qE 'HTTP 401|HTTP 403|Bad credentials|Resource not accessible by integration|Must have admin rights|equires authentication' <<<"$body"; then
        echo "FORBIDDEN"; return 0
      fi
      echo "UNREADABLE"; return 0
    }
  fi
  jq -e . >/dev/null 2>&1 <<<"$body" || { echo "UNREADABLE"; return 0; }
  # A protection object with no required_status_checks at all is not "zero
  # contexts to watch" — it is an unreadable authority, and reporting green off
  # it is the vacuous green this file exists to abolish.
  jq -e '.required_status_checks.checks | type == "array"' >/dev/null 2>&1 <<<"$body" \
    || { echo "UNREADABLE"; return 0; }
  jq -r '.required_status_checks.checks[].context' <<<"$body"
}

# ── authority 2: the check runs on the tip ───────────────────────────────────
# Prints TSV: name<TAB>status<TAB>conclusion, one row per NAME (latest run
# wins). A name whose latest run is what matters: GitHub re-runs render a second
# row with the same name, and the older one must not decide the verdict.
read_check_runs() {
  local body sha repo
  if [ -n "$CHECK_RUNS_FILE" ]; then
    [ -f "$CHECK_RUNS_FILE" ] || { return 1; }
    body="$(cat "$CHECK_RUNS_FILE")"
  else
    repo="${REPO_OVERRIDE:-$(spec_repo)}"
    sha="$1"
    # per_page=100 keeps the common case to ONE page; --paginate still handles
    # a repo that outgrows it. REVIEW (cch-w59): `gh api --paginate` on an
    # OBJECT endpoint emits one JSON document PER PAGE, so the dedup below must
    # slurp the whole stream (`jq -s`) before it groups — grouping per document
    # would let an older re-run row on page 1 decide a context whose latest row
    # is on page 2, which is the exact stale-verdict bug this watch exists to
    # abolish.
    body="$(gh api --paginate -X GET -f per_page=100 "repos/$repo/commits/$sha/check-runs" 2>&1)" || return 1
  fi
  jq -e . >/dev/null 2>&1 <<<"$body" || return 1
  jq -r -s '
    map(if type == "array" then . else (.check_runs // []) end)
    | (add // [])
    | map({name, status, conclusion,
           started_at: (.started_at // ""), id: (.id // 0)})
    | sort_by(.started_at, .id)
    | group_by(.name)
    | map(last)
    | .[]
    | [.name, (.status // ""), (.conclusion // "")]
    | @tsv
  ' <<<"$body"
}

resolve_tip_sha() {
  local repo branch
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  branch="${BRANCH_OVERRIDE:-$(spec_branch)}"
  gh api "repos/$repo/commits/$branch" -q '.sha' 2>/dev/null
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --protection-file) PROTECTION_FILE="${2:-}"; shift 2 ;;
      --check-runs-file) CHECK_RUNS_FILE="${2:-}"; shift 2 ;;
      --sha)             SHA_OVERRIDE="${2:-}"; shift 2 ;;
      --repo)            REPO_OVERRIDE="${2:-}"; shift 2 ;;
      --branch)          BRANCH_OVERRIDE="${2:-}"; shift 2 ;;
      --spec)            SPEC="${2:-}"; shift 2 ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) red "unknown argument: $1"; exit 3 ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || { red "CONFIGURATION FAULT — jq is not installed; this watch cannot read anything."; return 3; }

  local required
  required="$(read_required_contexts)"
  case "$required" in
    FORBIDDEN)
      red "CONFIGURATION FAULT — this run's credential cannot read branch protection (401/403)."
      red "That is not a transport blip: it stays broken until a human provisions a token that can."
      red "A watch with no live authority must never report success, so this run FAILS."
      return 3 ;;
    UNREADABLE|"")
      red "CONFIGURATION FAULT — branch protection could not be read, or carries no required_status_checks."
      red "The watched set is derived LIVE on purpose (a committed spec goes stale silently), so with no"
      red "authority there is nothing honest to say. This run FAILS rather than reporting an empty green."
      return 3 ;;
  esac

  # ── the roster assertion ───────────────────────────────────────────────────
  local unclassified="" watched="" ctx
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    if in_list "$ctx" "$EXCLUDED_CONTEXTS"; then
      say "  skipped (named exclusion): $ctx"
      continue
    fi
    if in_list "$ctx" "$WATCHED_CONTEXTS"; then
      watched="$watched$ctx
"
      continue
    fi
    unclassified="$unclassified$ctx
"
  done <<EOF
$required
EOF

  if [ -n "$unclassified" ]; then
    red "CONFIGURATION FAULT — branch protection requires a context this watch has never classified:"
    printf '%s' "$unclassified" | while IFS= read -r ctx; do [ -n "$ctx" ] && red "  $ctx"; done
    red "Add it to WATCHED_CONTEXTS (it re-runs post-merge) or to EXCLUDED_CONTEXTS (it is PR-scoped),"
    red "in scripts/main-gate-watch.sh. Guessing is how a watch either false-reds forever or silently"
    red "stops watching something that matters. This run FAILS until a human decides."
    return 3
  fi

  if [ -z "$watched" ]; then
    red "CONFIGURATION FAULT — every live required context is excluded, so this watch is watching nothing."
    return 3
  fi

  # ── the tip ────────────────────────────────────────────────────────────────
  local sha
  sha="${SHA_OVERRIDE:-$(resolve_tip_sha)}"
  if [ -z "$sha" ]; then
    red "CONFIGURATION FAULT — could not resolve the tip sha of ${BRANCH_OVERRIDE:-$(spec_branch)}."
    return 3
  fi

  local runs
  if ! runs="$(read_check_runs "$sha")"; then
    red "CONFIGURATION FAULT — could not read check runs for $sha."
    return 3
  fi

  say "main-gate-watch — tip $sha"

  local screams="" waits="" name status conclusion found
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    found=""
    while IFS="$(printf '\t')" read -r name status conclusion; do
      [ "$name" = "$ctx" ] || continue
      found=1
      break
    done <<EOF
$runs
EOF
    if [ -z "$found" ]; then
      # THE CASE THE WHOLE SLICE EXISTS FOR. Absence is not silence-is-golden;
      # it means this commit was never judged.
      say "  MISSING  $ctx — no check run at all on this sha"
      screams="$screams$ctx (MISSING)
"
      continue
    fi
    if [ "$status" != "completed" ]; then
      say "  WAITING  $ctx — status=$status, no conclusion yet"
      waits="$waits$ctx
"
      continue
    fi
    if [ "$conclusion" = "success" ]; then
      say "  ok       $ctx"
      continue
    fi
    say "  RED      $ctx — conclusion=$conclusion"
    screams="$screams$ctx ($conclusion)
"
  done <<EOF
$watched
EOF

  if [ -n "$screams" ]; then
    red ""
    red "MAIN'S TIP DOES NOT CARRY A GREEN VERDICT — $sha"
    printf '%s' "$screams" | while IFS= read -r line; do [ -n "$line" ] && red "  $line"; done
    red ""
    red "MISSING is not better than RED: it means the commit was never judged. Queued main runs collapse"
    red "to one (cloud.yml concurrency), so a tip with no verdict is a tip nobody measured."
    red "This is a LEVEL check. It reds on every run until the tip carries a green verdict on every"
    red "watched context — re-run the workflow on this sha, or land the fix that makes it green."
    return 1
  fi

  if [ -n "$waits" ]; then
    say "::notice::WAITING — main's tip has contexts still in flight. Not a pass and not a scream; the next run decides."
    printf '%s' "$waits" | while IFS= read -r line; do [ -n "$line" ] && say "  waiting: $line"; done
    return 2
  fi

  say "ok — every watched required context is PRESENT and green on $sha"
  return 0
}

main "$@"
