#!/usr/bin/env bash
# release-scan.sh (isu-w3) — deterministic release-candidate context for the
# release-curation agent (docs/ops/release-curator.md).
#
# PURE READ. It runs only git + gh queries — no tags, no pushes, no GitHub
# writes. It emits one JSON object on stdout describing the candidate release:
# the last vA.B.C tag, HEAD, every commit since, the CI rollup, and a suggested
# semver bump. The AGENT consumes this and applies the judgment a parser
# cannot — whether the range is release-worthy and how to word the notes.
#
# Usage:   scripts/release-scan.sh [ref]        (ref defaults to origin/main)
# Env:     RELEASE_SCAN_REPO=owner/name         (defaults to FRIKKern/barkpark)
#          RELEASE_SCAN_ALLOW_SHALLOW=1         (proceed on a shallow clone and
#                                                mark the output `shallow:true`)
#
# ─────────────────────────────────────────────────────────────────────────────
# HOW THE CI VERDICT IS DERIVED — and what it refuses to claim (honest-gates
# charter D27/D28; this script previously lied three ways).
#
# 1. ADVISORY COMES FROM THE CHECK-SUITE ROLLUP, NEVER FROM A NAME. There used
#    to be `advisory: (.name | test("advisory|lighthouse"))` here: a
#    hand-maintained key list smuggled into a regex. security.yml's Sobelow job
#    is `continue-on-error: true` but the word "advisory" appears only in a YAML
#    comment, so the regex called it BLOCKING and flipped ci.status to "failure"
#    on 3 of 25 recent main shas — which stopped the curator from proposing a
#    release at all, blaming a job GitHub itself had already decided did not
#    matter. `continue-on-error` is exposed by NO GitHub API (introspected three
#    ways: REST check-runs, REST actions jobs, GraphQL CheckRun). But GitHub
#    EXCLUDES continue-on-error failures from the check-SUITE rollup, and that
#    rollup IS the machine-readable statement of "this job was advisory". Two
#    calls, joined on suite id, zero names:
#       red run + suite success                       → "advisory"   (proven)
#       red run + suite failure + it is the ONLY red  → "blocking"   (proven:
#           had it been continue-on-error the suite would have rolled up green)
#       anything else                                 → "cannot_tell"
#    ci.status itself needs no per-job reasoning at all: it is derived from the
#    referenced suite conclusions ALONE.
#
# 2. IT ADMITS WHEN IT CANNOT TELL. Under a RED suite with several reds you
#    cannot say which of them were advisory. `ci.advisory_certainty` is
#    "known" or "cannot_tell" and every ci.failures entry carries a
#    three-valued `advisory` — never a boolean that would fake certainty.
#
# 3. CANCELLED IS NOT FAILURE. A superseded run and a genuinely cancelled run
#    are indistinguishable in the run list, and counting either as "failure"
#    is how main gets misdiagnosed as jammed. Cancelled runs are classified
#    three-valued (D28) into ci.cancelled_runs — SUPERSEDED (never dispatched,
#    `jobs.total_count == 0`, and a successor run for the same workflow was
#    created within 1s of this one's `updated_at`), CANCELLED (jobs did
#    dispatch, so it was killed mid-flight), UNKNOWN (the residue: a human
#    cancel of a still-queued run is indistinguishable on the run object).
#    A cancelled suite makes ci.status "unknown", never "failure".
#
# TRAP, measured: non-Actions GitHub apps auto-create check suites whose
# conclusion is permanently null. Only suites REFERENCED by a check run count
# toward the rollup — otherwise "pending" becomes eternal and the curator never
# proposes anything again, which is strictly worse than the bug this fixes.
#
# CI status is best-effort: any gh/network failure degrades ci.status to
# "unknown" (never a script failure), so the agent can still draft notes. Git
# failure is NOT best-effort — see the shallow guard below.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REF="${1:-origin/main}"
SLUG="${RELEASE_SCAN_REPO:-FRIKKern/barkpark}"

# ── Shallow-clone guard ──────────────────────────────────────────────────────
# Under a shallow clone `git describe --tags` finds no tag and `git log` walks
# a truncated history: the script used to emit `commits: []`, a null
# suggested_version and exit 0 — indistinguishable from "nothing to release".
# A reader that cannot see the history must say so, not shrug in green.
is_shallow="$(git rev-parse --is-shallow-repository 2>/dev/null || echo unknown)"
if [ "$is_shallow" != "false" ]; then
  if [ "${RELEASE_SCAN_ALLOW_SHALLOW:-0}" = "1" ]; then
    echo "release-scan: WARNING shallow repository (is-shallow=${is_shallow}) — commits[]/last_tag are TRUNCATED; output carries shallow:true" >&2
  else
    echo "release-scan: FATAL shallow repository (is-shallow=${is_shallow}). git log/describe would silently under-report the release range." >&2
    echo "release-scan: fix with \`git fetch --unshallow\`, or set RELEASE_SCAN_ALLOW_SHALLOW=1 to accept truncated commits[]." >&2
    exit 3
  fi
fi
if [ "$is_shallow" = "false" ]; then shallow_json=false; else shallow_json=true; fi

# Newest vA.B.C release tag reachable from REF. The exclude globs drop the
# separate cli-v* tag space and any pre-release/suffixed tag, matching
# Barkpark.BuildInfo's release-tag rule exactly.
last_tag="$(git describe --tags --match 'v[0-9]*' \
  --exclude 'v*-*' --exclude 'v*[a-zA-Z]*' --abbrev=0 "$REF" 2>/dev/null || true)"
# `^{commit}` dereferences annotated tags (whose bare sha is the tag object,
# not a commit) so the CI lookup below always targets the actual commit.
head_sha="$(git rev-parse "${REF}^{commit}")"
head_short="${head_sha:0:12}"

if [ -n "$last_tag" ]; then range="${last_tag}..${head_sha}"; else range="$head_sha"; fi

# Commits since the last tag (newest first) as sha<TAB>subject lines, folded
# into a JSON array. Squash-merges carry (#NNNN) in the subject; we surface
# the first PR number per commit so the agent can link them.
#
# THE ARRAY TRAVELS BY FILE, NEVER BY ARGV (honest-gates charter D44). Linux
# caps a SINGLE argv word at MAX_ARG_STRLEN = 131072 bytes, independently of
# the much larger ARG_MAX; macOS has no per-argument cap at all. This repo
# crossed that ceiling on 2026-07-15, and from then on `--argjson commits
# "$commits_json"` (~310 KB for the 1900-commit v0.2.25..HEAD range) made
# execve fail E2BIG: jq never started, bash returned 126, stdout was EMPTY.
# The script was dead on every Linux runner for two weeks and nobody saw it,
# because main carried no harness and no CI caller.
SCAN_TMP="$(mktemp -d)"
trap 'rm -rf "$SCAN_TMP"' EXIT
commits_file="$SCAN_TMP/commits.json"
git log --format='%H%x09%s' "$range" 2>/dev/null \
  | jq -R -s '
      split("\n")
      | map(select(length > 0))
      | map(split("\t") | {
          sha: (.[0][0:12]),
          subject: (.[1] // ""),
          pr: ((.[1] // "") | (capture("#(?<n>[0-9]+)") | .n | tonumber)? // null)
        })' >"$commits_file" || true
# An empty range yields empty stdin, and a failed jq leaves a truncated file;
# guarantee a valid JSON array either way rather than emitting `null`.
if ! jq -e 'type == "array"' "$commits_file" >/dev/null 2>&1; then
  printf '[]' >"$commits_file"
fi
commit_count="$(jq 'length' "$commits_file")"

# Suggested bump: any feat commit → minor, else patch. Major stays a manual
# decision (0.x, and it is never inferred). Applied to the last tag's A.B.C.
# NB: capture-then-grep -c, NOT `git log | grep -q` — under `pipefail`, grep -q
# closes the pipe on first match and the SIGPIPE'd git log fails the pipeline,
# silently losing the match.
subjects="$(git log --format='%s' "$range" 2>/dev/null || true)"
if [ "$(printf '%s\n' "$subjects" | grep -ciE '^feat(\(|!|:)' || true)" -gt 0 ]; then
  bump="minor"
else
  bump="patch"
fi

if [ -n "$last_tag" ]; then
  base="${last_tag#v}"
  IFS='.' read -r A B C <<EOF
$base
EOF
  case "$bump" in
    minor) B=$((B + 1)); C=0 ;;
    patch) C=$((C + 1)) ;;
  esac
  suggested_version="${A}.${B}.${C}"
else
  suggested_version=""
fi

# ── CI rollup for HEAD ───────────────────────────────────────────────────────
CI_UNKNOWN='{"status":"unknown","status_reason":"gh unavailable or no check data for this sha","advisory_certainty":"cannot_tell","checks_total":0,"suites_total":0,"failures":[],"cancelled_runs":[]}'

# A check run carries .check_suite.id inline but NOT the suite's conclusion,
# so the second call is genuinely needed to learn the rollup.
runs_json="$(gh api "repos/${SLUG}/commits/${head_sha}/check-runs?per_page=100" \
  --jq '[.check_runs[] | {name, status, conclusion, suite_id: .check_suite.id}]' 2>/dev/null || true)"
suites_json="$(gh api "repos/${SLUG}/commits/${head_sha}/check-suites?per_page=100" \
  --jq '[.check_suites[] | {id, status, conclusion}]' 2>/dev/null || true)"

# Classify every cancelled workflow run for this sha (D28). Only reached when
# something actually reads `cancelled`, so the normal path stays at two calls.
classify_cancelled() {
  local victims branch siblings totals id total
  victims="$(gh api "repos/${SLUG}/actions/runs?head_sha=${head_sha}&per_page=100" \
    --jq '[.workflow_runs[] | select(.conclusion == "cancelled")
           | {id, workflow: .name, workflow_id, head_branch, created_at, updated_at}]' 2>/dev/null || true)"
  if [ -z "$victims" ] || [ "$(printf '%s' "$victims" | jq 'length')" -eq 0 ]; then
    printf '[]'; return 0
  fi
  # Successor correlation: same workflow, a LATER run created within 1s of the
  # victim's updated_at. Measured 5/5 on main's queue-collapse victims.
  branch="$(printf '%s' "$victims" | jq -r '.[0].head_branch // ""')"
  siblings="$(gh api "repos/${SLUG}/actions/runs?branch=${branch}&per_page=100" \
    --jq '[.workflow_runs[] | {id, workflow_id, created_at}]' 2>/dev/null || true)"
  siblings="${siblings:-[]}"
  totals='{}'
  for id in $(printf '%s' "$victims" | jq -r '.[].id'); do
    total="$(gh api "repos/${SLUG}/actions/runs/${id}/jobs?per_page=1" \
      --jq '.total_count' 2>/dev/null || true)"
    totals="$(printf '%s' "$totals" | jq --arg id "$id" --argjson t "${total:-null}" '.[$id] = $t')"
  done
  printf '%s' "$victims" | jq --argjson siblings "$siblings" --argjson totals "$totals" '
    map(. as $v
      | ($totals[($v.id | tostring)]) as $jobs
      | ($v.updated_at | fromdateiso8601) as $ended
      | ([$siblings[]
          | select(.workflow_id == $v.workflow_id and .id > $v.id)
          | ((.created_at | fromdateiso8601) - $ended)
          | select(. >= 0 and . <= 1)] | length > 0) as $superseded
      | {
          run_id: $v.id,
          workflow: $v.workflow,
          jobs_dispatched: $jobs,
          classification: (
            if   $jobs == null   then "unknown"
            elif $jobs > 0       then "cancelled"
            elif $superseded     then "superseded"
            else "unknown" end),
          basis: (
            if   $jobs == null   then "jobs API unreadable — cannot tell dispatch from collapse"
            elif $jobs > 0       then "jobs dispatched (\($jobs)) then killed mid-flight"
            elif $superseded     then "never dispatched; a later run of the same workflow started within 1s of this one ending"
            else "never dispatched and no successor within 1s — human cancel of a queued run is indistinguishable here" end)
        })'
}

if [ -z "$runs_json" ] || [ -z "$suites_json" ]; then
  ci_json="$CI_UNKNOWN"
else
  # Here-string, NOT `printf | grep -q`: grep -q closes its input on the first
  # match and under `pipefail` the SIGPIPE'd writer returns 141, which reads as
  # "no match" — a size-dependent false negative that would skip the whole
  # cancelled-classification path exactly when it matters.
  if grep -q '"cancelled"' <<<"${runs_json}${suites_json}"; then
    cancelled_json="$(classify_cancelled)"
  else
    cancelled_json='[]'
  fi
  ci_json="$(jq -n \
    --argjson runs "$runs_json" \
    --argjson suites "$suites_json" \
    --argjson cancelled "${cancelled_json:-[]}" '
    # Only suites REFERENCED by a check run count: non-Actions apps leave
    # permanently-null suites behind that would pin the rollup at "pending".
    ($runs | map(.suite_id) | unique) as $refids
    | ($suites | map(select(.id as $i | $refids | index($i) != null))) as $ref
    | ($ref | map({key: (.id | tostring), value: .}) | from_entries) as $by_id
    | ["failure", "timed_out", "action_required", "startup_failure"] as $red
    | ($runs | map(select(.conclusion as $c | $red | index($c) != null))) as $reds
    | ($reds | group_by(.suite_id)
       | map({key: (.[0].suite_id | tostring), value: length}) | from_entries) as $reds_per_suite
    | ($ref | map(select(.conclusion as $c | $red | index($c) != null))) as $red_suites
    | ($ref | map(select(.status != "completed"))) as $running_suites
    | ($ref | map(select(.status == "completed"
                         and (.conclusion == null or .conclusion == "cancelled" or .conclusion == "stale")))) as $murky_suites
    | ($reds | map(. as $r
        | ($by_id[($r.suite_id | tostring)]) as $s
        | {
            name: $r.name,
            conclusion: $r.conclusion,
            # Three-valued on purpose. A boolean here would be a gate lying
            # about its own certainty inside the epic against gates that lie.
            advisory: (
              if   $s == null                 then "cannot_tell"
              elif $s.conclusion == "success" then "advisory"
              elif $s.conclusion == "failure"
                   and $reds_per_suite[($r.suite_id | tostring)] == 1 then "blocking"
              else "cannot_tell" end),
            advisory_basis: (
              if   $s == null                 then "no referenced check suite for this run"
              elif $s.conclusion == "success" then "its check suite rolled up green, so GitHub excluded it: continue-on-error"
              elif $s.conclusion == "failure"
                   and $reds_per_suite[($r.suite_id | tostring)] == 1 then "sole red in a red suite — a continue-on-error job would have left the suite green"
              else "red suite with \($reds_per_suite[($r.suite_id | tostring)] // 0) reds — GitHub does not expose which were continue-on-error" end)
          })) as $failures
    | {
        status: (
          if   ($ref | length) == 0        then "unknown"
          elif ($red_suites | length) > 0  then "failure"
          elif ($running_suites | length) > 0 then "pending"
          elif ($murky_suites | length) > 0   then "unknown"
          else "success" end),
        status_reason: (
          if   ($ref | length) == 0        then "no check suite is referenced by any check run on this sha"
          elif ($red_suites | length) > 0  then "\($red_suites | length) of \($ref | length) referenced check suites rolled up red"
          elif ($running_suites | length) > 0 then "\($running_suites | length) referenced check suites are still running"
          elif ($murky_suites | length) > 0   then "\($murky_suites | length) referenced check suites are cancelled/stale — cancelled is NOT failure, and this sha simply never finished"
          else "all \($ref | length) referenced check suites rolled up green" end),
        advisory_certainty: (
          if ($failures | map(select(.advisory == "cannot_tell")) | length) > 0
          then "cannot_tell" else "known" end),
        checks_total: ($runs | length),
        suites_total: ($ref | length),
        failures: $failures,
        cancelled_runs: $cancelled
      }' 2>/dev/null || echo "$CI_UNKNOWN")"
fi

jq -n \
  --arg repo "$SLUG" \
  --arg ref "$REF" \
  --arg last_tag "$last_tag" \
  --arg head_sha "$head_sha" \
  --arg head_short "$head_short" \
  --argjson shallow "$shallow_json" \
  --argjson commit_count "$commit_count" \
  --slurpfile commits "$commits_file" \
  --arg bump "$bump" \
  --arg suggested_version "$suggested_version" \
  --argjson ci "$ci_json" \
  '{
    repo: $repo,
    ref: $ref,
    shallow: $shallow,
    last_tag: (if $last_tag == "" then null else $last_tag end),
    head_sha: $head_sha,
    head_short: $head_short,
    commit_count: $commit_count,
    suggested_bump: $bump,
    suggested_version: (if $suggested_version == "" then null else $suggested_version end),
    ci: $ci,
    # --slurpfile wraps the file contents in an OUTER array, so this must be
    # $commits[0]. Plain $commits would nest the list one level deeper and
    # silently break the .commits[] reader in docs/ops/release-curator.md —
    # the argv fix is a contract change inside the jq program too.
    commits: $commits[0]
  }'
