#!/usr/bin/env bash
# Surface a failed SCHEDULED workflow run to a human by filing (or updating) a
# GitHub issue.
#
# WHY THIS EXISTS. Scheduled gates fail into the void: nobody opens the Actions
# tab on a cron. paper-readers was red on main for three consecutive days with
# nobody notified, and renew-mail-cert runs MONTHLY, so a silent failure there
# is ~90 days of expiring TLS. A red nobody reads is not a gate.
#
# WHY THE BUILT-IN TOKEN. This path uses GITHUB_TOKEN, which every run already
# has — it needs no provisioning, only `permissions: issues: write`. It does
# NOT file a bp task: BARKPARK_TASK_TOKEN does not exist in any scope, and the
# ledger mutation shape those workflows copy returns HTTP 200 while creating a
# DRAFT that `bp task ready` never sees. An alerting path that reports success
# while recording nothing is the exact defect this script exists to end.
#
# IDEMPOTENT. One open issue per failure key (default: the workflow name). An
# ongoing nightly failure appends a comment to the existing issue instead of
# minting a new one every night. Close the issue when the condition is fixed;
# the next failure opens a fresh one.
#
# LOUD ON DEGRADE. Every unusable-input and API failure emits ::error:: and
# exits non-zero. It never warns-and-passes: a notifier that silently no-ops is
# worse than no notifier, because it manufactures confidence.
#
# Exit: 0 = a human-visible issue now exists (created or commented).
#       1 = the alert could NOT be delivered (loudly).
#
# Env: GITHUB_TOKEN GITHUB_REPOSITORY (required)
#      CI_FAILURE_KEY (idempotency key, default $GITHUB_WORKFLOW)
#      CI_FAILURE_LABEL (default ci-failure)
#      CI_FAILURE_DETAIL (optional extra body text, e.g. what to check)
#      GITHUB_API_URL GITHUB_SERVER_URL GITHUB_RUN_ID GITHUB_WORKFLOW
#      GITHUB_JOB GITHUB_EVENT_NAME GITHUB_REF_NAME GITHUB_SHA

set -uo pipefail

die() { # die <message> — the LOUD degrade path
  printf '::error title=CI failure alert not delivered::%s\n' "$1" >&2
  exit 1
}

api_url="${GITHUB_API_URL:-https://api.github.com}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
token="${GITHUB_TOKEN:-}"
repo="${GITHUB_REPOSITORY:-}"
workflow="${GITHUB_WORKFLOW:-unknown-workflow}"
key="${CI_FAILURE_KEY:-$workflow}"
label="${CI_FAILURE_LABEL:-ci-failure}"
detail="${CI_FAILURE_DETAIL:-}"
run_id="${GITHUB_RUN_ID:-}"

command -v jq >/dev/null || die "jq is not installed; cannot parse the GitHub API response"
command -v curl >/dev/null || die "curl is not installed; cannot reach the GitHub API"

# The message names BOTH causes because the first one it named was the wrong
# one: crown-reconcile.yml declared `permissions: issues: write` correctly and
# still landed here, because its step set GH_TOKEN and this script reads
# GITHUB_TOKEN. A diagnostic that names one cause when there are two sends the
# reader to a file that is already correct.
[ -n "$token" ] || die "GITHUB_TOKEN is empty. Two causes produce this, and the calling step decides which: (a) the step sets a DIFFERENT variable — GH_TOKEN is the common slip, this script reads GITHUB_TOKEN and nothing else; or (b) the workflow is missing 'permissions: issues: write'. Check the step's own env: block FIRST. The failure that triggered this alert is UNREPORTED."
[ -n "$repo" ] || die "GITHUB_REPOSITORY is empty — cannot tell which repository to file against."

title="CI failure: $key"
run_url="$server_url/$repo/actions/runs/$run_id"

# Every response body lands here so a failed call can be quoted in the ::error::
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

api() { # api <method> <path> [json_body] → echoes HTTP status, body in $body_file
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -X "$method"
    -H "Authorization: Bearer $token"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    --connect-timeout 10 --max-time 30
    -o "$body_file" -w '%{http_code}')
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
  curl "${args[@]}" "$api_url$path" 2>/dev/null || printf '000'
}

context="$(jq -n \
  --arg workflow "$workflow" \
  --arg job "${GITHUB_JOB:-}" \
  --arg event "${GITHUB_EVENT_NAME:-}" \
  --arg ref "${GITHUB_REF_NAME:-}" \
  --arg sha "${GITHUB_SHA:-}" \
  --arg run_url "$run_url" \
  --arg detail "$detail" \
  -r '
    "- workflow: `\($workflow)`\n" +
    "- job: `\($job)`\n" +
    "- trigger: `\($event)`\n" +
    "- ref: `\($ref)` @ `\($sha)`\n" +
    "- run: \($run_url)\n" +
    (if $detail == "" then "" else "\n\($detail)\n" end)
  ')"

# ---------------------------------------------------------------------------
# Is this condition already reported? One open issue per key.
# ---------------------------------------------------------------------------
status="$(api GET "/repos/$repo/issues?state=open&labels=$label&per_page=100")"
case "$status" in
  200) ;;
  000) die "could not reach the GitHub API at $api_url to look for an existing issue" ;;
  *)   die "GitHub API returned HTTP $status listing open '$label' issues: $(head -c 400 "$body_file")" ;;
esac

# `issues` also returns pull requests; drop anything carrying pull_request.
existing="$(jq -r --arg title "$title" \
  'if type == "array"
   then [ .[] | select(has("pull_request") | not) | select(.title == $title) | .number ] | first // empty
   else empty end' "$body_file" 2>/dev/null)"

if [ -n "$existing" ]; then
  # Ongoing condition: comment, do not mint a duplicate.
  comment="$(jq -n --arg c "$context" \
    '{body: ("Still failing.\n\n" + $c)}')"
  status="$(api POST "/repos/$repo/issues/$existing/comments" "$comment")"
  case "$status" in
    201) printf 'commented on existing issue #%s (%s)\n' "$existing" "$title"
         printf '::notice title=CI failure still open::%s — commented on #%s\n' "$title" "$existing"
         exit 0 ;;
    000) die "could not reach the GitHub API to comment on existing issue #$existing" ;;
    *)   die "GitHub API returned HTTP $status commenting on issue #$existing: $(head -c 400 "$body_file")" ;;
  esac
fi

# ---------------------------------------------------------------------------
# New condition: file it.
# ---------------------------------------------------------------------------
new_issue="$(jq -n \
  --arg title "$title" \
  --arg label "$label" \
  --arg c "$context" \
  '{
     title: $title,
     labels: [$label],
     body: ("A scheduled gate failed. This issue is filed automatically by " +
            "`scripts/file-ci-failure-issue.sh` and is reused (commented on) " +
            "for as long as it stays open, so a recurring failure does not " +
            "spam new issues.\n\n" + $c +
            "\nClose this issue once the gate is green again; the next " +
            "failure will open a fresh one.\n")
   }')"

status="$(api POST "/repos/$repo/issues" "$new_issue")"
case "$status" in
  201)
    number="$(jq -r '.number // "?"' "$body_file")"
    printf 'filed issue #%s (%s)\n' "$number" "$title"
    printf '::notice title=CI failure filed::%s — issue #%s\n' "$title" "$number"
    exit 0 ;;
  000) die "could not reach the GitHub API at $api_url to file the issue" ;;
  *)   die "GitHub API returned HTTP $status filing the issue: $(head -c 400 "$body_file")" ;;
esac
