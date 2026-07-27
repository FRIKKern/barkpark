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

# The workflow whose STEP BODIES the last section executes. Overridable so the
# same fixtures can be pointed at a PRE-FIX copy of the workflow (e.g.
# `git show <sha>:.github/workflows/pr-task-gate.yml > /tmp/old.yml`) and shown
# RED — a fixture nobody has ever seen fail is not evidence of anything.
WORKFLOW="${PR_TASK_GATE_WORKFLOW:-.github/workflows/pr-task-gate.yml}"
[ -f "$WORKFLOW" ] || { echo "TEST HARNESS FAIL: $WORKFLOW not found from $PWD" >&2; exit 99; }

# Retry backoff off by default so the harness stays fast. The backoff itself is
# proven by its own timed fixture below, which sets this explicitly — the
# retries' EXISTENCE is proven by request counts against the flaky server, not
# by wall-clock, so zeroing the delay costs no coverage.
export PR_TASK_GATE_RETRY_DELAY="${PR_TASK_GATE_RETRY_DELAY:-0}"

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

# ── Lapsed-claim fixtures (D23) ───────────────────────────────────────────────
# The TTL sweeper reaps a claim out from under a PR that sits in review longer
# than the ~45min lease: it writes claim.worker→null AND lifecycle→"open" AND
# stamps claim.previous_worker + claim.expired_at. 11 of the gate's last 15 reds
# were that reap, not a missing task. These fixtures pin the exact predicate —
# every clause has a fixture that goes red when the clause is deleted.
raw_doc() { # raw_doc <id> <lifecycle> <claim-json>
  cat > "$fixtures/v1/data/doc/production/task/$1" <<EOF
{"result":{"_id":"$1","_type":"task","lifecycle_status":"$2","claim":$3}}
EOF
}
iso_ago() { # iso_ago <seconds> → an ISO-8601 Z stamp that many seconds in the past
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
t = datetime.now(timezone.utc) - timedelta(seconds=int(sys.argv[1]))
print(t.isoformat().replace("+00:00", "Z"))
PY
}
EXP_RECENT="$(iso_ago 600)"       # 10 min ago — inside the 6h grace
EXP_STALE="$(iso_ago 604800)"     # 7 days ago — far outside it
raw_doc lapserecent  open "{\"worker\":null,\"epoch\":3,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$EXP_RECENT\"}"
raw_doc lapsestale   open "{\"worker\":null,\"epoch\":3,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$EXP_STALE\"}"
# Never claimed, but the doc carries a claim object with a timestamp: no
# previous_worker means no reap ever happened, so there is nothing to forgive.
raw_doc lapsenoprev  open "{\"worker\":null,\"epoch\":0,\"expired_at\":\"$EXP_RECENT\"}"
# Reaped (previous_worker present) but no readable expired_at: HOW LONG AGO is
# unknown, and "cannot tell" is a red, never a pass.
raw_doc lapsenodate  open "{\"worker\":null,\"epoch\":3,\"previous_worker\":\"fable-tob\"}"
raw_doc lapsebadtime open "{\"worker\":null,\"epoch\":3,\"previous_worker\":\"fable-tob\",\"expired_at\":\"whenever\"}"
# open WITH a live claim.worker — a hand-flip, not a reap (a reap nulls worker).
raw_doc lapseworker  open "{\"worker\":\"fable-tob\",\"epoch\":3,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$EXP_RECENT\"}"
# THE VACUOUS-PASS HAZARD, hermetically. Release MERGES into the surviving claim
# — it stamps released_by/released_at and never previous_worker — so a task that
# was reaped, RE-CLAIMED, then voluntarily released still carries the old
# expired_at and reads as "just lapsed" unless released_at ≥ expired_at reds it.
# No such document exists on the live ledger, which is exactly why it is built
# here. Delete the ordering clause and this fixture goes green: that is the test.
raw_doc lapsereleased open "{\"worker\":null,\"epoch\":4,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$EXP_RECENT\",\"released_by\":\"fable-tob\",\"released_at\":\"$(iso_ago 300)\"}"
# ...and its mirror: a release that PREDATES the reap is stale residue on the
# claim, not a walk-away, so the ordering clause must compare the two stamps
# rather than merely notice that released_at exists. Without this pair, "reject
# any claim carrying released_at" would pass the suite and quietly red every
# task that had ever been released once.
raw_doc lapsereleasedold open "{\"worker\":null,\"epoch\":4,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$EXP_RECENT\",\"released_by\":\"fable-tob\",\"released_at\":\"$(iso_ago 1200)\"}"
# A FUTURE expired_at. `now - expired_at <= GRACE` is satisfied by any timestamp
# ahead of the clock, so without an explicit lower bound this fixture passes —
# a one-field document edit would buy an indefinite waiver. A reap cannot stamp
# a future expiry (the sweeper only reaps already-expired claims), so this is a
# document the gate cannot trust, and untrustworthy is red.
raw_doc lapsefuture open "{\"worker\":null,\"epoch\":3,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$(iso_ago -86400)\"}"
# ...and its boundary mirror: a few seconds of clock skew between the runner and
# the ledger is honest and must still pass, so the bound is -300s, not 0.
raw_doc lapseskew   open "{\"worker\":null,\"epoch\":3,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$(iso_ago -30)\"}"

# Boot a static server. It returns 200 for existing files, 404 else.
#
# The server ANNOUNCES ITS OWN PORT rather than being interrogated with lsof/ss.
# This harness now runs on every PR (it is the D26 fix), so a runner image
# without those tools would red the gate for a reason that has nothing to do
# with any PR — a false red inside the epic that exists to abolish them. The
# process that owns the socket is the one that knows the number; ask it.
# Inside $fixtures so the EXIT trap's `rm -rf` already cleans it up. It is not
# reachable at any path the gate requests (/v1/data/doc/...), so it cannot
# perturb a fixture.
portfile="$fixtures/static.port"
python3 - "$fixtures" "$portfile" >/dev/null 2>&1 <<'PY' &
import sys, functools
from http.server import HTTPServer, SimpleHTTPRequestHandler

srv = HTTPServer(("127.0.0.1", 0),
                 functools.partial(SimpleHTTPRequestHandler, directory=sys.argv[1]))
with open(sys.argv[2], "w") as f:
    f.write("%d\n" % srv.server_address[1])
srv.serve_forever()
PY
SRV_PID=$!
port=""
for _ in $(seq 1 100); do
  [ -s "$portfile" ] && port="$(tr -d ' \n' < "$portfile")" && [ -n "$port" ] && break
  sleep 0.1
done
if [ -z "$port" ]; then echo "TEST HARNESS FAIL: the fixture server never announced a port" >&2; exit 99; fi
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

# -- The lapsed-claim predicate (D23) -----------------------------------------
check "lapsed recently passes"       0 'TASK_ID=lapserecent'
check "lapsed long ago fails"        1 'TASK_ID=lapsestale'
check "open, never claimed, fails"   1 'TASK_ID=openone'
check "open, no previous_worker"     1 'TASK_ID=lapsenoprev'
check "lapsed, no expired_at, fails" 1 'TASK_ID=lapsenodate'
check "lapsed, bad expired_at, fails" 1 'TASK_ID=lapsebadtime'
check "open with live worker fails"  1 'TASK_ID=lapseworker'
check "released after reap fails"    1 'TASK_ID=lapsereleased'
check "future expired_at fails"      1 'TASK_ID=lapsefuture'
check "small clock skew still passes" 0 'TASK_ID=lapseskew'
check "released before reap passes"  0 'TASK_ID=lapsereleasedold'
# The grace is a knob, and it must move the verdict in BOTH directions --
# otherwise "env-overridable" is an untested claim about a variable nothing reads.
check "grace shrunk reds a lapse"    1 'TASK_ID=lapserecent LAPSE_GRACE_SECONDS=60'
check "grace widened greens a lapse" 0 'TASK_ID=lapsestale LAPSE_GRACE_SECONDS=999999999'
# The lapsed actor is previous_worker, so an author map (when one exists) must be
# compared against it rather than against the null worker.
check "lapsed actor matches worker"  0 'TASK_ID=lapserecent EXPECTED_WORKER=fable-tob'
check "lapsed actor wrong worker"    1 'TASK_ID=lapserecent EXPECTED_WORKER=nobody'

# -- Bounded retry, then FAIL (D24) -------------------------------------------
# A flaky ledger that 500s the first N requests per id and then answers. This is
# the only way to prove the retry is REAL (a blip is survived) and BOUNDED (a
# genuine outage still reds) rather than either a decoration or an infinite loop.
cat > "$fixtures/flaky.py" <<'PY'
import os
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, HTTPServer

FAILS = int(os.environ.get("FLAKY_FAILS", "2"))
seen = defaultdict(int)
DOC = (b'{"result":{"_id":"flaky","_type":"task","lifecycle_status":"in_progress",'
       b'"claim":{"worker":"fable-tob","epoch":1}}}')


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        seen[self.path] += 1
        # /task/perma500 never recovers; every other id recovers after FAILS.
        if "perma500" in self.path or seen[self.path] <= FAILS:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"upstream is having a day")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(DOC)))
        self.end_headers()
        self.wfile.write(DOC)

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
python3 "$fixtures/flaky.py" > "$fixtures/flaky.port" 2>/dev/null &
FLAKY_PID=$!
# Re-arm the trap so the flaky server is reaped too (same reason as SRV_PID).
trap 'kill "${SRV_PID:-0}" "${FLAKY_PID:-0}" 2>/dev/null; wait "${SRV_PID:-0}" "${FLAKY_PID:-0}" 2>/dev/null; rm -rf "$fixtures"' EXIT
flaky_port=""
for _ in $(seq 1 50); do
  flaky_port="$(head -1 "$fixtures/flaky.port" 2>/dev/null || true)"
  [ -n "$flaky_port" ] && break
  sleep 0.1
done
[ -n "$flaky_port" ] || { echo "TEST HARNESS FAIL: flaky server did not report a port" >&2; exit 99; }
FLAKY="http://127.0.0.1:$flaky_port"

check "two 500s then 200 passes"      0 "TASK_ID=blip1 LEDGER_BASE=$FLAKY PR_TASK_GATE_RETRIES=3"
check "one attempt does not retry"    2 "TASK_ID=blip2 LEDGER_BASE=$FLAKY PR_TASK_GATE_RETRIES=1"
check "permanent 500 is UNCHECKED"    2 "TASK_ID=perma500 LEDGER_BASE=$FLAKY PR_TASK_GATE_RETRIES=3"
check "unreachable host is UNCHECKED" 2 "TASK_ID=active LEDGER_BASE=http://127.0.0.1:1 PR_TASK_GATE_RETRIES=2"
# A 404 is an ANSWER, not an outage, so it must not be retried: with a 5s
# backoff and 3 attempts, a retried 404 could not finish inside 5s. Retrying an
# answer would only make the verdict a function of the wall clock.
t404=$SECONDS
( TASK_ID=ghost LEDGER_BASE="$BASE" PR_TASK_GATE_RETRIES=3 PR_TASK_GATE_RETRY_DELAY=5 bash "$GATE" ) >/dev/null 2>&1
rc404=$?; el404=$((SECONDS - t404))
if [ "$rc404" = 1 ] && [ "$el404" -lt 5 ]; then pass=$((pass+1)); printf 'ok   %-40s (exit 1, %ss)\n' "404 fails at once, never retried" "$el404"
else fail=$((fail+1)); printf 'FAIL %-40s want exit 1 under 5s, got %s in %ss\n' "404 fails at once, never retried" "$rc404" "$el404"; fi

# A retry count that is not a positive integer would make the bound test error
# out, which reads as FALSE and retries forever — a gate that hangs instead of
# deciding. Both knobs refuse bad input instead of guessing at one.
check "zero retries is refused"       1 "TASK_ID=active PR_TASK_GATE_RETRIES=0"
check "non-numeric retries refused"   1 "TASK_ID=active PR_TASK_GATE_RETRIES=lots"
check "non-numeric delay refused"     1 "TASK_ID=active PR_TASK_GATE_RETRY_DELAY=soon"

# The backoff is a real sleep between attempts, not a comment: 2 attempts at 1s
# apart cannot finish in under a second.
t0=$SECONDS
( LEDGER_BASE="http://127.0.0.1:1" TASK_ID=active PR_TASK_GATE_RETRIES=2 PR_TASK_GATE_RETRY_DELAY=1 bash "$GATE" ) >/dev/null 2>&1
elapsed=$((SECONDS - t0))
if [ "$elapsed" -ge 1 ]; then pass=$((pass+1)); printf 'ok   %-40s (%ss)\n' "retry backoff actually sleeps" "$elapsed"
else fail=$((fail+1)); printf 'FAIL %-40s want >=1s got %ss\n' "retry backoff actually sleeps" "$elapsed"; fi

# ── Trailer extraction ────────────────────────────────────────────────────────
# Turning a PR body into a task id is a SEPARATE contract from the ledger
# decision above, and it went untested for months because it lived inline in
# .github/workflows/pr-task-gate.yml, where no harness could run it. That is
# exactly how the backtick-wrapped form came to red a correctly-referenced PR
# (#5290 red / #5307 green, run 29804094521). It is now `pr-task-gate.sh
# --extract-task-id`, so these cases can reach it.
extract() { PR_BODY="$1" bash "$GATE" --extract-task-id; }
check_extract() { # check_extract <label> <pr_body> <expected_id>
  local label="$1" body="$2" want="$3" got
  got="$(extract "$body")"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %-40s (id %s)\n' "$label" "${got:-<empty>}"
  else fail=$((fail+1)); printf 'FAIL %-40s want %s got %s\n' "$label" "${want:-<empty>}" "${got:-<empty>}"; fi
}

check_extract "trailer: plain id"        $'Does a thing.\n\nTask: cch-bl-x\n'   'cch-bl-x'
check_extract "trailer: backticked id"   $'Does a thing.\n\nTask: `cch-bl-x`\n' 'cch-bl-x'
check_extract "trailer: backticked lower" $'task:   `cch-bl-x`\n'               'cch-bl-x'
check_extract "trailer: first match wins" $'Task: first-one\nTask: second-one\n' 'first-one'
check_extract "trailer: absent -> empty"  $'No trailer here at all.\n'          ''
check_extract "trailer: label with no id" $'Task:\ncch-bl-x\n'                  ''
check_extract "trailer: mid-sentence no"  $'Please see Task: cch-bl-x for why.\n' ''
check_extract "trailer: bold wrapper no"  $'**Task:** cch-bl-x\n'               ''

# End-to-end: the id a backticked trailer yields must be CLEAN, because it is
# pasted straight into the ledger URL. A leaked backtick makes the GET
# .../task/%60active%60, which the fixture server answers 404 → exit 1, so this
# case cannot go green on a dirty id.
backticked_id="$(extract 'Task: `active`')"
echo "extracted from 'Task: \`active\`' -> [${backticked_id}] ; ledger URL -> ${BASE}/v1/data/doc/production/task/${backticked_id}"
check "backticked trailer reaches ledger" 0 "TASK_ID='${backticked_id}'"
# ...and a body with NO trailer at all must still be a definitive FAIL: the
# empty id flows on and the gate rejects it. This is the RED that must survive.
check "no-trailer body still fails"      1 "TASK_ID='$(extract 'nothing to see here')'"

# -- The WORKFLOW STEP BODIES, under GitHub's real shell (D24, D25) -----------
# Everything above this line is script-scoped, and both defects this section
# exists for lived in the YAML, where no script-scoped fixture could reach them.
# GitHub runs every `run:` as `bash -e {0}`; the step bodies write
# `set -uo pipefail`, which adds -u and pipefail and does NOT clear that -e. So
# these cases execute the bodies EXACTLY as written, extracted from the workflow
# file itself, under `bash --noprofile --norc -e -o pipefail`. Point
# PR_TASK_GATE_WORKFLOW at an older copy of the workflow and they go red.
case "$WORKFLOW" in /*) WORKFLOW_ABS="$WORKFLOW" ;; *) WORKFLOW_ABS="$PWD/$WORKFLOW" ;; esac
step_body() { # step_body <step id> — print that step's `run:` block, dedented
  python3 - "$WORKFLOW_ABS" "$1" <<'PY'
import re, sys

path, want = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
i = 0
while i < len(lines) and not re.match(r"^\s*id:\s*%s\s*$" % re.escape(want), lines[i]):
    i += 1
if i == len(lines):
    sys.exit(3)  # no such step id — the harness must abort, not skip
run = None
for j in range(i, len(lines)):
    m = re.match(r"^(\s*)run: \|\s*$", lines[j])
    if m:
        run = (j, len(m.group(1)) + 2)
        break
    # A later step's `- name:` at list level means this step had no `run: |`.
    if j > i and re.match(r"^\s*- name:", lines[j]):
        sys.exit(4)
if run is None:
    sys.exit(4)
start, indent = run
out = []
for line in lines[start + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) < indent:
        break
    out.append(line[indent:] if len(line) >= indent else line)
if not any(l.strip() for l in out):
    sys.exit(5)  # an empty body would make every assertion below vacuous
print("\n".join(out))
PY
}
judge() { # judge <label> <want_exit> <got_exit> <want_substring|-> <outfile>
  local label="$1" want="$2" got="$3" sub="$4" out="$5"
  if [ "$got" != "$want" ]; then
    fail=$((fail+1)); printf 'FAIL %-40s want exit %s got %s\n' "$label" "$want" "$got"; return
  fi
  if [ "$sub" != "-" ] && ! grep -qF -- "$sub" "$out"; then
    fail=$((fail+1)); printf 'FAIL %-40s exit %s ok, but output lacks %s\n' "$label" "$got" "$sub"; return
  fi
  pass=$((pass+1)); printf 'ok   %-40s (exit %s)\n' "$label" "$got"
}

# Extraction itself must be able to fail loudly: a typo'd step id has to abort
# the harness, never silently run an empty body and report green.
if step_body no-such-step-id >/dev/null 2>&1; then
  fail=$((fail+1)); printf 'FAIL %-40s extractor accepted a nonexistent step id\n' "step extractor is falsifiable"
else
  pass=$((pass+1)); printf 'ok   %-40s (aborts on an unknown step id)\n' "step extractor is falsifiable"
fi
for _s in verify cutoff; do
  if ! step_body "$_s" > "$fixtures/body.$_s" 2>/dev/null; then
    echo "TEST HARNESS FAIL: cannot extract step '$_s' from $WORKFLOW" >&2; exit 99
  fi
done

run_step() { # run_step <id> — the body verbatim, under GitHub's shell
  bash --noprofile --norc -e -o pipefail "$fixtures/body.$1"
}

# -- verify step: exit 2 must REACH the handler and become an honest red -------
so="$fixtures/verify.out"
: > "$so"
( GITHUB_STEP_SUMMARY="$fixtures/verify.summary" TASK_ID=active \
  LEDGER_BASE="http://127.0.0.1:1" PR_TASK_GATE_RETRIES=1 \
  run_step verify ) > "$so" 2>&1
judge "step verify: outage reds honestly" 1 $? "task backing UNVERIFIED" "$so"

: > "$so"
( GITHUB_STEP_SUMMARY="$fixtures/verify.summary" TASK_ID=active LEDGER_BASE="$BASE" \
  run_step verify ) > "$so" 2>&1
judge "step verify: backed PR passes" 0 $? "PASS" "$so"

: > "$so"
( GITHUB_STEP_SUMMARY="$fixtures/verify.summary" TASK_ID=openone LEDGER_BASE="$BASE" \
  run_step verify ) > "$so" 2>&1
judge "step verify: violation still reds" 1 $? "FAIL" "$so"

# -- cutoff step: three states, and UNKNOWN is not "old" ----------------------
# A hermetic repo with one pre-gate commit and one post-gate commit, so the
# grandfather can be exercised for real instead of asserted about.
gitrepo="$fixtures/basegit"
mkdir -p "$gitrepo"
(
  cd "$gitrepo" || exit 99
  git init -q -b main .
  git config user.email harness@example.invalid
  git config user.name "pr-task-gate harness"
  echo pre > README.md
  git add README.md
  git commit -qm "pre-gate"
  git rev-parse HEAD > "$gitrepo/.sha-pre"
  mkdir -p .github/workflows
  echo "name: pr-task-gate" > .github/workflows/pr-task-gate.yml
  git add .github/workflows/pr-task-gate.yml
  git commit -qm "the gate lands"
  git rev-parse HEAD > "$gitrepo/.sha-post"
) >/dev/null 2>&1 || { echo "TEST HARNESS FAIL: could not build the hermetic base repo" >&2; exit 99; }
SHA_PRE="$(cat "$gitrepo/.sha-pre")"
SHA_POST="$(cat "$gitrepo/.sha-post")"

cutoff_case() { # cutoff_case <label> <base_sha> <want_exit> <want_in_GITHUB_OUTPUT|-> [want_absent]
  local label="$1" sha="$2" want="$3" wantout="$4" absent="${5:-}" got
  local go="$fixtures/cutoff.output" ss="$fixtures/cutoff.summary" so="$fixtures/cutoff.out"
  : > "$go"; : > "$ss"; : > "$so"
  ( cd "$gitrepo" && GITHUB_OUTPUT="$go" GITHUB_STEP_SUMMARY="$ss" BASE_SHA="$sha" \
    bash --noprofile --norc -e -o pipefail "$fixtures/body.cutoff" ) > "$so" 2>&1
  got=$?
  cat "$ss" >> "$so"
  if [ "$got" != "$want" ]; then
    fail=$((fail+1)); printf 'FAIL %-40s want exit %s got %s\n' "$label" "$want" "$got"; return
  fi
  if [ "$wantout" != "-" ] && ! grep -qF -- "$wantout" "$go"; then
    fail=$((fail+1)); printf 'FAIL %-40s GITHUB_OUTPUT lacks %s (got: %s)\n' "$label" "$wantout" "$(tr '\n' ' ' < "$go")"; return
  fi
  if [ -n "$absent" ] && grep -qF -- "$absent" "$go"; then
    fail=$((fail+1)); printf 'FAIL %-40s GITHUB_OUTPUT contains %s and must not\n' "$label" "$absent"; return
  fi
  pass=$((pass+1)); printf 'ok   %-40s (exit %s)\n' "$label" "$got"
}

cutoff_case "step cutoff: post-gate enforces"  "$SHA_POST" 0 "enforced=1"
cutoff_case "step cutoff: pre-gate grandfathers" "$SHA_PRE" 0 "enforced=0"
# The defect: an unresolvable base used to take the grandfather branch, which
# skipped every downstream step and reported SUCCESS having checked nothing.
# UNKNOWN must be a loud red, and must never write enforced= at all.
cutoff_case "step cutoff: unknown base reds" "0000000000000000000000000000000000000000" 1 "-" "enforced="
cutoff_case "step cutoff: garbage base reds" "not-a-sha-at-all" 1 "-" "enforced="

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
