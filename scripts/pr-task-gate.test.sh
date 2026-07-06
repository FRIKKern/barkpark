#!/usr/bin/env bash
# Hermetic test for scripts/pr-task-gate.sh — serves canned ledger responses
# from a local http.server so no guerrilla / network access is needed. Proves
# every exit-code path in the gate's contract.
#
# Run: bash scripts/pr-task-gate.test.sh   (exit 0 = all green)

set -uo pipefail
cd "$(dirname "$0")/.."
GATE="scripts/pr-task-gate.sh"

fixtures="$(mktemp -d)"
trap 'kill "${SRV_PID:-0}" 2>/dev/null; rm -rf "$fixtures"' EXIT

# The gate GETs /v1/data/doc/production/task/<id>. Lay fixtures at that path so
# a plain static file server answers exactly what the ledger would.
mkdir -p "$fixtures/v1/data/doc/production/task"
doc() { # doc <id> <lifecycle> <worker|->
  local id="$1" lc="$2" w="$3"
  local claim="null"
  [ "$w" != "-" ] && claim="{\"worker\":\"$w\",\"epoch\":1}"
  cat > "$fixtures/v1/data/doc/production/task/$id" <<EOF
{"result":{"_id":"$id","_type":"task","lifecycle_status":"$lc","claim":$claim}}
EOF
}
doc active   in_progress fable-tob
doc openone   open        -
doc claimless in_progress -
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

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
