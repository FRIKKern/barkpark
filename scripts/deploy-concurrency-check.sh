#!/usr/bin/env bash
# deploy-concurrency-check.sh — a queued production deploy must never be
# EVICTED by the next merge.
#
# THE DEFECT THIS FORBIDS, measured 2026-09-02 on main. deploy.yml carried
#
#     concurrency:
#       group: deploy-production
#       cancel-in-progress: false
#
# One group for every push. GitHub keeps exactly ONE not-yet-started run per
# concurrency group, and the survivor does NOT inherit the evicted run place in
# the runner queue — it is queued fresh, at the back. Under a merge storm (390
# runs queued, about an hour to a runner) that is not coalescing, it is
# starvation: the last SIX push runs were cancelled before starting, guerrilla
# stayed 1.5 h behind main, and the only repair was two deploys by hand.
#
# cancel-in-progress:false does not save it. That setting governs a RUNNING run;
# the eviction happens to the PENDING one, and it happens either way.
#
# THE PROPERTY, and it is ONE property with two halves: the GitHub side must not
# be able to drop a queued deploy.
#
#   (a) the group must vary by push sha — an expression mentioning github.sha —
#       so two pushes are never rivals for the same slot; and
#   (b) cancel-in-progress must be the literal boolean false, so the run that IS
#       on a runner is not killed mid-swap either.
#
# Neither half alone buys it. Per-sha groups with cancel-in-progress:true would
# still cancel a re-run of the same sha mid-deploy; never-cancel with one shared
# group is exactly the shape measured above. scripts/never-cancel-main-check.sh
# owns half (b) for the WHOLE corpus but only forbids the literal true — it
# accepts the ref-guard expression, which on this push-to-main-only workflow
# evaluates to false today and to something else the day a branch is added. This
# gate pins the deploy workflow to the literal.
#
# LEG TWO, SAME PROPERTY, MEASURED 2026-09-05..06 (task-8811b4b25c529dbe). Not
# being EVICTED is worthless if the queued run is reported failed for queueing.
# Ten of the last fourteen failed deploy.yml runs on main died only in the
# instance job with `client_loop: send disconnect: Broken pipe` and exit 255,
# every one of them after logging "another deploy holds the lock — queueing".
# The on-box wait is silent, so the ssh session carries no bytes and the runner
# NAT drops it after roughly five minutes. The client-side half of that fix is
# a keepalive on EVERY ssh/scp option string in the workflow:
#
#   -o ServerAliveInterval=30 -o ServerAliveCountMax=90     (= 45 min tolerance)
#
# and 45 min must stay comfortably over the longest on-box lock wait, which is
# 1800 s (deploy/instance-deploy.sh, deploy/cp-deploy.sh). This gate reds if any
# SSH=/SCP= string in the target loses the pair or drops the product under that
# floor. The on-box half — a heartbeat line while queued — lives in the deploy
# scripts and is guarded by deploy/cp-deploy_test.sh and
# deploy/instance-deploy_test.sh.
#
# WHAT MAKES THE EXTRA RUNS SAFE is not this file: deploy/instance-deploy.sh and
# deploy/cp-deploy.sh open the deploy lock, log "another deploy holds the lock —
# queueing (max 30 min)" and flock -w 1800, then pull AFTER taking it ("git fetch
# origin main + reset --hard") so a queued run ships origin/main tip, and exit at
# the coalesce arm "HEAD ... already deployed healthy — nothing to do" when the
# run ahead already shipped that tree. Serialisation moved from GitHub, where it
# cost a queue position, to the box, where it costs a lock wait.
#
# EXIT CODES
#   0  the stanza cannot drop a queued deploy
#   1  FINDING — it can, or an ssh/scp string lost its keepalive; the reason is named
#   2  CANNOT MEASURE — no python3/PyYAML, no target file, no concurrency block,
#      or a bad flag. Never a vacuous green: a stanza that could not be read is
#      not a stanza that passed.
#
# USAGE
#   bash scripts/deploy-concurrency-check.sh
#   DEPLOY_CONCURRENCY_TARGET=<file> bash scripts/deploy-concurrency-check.sh
#
# The env override exists ONLY so scripts/deploy-concurrency-check.test.sh can
# drive this script end-to-end against planted fixtures — including a verbatim
# copy of the pre-fix stanza, which must red. CI leaves it unset.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${1:-}" ]; then
  echo "deploy-concurrency-check: unknown argument '$1' (this gate takes none)" >&2
  echo "  point it at another file with DEPLOY_CONCURRENCY_TARGET=<path>." >&2
  exit 2
fi

TARGET="${DEPLOY_CONCURRENCY_TARGET:-.github/workflows/deploy.yml}"

if [ ! -f "$TARGET" ]; then
  echo "deploy-concurrency gate could not RUN: target '$TARGET' is not a file — this is NOT a verdict on the workflow." >&2
  exit 2
fi

# NO APOSTROPHES OR BACKTICKS IN THE PYTHON BLOCK. bash 3.2 (what macOS ships)
# scans for the closing paren THROUGH a quoted heredoc inside a command
# substitution, so one stray apostrophe in a Python comment breaks the parse.
scan() {
  python3 - "$1" <<'PY'
import sys

try:
    import yaml
except ImportError:
    print("HARNESS-UNAVAILABLE: PyYAML not importable; this is NOT a verdict on the workflow")
    sys.exit(2)

path = sys.argv[1]
try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:
    print("HARNESS-UNAVAILABLE: %s did not parse as YAML: %s" % (path, exc))
    sys.exit(2)

if not isinstance(doc, dict):
    print("HARNESS-UNAVAILABLE: %s is not a YAML mapping" % path)
    sys.exit(2)

conc = doc.get("concurrency")
if conc is None:
    # An ABSENT block is not a pass. GitHub defaults to no grouping at all,
    # which happens to be safe today, but a deploy workflow that says nothing
    # about concurrency has not decided anything -- and this gate exists to pin
    # a DECISION, not to bless a default that the next edit can move.
    print("HARNESS-UNAVAILABLE: %s declares no top-level concurrency block" % path)
    sys.exit(2)
if not isinstance(conc, dict):
    print("HARNESS-UNAVAILABLE: %s concurrency is not a mapping (shorthand string form)" % path)
    sys.exit(2)

group = conc.get("group")
if not isinstance(group, str) or not group.strip():
    print("HARNESS-UNAVAILABLE: %s concurrency.group is missing or not a string" % path)
    sys.exit(2)

cip = conc.get("cancel-in-progress", False)

findings = []

if "github.sha" not in group:
    findings.append(
        "concurrency.group %r does not vary by push sha. GitHub keeps ONE "
        "not-yet-started run per group and re-queues the survivor at the BACK "
        "of the runner FIFO, so under a merge storm the deploy never reaches a "
        "runner (measured 2026-09-02: six consecutive push runs cancelled "
        "before starting, prod 1.5 h stale)." % group
    )

if cip is not False:
    findings.append(
        "concurrency.cancel-in-progress is %r, not the literal boolean false. A "
        "production deploy must never be killed mid-swap, and an expression is "
        "not a promise -- it is re-evaluated against whatever refs exist later."
        % (cip,)
    )

print("target: %s" % path)
print("group: %s" % group)
print("cancel-in-progress: %r" % (cip,))

for f in findings:
    print("FAIL " + f)

if not findings:
    print("OK a queued deploy cannot be evicted, and a running one cannot be cancelled")
PY
}

SCAN_STATUS=0
RESULT="$(scan "$TARGET")" || SCAN_STATUS=$?

# `|| SCAN_STATUS=$?` is load-bearing: under set -e a bare assignment aborts
# HERE and the HARNESS-UNAVAILABLE text dies inside the discarded capture,
# leaving a red step with an empty log that a reader cannot tell from a finding.
if [ "$SCAN_STATUS" -ne 0 ] || grep -q '^HARNESS-UNAVAILABLE' <<<"$RESULT"; then
  echo "deploy-concurrency gate could not RUN (harness exit ${SCAN_STATUS}) — this is NOT a verdict on the workflow." >&2
  echo "${RESULT:-(the harness produced no output)}" >&2
  exit 2
fi

echo "$RESULT"

if grep -q '^FAIL ' <<<"$RESULT"; then
  echo "" >&2
  echo "deploy-concurrency gate FAILED — this stanza can drop a queued production deploy." >&2
  echo "" >&2
  echo "Fix, in ${TARGET}:" >&2
  echo "    concurrency:" >&2
  # shellcheck disable=SC2016  # the expression is literal prose, not substitution
  echo '      group: deploy-production-${{ github.event_name == '"'"'push'"'"' && github.sha || '"'"'dispatch'"'"' }}' >&2
  echo "      cancel-in-progress: false" >&2
  echo "" >&2
  echo "Per-sha groups mean nothing is evicted, so the OLDEST queued deploy keeps" >&2
  echo "its runner-queue position. The extra runs serialise on the box instead:" >&2
  echo "deploy/instance-deploy.sh and deploy/cp-deploy.sh flock -w 1800, pull AFTER" >&2
  echo "taking the lock, and coalesce with 'already deployed healthy — nothing to do'." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# LEG TWO: the ssh client keepalive on every SSH=/SCP= string.
#
# Deliberately a TEXT scan, not a YAML one: these assignments live inside `run:`
# script bodies, so the parser hands them back as one opaque string per step and
# a structural read would have to re-lex the shell anyway.
#
# LOCK_WAIT_FLOOR is the longest on-box `flock` budget the workflow can be
# waiting behind (instance-deploy.sh / cp-deploy.sh, 1800 s). Interval x count
# must EXCEED it, so a session queued for the whole budget is never dropped
# mid-wait. 30 x 90 = 2700 s leaves 15 minutes of headroom.
LOCK_WAIT_FLOOR=1800
KA_N=0
KA_FINDINGS=""

while IFS= read -r line; do
  case "$line" in
    *SSH=\"ssh\ *|*SCP=\"scp\ *) : ;;
    *) continue ;;
  esac
  KA_N=$((KA_N + 1))
  interval=""; countmax=""
  case "$line" in
    *ServerAliveInterval=*) interval="${line#*ServerAliveInterval=}"; interval="${interval%%[! 0-9]*}"; interval="${interval%% *}" ;;
  esac
  case "$line" in
    *ServerAliveCountMax=*) countmax="${line#*ServerAliveCountMax=}"; countmax="${countmax%%[! 0-9]*}"; countmax="${countmax%% *}" ;;
  esac
  trimmed="${line#"${line%%[![:space:]]*}"}"
  if [ -z "$interval" ] || [ -z "$countmax" ]; then
    KA_FINDINGS="${KA_FINDINGS}FAIL ssh/scp string without a ServerAliveInterval + ServerAliveCountMax pair: ${trimmed}
"
    continue
  fi
  window=$((interval * countmax))
  if [ "$window" -le "$LOCK_WAIT_FLOOR" ]; then
    KA_FINDINGS="${KA_FINDINGS}FAIL keepalive window ${interval}x${countmax}=${window}s does not exceed the ${LOCK_WAIT_FLOOR}s on-box lock wait: ${trimmed}
"
  fi
done < "$TARGET"

if [ "$KA_N" -eq 0 ]; then
  echo "ssh keepalive: no SSH=/SCP= strings in ${TARGET} — nothing to check"
else
  echo "ssh keepalive: ${KA_N} ssh/scp string(s) checked against a ${LOCK_WAIT_FLOOR}s lock wait"
fi

if [ -n "$KA_FINDINGS" ]; then
  printf '%s' "$KA_FINDINGS"
  echo "" >&2
  echo "deploy-concurrency gate FAILED — a queued deploy can be reported FAILED for queueing." >&2
  echo "" >&2
  echo "Every ssh/scp option string in ${TARGET} must carry:" >&2
  echo "    -o ServerAliveInterval=30 -o ServerAliveCountMax=90" >&2
  echo "" >&2
  echo "The on-box deploy waits up to ${LOCK_WAIT_FLOOR}s for the deploy lock and the" >&2
  echo "session is silent while it does. Without a keepalive the runner NAT drops it" >&2
  echo "after ~5 min, ssh exits 255, and a run that was merely QUEUED is recorded as a" >&2
  echo "failed production deploy (10 of the last 14 failed main runs, 2026-09-05..06)." >&2
  exit 1
fi

echo "deploy-concurrency gate OK — ${TARGET} keeps one group per push sha, never cancels, and keeps every ssh session alive through a queued deploy."
