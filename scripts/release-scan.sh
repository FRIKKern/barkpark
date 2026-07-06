#!/usr/bin/env bash
# release-scan.sh (isu-w3) — deterministic release-candidate context for the
# release-curation agent (docs/ops/release-curator.md).
#
# PURE READ. It runs only git + gh queries — no tags, no pushes, no GitHub
# writes. It emits one JSON object on stdout describing the candidate release:
# the last vA.B.C tag, HEAD, every commit since, the CI rollup (advisory
# checks flagged separately, per the always-merge rule), and a suggested
# semver bump. The AGENT consumes this and applies the judgment a parser
# cannot — whether the range is release-worthy and how to word the notes.
#
# Usage:   scripts/release-scan.sh [ref]        (ref defaults to origin/main)
# Env:     RELEASE_SCAN_REPO=owner/name         (defaults to FRIKKern/barkpark)
#
# CI status is best-effort: any gh/network failure degrades ci.status to
# "unknown" (never a script failure), so the agent can still draft notes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REF="${1:-origin/main}"
SLUG="${RELEASE_SCAN_REPO:-FRIKKern/barkpark}"

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
commits_json="$(git log --format='%H%x09%s' "$range" 2>/dev/null \
  | jq -R -s '
      split("\n")
      | map(select(length > 0))
      | map(split("\t") | {
          sha: (.[0][0:12]),
          subject: (.[1] // ""),
          pr: ((.[1] // "") | (capture("#(?<n>[0-9]+)") | .n | tonumber)? // null)
        })')"
# An empty range yields empty stdin; guarantee a valid JSON array either way.
commits_json="${commits_json:-[]}"
commit_count="$(printf '%s' "$commits_json" | jq 'length')"

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

# CI rollup for HEAD. Advisory checks (name contains "advisory" or
# "lighthouse", case-insensitive) never gate a release — per the project's
# always-merge rule — so they are reported but excluded from ci.status.
# shellcheck disable=SC2016  # the --jq filter is jq syntax, not shell — must NOT expand
ci_json="$(gh api "repos/${SLUG}/commits/${head_sha}/check-runs" \
  --jq '
    [.check_runs[] | {name, status, conclusion,
       advisory: ((.name | ascii_downcase) | test("advisory|lighthouse"))}]
    as $runs
    | ($runs | map(select(.advisory | not))) as $req
    | {
        status: (
          if   ($req | map(select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")) | length) > 0 then "failure"
          elif ($req | map(select(.status != "completed")) | length) > 0 then "pending"
          elif ($req | length) == 0 then "unknown"
          else "success" end),
        required_total: ($req | length),
        failures: ($runs | map(select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")) | map({name, conclusion, advisory}))
      }' 2>/dev/null || echo '{"status":"unknown","required_total":0,"failures":[]}')"

jq -n \
  --arg repo "$SLUG" \
  --arg ref "$REF" \
  --arg last_tag "$last_tag" \
  --arg head_sha "$head_sha" \
  --arg head_short "$head_short" \
  --argjson commit_count "$commit_count" \
  --argjson commits "$commits_json" \
  --arg bump "$bump" \
  --arg suggested_version "$suggested_version" \
  --argjson ci "$ci_json" \
  '{
    repo: $repo,
    ref: $ref,
    last_tag: (if $last_tag == "" then null else $last_tag end),
    head_sha: $head_sha,
    head_short: $head_short,
    commit_count: $commit_count,
    suggested_bump: $bump,
    suggested_version: (if $suggested_version == "" then null else $suggested_version end),
    ci: $ci,
    commits: $commits
  }'
