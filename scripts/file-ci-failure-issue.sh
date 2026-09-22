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
# BOUNDED. The append above is not free: measured 2026-09-17, the 18 open
# ci-failure issues carry 2782 bot comments between them and #11714
# (crown-reconcile) alone carries 1283 in 31 days — ~41/day, zero human
# replies, and not one of the 18 has ever been adopted into the ledger. A
# notification that repeats 1283 times is a notification nobody reads. So
# after ESCALATE_AFTER consecutive appends on the SAME key the script STOPS
# appending and escalates ONCE: it retitles the issue with the repeat count,
# the first-seen age and the latest run URL, labels it ci-failure-escalated,
# posts ONE @-mention comment, and OPENS one escalation issue under a distinct
# key — the record the ledger could adopt. Every firing after that is SILENT
# on the issue (a ::notice:: in the run log, nothing on GitHub).
#
# THE COUNTER IS THE ISSUE. Nothing here persists across runs, so the repeat
# count is not stored: it is READ from the existing issue's own `comments`
# field, and "already escalated" is read from its LABELS. That is a predicate
# over whatever GitHub currently holds, not a list of keys that goes stale —
# a new workflow gets the behaviour without being enrolled anywhere.
#
# THE LEDGER DOES NOT ADOPT IT, AND THE COMMENT SAYS SO. Barkpark's GitHub
# intake drops every payload whose `sender.type == "Bot"` as its FIRST gate
# (Barkpark.Plugins.Github.Intake.bot_sender?/1 — the D4 structural loop cut),
# and this script writes as github-actions[bot]. So the escalation issue is
# dropped before birth and NO gh-<n> row is created. The escalation comment
# states that in words rather than implying a mirror that does not happen.
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
# COMMITTED LITERAL. After this many consecutive "Still failing." appends on
# the same key the script escalates once and goes quiet. 3 is deliberate: it is
# large enough that a flap self-heals before anyone is paged twice, and small
# enough that the 1283-comment shape measured on #11714 cannot recur. Not an
# env knob — a caller that could raise it would re-open the spiral.
escalate_after=3
escalated_label="ci-failure-escalated"
escalation_label="ci-escalation"
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
# The list response already carries everything the escalation predicate needs —
# `comments` (the repeat count), `created_at` (first seen) and `labels` (has it
# already escalated?) — so no extra round trip is made to decide. Five
# tab-separated fields out of one extraction. `title` is matched WITHOUT the
# escalated suffix, so an issue this script already retitled is still found: the
# match is on the prefix, which is the key.
existing_row="$(jq -r --arg title "$title" --arg esc "$escalated_label" \
  'if type == "array"
   then [ .[] | select(has("pull_request") | not)
          | select((.title // "") == $title
                   or ((.title // "") | startswith($title + " [ESCALATED")))
          | "\(.number)\t\((.assignees // []) | length)\t\(.comments // 0)\t\(.created_at // "")\t\(if ((.labels // []) | map(.name // .) | index($esc)) == null then "no" else "yes" end)\t\(((.labels // []) | map(.name // .) | join(",")))" ] | first // empty
   else empty end' "$body_file" 2>/dev/null)"
IFS=$'\t' read -r existing existing_assignees existing_comments existing_created \
  existing_escalated existing_labels <<<"$existing_row"
existing_comments="${existing_comments:-0}"
existing_escalated="${existing_escalated:-no}"

if [ -n "$existing" ] && [ "$existing_escalated" = yes ]; then
  # ALREADY ESCALATED — the terminal state. The issue is open, retitled with the
  # repeat count, assigned and @-mentioned; another identical comment adds no
  # information and is exactly the 1283-comment defect. Say it in the RUN LOG,
  # where it costs nobody a notification, and write nothing to GitHub.
  printf 'escalated issue #%s already carries this condition (%s) — no comment appended\n' \
    "$existing" "$title"
  printf '::notice title=CI failure already escalated::%s — issue #%s is escalated (%s comments); this firing appended nothing. Close #%s when the condition is fixed.\n' \
    "$title" "$existing" "$existing_comments" "$existing"
  exit 0
fi

if [ -n "$existing" ] && [ "$existing_comments" -ge "$escalate_after" ] 2>/dev/null; then
  # ESCALATE, ONCE. $escalate_after consecutive appends have reported the same
  # condition to the same human with no reply. Four writes, in this order:
  #   1. PATCH the issue: retitle with the count + age, rewrite the body, and
  #      add $escalated_label. The LABEL IS THE LATCH — it is written FIRST, so
  #      a failure in any later step cannot produce a second escalation. That
  #      ordering is what makes "at most once per key" true rather than likely.
  #   2. POST one @-mention comment naming the count, the age, the latest run,
  #      and — in words — that the ledger does not adopt this.
  #   3. POST one NEW issue under $esc_key: the structured record.
  first_seen_days="$(jq -n --arg c "$existing_created" -r '
    if $c == "" then "unknown"
    else (((now - ($c | fromdateiso8601)) / 86400) | floor | tostring) end' 2>/dev/null)"
  [ -n "$first_seen_days" ] || first_seen_days="unknown"
  esc_key="$key"
  esc_title="CI escalation: $esc_key"
  new_title="$title [ESCALATED after $existing_comments repeats]"

  esc_summary="$(jq -n \
    --arg key "$key" \
    --arg n "$existing_comments" \
    --arg age "$first_seen_days" \
    --arg run_url "$run_url" \
    --arg after "$escalate_after" \
    --arg num "$existing" \
    -r '
      "- failure key: `\($key)`\n" +
      "- repeats: \($n) identical automated reports on #\($num)\n" +
      "- first seen: \($age) days ago\n" +
      "- latest run: \($run_url)\n" +
      "- escalated after: \($after) consecutive appends\n"
    ')"

  # The honest line. Verified against api/lib/barkpark/plugins/github/intake.ex:
  # bot_sender?/1 returns true for sender.type == "Bot" and the FIRST gate in
  # handle/2 drops it — this script writes as github-actions[bot], so the
  # escalation issue below is dropped before birth and mints no gh-<n> row.
  ledger_note="$(printf '%s' 'LEDGER: NOT ADOPTED. This escalation is opened by `github-actions[bot]`. Barkpark'"'"'s GitHub intake drops every payload whose `sender.type == "Bot"` as its first gate (`Barkpark.Plugins.Github.Intake.bot_sender?/1`, the D4 loop cut), so NO `gh-<n>` task row is born from it and nothing in the ledger will ever show this condition. Adopt it by hand (`bp task create`) if it needs to be tracked. This line exists so the escalation does not read as a mirror that happened.')"

  esc_body="$(jq -n \
    --arg s "$esc_summary" \
    --arg c "$context" \
    --arg note "$ledger_note" \
    --arg num "$existing" \
    -r '
      "A CI failure has repeated past the point where another automated comment " +
      "tells anyone anything. `scripts/file-ci-failure-issue.sh` has STOPPED " +
      "appending to #\($num) and filed this once instead.\n\n" +
      $s + "\n" + $c + "\n" + $note + "\n"
    ')"

  patch_body="$(jq -n \
    --arg t "$new_title" \
    --arg s "$esc_summary" \
    --arg c "$context" \
    --arg note "$ledger_note" \
    --arg esc "$escalated_label" \
    --argjson labels "$(printf '%s' "$existing_labels" | jq -R 'split(",") | map(select(length > 0))')" \
    '{
       title: $t,
       labels: (($labels + [$esc]) | unique),
       body: ("**ESCALATED.** This condition has repeated without a human reply. " +
              "No further automated comments will be appended to this issue " +
              "while it carries the `" + $esc + "` label — reopening the spiral " +
              "requires closing this issue, which is also how you tell the gate " +
              "the condition is fixed.\n\n" + $s + "\n" + $c + "\n" + $note + "\n")
     }')"

  esc_status="$(api PATCH "/repos/$repo/issues/$existing" "$patch_body")"
  [ "$esc_status" = 200 ] || die "GitHub API returned HTTP $esc_status escalating issue #$existing (the latch was NOT written, so this will be retried): $(head -c 400 "$body_file")"

  mention_line=''
  [ -n "$assignee" ] && mention_line="$(printf '@%s — you are the routed human for this.\n\n' "$assignee")"
  esc_comment="$(jq -n --arg m "$mention_line" --arg s "$esc_summary" --arg note "$ledger_note" \
    '{body: ($m + "**Escalated — no further automated comments will be posted here.**\n\n" + $s + "\n" + $note + "\n")}')"
  esc_status="$(api POST "/repos/$repo/issues/$existing/comments" "$esc_comment")"
  [ "$esc_status" = 201 ] || die "GitHub API returned HTTP $esc_status posting the escalation comment on #$existing: $(head -c 400 "$body_file")"

  esc_issue="$(jq -n --arg t "$esc_title" --arg l "$escalation_label" --arg b "$esc_body" \
    --argjson assignees "$( [ -n "$assignee" ] && jq -n --arg a "$assignee" '[$a]' || printf '[]' )" \
    '{title: $t, labels: [$l], assignees: $assignees, body: $b}')"
  esc_status="$(api POST "/repos/$repo/issues" "$esc_issue")"
  case "$esc_status" in
    201) esc_number="$(jq -r '.number // "?"' "$body_file")" ;;
    *)   die "GitHub API returned HTTP $esc_status opening the escalation issue '$esc_title'. Issue #$existing IS escalated (it carries $escalated_label) and will not be retried, so this record is LOST unless filed by hand: $(head -c 400 "$body_file")" ;;
  esac

  printf 'escalated issue #%s after %s repeats; opened escalation issue #%s (%s)\n' \
    "$existing" "$existing_comments" "$esc_number" "$esc_title"
  printf '::notice title=CI failure ESCALATED::%s — #%s repeated %s times over %s days; escalation issue #%s opened. The ledger does NOT adopt it (bot sender drop).\n' \
    "$title" "$existing" "$existing_comments" "$first_seen_days" "$esc_number"
  warn "escalation issue #$esc_number was opened by github-actions[bot] and Barkpark's GitHub intake drops Bot senders, so NO ledger row was created for it. Track it by hand if it matters."
  exit 0
fi

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
