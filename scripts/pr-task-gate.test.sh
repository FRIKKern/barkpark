#!/usr/bin/env bash
# Hermetic test for scripts/pr-task-gate.sh — serves canned ledger responses
# from a local http.server so no guerrilla / network access is needed. Proves
# every exit-code path in the gate's contract.
#
# Run: bash scripts/pr-task-gate.test.sh   (exit 0 = all green)

set -uo pipefail
# Hard-exit on a failed cd: silently running from the wrong directory would make
# every `bash "$GATE"` a "file not found" — which the harness would read as an
# exit code, not as a broken run. A gate must never be able to go vacuously green.
cd "$(dirname "$0")/.." || { echo "TEST HARNESS FAIL: cannot cd to the repo root" >&2; exit 99; }
GATE="scripts/pr-task-gate.sh"
[ -f "$GATE" ] || { echo "TEST HARNESS FAIL: $GATE not found from $PWD" >&2; exit 99; }

fixtures="$(mktemp -d)"
# `wait` after the kill reaps the server so bash does not print a job-control
# "Terminated: 15" line AFTER the passing summary — trailing scare-text on a
# green run is how a gate teaches its readers to stop trusting its output.
trap 'kill "${SRV_PID:-0}" 2>/dev/null; wait "${SRV_PID:-0}" 2>/dev/null; rm -rf "$fixtures"' EXIT

# The gate GETs /v1/data/doc/production/task/<id>. Lay fixtures at that path so
# a plain static file server answers exactly what the ledger would.
mkdir -p "$fixtures/v1/data/doc/production/task"
doc() { # doc <id> <lifecycle> <worker|-> [closed_by]
  local id="$1" lc="$2" w="$3" cb="${4:--}"
  local claim="null" fields=""
  [ "$w"  != "-" ] && fields="\"worker\":\"$w\",\"epoch\":1"
  [ "$cb" != "-" ] && fields="${fields:+$fields,}\"closed_by\":\"$cb\""
  [ -n "$fields" ] && claim="{$fields}"
  cat > "$fixtures/v1/data/doc/production/task/$id" <<EOF
{"result":{"_id":"$id","_type":"task","lifecycle_status":"$lc","claim":$claim}}
EOF
}
doc active   in_progress fable-tob
doc openone   open        -
doc claimless in_progress -
# Non-in_progress lifecycles WITH a worker present. Without these, the gate's
# lifecycle discrimination and its claim.worker check are indistinguishable on
# the fixture set: the only non-in_progress case was `openone`, whose claim is
# null, so it is really caught by the worker check — and deleting the lifecycle
# check entirely left the harness fully GREEN. These two are the only fixtures
# that can tell the two checks apart. Do not remove them.
doc donetask "done"      fable-tob
doc canctask cancelled fable-tob
# The done path. `doneclosed` went through the claim/close engine (claim carries
# closed_by) and is the SUCCESS case the gate used to red. `donebare` has claim:
# null — done but never worked — and `donetask` above was hand-flipped to done
# while its claim still only carries a worker. Only the first is task-backed.
doc doneclosed "done" fable-tob fable-tob
doc donebare   "done" -
# Worker/closed_by strings containing a SPACE. The ledger accepts them (nothing
# constrains the field to a slug), and a whitespace-split positional read of the
# parser's output shifts every later field one position — the gate would then
# report `closed_by` as the worker's second word and compare EXPECTED_WORKER
# against garbage, all while returning a confident verdict. These fixtures pin
# the tab-separated read; they go red the moment it reverts to plain `read -r`.
doc spacey      in_progress "fable tob"
doc spaceclosed "done"      "fable tob" "lead truthgrip"
# 404 fixture: an id with no file → http.server returns 404 for /task/ghost
# (missing.json below is a malformed-JSON body served with 200 to test parsing)
printf 'not json{' > "$fixtures/v1/data/doc/production/task/garbled"

# Boot a static server. http.server returns 200 for existing files, 404 else.
python3 -m http.server 0 --directory "$fixtures" >/dev/null 2>&1 &
SRV_PID=$!
# Discover the assigned port by parsing the socket the child is listening on.
port=""
for _ in $(seq 1 50); do
  port="$(python3 - "$SRV_PID" <<'PY' 2>/dev/null || true
import sys, subprocess, re
pid = sys.argv[1]
out = subprocess.run(["lsof","-Pan","-p",pid,"-iTCP","-sTCP:LISTEN"],
                     capture_output=True, text=True).stdout
m = re.search(r":(\d+) \(LISTEN\)", out)
print(m.group(1) if m else "")
PY
)"
  [ -n "$port" ] && break
  sleep 0.1
done
if [ -z "$port" ]; then echo "TEST HARNESS FAIL: could not find server port" >&2; exit 99; fi
BASE="http://127.0.0.1:$port"

pass=0 fail=0
check() { # check <label> <expected_exit> <env...>
  local label="$1" want="$2"; shift 2
  # Default LEDGER_BASE FIRST so a per-check override (passed in "$@") wins —
  # in `A=1 A=2 cmd` the last assignment takes effect.
  ( eval "LEDGER_BASE=\"$BASE\" $* bash \"$GATE\"" ) >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s (exit %s)\n' "$label" "$got"
  else fail=$((fail+1)); printf 'FAIL %-40s want %s got %s\n' "$label" "$want" "$got"; fi
}

check "active task passes"          0 'TASK_ID=active'
check "open task fails"             1 'TASK_ID=openone'
check "in_progress but unclaimed"   1 'TASK_ID=claimless'
check "nonexistent task fails"      1 'TASK_ID=ghost'
check "garbled json is neutral"     2 'TASK_ID=garbled'
check "no task ref fails"           1 'TASK_ID='
check "wrong worker fails"          1 'TASK_ID=active EXPECTED_WORKER=nobody'
check "right worker passes"         0 'TASK_ID=active EXPECTED_WORKER=fable-tob'
check "unreachable ledger neutral"  2 'TASK_ID=active LEDGER_BASE=http://127.0.0.1:1'
check "done+worker, no closed_by"   1 'TASK_ID=donetask'
check "cancelled+worker fails"      1 'TASK_ID=canctask'
check "done+closed_by passes"       0 'TASK_ID=doneclosed'
check "done with no claim fails"    1 'TASK_ID=donebare'
check "done+closed_by right worker" 0 'TASK_ID=doneclosed EXPECTED_WORKER=fable-tob'
check "done+closed_by wrong worker" 1 'TASK_ID=doneclosed EXPECTED_WORKER=nobody'
check "spaced worker passes"        0 'TASK_ID=spacey'
check "spaced worker matches"       0 'TASK_ID=spacey EXPECTED_WORKER="fable tob"'
check "spaced worker rejects prefix" 1 'TASK_ID=spacey EXPECTED_WORKER=fable'
check "spaced closed_by passes"     0 'TASK_ID=spaceclosed'
check "spaced closed_by matches"    0 'TASK_ID=spaceclosed EXPECTED_WORKER="lead truthgrip"'

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
