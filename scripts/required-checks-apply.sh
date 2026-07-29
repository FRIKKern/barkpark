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
# THE BREAK-GLASS IS NOT HERE. IT IS scripts/breakglass.sh (wave 5, S4)
#
# `--disable` removes ALL protection from the branch — the total hammer: admin
# merge AND direct `git push` come back, and re-arming is just `--confirm`
# again, because the PUT is a full replace. It used to gate on nothing but
# `--confirm`, write NO record, and echo an attribution line into the operator's
# own terminal. That is a silent open, which is the failure this epic exists to
# abolish, so `--disable` now DELEGATES to `scripts/breakglass.sh --open
# --total`: same refusals, same write-record-and-acknowledge-BEFORE-the-DELETE
# ordering, same append-only log, and the record carries `scope: total` so
# `--close` restores the FULL object rather than enforce_admins alone.
#
#     scripts/breakglass.sh --open  --reason "…" --task <id>            # narrow
#     scripts/breakglass.sh --open  --reason "…" --task <id> --total    # total
#     scripts/breakglass.sh --close --reason "…" --task <id>            # back
#
# There is no unrecorded recipe in this header any more. The two raw `gh api`
# lines that used to live here taught the exact path the epic is closing; the
# narrow form is `breakglass.sh --open`, which is one command, attributable, and
# refuses to touch the API before the record is on disk.
#
# Either scope reds `required-checks-verify.sh` while the glass is open (it
# asserts enforce_admins.enabled == true) and reds `breakglass-watch.sh` every
# 30 minutes, so a break-glass left open is a CI failure and not a quiet drift.
#
# SAFETY
#   * refuses unless the spec says enforced:true (so the tooling slice cannot
#     protect anything by accident)
#   * refuses without --confirm
#   * `--disable` additionally refuses without --reason AND --task, because it
#     is a break-glass and a break-glass with no why is a shrug
#   * always verifies the read-back afterwards, and reds if it disagrees
#
# USAGE
#   scripts/required-checks-apply.sh --payload            # print, touch nothing
#   scripts/required-checks-apply.sh --confirm            # apply + verify
#   scripts/required-checks-apply.sh --confirm --branch <throwaway>
#   scripts/required-checks-apply.sh --disable --confirm --reason "…" --task <id>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SPEC="$REPO_ROOT/.github/required-checks.json"
CONFIRM=0
PAYLOAD_ONLY=0
DISABLE=0
BRANCH_OVERRIDE=""
REASON=""
TASK=""
LOG_OVERRIDE=""

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
      --reason) REASON="${2:-}"; shift 2 ;;
      --task) TASK="${2:-}"; shift 2 ;;
      --log) LOG_OVERRIDE="${2:-}"; shift 2 ;;
      # By SHAPE, not a line range: a range silently truncates the moment anyone
      # adds a line to the header above it.
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done

  [ -f "$SPEC" ] || fail "no spec at $SPEC"
  jq -e . "$SPEC" >/dev/null || fail "$SPEC is not valid JSON"

  local repo branch
  repo="$(jq -r '.repo' "$SPEC")"
  branch="${BRANCH_OVERRIDE:-$(jq -r '.branch' "$SPEC")}"

  if [ "$DISABLE" -eq 1 ]; then
    # BREAK-GLASS, TOTAL SCOPE — and it does not happen here. This used to DELETE
    # the protection object directly after echoing the actor's login at the
    # operator's own terminal, with a fallback that printed the literal string
    # "unknown" when the read failed: no record, and an UNATTRIBUTABLE actor let
    # through, which is not a break-glass at all.
    #
    # Every clause of that is now breakglass.sh's:
    # it refuses without --reason and --task before any API call, hard-fails on
    # an unreadable actor (read_actor), writes the record and READS IT BACK OFF
    # DISK before the DELETE, and stamps `scope: total` so --close restores the
    # whole object instead of enforce_admins alone.
    [ "$CONFIRM" -eq 1 ] || fail "--disable needs --confirm; disabling protection is never implicit"
    [ -n "$REASON" ] || fail "--disable needs --reason; the total hammer records, and a record with no stated reason is a shrug"
    [ -n "$TASK" ]   || fail "--disable needs --task; the record must point at the work that justified it"

    echo "BREAK-GLASS (total) — delegating to scripts/breakglass.sh, which records BEFORE it deletes."
    # Built as an ARRAY. `${LOG_OVERRIDE:+--log "$LOG_OVERRIDE"}` has to stay
    # unquoted to vanish when empty, which also means it WORD-SPLITS when set —
    # so a log or branch path containing a space would have reached breakglass.sh
    # as two arguments and been refused, at the worst possible moment.
    # `if`, not `[ … ] && …`: under `set -e` an AND-list whose FIRST command is
    # false makes the whole list the failing pipeline, and the script would exit
    # 1 — silently doing nothing — in the ordinary case where no override is set.
    local -a glass_args=(--open --total --spec "$SPEC")
    if [ -n "$LOG_OVERRIDE" ]; then    glass_args+=(--log "$LOG_OVERRIDE"); fi
    if [ -n "$BRANCH_OVERRIDE" ]; then glass_args+=(--branch "$branch"); fi
    glass_args+=(--reason "$REASON" --task "$TASK")
    exec bash "$REPO_ROOT/scripts/breakglass.sh" "${glass_args[@]}"
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
  # `--branch` too, not just `--sha`: verify otherwise reads the live protection
  # of the branch the SPEC names (main), so an apply to a throwaway branch would
  # verify a branch it never touched — an apply/verify pair that cannot agree.
  bash "$REPO_ROOT/scripts/required-checks-verify.sh" --spec "$SPEC" \
    ${BRANCH_OVERRIDE:+--branch "$branch" --sha "$(gh api "repos/$repo/commits/$branch" --jq .sha)"}
}

main "$@"
