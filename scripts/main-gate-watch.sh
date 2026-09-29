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
# THE FOURTH OUTCOME: NOT_OWED (task-2253e13aba12fbe8)
#
# A watched context whose workflow carries a `paths:` filter on its `push:` arm
# is not owed by every main push. `Console gate` is rendered by
# .github/workflows/console-harness.yml, whose push arm was paths-filtered on
# 2026-09-10 (task-7ef9d81ed33d2b9c) — the pull_request arm was NOT, so every PR
# head still renders the context and branch protection still evaluates it. There
# is no merge-safety hole; a main push that touched no console path was simply
# never owed a run.
#
# MEASURED 2026-09-20, the last 50 main pushes: FORTY-TWO carry no `Console
# gate` check run at all. Before #19414 that was muted by this watch counting
# its own in-flight run as a reason to WAIT. After #19414 — a correct fix — it
# became `MISSING Console gate`, exit 1, on 84% of main tips: a false alarm on a
# scheduled instrument, which is how a real red gets ignored.
#
# THE ALARM IS NARROWED, NOT SILENCED, AND THAT DISTINCTION IS THE WHOLE POINT.
# The tempting repair — "CONDITIONAL tier and nothing rendered, so stay quiet" —
# is what scripts/main-verdict-presence.sh does for its own, different question,
# and adopting it HERE would make the MISSING arm unreachable for every
# paths-filtered workflow. That silences the detector whose entire job is to
# notice an unjudged tip. So owed-ness is decided from what the commit TOUCHED:
#
#   the sha touched a path the filter watches, and still nothing rendered
#                                     -> MISSING, exit 1, exactly as before
#   the sha touched none of them      -> NOT_OWED, printed, exit 0
#   owed-ness could not be determined -> OWED. Fail closed, always.
#
# Both directions are proven by mutation in scripts/main-gate-watch.test.sh
# against three real shas: 9980425e6 (internal/cli only) and 56e0dbca4
# (.claude/skills only) read NOT_OWED; a5260f609, which touched cloud/lib/**,
# KEEPS reading MISSING and exit 1 on all three contexts.
#
# NO SECOND HAND-MAINTAINED LIST SHIPS HERE. The tier comes from
# .github/main-push-workflows.txt, the transcript main-verdict-presence.sh
# already ratchets; the context-to-workflow mapping is DERIVED by finding the
# job whose `name:` is the context; the glob matching lives in
# scripts/lib/main-push-owedness.sh, the FIRST copy of those semantics in the
# tree, sourced rather than duplicated.
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
#   NOT_OWED is not an exit code. It removes a context from the verdict set for
#   this sha, so a tip owing nothing else exits 0 — and it is PRINTED, so the
#   silence is always accounted for on a line somebody can read.
#
# USAGE
#   scripts/main-gate-watch.sh
#   scripts/main-gate-watch.sh --repo O/R --branch main
#   # the watch's own run id is read from GITHUB_RUN_ID; override for a test:
#   scripts/main-gate-watch.sh --self-run-id <id>
#   # hermetic (the test harness; no network at all):
#   scripts/main-gate-watch.sh --sha <sha> \
#       --protection-file <f> --check-runs-file <f> [--runs-file <f>] \
#       [--changed-files-file <f>] [--workflows-dir <d>] [--manifest <f>]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$REPO_ROOT/.github/required-checks.json"

# Owed-ness: the tier list, the glob matcher and the context->workflow mapping
# all live here, shared rather than copied. See its header for the stated bound.
# shellcheck source=scripts/lib/main-push-owedness.sh
. "$REPO_ROOT/scripts/lib/main-push-owedness.sh"

WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
MANIFEST="$REPO_ROOT/.github/main-push-workflows.txt"

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
CHANGED_FILES_FILE=""
SHA_OVERRIDE=""
REPO_OVERRIDE=""
BRANCH_OVERRIDE=""
# THE WATCH MUST NOT COUNT ITSELF AS A REASON TO WAIT (task-PENDING-gatewatch).
# The in-flight set below is what separates "no row YET" from "never judged".
# On the schedule arm this workflow's OWN run is ALWAYS in that set — it is
# reading the tip while running on the tip — and it renders NONE of the watched
# contexts, so it can never be the run that makes an absent row appear. Counting
# it downgrades a genuine MISSING to WAITING, and WAITING exits 0.
# MEASURED, not reasoned: scheduled run 35492442980 (2026-09-20T05:44Z, sha
# 56e0dbca4) printed "WAITING Console gate — ... still in flight:
# main-gate-watch #35492442980" — its SOLE in-flight row was ITSELF. `Console
# gate` had never rendered on that sha and never did; the same script re-run on
# the same sha once that run went terminal prints "MISSING Console gate" and
# exits 1. Only the `Elixir gate` red carried that run to a scream; with Elixir
# green it would have exited 2 = green while a required context was absent from
# main's tip forever. Defaulted from GITHUB_RUN_ID so the live workflow needs no
# argument, and overridable so the harness can prove both directions.
SELF_RUN_ID="${GITHUB_RUN_ID:-}"

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

# ── authority 4: the files this sha touched ──────────────────────────────────
# Prints the path of a file holding one repo-relative filename per line, or
# NOTHING. Nothing means "unknown", and every caller of mpo_owed treats unknown
# as OWED, so a failure of this read can only make the watch LOUDER — never
# quieter. That asymmetry is deliberate: the three authorities above exit 3 when
# they go blind because a blind read of them could manufacture a false green,
# and this one cannot.
read_changed_files() {
  local sha="$1" repo out
  if [ -n "$CHANGED_FILES_FILE" ]; then
    [ -f "$CHANGED_FILES_FILE" ] && printf '%s\n' "$CHANGED_FILES_FILE"
    return 0
  fi
  # Hermetic (the harness supplies check runs but no file list): unknown, so
  # every paths-filtered context stays OWED and the pre-existing arms of
  # scripts/main-gate-watch.test.sh keep measuring exactly what they measured.
  [ -n "$CHECK_RUNS_FILE" ] && return 0
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  [ -n "$repo" ] || return 0
  out="$(mktemp)" || return 0
  if gh api "repos/$repo/commits/$sha" -q '.files[].filename' > "$out" 2>/dev/null \
     && [ -s "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  rm -f "$out"
  return 0
}

# ── the full-oid gate ────────────────────────────────────────────────────────
# THE TWO ENDPOINTS DISAGREE ABOUT ABBREVIATED SHAS, AND ONLY ONE SAYS SO.
# `repos/<r>/commits/<sha>/check-runs` ACCEPTS a prefix and answers the same
# rows for `a5260f609` as for the full oid. `repos/<r>/actions/runs?head_sha=`
# matches the FULL 40-character oid ONLY: handed a prefix it returns
# `{"total_count":0,"workflow_runs":[]}` — HTTP 200, well-formed, empty. Every
# guard in read_workflow_runs() fires on a transport or shape failure and NONE
# of them fires on this, so the in-flight set comes back empty for the wrong
# reason and the absence branch below concludes "every workflow run on it is
# terminal" and screams MISSING at a tip that is simply still running.
#
# MEASURED, not reasoned (2026-09-20T13:36Z, tip 769c39bd6…):
#   --sha 769c39bd6959f1adb7428b72d9dde4237421640d -> WAITING, exit 2
#   --sha 769c39bd6                                -> MISSING, exit 1
# Same commit, same minute, opposite verdicts. That is the failed-read-equals-
# zero class, in the one script whose whole subject is an unjudged tip.
#
# So the sha is widened BEFORE the run feed is ever queried, and a prefix that
# cannot be widened is REFUSED at exit 3 rather than answered. Resolution is
# local first (a checkout already knows the oid, and costs no network), then
# `repos/<r>/commits/<sha>`, which — unlike the run feed — accepts a prefix.
# Prints the 40-character oid, or the single token UNRESOLVED.
full_oid() {
  local sha="$1" repo full
  case "$sha" in
    ""|*[!0-9a-fA-F]*) echo "UNRESOLVED"; return 0 ;;
  esac
  if [ "${#sha}" -eq 40 ]; then
    printf '%s\n' "$sha" | tr 'A-F' 'a-f'
    return 0
  fi
  [ "${#sha}" -ge 4 ] || { echo "UNRESOLVED"; return 0; }
  full="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null)"
  case "$full" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      printf '%s\n' "$full"; return 0 ;;
  esac
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  if [ -n "$repo" ]; then
    # The RAW payload, with this script applying its own jq: a reader that let
    # `gh -q` do the projection could not tell an empty answer from a missing
    # field, which is the very confusion this gate exists to end.
    full="$(gh api "repos/$repo/commits/$sha" 2>/dev/null | jq -r '.sha // ""' 2>/dev/null)"
    case "$full" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        printf '%s\n' "$full"; return 0 ;;
    esac
  fi
  echo "UNRESOLVED"
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
      --changed-files-file) CHANGED_FILES_FILE="${2:-}"; shift 2 ;;
      --workflows-dir)   WORKFLOWS_DIR="${2:-}"; shift 2 ;;
      --manifest)        MANIFEST="${2:-}"; shift 2 ;;
      --sha)             SHA_OVERRIDE="${2:-}"; shift 2 ;;
      --repo)            REPO_OVERRIDE="${2:-}"; shift 2 ;;
      --branch)          BRANCH_OVERRIDE="${2:-}"; shift 2 ;;
      --self-run-id)     SELF_RUN_ID="${2:-}"; shift 2 ;;
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

  # WIDEN BEFORE ANY head_sha= QUERY (see full_oid above). Only the live path
  # issues one: with --runs-file the feed is a recorded payload, and with
  # --check-runs-file and no --runs-file read_workflow_runs() returns without
  # touching the network at all. The hermetic harness names its fixtures by the
  # abbreviated sha it recorded them under, so the gate bites in exactly the
  # place the endpoint does and nowhere else.
  if [ -z "$RUNS_FILE" ] && [ -z "$CHECK_RUNS_FILE" ]; then
    local full
    full="$(full_oid "$sha")"
    if [ "$full" = "UNRESOLVED" ]; then
      red "CONFIGURATION FAULT — the sha argument '$sha' is not a full 40-character commit oid and could not be widened to one."
      red "repos/<repo>/actions/runs?head_sha= matches the FULL oid only: handed an abbreviation it returns an EMPTY"
      red "run list with HTTP 200, and this watch would then read 'nothing is in flight' and report MISSING on a tip"
      red "that is simply still running. Pass the full 40-character oid (git rev-parse <ref>)."
      red "This run FAILS rather than answering off a query it could not satisfy."
      return 3
    fi
    if [ "$full" != "$sha" ]; then
      say "  resolved the sha argument '$sha' to the full oid $full (the run feed matches the full oid only)"
      sha="$full"
    fi
  fi

  local changed_files
  changed_files="$(read_changed_files "$sha")"

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
    # This run is not evidence that a row is coming — see SELF_RUN_ID above.
    # Matched on the run ID, never the workflow NAME: a genuinely concurrent
    # second main-gate-watch run is a different id and stays in the set.
    if [ -n "$SELF_RUN_ID" ] && [ "$rid" = "$SELF_RUN_ID" ]; then
      say "  (ignoring this watch's own run #$rid — it renders no watched context)"
      continue
    fi
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

  local screams="" waits="" not_owed="" name status conclusion found ctx_wf owed
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
      # NOT OWED, rather than NEVER (task-2253e13aba12fbe8). Asked BEFORE
      # WAITING: a context this sha was never owed is not pending either, and
      # reporting it as in flight would leave it waiting forever. The workflow
      # is found by the job whose `name:` IS the context, the tier comes from
      # the committed manifest, and the filter is matched against what this
      # commit touched. Anything unknown answers OWED and falls through to the
      # arms below, so this branch can only ever subtract a context it can
      # POSITIVELY show was declined.
      ctx_wf="$(mpo_workflow_for_context "$WORKFLOWS_DIR" "$ctx")"
      owed="$(mpo_owed "$WORKFLOWS_DIR" "$MANIFEST" "$ctx_wf" "$changed_files")"
      if [ "$owed" = "NOT_OWED" ]; then
        say "  NOT_OWED $ctx — $ctx_wf is CONDITIONAL in $(basename "$MANIFEST") and this sha touched none of its push paths, so no run was ever owed"
        not_owed="$not_owed$ctx (declined by the paths: filter of $ctx_wf)
"
        continue
      fi
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

  if [ -n "$not_owed" ]; then
    say "  (not owed on this sha, and therefore not watched on it:)"
    printf '%s' "$not_owed" | while IFS= read -r line; do [ -n "$line" ] && say "    $line"; done

    # A TIP THAT OWED NOTHING IS NOT A GREEN TIP. If NOT_OWED ever subtracts the
    # entire watched set, this watch has measured nothing and must not say ok —
    # that is the vacuous green in the header, re-created one level down. It
    # cannot happen while cloud.yml and elixir.yml are ALWAYS in the manifest,
    # which is precisely why it is asserted rather than assumed: the manifest is
    # regenerated by a tool and a tier can move without anybody deciding to.
    local n_watched n_not_owed
    n_watched="$(printf '%s' "$watched" | grep -c .)"
    n_not_owed="$(printf '%s' "$not_owed" | grep -c .)"
    if [ "$n_not_owed" -ge "$n_watched" ]; then
      red "CONFIGURATION FAULT — every watched required context was NOT_OWED on $sha."
      red "This watch then measured nothing at all, and reporting green off an empty set is the"
      red "vacuous green it exists to abolish. A tier in $(basename "$MANIFEST") most likely moved"
      red "from ALWAYS to CONDITIONAL. A human decides what this watch watches, not a regenerated file."
      return 3
    fi
  fi

  say "ok — every watched required context is PRESENT and green on $sha"
  return 0
}

main "$@"
