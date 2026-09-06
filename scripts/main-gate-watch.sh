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
# A ROW THAT DOES NOT EXIST YET IS NOT A ROW THAT WILL NEVER EXIST (cch-w61)
#
# WAITING as described above is keyed on the `.status` of an EXISTING row, so it
# says nothing about a context whose row has not been created at all — and that
# is the shape the production failure actually had. Scheduled run 31312071143
# (2026-08-09 11:57:21Z) red on tip 2e72d2948 with `MISSING Elixir gate` while
# main was in fact fine: the tip was 5m02s old and carried THIRTY-SIX check-run
# rows (Cloud gate and Console gate both green), but the `elixir` workflow run on
# it (31311871968, created 11:52:33Z, terminal only at 11:59:07Z) had produced
# NO JOBS YET — `actions/runs/31311871968/jobs` returns `total_count: 0` — so no
# `Elixir gate` row COULD exist. Absence there meant "not yet", not "never".
#
# THE DISCRIMINATOR IS THE RUN STATUS, AND IT CARRIES NO CONSTANT
#
# A third authority answers it directly: `actions/runs?head_sha=<tip>`. If ANY
# workflow run on the tip is not `completed`, this commit is still being judged,
# and an absent required row is WAITING (exit 2). If every run on the tip is
# terminal and a required row is still absent, the commit is done being judged
# and never got a verdict — MISSING (exit 1). On the never-judged sha a5260f609
# all 9 runs are `completed`, so it screams exactly as loudly as before.
#
# It is threshold-free, so it cannot go stale, and it needs no workflow-to-
# context name mapping. Honest caveat: it is per-TIP, not per-context, so a tip
# whose elixir run was cancelled while another workflow is still running waits
# one extra tick before the scream lands. The workflow's schedule header already
# accepts a multi-hour verdict lag (GitHub delivers this repo's */30 cron every
# 2.1-4.7 h, measured 2026-09-06), so that is affordable; being late is not being mute.
#
# WHY NOT AN AGE THRESHOLD (measured, and it is worse than it sounds)
#
# The obvious alternative — "a tip younger than the observed row-creation lag is
# WAITING" — needs a constant, and the constant is both wrong and costly. The
# inherited +7m15s/+9m52s/+25m27s triple is ONE tip; re-derived across nine main
# tips the Elixir-gate lag runs 14m17s..27m37s, so 25m27s STILL false-reds.
# Worse, simulating */30 ticks over the 100 main commits in
# 2026-08-08T10:27:24Z..2026-08-09T11:59:03Z: 51 ticks, and at a 28m threshold 35
# are still judged and 16 become WAITING — but of the 17 distinct tips a tick
# ever landed on, SEVEN (dcfd083dd, 2e38228b0, 797950e89, 10cab42a3, b3b8a779b,
# abfd8dd01, e8c32a946) would be judged NEVER, because a newer commit superseded
# them before their grace expired. An age threshold converts a false red into a
# never-measured tip — the vacuous silence this file exists to abolish, moved up
# one level. The run-status rule has no such property. So NO age arm ships here:
# `grep -c 'GRACE' scripts/main-gate-watch.sh` is 0.
#
# EXIT CODES  0 = every watched context PRESENT and green
#             1 = SCREAM — at least one watched context RED, or MISSING with
#                 every workflow run on the tip already terminal
#             2 = WAITING — at least one still in flight (an in-flight row, or
#                 an absent row while a run on the tip is not `completed`)
#             3 = CONFIGURATION FAULT — protection or the tip's workflow runs
#                 unreadable, or a live required context that is neither watched
#                 nor excluded
#
# USAGE
#   scripts/main-gate-watch.sh
#   scripts/main-gate-watch.sh --repo O/R --branch main
#   # hermetic (the test harness; no network at all):
#   scripts/main-gate-watch.sh --sha <sha> \
#       --protection-file <f> --check-runs-file <f> [--runs-file <f>]

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
RUNS_FILE=""
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

# ── authority 3: the workflow runs on the tip ────────────────────────────────
# Prints TSV: name<TAB>status<TAB>id, one row per workflow run on this sha — or
# the single token FORBIDDEN / UNREADABLE. This is the ONLY thing that can tell
# "no row has been created yet" from "no row will ever be created", so a read
# that fails must reach the exit-3 vocabulary and NOT fall through to a verdict:
# a third endpoint is a third way to be blind, and a blind watch that reports
# MISSING is just the false red under a new name.
read_workflow_runs() {
  local body sha repo
  sha="$1"
  if [ -n "$RUNS_FILE" ]; then
    [ -f "$RUNS_FILE" ] || { echo "UNREADABLE"; return 0; }
    body="$(cat "$RUNS_FILE")"
  elif [ -n "$CHECK_RUNS_FILE" ]; then
    # Hermetic and no runs fixture supplied: no run data is KNOWN, so nothing is
    # known to be in flight. Only the test harness reaches this branch — the
    # live path below always reads the endpoint, and cannot default to silence.
    return 0
  else
    repo="${REPO_OVERRIDE:-$(spec_repo)}"
    if [ -z "$repo" ]; then echo "UNREADABLE"; return 0; fi
    body="$(gh api --paginate -X GET -f head_sha="$sha" -f per_page=100 "repos/$repo/actions/runs" 2>&1)" || {
      if grep -qE 'HTTP 401|HTTP 403|Bad credentials|Resource not accessible by integration|Must have admin rights|equires authentication' <<<"$body"; then
        echo "FORBIDDEN"; return 0
      fi
      echo "UNREADABLE"; return 0
    }
  fi
  jq -e . >/dev/null 2>&1 <<<"$body" || { echo "UNREADABLE"; return 0; }
  # Same slurp discipline as the check-run reader: `--paginate` on an OBJECT
  # endpoint emits one document per page, and a run still in flight may sit on
  # any of them.
  jq -e -s 'all(.[]; .workflow_runs | type == "array")' >/dev/null 2>&1 <<<"$body" \
    || { echo "UNREADABLE"; return 0; }
  jq -r -s '
    map(.workflow_runs // [])
    | (add // [])
    | .[]
    | [(.name // ""), (.status // ""), (.id // 0)]
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
      --runs-file)       RUNS_FILE="${2:-}"; shift 2 ;;
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

  # ── the run-status discriminator ───────────────────────────────────────────
  # Read BEFORE any verdict, and unconditionally: a watch that only reaches for
  # this authority when it is about to scream would silently keep its old
  # behaviour on the day the endpoint breaks.
  local tip_runs inflight="" rname rstatus rid
  tip_runs="$(read_workflow_runs "$sha")"
  case "$tip_runs" in
    FORBIDDEN)
      red "CONFIGURATION FAULT — this run's credential cannot read the workflow runs on the tip (401/403)."
      red "That read is what separates 'no check-run row has been created YET' from 'this commit was never"
      red "judged'. Without it every young tip reads as never-judged, which is the false red this watch was"
      red "repaired to stop emitting. This run FAILS rather than guessing."
      red ""
      # THE REMEDY, NAMED (added in review, cch-w61). Exit 3 is honest, but a
      # fault that recurs on every scheduled run and does not say how to clear itself
      # is how a watch gets muted by the people it is shouting at. This is the
      # one predictable way the new read fails: the workflow runs `gh` under
      # GH_TOKEN, which is `secrets.BREAKGLASS_TOKEN` when that secret exists and
      # `github.token` otherwise. The workflow's own `permissions:` block already
      # grants `actions: read`, so `github.token` is fine — but a fine-grained
      # PAT in BREAKGLASS_TOKEN carries its own scope set and that grant does
      # not reach it.
      red "REMEDY: whatever credential \$GH_TOKEN carries needs Actions: read on this repository."
      red "  This workflow's own permissions: block already grants actions: read, so the DEFAULT"
      red "  github.token is sufficient. If secrets.BREAKGLASS_TOKEN is set, it OVERRIDES that token"
      red "  and must carry the Actions: read permission itself — a fine-grained PAT without it 403s"
      red "  here on every scheduled run while branch protection and check-runs still read fine."
      return 3 ;;
    UNREADABLE)
      red "CONFIGURATION FAULT — the workflow runs on $sha could not be read (repos/<repo>/actions/runs)."
      red "A watch that cannot see whether the tip is still being judged must not decide that it never was."
      return 3 ;;
  esac
  while IFS="$(printf '\t')" read -r rname rstatus rid; do
    [ -n "$rname" ] || continue
    [ "$rstatus" = "completed" ] && continue
    inflight="$inflight$rname #$rid (status=$rstatus)
"
  done <<EOF
$tip_runs
EOF

  say "main-gate-watch — tip $sha"

  local first_inflight=""
  if [ -n "$inflight" ]; then
    first_inflight="$(printf '%s' "$inflight" | head -n 1)"
    # Printed in FULL, not just the one row quoted below: when this watch says
    # WAITING instead of MISSING, the reader's next question is always "waiting
    # on WHAT", and answering it is the difference between an instrument and an
    # excuse.
    say "  still in flight on this tip — a row that is absent may yet appear:"
    printf '%s' "$inflight" | while IFS= read -r line; do [ -n "$line" ] && say "    $line"; done
  fi

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
      if [ -n "$first_inflight" ]; then
        # NOT YET, rather than NEVER (cch-w61). A workflow run on this tip has
        # not reached a terminal state, so a row that does not exist may still
        # be created — including by a run that has produced no jobs at all yet,
        # which is exactly how run 31312071143 false-red on 2e72d2948.
        say "  WAITING  $ctx — no check run row YET, and a workflow run on this sha is still in flight: $first_inflight"
        waits="$waits$ctx (no row yet; still in flight: $first_inflight)
"
        continue
      fi
      # THE CASE THE WHOLE SLICE EXISTS FOR. Absence with every workflow run on
      # the tip already terminal is not silence-is-golden; it means this commit
      # is done being judged and never got a verdict.
      say "  MISSING  $ctx — no check run at all on this sha, and every workflow run on it is terminal"
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
    red "MISSING is not better than RED: it means the commit was never judged — and it is now only said when"
    red "every workflow run on this tip is terminal, so it is never merely 'too early to tell'. Queued main runs collapse"
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
