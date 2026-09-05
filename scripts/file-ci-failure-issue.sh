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
# FILED IS NOT ROUTED. An issue nobody is assigned to and nobody is mentioned
# in reaches nobody: `gh repo view FRIKKern/barkpark --json viewerSubscription`
# reads UNSUBSCRIBED, which means GitHub notifies the owner only when they are
# participating or @mentioned. The proof this mattered is #5658, open since
# 2026-07-22 with 8 comments, every one authored by github-actions and none by
# a human. So a NEW issue is filed WITH an assignee and an @mention, and an
# EXISTING issue that has nobody assigned gets assigned + @mentioned on the
# comment that reports the next firing — once, because the assignment it just
# made is what silences the mention on every firing after it. This is routing,
# not delivery: whether the human then reads it is not something this script can
# prove, and #5658 is the standing counter-example.
#
# LOUD ON DEGRADE. Every unusable-input and API failure emits ::error:: and
# exits non-zero. It never warns-and-passes: a notifier that silently no-ops is
# worse than no notifier, because it manufactures confidence. The ONE softened
# case is routing: a rejected or dropped assignment emits ::warning:: and still
# exits 0, because the issue itself IS the alarm and losing it to a bad login
# would be strictly worse than filing it unrouted.
#
# Exit: 0 = a human-visible issue now exists (created or commented).
#       1 = the alert could NOT be delivered (loudly).
#
# Env: GITHUB_TOKEN GITHUB_REPOSITORY (required)
#      CI_FAILURE_ASSIGNEE (login to route to — a NEW issue, or an existing one
#        that has nobody assigned; default: the owner
#        half of GITHUB_REPOSITORY. Set it to the EMPTY string to file unrouted
#        deliberately — that is an opt-out and warns about nothing.)
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

warn() { # warn <message> — the alarm exists but did not reach a named human
  printf '::warning title=CI failure filed but NOT routed::%s\n' "$1" >&2
}

api_url="${GITHUB_API_URL:-https://api.github.com}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
token="${GITHUB_TOKEN:-}"
repo="${GITHUB_REPOSITORY:-}"
workflow="${GITHUB_WORKFLOW:-unknown-workflow}"
key="${CI_FAILURE_KEY:-$workflow}"
label="${CI_FAILURE_LABEL:-ci-failure}"
detail="${CI_FAILURE_DETAIL:-}"
# REDACTION (task-6f18e71a351f8081, E). The issue this script files is PUBLIC and
# the detail is pasted from CI logs by the caller. Anything shaped like a
# credential is masked BEFORE it reaches the body: GitHub tokens (ghp_/gho_/
# ghu_/ghs_/ghr_/github_pat_), Bearer/Basic authorization values, and
# KEY=value pairs whose key names a TOKEN/SECRET/PASSWORD/KEY. The mask keeps
# the key so the reader still learns WHICH thing leaked. Proven by mutation in
# file-ci-failure-issue.test.sh ("redaction" case).
redact() {
  sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED:github-token]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED:github-token]/g' \
    -e 's/([Aa]uthorization:?[[:space:]]*)(Bearer|Basic|token)[[:space:]]+[^[:space:]"\x27]+/\1\2 [REDACTED]/g' \
    -e 's/\b(Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+\/=-]{16,}/\1 [REDACTED]/g' \
    -e 's/([A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|KEY_BASE|CLOAK_KEY|KEK)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*)[^[:space:]"\x27]+/\1[REDACTED]/g'
}
detail="$(printf '%s' "$detail" | redact)"
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

# Derived, never hardcoded: an explicit login wins, otherwise the owner half of
# GITHUB_REPOSITORY, which is correct in every fork and every mirror. `-` (not
# `:-`) so an explicitly EMPTY CI_FAILURE_ASSIGNEE is an opt-out rather than a
# fallback to the owner.
assignee="${CI_FAILURE_ASSIGNEE-${repo%%/*}}"

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
# The list response ALREADY carries `assignees`, so the comment path can tell a
# routed issue from an unrouted one without a second round trip: number and
# assignee count come out of this one extraction, tab-separated.
existing_row="$(jq -r --arg title "$title" \
  'if type == "array"
   then [ .[] | select(has("pull_request") | not) | select(.title == $title)
          | "\(.number)\t\((.assignees // []) | length)" ] | first // empty
   else empty end' "$body_file" 2>/dev/null)"
existing="${existing_row%%$'\t'*}"
existing_assignees="${existing_row#*$'\t'}"

if [ -n "$existing" ]; then
  # Ongoing condition: comment, do not mint a duplicate.
  #
  # ROUTE ONCE, THEN STOP NAGGING. An issue filed before this script routed
  # anything has NO assignee, and every later firing took this path — #5658 sat
  # open from 2026-07-22 with 8 comments, all from github-actions, nobody
  # assigned. So when the existing issue has ZERO assignees, assign it (the
  # same source as the create path) AND @mention in that same comment. Both
  # halves are conditioned on the SAME zero-assignee test, which is what makes
  # this route-once rather than nag: the next firing sees an assignee and says
  # nothing. Mentioning without assigning would repeat forever — the crown
  # fires 6-hourly — and assigning without mentioning leans on auto-subscribe
  # this script cannot prove.
  mention='' patch_rejected=''
  if [ "${existing_assignees:-0}" = 0 ] && [ -n "$assignee" ]; then
    patch_status="$(api PATCH "/repos/$repo/issues/$existing" \
      "$(jq -n --arg a "$assignee" '{assignees: [$a]}')")"
    if [ "$patch_status" = 200 ]; then
      mention="$(printf '\nRouted to @%s, who is now assigned to this issue — it was filed with nobody assigned. Set `CI_FAILURE_ASSIGNEE` on the calling step to route it elsewhere.\n' "$assignee")"
    else
      # Same degrade contract as the create path: the comment IS the alarm, so
      # a rejected assignment warns and still exits 0. The @mention stays in
      # the body — it is the routing that survived.
      patch_rejected="$patch_status"
      mention="$(printf '\nRouted to @%s by mention only: this issue has nobody assigned and GitHub returned HTTP %s for the assignment. Check that the login can be assigned in this repository, or set `CI_FAILURE_ASSIGNEE` on the calling step.\n' "$assignee" "$patch_status")"
    fi
  fi

  comment="$(jq -n --arg c "$context" --arg mention "$mention" \
    '{body: ("Still failing.\n\n" + $c + $mention)}')"
  status="$(api POST "/repos/$repo/issues/$existing/comments" "$comment")"
  case "$status" in
    201) printf 'commented on existing issue #%s (%s)\n' "$existing" "$title"
         printf '::notice title=CI failure still open::%s — commented on #%s\n' "$title" "$existing"
         if [ -n "$patch_rejected" ]; then
           warn "issue #$existing carries the failure and the comment @mentions @$assignee, but GitHub returned HTTP $patch_rejected for the assignment, so nobody is assigned to it. Check that the login can be assigned in this repository, or set CI_FAILURE_ASSIGNEE on the calling step."
         fi
         exit 0 ;;
    000) die "could not reach the GitHub API to comment on existing issue #$existing" ;;
    *)   die "GitHub API returned HTTP $status commenting on issue #$existing: $(head -c 400 "$body_file")" ;;
  esac
fi

# ---------------------------------------------------------------------------
# New condition: file it, and route it to a human.
# ---------------------------------------------------------------------------
build_issue() { # build_issue <route: 1 = carry the assignee, 0 = unrouted>
  local assignees='[]' mention=''
  if [ "$1" = 1 ] && [ -n "$assignee" ]; then
    assignees="$(jq -n --arg a "$assignee" '[$a]')"
    mention="$(printf '\nRouted to @%s, who is assigned to this issue. Set `CI_FAILURE_ASSIGNEE` on the calling step to route it elsewhere.\n' "$assignee")"
  fi
  jq -n \
    --arg title "$title" \
    --arg label "$label" \
    --arg c "$context" \
    --arg mention "$mention" \
    --argjson assignees "$assignees" \
    '{
       title: $title,
       labels: [$label],
       assignees: $assignees,
       body: ("A scheduled gate failed. This issue is filed automatically by " +
              "`scripts/file-ci-failure-issue.sh` and is reused (commented on) " +
              "for as long as it stays open, so a recurring failure does not " +
              "spam new issues.\n\n" + $c + $mention +
              "\nClose this issue once the gate is green again; the next " +
              "failure will open a fresh one.\n")
     }'
}

status="$(api POST "/repos/$repo/issues" "$(build_issue 1)")"

# The assignment has its own failure mode — a login that does not exist, one
# that cannot be assigned in this repository, a token without the scope — and
# GitHub rejects the WHOLE create for it. The issue is the alarm, so refile it
# unrouted rather than lose it; the ::warning:: below names what was lost.
rejected=""
if [ "$status" != 201 ] && [ -n "$assignee" ]; then
  rejected="$status"
  status="$(api POST "/repos/$repo/issues" "$(build_issue 0)")"
fi

case "$status" in
  201)
    number="$(jq -r '.number // "?"' "$body_file")"
    routed="$(jq -r --arg a "$assignee" \
      'if ([(.assignees // [])[] | .login] | index($a)) == null then "" else "yes" end' \
      "$body_file" 2>/dev/null)"
    printf 'filed issue #%s (%s)\n' "$number" "$title"
    if [ -z "$assignee" ]; then
      printf '::notice title=CI failure filed::%s — issue #%s (unrouted: CI_FAILURE_ASSIGNEE is set to the empty string)\n' "$title" "$number"
    elif [ -n "$routed" ]; then
      printf '::notice title=CI failure filed::%s — issue #%s, routed to @%s\n' "$title" "$number" "$assignee"
    elif [ -n "$rejected" ]; then
      warn "issue #$number exists and carries the failure, but GitHub returned HTTP $rejected for the create that assigned @$assignee, so it was refiled with NOBODY assigned. Check that the login exists and can be assigned in this repository, or set CI_FAILURE_ASSIGNEE on the calling step."
    else
      warn "issue #$number exists and carries the failure, but GitHub accepted the create WITHOUT applying the assignment to @$assignee, so nobody is assigned to it. Check that the login can be assigned in this repository, or set CI_FAILURE_ASSIGNEE on the calling step."
    fi
    exit 0 ;;
  000) die "could not reach the GitHub API at $api_url to file the issue" ;;
  *)   die "GitHub API returned HTTP $status filing the issue: $(head -c 400 "$body_file")" ;;
esac
