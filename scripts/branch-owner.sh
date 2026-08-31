#!/usr/bin/env bash
#
# branch-owner.sh — "is a live agent already working this branch?"
#
# THE RULE THIS ENFORCES
#
#   VERIFY THE OWNER IS UNREACHABLE BEFORE LAUNCHING AN ADOPTER.
#   Silence is not abandonment. An agent that has not pushed in ninety minutes
#   is usually mid-compile, mid-test-run, or waiting on a gate — not gone.
#   Adopting a branch out from under a live owner costs both agents their work
#   and leaves a force-push race behind. This script never says "go"; the best
#   it says is "the signals are old", and it ends every non-stale verdict with
#   the same sentence.
#
# THE THREE SIGNALS
#
#   1. the open PR whose head is this branch        gh pr list --head
#   2. the last push                                git log -1 origin/<branch>
#   3. the bp task claim behind it                  the `Task:` trailer in the
#                                                   PR body, then that row's
#                                                   claim
#
#   The claim lives FLAT at the top level of the raw document, under `claim`.
#   `content.claim` is ALWAYS null and reading it is how an adopter convinces
#   itself an actively-held row is free. This script reads `.claim`.
#
# USAGE
#
#   branch-owner.sh [--stale-after <minutes>] [--no-fetch] <branch>
#
#   --stale-after N   how many minutes of silence before a signal counts as
#                     old. Default 120. A compile-and-gate cycle in this repo
#                     regularly exceeds 30, so do not lower it casually.
#   --no-fetch        skip `git fetch origin <branch>`; read what you have.
#
# EXIT CODES — chosen so `if branch-owner.sh <b>; then …` is the SAFE shape
#   0  POSSIBLY-STALE  every readable signal is older than --stale-after
#   1  OWNED-LIVE      a push or a claim moved inside the window
#   2  usage error
#   3  UNKNOWN         no signal could be read; the script names which ones

set -euo pipefail

PROG="$(basename -- "$0")"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
usage: branch-owner.sh [--stale-after <minutes>] [--no-fetch] <branch>

  Is a live agent already on this branch? Reads three signals: the open PR for
  that head, the last push to origin/<branch>, and the bp claim on the task in
  the PR body's `Task:` trailer (read FLAT at .claim, never content.claim,
  which is always null).

  --stale-after N   silence threshold in minutes (default 120)
  --no-fetch        do not fetch origin/<branch> first

exit: 0 POSSIBLY-STALE   1 OWNED-LIVE   2 usage error   3 UNKNOWN
EOF
}

die_usage() {
  printf '%s: %s\n\n' "$PROG" "$1" >&2
  usage >&2
  exit 2
}

STALE_AFTER=120
DO_FETCH=1
BRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --stale-after)
      [ $# -ge 2 ] || die_usage "--stale-after needs a number of minutes"
      case "$2" in ''|*[!0-9]*) die_usage "--stale-after must be a number: $2" ;; esac
      STALE_AFTER="$2"; shift 2 ;;
    --no-fetch) DO_FETCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die_usage "unknown flag: $1" ;;
    *)
      [ -z "$BRANCH" ] || die_usage "one branch at a time (got '$BRANCH' and '$1')"
      BRANCH="$1"; shift ;;
  esac
done

[ -n "$BRANCH" ] || die_usage "no branch given"

cd -- "$ROOT"

NOW="$(date +%s)"

# iso_to_epoch <iso8601> — portable across python3, GNU date and BSD date.
# Prints nothing when the stamp cannot be parsed, so callers see "unreadable"
# rather than a silently-wrong number.
#
# ORDER MATTERS, AND THE BSD ARM IS LAST FOR A MEASURED REASON. BSD `date -j`
# ACCEPTS a trailing Z in the format string and then interprets the stamp in
# the LOCAL zone anyway, exit 0, no warning: on a CEST host a UTC stamp came
# back two hours early, which silently ages every claim past a 120-minute
# threshold and turns a live owner into POSSIBLY-STALE. So the BSD arm runs
# under TZ=UTC with the Z stripped, and python3 — which actually understands
# the offset — is tried first.
iso_to_epoch() {
  local iso="$1" out bare
  [ -n "$iso" ] || return 0

  if command -v python3 >/dev/null 2>&1; then
    if out="$(ISO="$iso" python3 -c '
import os, sys, datetime
s = os.environ["ISO"].strip()
if s.endswith("Z"):
    s = s[:-1] + "+00:00"
try:
    d = datetime.datetime.fromisoformat(s)
except Exception:
    sys.exit(1)
if d.tzinfo is None:
    d = d.replace(tzinfo=datetime.timezone.utc)
print(int(d.timestamp()))
' 2>/dev/null)"; then
      printf '%s\n' "$out"; return 0
    fi
  fi

  if out="$(date -d "$iso" +%s 2>/dev/null)"; then printf '%s\n' "$out"; return 0; fi

  bare="${iso%%.*}"          # drop any fractional seconds
  bare="${bare%Z}"           # and the zone marker BSD date mis-reads
  if out="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$bare" +%s 2>/dev/null)"; then
    printf '%s\n' "$out"; return 0
  fi
  return 0
}

# age_minutes <epoch> — whole minutes between then and now.
age_minutes() {
  local then="$1"
  [ -n "$then" ] || return 0
  printf '%s\n' "$(( (NOW - then) / 60 ))"
}

# ── signal 1: the open PR for this head ──────────────────────────────────────

PR_NUMBER=""
PR_URL=""
PR_BODY=""
PR_UPDATED=""
PR_AUTHOR=""
PR_READ="no"
PR_WHY=""

if ! command -v gh >/dev/null 2>&1; then
  PR_WHY="gh is not on PATH"
else
  if PR_LINE="$(gh pr list --head "$BRANCH" --state open --limit 1 \
        --json number,url,updatedAt,author,body \
        --template '{{range .}}{{.number}}	{{.url}}	{{.updatedAt}}	{{.author.login}}{{end}}' 2>&1)"; then
    PR_READ="yes"
    if [ -n "$PR_LINE" ]; then
      IFS=$'\t' read -r PR_NUMBER PR_URL PR_UPDATED PR_AUTHOR <<<"$PR_LINE"
      PR_BODY="$(gh pr view "$PR_NUMBER" --json body --template '{{.body}}' 2>/dev/null || true)"
    fi
  else
    PR_WHY="gh pr list failed: $(printf '%s' "$PR_LINE" | head -2 | tr '\n' ' ')"
    PR_LINE=""
  fi
fi

# ── signal 2: the last push ──────────────────────────────────────────────────

PUSH_EPOCH=""
PUSH_LINE=""
PUSH_WHY=""

if [ "$DO_FETCH" = 1 ]; then
  git fetch origin "$BRANCH" --quiet 2>/dev/null || true
fi

if git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
  PUSH_LINE="$(git log -1 --format='%cI	%an	%s' "origin/$BRANCH" 2>/dev/null || true)"
  PUSH_EPOCH="$(git log -1 --format='%ct' "origin/$BRANCH" 2>/dev/null || true)"
else
  PUSH_WHY="origin/$BRANCH does not exist locally (never pushed, or not fetched)"
fi

# ── signal 3: the bp claim behind the PR's Task: trailer ─────────────────────

TASK_ID=""
CLAIM_WORKER=""
CLAIM_EPOCH=""
CLAIM_TS=""
CLAIM_AGE=""
CLAIM_WHY=""

if [ -n "$PR_BODY" ]; then
  # Bare, backticked or bulleted — all three trailer shapes are in the wild.
  TASK_ID="$(grep -oE 'task-[0-9a-f]{8,}' <<<"$PR_BODY" | head -1 || true)"
fi

# claim_fields — reads the FLAT top-level `claim` off a raw bp task document on
# stdin and prints "worker<TAB>epoch<TAB>timestamp". Kept in its own function so
# the program text is not nested three quoting levels deep.
claim_fields() {
  python3 -c '
import json, sys

try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)

# bp nests the row under "doc" on some verbs and returns it bare on others.
row = d.get("doc") if isinstance(d, dict) and isinstance(d.get("doc"), dict) else d
if not isinstance(row, dict):
    sys.exit(1)

# THE CLAIM IS FLAT. content.claim is always null, and reading that is how an
# adopter talks itself into stealing an actively-held row.
claim = row.get("claim")
if not isinstance(claim, dict):
    sys.exit(1)

now = claim.get("now")
ts = claim.get("claimed_at") or claim.get("ts")
if not ts and isinstance(now, dict):
    ts = now.get("ts")

worker = claim.get("worker_id") or claim.get("worker") or ""
epoch = claim.get("epoch")
sys.stdout.write("%s\t%s\t%s\n" % (worker, "" if epoch is None else epoch, ts or ""))
'
}

if [ -z "$TASK_ID" ]; then
  CLAIM_WHY="no Task: trailer found in the PR body"
elif ! command -v bp >/dev/null 2>&1; then
  CLAIM_WHY="bp is not on PATH - the claim signal was SKIPPED, not evaluated"
elif ! command -v python3 >/dev/null 2>&1; then
  CLAIM_WHY="python3 is not on PATH - the claim signal was SKIPPED, not evaluated"
else
  if RAW="$(bp doc get task "$TASK_ID" --perspective raw -o json 2>/dev/null)"; then
    CLAIM_FIELDS="$(claim_fields <<<"$RAW" 2>/dev/null || true)"
    if [ -n "$CLAIM_FIELDS" ]; then
      IFS=$'\t' read -r CLAIM_WORKER CLAIM_EPOCH CLAIM_TS <<<"$CLAIM_FIELDS"
      if [ -n "$CLAIM_TS" ]; then
        CLAIM_AGE="$(age_minutes "$(iso_to_epoch "$CLAIM_TS")")"
      fi
    fi
    if [ -z "$CLAIM_WORKER" ]; then
      CLAIM_WHY="$TASK_ID carries no live top-level .claim"
    fi
  else
    CLAIM_WHY="bp doc get $TASK_ID failed - the claim signal is UNREAD, not absent"
  fi
fi

# ── the verdict ──────────────────────────────────────────────────────────────

PUSH_AGE=""
[ -n "$PUSH_EPOCH" ] && PUSH_AGE="$(age_minutes "$PUSH_EPOCH")"

LIVE=0
HAVE_SIGNAL=0

if [ -n "$PUSH_AGE" ]; then
  HAVE_SIGNAL=1
  [ "$PUSH_AGE" -le "$STALE_AFTER" ] && LIVE=1
fi
if [ -n "$CLAIM_WORKER" ]; then
  HAVE_SIGNAL=1
  if [ -n "$CLAIM_AGE" ]; then
    [ "$CLAIM_AGE" -le "$STALE_AFTER" ] && LIVE=1
  else
    # A claim with no readable timestamp is a held claim of unknown age. Held
    # beats unknown: treat it as live rather than invite a theft.
    LIVE=1
  fi
fi

if [ "$HAVE_SIGNAL" = 0 ]; then
  VERDICT=UNKNOWN
elif [ "$LIVE" = 1 ]; then
  VERDICT=OWNED-LIVE
else
  VERDICT=POSSIBLY-STALE
fi

printf '%s\n' "$VERDICT"
printf '  branch: %s   (stale-after: %s min)\n' "$BRANCH" "$STALE_AFTER"

printf '\n  PR for this head:\n'
if [ -n "$PR_NUMBER" ]; then
  printf '    #%s by %s   updated %s\n' "$PR_NUMBER" "$PR_AUTHOR" "$PR_UPDATED"
  printf '    %s\n' "$PR_URL"
elif [ "$PR_READ" = "yes" ]; then
  printf '    none open\n'
else
  printf '    UNREAD: %s\n' "${PR_WHY:-gh could not be read}"
fi

printf '\n  last push to origin/%s:\n' "$BRANCH"
if [ -n "$PUSH_LINE" ]; then
  printf '    %s\n' "$PUSH_LINE"
  printf '    %s minutes ago\n' "$PUSH_AGE"
else
  printf '    UNREAD: %s\n' "${PUSH_WHY:-no commit readable}"
fi

printf '\n  bp claim behind the Task: trailer:\n'
if [ -n "$CLAIM_WORKER" ]; then
  printf '    task %s held by %s (epoch %s)\n' "$TASK_ID" "$CLAIM_WORKER" "${CLAIM_EPOCH:-?}"
  if [ -n "$CLAIM_AGE" ]; then
    printf '    claim last moved %s minutes ago (%s)\n' "$CLAIM_AGE" "$CLAIM_TS"
  else
    printf '    claim carries no readable timestamp — age UNKNOWN, treated as LIVE\n'
  fi
else
  printf '    UNREAD: %s\n' "${CLAIM_WHY:-no claim readable}"
fi

case "$VERDICT" in
  OWNED-LIVE)
    printf '\n  A signal moved inside the window. Someone is on this branch.\n'
    printf '  Do NOT adopt unless the owner is confirmed unreachable.\n'
    exit 1 ;;
  UNKNOWN)
    printf '\n  NO signal could be read, so this is not evidence of abandonment —\n'
    printf '  it is evidence the instrument is blind. Fix the unread signals above.\n'
    printf '  Do NOT adopt unless the owner is confirmed unreachable.\n'
    exit 3 ;;
  *)
    printf '\n  Every readable signal is older than %s minutes.\n' "$STALE_AFTER"
    printf '  That is still not proof of abandonment: a long compile, a gate wait\n'
    printf '  or a queued test run all look exactly like this. Ping the owner and\n'
    printf '  confirm they are unreachable before you launch an adopter.\n'
    exit 0 ;;
esac
