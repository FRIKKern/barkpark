#!/usr/bin/env bash
# breakglass-watch.sh — the scream. A LEVEL check that reds for as long as the
# break-glass is open, not once at the moment it opens.
#
# WHY THIS IS A SEPARATE, NARROW READER (honest-gates D61)
#
# required-checks-verify.sh --ci is the right guard for the required-check spec
# and the WRONG one here: it also reads the rendered check-run feed and the open
# pull-request list, so its verdict depends on three endpoints and a settled PR
# head. This reads ONE endpoint — `repos/:o/:r/branches/:b/protection` — and
# answers one question: is the glass open. A watch that can red for a reason
# other than the thing it watches is a watch the fleet learns to dismiss.
#
# WHY `branch_protection_rule` IS NOT THE TRIGGER
#
# It is an EDGE trigger: it fires once when the rule changes and is silent
# forever after. A glass LEFT open needs a LEVEL trigger — a schedule that keeps
# asking. See .github/workflows/breakglass-watch.yml.
#
# TWO AUTHORITIES, IN THIS ORDER
#
#   1. the committed log (offline, always readable, needs no token). A record is
#      written and acknowledged BEFORE the DELETE, so a pushed open record reds
#      main even while the GitHub API is unreachable.
#   2. the live protection object (authoritative about reality, not about
#      intent), read up to 3 times with backoff.
#
# It reds ONLY on an authoritative answer: a 200 that says enforce_admins is
# down, a 404 "Branch not protected" while the committed spec says enforced,
# or an open record in the log. A transport failure after every retry is
# UNKNOWN (exit 2) and is deliberately NOT a red — a GitHub blip that reds main
# every 30 minutes trains the fleet to ignore this check, which is the disease
# this epic exists to cure. That silence is a documented residual, and
# authority 1 covers the case that matters.
#
# EXIT CODES  0 = shut (or not armed) · 1 = OPEN, scream · 2 = UNKNOWN
#
# USAGE
#   scripts/breakglass-watch.sh
#   scripts/breakglass-watch.sh --log <f> --protection-file <f>   # hermetic
#   scripts/breakglass-watch.sh --attempts 3

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SPEC="$REPO_ROOT/.github/required-checks.json"
LOG="$REPO_ROOT/docs/ops/break-glass-log.md"
PROTECTION_FILE=""
REPO_OVERRIDE=""
BRANCH_OVERRIDE=""
ATTEMPTS=3
# 0 in the harness; a real run backs off so three attempts span ~45s and a
# rate-limit window has a chance to clear.
SLEEPS="${BG_RETRY_SLEEP:-5 15 0}"

say() { echo "$*"; }
red() { echo "$*" >&2; }

spec_repo()     { [ -f "$SPEC" ] && jq -r '.repo'   "$SPEC" 2>/dev/null || echo ""; }
spec_branch()   { [ -f "$SPEC" ] && jq -r '.branch' "$SPEC" 2>/dev/null || echo ""; }
spec_enforced() { [ -f "$SPEC" ] && jq -r '.enforced == true' "$SPEC" 2>/dev/null || echo "false"; }

# Identical parse to breakglass.sh: every `open` with no `close` pointing back.
open_glasses() {
  [ -f "$LOG" ] || return 0
  awk '
    /^### BG-/       { id = $2; next }
    /^- event: open/ { if (id != "") opens[id] = 1; next }
    /^- closes: /    { closed[$3] = 1; next }
    END { for (i in opens) if (!(i in closed)) print i }
  ' "$LOG" | sort
}

# ONE endpoint. Prints: true | false | MISSING | UNPROTECTED | UNKNOWN
read_protection_state() {
  if [ -n "$PROTECTION_FILE" ]; then
    if [ ! -f "$PROTECTION_FILE" ]; then
      echo "UNKNOWN"; return 0
    fi
    if grep -q "Branch not protected" "$PROTECTION_FILE" 2>/dev/null; then
      echo "UNPROTECTED"; return 0
    fi
    jq -e . "$PROTECTION_FILE" >/dev/null 2>&1 || { echo "UNKNOWN"; return 0; }
    jq -r '.enforce_admins.enabled | if . == null then "MISSING" else tostring end' "$PROTECTION_FILE"
    return 0
  fi

  local repo branch out i=0 sleep_for
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  branch="${BRANCH_OVERRIDE:-$(spec_branch)}"
  if [ -z "$repo" ] || [ -z "$branch" ]; then
    echo "UNKNOWN"; return 0
  fi

  while [ "$i" -lt "$ATTEMPTS" ]; do
    i=$((i + 1))
    if out="$(gh api "repos/$repo/branches/$branch/protection" 2>&1)"; then
      printf '%s' "$out" \
        | jq -r '.enforce_admins.enabled | if . == null then "MISSING" else tostring end' 2>/dev/null \
        || echo "UNKNOWN"
      return 0
    fi
    # A 404 with this body is an ANSWER, not a transport failure: the branch has
    # no protection at all. Never retried, never softened.
    if grep -q "Branch not protected" <<<"$out"; then
      echo "UNPROTECTED"; return 0
    fi
    red "  attempt $i/$ATTEMPTS could not read protection: $(printf '%s' "$out" | head -1)"
    sleep_for="$(printf '%s\n' $SLEEPS | sed -n "${i}p")"
    [ -n "${sleep_for:-}" ] || sleep_for=0
    [ "$sleep_for" = "0" ] || sleep "$sleep_for"
  done
  echo "UNKNOWN"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --log) LOG="${2:-}"; shift 2 ;;
      --spec) SPEC="${2:-}"; shift 2 ;;
      --protection-file) PROTECTION_FILE="${2:-}"; shift 2 ;;
      --repo) REPO_OVERRIDE="${2:-}"; shift 2 ;;
      --branch) BRANCH_OVERRIDE="${2:-}"; shift 2 ;;
      --attempts) ATTEMPTS="${2:-}"; shift 2 ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) red "unknown argument: $1"; exit 2 ;;
    esac
  done

  local standing state enforced
  standing="$(open_glasses)"
  enforced="$(spec_enforced)"

  if [ -n "$standing" ]; then
    red "BREAK-GLASS OPEN — $LOG carries an unclosed record:"
    printf '%s\n' "$standing" | while IFS= read -r id; do
      [ -n "$id" ] || continue
      red "  $id"
    done
    red "Close it: scripts/breakglass.sh --close --reason … --task …"
    red "This is a LEVEL check. It will red on every run until the glass is closed."
    return 1
  fi

  state="$(read_protection_state)"
  case "$state" in
    true)
      say "ok — enforce_admins.enabled = true, no open record in $LOG"
      return 0 ;;
    false)
      red "BREAK-GLASS OPEN — enforce_admins.enabled = false on the live branch, and NOTHING in $LOG says why."
      red "An unrecorded open glass is worse than a recorded one: restore it with"
      red "  scripts/breakglass.sh --close --reason … --task …"
      red "and write the record by hand, because whoever opened it did not."
      return 1 ;;
    UNPROTECTED)
      if [ "$enforced" = "true" ]; then
        red "BREAK-GLASS OPEN (total) — the branch has NO protection at all while the committed spec says enforced=true."
        return 1
      fi
      say "not armed — the committed spec says enforced=false and the branch is unprotected. Nothing to watch yet."
      return 0 ;;
    MISSING)
      red "the protection object carries no enforce_admins at all — that is not a state this repo's spec can produce."
      return 1 ;;
    *)
      say "::warning::UNKNOWN — protection could not be read after $ATTEMPTS attempts. This is NOT a green: it is a silence, and it is a documented residual (docs/ops/break-glass-log.md). The committed-log authority above still ran."
      return 2 ;;
  esac
}

main "$@"
