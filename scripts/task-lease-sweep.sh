#!/usr/bin/env bash
# task-lease-sweep.sh — renew the claim behind EVERY open PR, on a schedule.
#
# THE GAP THIS CLOSES (task-b345a8dce6ca9b8a)
#
# task-lease-renew.yml fires only on pull_request events, and one renewal buys
# `task_lease_extension_window_seconds` (2700 s) of grace. A PR that is opened
# and then waits in the CI queue with no further push therefore loses its
# row's claim ~45 min later, and the REQUIRED "PR references an active task"
# context reds with "the claim had ALREADY lapsed Ns before" (specimen:
# run 33687829197, task-8c2fa9368a937465, 7593 s). 16 of the gate's reds in
# 14 days were this shape; 43 percent of its reds quoted a lapsed claim.
#
# WHAT THIS DOES. Lists the open PRs against main, and for each one runs the
# existing scripts/task-lease-renew.sh with PR_BODY / PR_NUMBER /
# PR_ACTION=synchronize — exactly what the pull_request event would have
# done. This script owns NO second copy of the trailer grammar, the request
# body, the retry ladder or the answer table: those stay in task-lease-renew.sh
# (and its harness), so a change there cannot silently diverge here.
#
# WHAT IT DOES NOT DO. It never resurrects a lapsed claim (the ledger's 409
# not_claimed is a notice, never a retry), never extends past the ledger's
# extension cap (409 extension_cap_reached), and never touches the epoch or
# the holder. A PR whose body names no Task: trailer is skipped and counted.
#
# EXIT CODES
#   0  the open-PR list was read and every row was handled (renewed, skipped,
#      or declined by the ledger with a named reason)
#   1  the ledger REFUSED the token (401/403) on at least one renew — the
#      sweep is inert until the secret is fixed, and that must be red
#   2  CANNOT MEASURE — the PR list could not be read, or a renew exited 2;
#      never a pass over an unknown population
#
# ENV
#   GH_REPO            owner/repo (default: FRIKKern/barkpark)
#   LEDGER_BASE, LEDGER_TOKEN  passed through to task-lease-renew.sh
#   TASK_LEASE_SWEEP_LIST      override the PR-list command's OUTPUT with a file
#                              of JSON lines {"number":N,"body":"..."} (harness)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GH_REPO:-FRIKKern/barkpark}"
RENEW="${TASK_LEASE_SWEEP_RENEW:-$ROOT/scripts/task-lease-renew.sh}"
[ -f "$RENEW" ] || { echo "task-lease-sweep: CANNOT MEASURE — ${RENEW} is not there" >&2; exit 2; }

TMPD="$(mktemp -d -t task-lease-sweep.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT
LIST="$TMPD/prs.jsonl"

if [ -n "${TASK_LEASE_SWEEP_LIST:-}" ]; then
  cp -- "$TASK_LEASE_SWEEP_LIST" "$LIST" || { echo "task-lease-sweep: CANNOT MEASURE — TASK_LEASE_SWEEP_LIST unreadable" >&2; exit 2; }
else
  # One JSON object per line so a multi-line body survives the shell.
  if ! gh api --paginate "repos/${REPO}/pulls?state=open&base=main&per_page=100" \
        --jq '.[] | {number: .number, body: (.body // "")} | tojson' > "$LIST" 2> "$TMPD/gh.err"; then
    echo "task-lease-sweep: CANNOT MEASURE — could not list open PRs for ${REPO}: $(head -c 300 "$TMPD/gh.err")" >&2
    exit 2
  fi
fi

total=0; renewed=0; skipped=0; declined=0; unknown=0; auth=0; unmeasured=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  total=$((total + 1))
  num="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])' 2>/dev/null)" || { unmeasured=$((unmeasured + 1)); echo "task-lease-sweep: CANNOT MEASURE — malformed PR line: $(printf '%s' "$line" | cut -c1-120)" >&2; continue; }
  body="$(printf '%s' "$line" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("body") or "")' 2>/dev/null)"
  out="$(PR_BODY="$body" PR_NUMBER="$num" PR_ACTION="synchronize" bash "$RENEW" 2>&1)"; rc=$?
  # Classify from the subject's own words, so the tally cannot drift from what it did.
  case "$rc:$out" in
    0:*"keeps "*" claimed until"*) renewed=$((renewed + 1)); echo "PR #${num}: renewed" ;;
    0:*"the ledger accepted the renew"*) renewed=$((renewed + 1)); echo "PR #${num}: renewed (accepted; the answer carried no until)" ;;
    0:*"names no task row"*|0:*"two or more DISTINCT"*) skipped=$((skipped + 1)); echo "PR #${num}: skipped (no single Task: trailer)" ;;
    0:*"HTTP 409"*|0:*"HTTP 404"*) declined=$((declined + 1)); echo "PR #${num}: declined by the ledger — $(printf '%s' "$out" | grep -oE 'HTTP 4[0-9]{2}[^)]*' | head -1)" ;;
    1:*) auth=$((auth + 1)); echo "PR #${num}: TOKEN REFUSED" ; printf '%s\n' "$out" | tail -2 >&2 ;;
    2:*) unmeasured=$((unmeasured + 1)); echo "PR #${num}: cannot measure" ; printf '%s\n' "$out" | tail -1 >&2 ;;
    *) unknown=$((unknown + 1)); echo "PR #${num}: rc ${rc}, unclassified — $(printf '%s' "$out" | tail -1 | cut -c1-160)" ;;
  esac
done < "$LIST"

echo "task-lease-sweep: ${total} open PR(s): ${renewed} renewed, ${skipped} skipped, ${declined} declined, ${unknown} unclassified, ${unmeasured} unmeasured, ${auth} token-refused"
[ "$auth" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
