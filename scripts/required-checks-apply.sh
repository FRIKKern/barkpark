#!/usr/bin/env bash
# required-checks-apply.sh — put the committed spec onto a branch, in full,
# every field, every time.
#
# LEGACY PUT, NOT RULESETS (honest-gates D22). `PUT /repos/:o/:r/branches/:b/
# protection` is an idempotent full replace on a FIXED url with ONE verify read.
# Rulesets are POST-and-stack — every call creates another ruleset and you need
# a name->id lookup to find yours, which is precisely the hand-maintained key
# list this epic exists to abolish.
#
# WHY EVERY FIELD IS SENT, INCLUDING THE FALSES (D41)
#
# The full-replace PUT does not converge. Measured: with
# required_conversation_resolution, required_linear_history and
# allow_force_pushes all true, a re-apply that OMITS all three resets
# allow_force_pushes to false and leaves the other two TRUE. So an "idempotent
# apply" that sends only what it cares about passes its own verify while the
# branch carries settings nobody committed. Explicit `false` does reset them —
# hence the spec enumerates every field and this script sends every field.
#
# WHY app_id IS ALWAYS PINNED
#
# app_id pins are STICKY per context NAME: `{"context":"X","app_id":15368}` then
# later `{"context":"X"}` reads back 15368 — omitting app_id means "any app"
# only the FIRST time a name is seen. A brand-new name omitting it reads back
# `null`, i.e. anything with checks:write may satisfy it. Never omit it.
#
# WHY `contexts` IS NEVER SENT
#
# Sending `contexts` alongside `checks` — including `contexts: []` — is a hard
# 422. It fails loudly, which is a mercy; this script simply never sends it.
#
# WHY strict IS FALSE
#
# `strict: true` requires every PR to be up to date with the base before merge.
# This fleet has merged three PRs inside 78 seconds; strict would convert
# parallel merges into a serial rebase-and-rerun train.
#
# SAFETY
#   * refuses unless the spec says enforced:true (so the tooling slice cannot
#     protect anything by accident)
#   * refuses without --confirm
#   * always verifies the read-back afterwards, and reds if it disagrees
#
# USAGE
#   scripts/required-checks-apply.sh --payload            # print, touch nothing
#   scripts/required-checks-apply.sh --confirm            # apply + verify
#   scripts/required-checks-apply.sh --confirm --branch <throwaway>
#   scripts/required-checks-apply.sh --disable --confirm  # break-glass, loud

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SPEC="$REPO_ROOT/.github/required-checks.json"
CONFIRM=0
PAYLOAD_ONLY=0
DISABLE=0
BRANCH_OVERRIDE=""

fail() { echo "FAIL: $*" >&2; exit 1; }

build_payload() {
  # Note what is NOT here: `contexts`. See the header.
  jq '{
    required_status_checks: {
      strict: .protection.required_status_checks.strict,
      checks: .protection.required_status_checks.checks
    },
    enforce_admins: .protection.enforce_admins,
    required_pull_request_reviews: .protection.required_pull_request_reviews,
    restrictions: .protection.restrictions,
    required_linear_history: .protection.required_linear_history,
    allow_force_pushes: .protection.allow_force_pushes,
    allow_deletions: .protection.allow_deletions,
    block_creations: .protection.block_creations,
    required_conversation_resolution: .protection.required_conversation_resolution,
    lock_branch: .protection.lock_branch,
    allow_fork_syncing: .protection.allow_fork_syncing
  }' "$SPEC"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) SPEC="$2"; shift 2 ;;
      --branch) BRANCH_OVERRIDE="$2"; shift 2 ;;
      --confirm) CONFIRM=1; shift ;;
      --payload) PAYLOAD_ONLY=1; shift ;;
      --disable) DISABLE=1; shift ;;
      -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done

  [ -f "$SPEC" ] || fail "no spec at $SPEC"
  jq -e . "$SPEC" >/dev/null || fail "$SPEC is not valid JSON"

  local repo branch
  repo="$(jq -r '.repo' "$SPEC")"
  branch="${BRANCH_OVERRIDE:-$(jq -r '.branch' "$SPEC")}"

  if [ "$DISABLE" -eq 1 ]; then
    # BREAK-GLASS. One command, attributable, never a silent flag: it prints who
    # ran it and leaves the committed spec untouched, so the guard goes RED
    # (enforced:true + branch unprotected) until protection is restored.
    [ "$CONFIRM" -eq 1 ] || fail "--disable needs --confirm; disabling protection is never implicit"
    echo "BREAK-GLASS: removing protection from $repo/$branch as $(gh api user --jq .login 2>/dev/null || echo UNKNOWN) at $(date -u +%FT%TZ)"
    gh api -X DELETE "repos/$repo/branches/$branch/protection" >/dev/null \
      || fail "could not remove protection"
    echo "protection removed. The committed spec still says enforced=$(jq -r .enforced "$SPEC"), so the CI guard is now RED until it is restored — that is the point."
    return 0
  fi

  local payload
  payload="$(build_payload)"

  if [ "$PAYLOAD_ONLY" -eq 1 ]; then
    printf '%s\n' "$payload"
    return 0
  fi

  [ "$(jq -r '.enforced' "$SPEC")" = "true" ] \
    || fail "$SPEC says enforced=false — regenerate and flip it in the PR that intends the protection, then apply"
  [ "$CONFIRM" -eq 1 ] || fail "refusing to write branch protection without --confirm"

  echo "applying $(jq '.required_status_checks.checks | length' <<<"$payload") required context(s) to $repo/$branch"
  printf '%s' "$payload" | gh api -X PUT "repos/$repo/branches/$branch/protection" --input - >/dev/null \
    || fail "the protection PUT failed"

  echo "verifying the read-back (GitHub validates neither the context string nor the app_id)"
  bash "$REPO_ROOT/scripts/required-checks-verify.sh" --spec "$SPEC" ${BRANCH_OVERRIDE:+--sha "$(gh api "repos/$repo/commits/$branch" --jq .sha)"}
}

main "$@"
