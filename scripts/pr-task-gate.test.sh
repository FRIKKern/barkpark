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
# THE TWO 200-WITHOUT-A-DOCUMENT SHAPES (D59). Both are well-formed JSON that
# answers without answering: a null `result`, and a bare document served with no
# envelope at all (what `?filterresponse=false` emits). Neither is evidence that
# the task does not exist — a task that genuinely does not exist answers 404,
# which `ghost` above pins as a definitive red — so both must read UNCHECKED.
printf '{"result":null}' > "$fixtures/v1/data/doc/production/task/nullresult"
printf '{"_id":"baredoc","_type":"task","lifecycle_status":"in_progress","claim":{"worker":"fable-tob"}}' \
  > "$fixtures/v1/data/doc/production/task/baredoc"

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
EXP_RECENT="$(iso_ago 600)"       # claim lapsed 10 min ago
EXP_STALE="$(iso_ago 604800)"     # claim lapsed 7 days ago
# The PR's own created_at, which is what the lease is now measured against
# (D58): a lapsed claim backs the PR iff expired_at >= PR_OPENED_AT. PR_OPEN is
# the default for the lapse checks below — a PR opened 15 min ago, i.e. BEFORE
# EXP_RECENT lapsed and long after EXP_STALE did, so the same pair of documents
# now separates on when the PR opened instead of on how long the gate took to
# run. Nothing here reads the wall clock at verdict time.
PR_OPEN="$(iso_ago 900)"          # PR opened 15 min ago
PR_OPEN_LATE="$(iso_ago 60)"      # PR opened 1 min ago — AFTER EXP_RECENT lapsed
PR_OPEN_ANCIENT="$(iso_ago 1209600)" # PR opened 14 days ago — before EXP_STALE lapsed
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
# THE BOUNDARY of the new predicate: expired_at EXACTLY equal to the PR's
# created_at. The claim was live up to that instant, so `>=` passes it and a `>`
# would red it — a one-character slip that no other fixture can see.
EXP_EXACT="$(iso_ago 1800)"
raw_doc lapseexact open "{\"worker\":null,\"epoch\":3,\"previous_worker\":\"fable-tob\",\"expired_at\":\"$EXP_EXACT\"}"

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

# Hermeticity: the token-matrix rows below distinguish token-PRESENT from
# token-ABSENT, and check()'s subshell INHERITS the caller's environment — a
# developer running this harness with LEDGER_TOKEN exported (say, after poking
# the gate by hand) would red every token-absent row for a reason that has
# nothing to do with the gate. CI never sets it on the self-test step; make the
# local run match.
unset LEDGER_TOKEN

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

# An exit code alone cannot tell a refusal apart from the clause standing next
# to it: with PR_OPENED_AT withheld, both the refusal and the "could not
# compare" clause exit 1, so deleting the refusal leaves the suite green while
# the PR is handed a message about a comparison instead of about the input that
# is missing. Where the WORDS are the deliverable, assert the words.
check_says() { # check_says <label> <expected_exit> <substring> <env...>
  local label="$1" want="$2" sub="$3"; shift 3
  local out="$fixtures/says.out" got
  ( eval "LEDGER_BASE=\"$BASE\" $* bash \"$GATE\"" ) > "$out" 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    fail=$((fail+1)); printf 'FAIL %-40s want exit %s got %s\n' "$label" "$want" "$got"; return
  fi
  if ! grep -qF -- "$sub" "$out"; then
    fail=$((fail+1)); printf 'FAIL %-40s exit %s ok, but output lacks %s\n' "$label" "$got" "$sub"; return
  fi
  pass=$((pass+1)); printf 'ok   %-40s (exit %s, says it)\n' "$label" "$got"
}

check "active task passes"          0 'TASK_ID=active'
check "open task fails"             1 'TASK_ID=openone'
check "in_progress but unclaimed"   1 'TASK_ID=claimless'
check "nonexistent task fails"      1 'TASK_ID=ghost LEDGER_TOKEN=harness-token'
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

# -- The lapsed-claim predicate (D23), now PR-relative: P4 (D58) --------------
# Every check in this block supplies PR_OPENED_AT, because that is what the
# workflow supplies; the refusal fixtures below are the ones that withhold it.
check "claim live at PR open passes"  0 "TASK_ID=lapserecent PR_OPENED_AT=$PR_OPEN"
check "claim dead at PR open fails"   1 "TASK_ID=lapsestale PR_OPENED_AT=$PR_OPEN"
check "expired_at == PR open passes"  0 "TASK_ID=lapseexact PR_OPENED_AT=$EXP_EXACT"
check "open, never claimed, fails"   1 "TASK_ID=openone PR_OPENED_AT=$PR_OPEN"
check "open, no previous_worker"     1 "TASK_ID=lapsenoprev PR_OPENED_AT=$PR_OPEN"
check "lapsed, no expired_at, fails" 1 "TASK_ID=lapsenodate PR_OPENED_AT=$PR_OPEN"
check "lapsed, bad expired_at, fails" 1 "TASK_ID=lapsebadtime PR_OPENED_AT=$PR_OPEN"
check "open with live worker fails"  1 "TASK_ID=lapseworker PR_OPENED_AT=$PR_OPEN"
check "released after reap fails"    1 "TASK_ID=lapsereleased PR_OPENED_AT=$PR_OPEN"
check "future expired_at fails"      1 "TASK_ID=lapsefuture PR_OPENED_AT=$PR_OPEN"
check "small clock skew still passes" 0 "TASK_ID=lapseskew PR_OPENED_AT=$PR_OPEN"
check "released before reap passes"  0 "TASK_ID=lapsereleasedold PR_OPENED_AT=$PR_OPEN"
# The predicate must move the verdict in BOTH directions on the SAME document,
# and the only thing that moves is when the PR opened -- which is exactly the
# claim P4 makes. These replace the two grace-tuning cases: the old knob was a
# number the gate had to be right about, and it is gone.
check "PR opened after the lapse reds" 1 "TASK_ID=lapserecent PR_OPENED_AT=$PR_OPEN_LATE"
check "PR opened before the lapse greens" 0 "TASK_ID=lapsestale PR_OPENED_AT=$PR_OPEN_ANCIENT"
# ...and it must REFUSE rather than fall open when it cannot read the PR's open
# time. Withholding PR_OPENED_AT on a document that otherwise passes is the whole
# test: if either of these greens, a workflow that ever drops the env line goes
# silently permissive on every lapsed claim.
check_says "no PR_OPENED_AT refuses"  1 "PR_OPENED_AT was not supplied" 'TASK_ID=lapserecent'
check_says "empty PR_OPENED_AT refuses" 1 "PR_OPENED_AT was not supplied" 'TASK_ID=lapserecent PR_OPENED_AT=""'
check_says "unparseable PR_OPENED_AT refuses" 1 "is not a readable ISO-8601 timestamp" 'TASK_ID=lapserecent PR_OPENED_AT=whenever'
# The red a lapsed-before-open PR actually receives must name the lapse, not the
# grace that no longer exists.
check_says "dead-at-open red names the lapse" 1 "had ALREADY lapsed" "TASK_ID=lapsestale PR_OPENED_AT=$PR_OPEN"
# ...but only on the branch that needs it: in_progress and done are decided from
# the document alone, so withholding it there must NOT red a readable PR.
check "in_progress needs no PR_OPENED_AT" 0 'TASK_ID=active'
check "done needs no PR_OPENED_AT"        0 'TASK_ID=doneclosed'
# The lapsed actor is previous_worker, so an author map (when one exists) must be
# compared against it rather than against the null worker.
check "lapsed actor matches worker"  0 "TASK_ID=lapserecent PR_OPENED_AT=$PR_OPEN EXPECTED_WORKER=fable-tob"
check "lapsed actor wrong worker"    1 "TASK_ID=lapserecent PR_OPENED_AT=$PR_OPEN EXPECTED_WORKER=nobody"

# -- THE RED MUST CARRY THE WHOLE CURE, not a third of it ---------------------
# Wave 24: six PRs green on every code gate sat red for hours on this one
# required context. The message named the violation and handed over `bp task
# claim` — and stopped there, one step short of landing anything. Re-claiming
# does NOT re-fire this check (a ledger write is not a pull_request event), and
# releasing the claim afterwards trips the ordering clause FOREVER (release
# merges released_at into the surviving claim and never touches expired_at). An
# exit code cannot see any of that: all three renderings exit 1 either way, so
# these assert the WORDS. Delete any one clause from CURE and exactly the cases
# below go red.
# REVIEW ADDITION: the cure is owed by every refusal a re-claim actually fixes,
# not just the two the brief named. All six 'open'/in_progress claim refusals
# below land a reader in the same place — the ledger is wrong, a fresh claim is
# the fix, and the check will not re-evaluate on its own. Leaving four of them
# carrying only `bp task claim` reproduced the exact wave-24 stall on a narrower
# input: the reader does the claim, watches the red sit, and gives up. The
# RELEASED refusal is the sharpest of the four — it is the terminal state the
# other messages warn about, so it is the one message a reader most needs the
# re-fire clause on.
for _who in "lapsed-before-open:1:TASK_ID=lapsestale PR_OPENED_AT=$PR_OPEN" \
            "open-with-live-worker:1:TASK_ID=lapseworker PR_OPENED_AT=$PR_OPEN" \
            "never-claimed:1:TASK_ID=openone PR_OPENED_AT=$PR_OPEN" \
            "no-previous-worker:1:TASK_ID=lapsenoprev PR_OPENED_AT=$PR_OPEN" \
            "no-readable-expiry:1:TASK_ID=lapsenodate PR_OPENED_AT=$PR_OPEN" \
            "unreadable-expiry:1:TASK_ID=lapsebadtime PR_OPENED_AT=$PR_OPEN" \
            "future-expiry:1:TASK_ID=lapsefuture PR_OPENED_AT=$PR_OPEN" \
            "released-claim:1:TASK_ID=lapsereleased PR_OPENED_AT=$PR_OPEN" \
            "in-progress-no-worker:1:TASK_ID=claimless"; do
  _label="${_who%%:*}"; _rest="${_who#*:}"; _want="${_rest%%:*}"; _env="${_rest#*:}"
  check_says "$_label red gives the claim cmd" "$_want" "bp task claim " "$_env"
  check_says "$_label red says re-fire"        "$_want" "gh run rerun "  "$_env"
  check_says "$_label red warns on release"    "$_want" "NO re-fire can clear" "$_env"
done

# The run id is INTERPOLATED when Actions supplies one, and degrades to a
# readable literal when it does not. Both renderings are asserted because the
# failure modes are opposite: a hardcoded placeholder in CI hands the reader a
# command they must then go hunt the id for (and the check-runs API paginates at
# 30, which is how a 36-check sha reported "no such run"), while a bare
# `gh run rerun  --failed` outside CI reads as a broken command.
check_says "re-fire interpolates the real run id" 1 "gh run rerun 29999999999 --failed" \
  "TASK_ID=lapsestale PR_OPENED_AT=$PR_OPEN GITHUB_RUN_ID=29999999999"
check_says "re-fire degrades outside Actions"     1 "gh run rerun <this run id> --failed" \
  "TASK_ID=lapsestale PR_OPENED_AT=$PR_OPEN GITHUB_RUN_ID="

# The refusal CITES the ordering clause by line number, which is the one part of
# the message that rots silently: an edit above it shifts the clause and the
# reader is sent to whatever now sits on that line. So read the citation back
# OUT of the gate's own output and check what is actually there.
: > "$fixtures/says.out"
( TASK_ID=lapsestale PR_OPENED_AT="$PR_OPEN" LEDGER_BASE="$BASE" bash "$GATE" ) \
  > "$fixtures/says.out" 2>&1
cited_rc=$?
# CAPTURE THE RC (above) BEFORE reading the output. Without it a gate that
# CRASHES — syntax error, bad interpreter, an unset-var abort — is
# indistinguishable here from one that refuses correctly: neither prints a
# citation, so the assertion reported `cited line <none> reads: <nothing>` while
# the gate's real error sat unread in says.out. `lapsestale` is a definitive
# red, so exit 1 is the ONLY status that means "the gate ran and refused"
# (2 is UNCHECKED, anything else is a broken run) — and on any other status the
# harness must SHOW what the gate actually said instead of an empty citation.
if [ "$cited_rc" != "1" ]; then
  fail=$((fail+1))
  printf 'FAIL %-40s gate exited %s (want 1 — refusal); its output was:\n' \
    "cited ordering-clause line is real" "$cited_rc"
  tail -20 "$fixtures/says.out" | sed -e 's/^/       | /'
else
  cited_line="$(grep -oE 'pr-task-gate\.sh:[0-9]+' "$fixtures/says.out" | head -1)"
  cited_line="${cited_line##*:}"
  cited_src="$([ -n "$cited_line" ] && awk -v n="$cited_line" 'NR==n' "$GATE")"
  if [ -n "$cited_line" ] && printf '%s' "$cited_src" | grep -q 'released_ge_expired'; then
    pass=$((pass+1)); printf 'ok   %-40s (line %s is the ordering clause)\n' "cited ordering-clause line is real" "$cited_line"
  else
    fail=$((fail+1)); printf 'FAIL %-40s cited line %s reads: %s\n' "cited ordering-clause line is real" "${cited_line:-<none>}" "${cited_src:-<nothing>}"
  fi
fi

# -- A 200 that carries no document is UNCHECKED, never an accusation (D59) ---
# Both shapes used to print "task does not exist on the ledger" at a PR whose
# task is fine. A genuine nonexistent task answers 404 and stays a definitive
# red (`ghost`, above and below), so this reroute loses zero true detection.
check_says "200 with result:null is UNCHECKED" 2 "carried no task document" 'TASK_ID=nullresult'
check_says "200 with a bare doc is UNCHECKED"  2 "carried no task document" 'TASK_ID=baredoc'
# ...and the 404 keeps the accusation WHEN WE READ AS OURSELVES, because there it
# is TRUE: an authenticated read that gets 404 means the task really is not there.
# Assert the words: an exit code alone cannot tell "does not exist" from "could
# not check", and printing the wrong one of those at a reader is the whole defect.
# (Token PRESENT is load-bearing here — a token-ABSENT 404 is UNCHECKED now; see
# the token-matrix section below.)
check_says "404 still accuses definitively"    1 "does not exist on the ledger" 'TASK_ID=ghost LEDGER_TOKEN=harness-token'

# -- Authenticated ledger read: the private-flip token matrix (wave 3) ---------
# fetch_doc sends `Authorization: Bearer $LEDGER_TOKEN` ONLY when the token is
# non-empty, so a future flip of tasks to private cannot make main unmergeable:
# authenticated reads still see the task. The three states that matter:
#   token PRESENT + 404 → the task genuinely is not there → definitive FAIL (1).
#   token ABSENT  + 404 → cannot tell missing from private → UNCHECKED (2), and
#                         the message must NAME the secret so a reader knows the
#                         fix is provisioning, not editing their PR.
#   token PRESENT + 2xx → the happy path is unbroken; the auth header does not
#                         perturb a task that reads fine.
# MUTATION PROOF (recorded here so the guard is falsifiable): delete the `-H
# Authorization` construction / the token-absent arm of the 404 case in
# scripts/pr-task-gate.sh and the "token absent, 404 is UNCHECKED" row below
# reds (a token-absent ghost reverts to the exit-1 accusation) — the row is not
# satisfiable by the pre-change gate.
check_says "token present, 404 accuses"        1 "does not exist on the ledger" 'TASK_ID=ghost LEDGER_TOKEN=harness-token'
check_says "token absent, 404 is UNCHECKED"    2 "BARKPARK_TASK_TOKEN"          'TASK_ID=ghost'
check      "token present, happy path passes"  0 'TASK_ID=active LEDGER_TOKEN=harness-token'

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
# A 404 is an ANSWER, not an outage, so it must not be retried — and this holds
# on the NEW token-absent branch too, which reroutes a 404 to UNCHECKED (exit 2):
# with a 5s backoff and 3 attempts, a retried 404 could not finish inside 5s.
# Retrying an answer would only make the verdict a function of the wall clock. No
# LEDGER_TOKEN, so ghost's 404 takes the exit-2 arm; it must still fail FAST.
t404=$SECONDS
( TASK_ID=ghost LEDGER_BASE="$BASE" PR_TASK_GATE_RETRIES=3 PR_TASK_GATE_RETRY_DELAY=5 bash "$GATE" ) >/dev/null 2>&1
rc404=$?; el404=$((SECONDS - t404))
if [ "$rc404" = 2 ] && [ "$el404" -lt 5 ]; then pass=$((pass+1)); printf 'ok   %-40s (exit 2, %ss)\n' "token-absent 404 fails fast, never retried" "$el404"
else fail=$((fail+1)); printf 'FAIL %-40s want exit 2 under 5s, got %s in %ss\n' "token-absent 404 fails fast, never retried" "$rc404" "$el404"; fi

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
for _s in verify cutoff hotfix hotfix_record; do
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

cutoff_case() { # cutoff_case <label> <base_sha> <want_exit> <want_in_GITHUB_OUTPUT|-> [want_absent] [want_in_stdout] [repo]
  local label="$1" sha="$2" want="$3" wantout="$4" absent="${5:-}" saysub="${6:-}" repo="${7:-$gitrepo}" got
  local go="$fixtures/cutoff.output" ss="$fixtures/cutoff.summary" so="$fixtures/cutoff.out"
  : > "$go"; : > "$ss"; : > "$so"
  ( cd "$repo" && GITHUB_OUTPUT="$go" GITHUB_STEP_SUMMARY="$ss" BASE_SHA="$sha" \
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
  # What the step SAYS is part of the contract, not decoration: a grandfathered
  # run is a green that verified nothing, and the only channel that reaches the
  # check-run API is an annotation. Asserted on stdout+summary.
  if [ -n "$saysub" ] && ! grep -qF -- "$saysub" "$so"; then
    fail=$((fail+1)); printf 'FAIL %-40s output lacks %s (got: %s)\n' "$label" "$saysub" "$(tr '\n' ' ' < "$so")"; return
  fi
  pass=$((pass+1)); printf 'ok   %-40s (exit %s)\n' "$label" "$got"
}

# -- the verify step must PLUMB the PR open time -------------------------------
# The step bodies above run with an env this harness supplies, so they cannot
# see the YAML `env:` block at all: delete `PR_OPENED_AT` from the workflow and
# every fixture in this file still passes, while in production every lapsed
# claim would hit the refusal and red. The env line is checked as text, in the
# same file the step bodies are extracted from, for exactly that reason.
if grep -qE '^\s*PR_OPENED_AT:\s*\$\{\{\s*github\.event\.pull_request\.created_at\s*\}\}\s*$' "$WORKFLOW_ABS"; then
  pass=$((pass+1)); printf 'ok   %-40s (workflow passes created_at)\n' "verify step plumbs PR_OPENED_AT"
else
  fail=$((fail+1)); printf 'FAIL %-40s %s has no PR_OPENED_AT: ${{ github.event.pull_request.created_at }} line\n' "verify step plumbs PR_OPENED_AT" "$WORKFLOW"
fi

cutoff_case "step cutoff: post-gate enforces"  "$SHA_POST" 0 "enforced=1"
# REWRITTEN (wave 56 S4). This line used to read
#   cutoff_case "step cutoff: pre-gate grandfathers" "$SHA_PRE" 0 "enforced=0"
# and that expectation was WRONG — not about the exit code, about what the exit
# code was allowed to mean. `enforced=0` makes every downstream step skip
# (`if: enforced == '1'`), so this required context concluded SUCCESS having
# verified no task at all, and on the check-run API that green is byte-identical
# to one where a live claim was proven. The old assertion PINNED that silence as
# correct: a run that said nothing passed, and so would a gate that had been
# quietly disarmed. Grandfathering is still legitimate and still exits 0 — what
# is no longer optional is SAYING SO on the channel that reaches the check run,
# the same `nothing ran` disclosure the other three required contexts emit.
cutoff_case "step cutoff: pre-gate grandfathers, and SAYS SO" "$SHA_PRE" 0 "enforced=0" "" \
  "::notice title=PR task gate: green — nothing evaluated::"
# The defect: an unresolvable base used to take the grandfather branch, which
# skipped every downstream step and reported SUCCESS having checked nothing.
# UNKNOWN must be a loud red, and must never write enforced= at all.
cutoff_case "step cutoff: unknown base reds" "0000000000000000000000000000000000000000" 1 "-" "enforced="
cutoff_case "step cutoff: garbage base reds" "not-a-sha-at-all" 1 "-" "enforced="

# -- the rename tripwire: the cutoff must not outlive the file it tests for ----
# The predicate is a hard-coded literal path to the workflow's OWN file. Move or
# rename that file and the literal goes stale in silence: every open PR's base
# lacks the path, so `enforced=0` FLEET-WIDE and the required context goes green
# on every PR while checking nothing — and the PR performing the rename passes
# too, because at ITS base the old path still exists. One rename, a disarmed
# required gate, no red anywhere.
# So the checkout is now self-checked: absent at HEAD = the cutoff cannot be
# believed = FAIL CLOSED. This fixture is the guard's losing case — it hands the
# step a base that DOES contain the gate (the enforcing path, i.e. the case that
# would otherwise sail through) inside a checkout where the file has been
# renamed away, and demands a red that names the reason.
renamedrepo="$fixtures/basegit-renamed"
cp -R "$gitrepo" "$renamedrepo" 2>/dev/null || { echo "TEST HARNESS FAIL: could not copy the hermetic base repo" >&2; exit 99; }
(
  cd "$renamedrepo" || exit 99
  git mv .github/workflows/pr-task-gate.yml .github/workflows/pr-task-gate-renamed.yml
  git commit -qm "rename the gate out from under its own predicate"
) >/dev/null 2>&1 || { echo "TEST HARNESS FAIL: could not build the renamed-gate repo" >&2; exit 99; }
cutoff_case "step cutoff: renamed gate fails closed" "$SHA_POST" 1 "-" "enforced=" \
  "cannot trust its own cutoff" "$renamedrepo"

# -- hotfix step: the emergency exit must engage regardless of LABEL ORDER -----
# Until this block existed, `for _s in verify cutoff` extracted exactly two step
# ids, so NO fixture could execute the hotfix step body. Measured consequence:
# replacing the detector line with `if true; then` — routing every PR through the
# bypass, i.e. disabling the task gate repo-wide — left this file at 73 passed /
# 0 failed. A kill mutant that a suite cannot see is a suite that is not watching
# that code at all, which is why this is not a one-line fix.
#
# The defect these four cases pin: `.pull_request.labels[]?.name == "hotfix!"` is
# a GENERATOR, one boolean per label, and `jq -e` takes its exit status from the
# LAST one. Against the pre-fix line, hotfix-first and hotfix-middle both report
# hotfix=0 — the lane silently does not engage the moment a human adds a second
# label to an urgent PR. Point PR_TASK_GATE_WORKFLOW at a pre-fix copy of the
# workflow and exactly those two go red.
hotfix_case() { # hotfix_case <label> <labels-json-array> <want hotfix=N>
  local label="$1" labels="$2" want="$3" got
  local ev="$fixtures/hotfix.event.json" go="$fixtures/hotfix.output" so="$fixtures/hotfix.out"
  printf '{"pull_request":{"number":1,"labels":%s}}' "$labels" > "$ev"
  : > "$go"; : > "$so"
  ( GITHUB_EVENT_PATH="$ev" GITHUB_OUTPUT="$go" \
    bash --noprofile --norc -e -o pipefail "$fixtures/body.hotfix" ) > "$so" 2>&1
  got=$?
  if [ "$got" != "0" ]; then
    fail=$((fail+1)); printf 'FAIL %-40s step exited %s (must always decide, never abort)\n' "$label" "$got"; return
  fi
  if ! grep -qFx -- "$want" "$go"; then
    fail=$((fail+1)); printf 'FAIL %-40s GITHUB_OUTPUT wants %s (got: %s)\n' "$label" "$want" "$(tr '\n' ' ' < "$go")"; return
  fi
  pass=$((pass+1)); printf 'ok   %-40s (%s)\n' "$label" "$want"
}

hotfix_case "step hotfix: label first engages"  '[{"name":"hotfix!"},{"name":"bug"}]' "hotfix=1"
hotfix_case "step hotfix: label last engages"   '[{"name":"bug"},{"name":"hotfix!"}]' "hotfix=1"
hotfix_case "step hotfix: label middle engages" '[{"name":"bug"},{"name":"hotfix!"},{"name":"docs"}]' "hotfix=1"
hotfix_case "step hotfix: no label, no lane"    '[{"name":"bug"}]' "hotfix=0"
hotfix_case "step hotfix: no labels at all"     '[]' "hotfix=0"

# -- hotfix record: an UNWRITTEN override record is the job's failure ----------
# The lane's whole justification is that the exception SATISFIES the invariant —
# a task exists for the change. The record step used to warn and `exit 0` on a
# missing token or a non-200 ledger, and every step below it carries
# `if: hotfix != '1'`, so once the lane engaged the job reported SUCCESS no
# matter what was written: a silent, unattributable waiver of a required check.
# A POST-accepting stub stands in for the ledger so the SUCCESS path is exercised
# too — a pair of red cases alone would be satisfied by a step that always reds.
recport="$fixtures/rec.port"
python3 - "$recport" >/dev/null 2>&1 <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.end_headers(); self.wfile.write(b'{"results":[]}')
    def log_message(self, *a): pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write("%d\n" % srv.server_address[1])
srv.serve_forever()
PY
REC_PID=$!
trap 'kill "${SRV_PID:-0}" "${FLAKY_PID:-0}" "${REC_PID:-0}" 2>/dev/null; wait "${SRV_PID:-0}" "${FLAKY_PID:-0}" "${REC_PID:-0}" 2>/dev/null; rm -rf "$fixtures"' EXIT
rec_port=""
for _ in $(seq 1 100); do
  [ -s "$recport" ] && rec_port="$(tr -d ' \n' < "$recport")" && [ -n "$rec_port" ] && break
  sleep 0.1
done
[ -n "$rec_port" ] || { echo "TEST HARNESS FAIL: the record stub never announced a port" >&2; exit 99; }
REC_BASE="http://127.0.0.1:$rec_port"

record_case() { # record_case <label> <token> <ledger base> <want exit> <want substring>
  local label="$1" tok="$2" base="$3" want="$4" sub="$5" got
  local so="$fixtures/record.out" ss="$fixtures/record.summary"
  : > "$so"; : > "$ss"
  ( GITHUB_STEP_SUMMARY="$ss" LEDGER_BASE="$base" TASK_TOKEN="$tok" \
    PR_NUMBER=4242 PR_TITLE="urgent: the roof is on fire" \
    PR_URL="https://github.com/example/repo/pull/4242" \
    bash --noprofile --norc -e -o pipefail "$fixtures/body.hotfix_record" ) > "$so" 2>&1
  got=$?
  judge "$label" "$want" "$got" "$sub" "$so"
}

record_case "hotfix record: no token REDS"   ""    "$REC_BASE"        1 "::error title=Hotfix override not recorded::"
record_case "hotfix record: dead ledger REDS" "tok" "http://127.0.0.1:1" 1 "::error title=Hotfix override not recorded::"
record_case "hotfix record: filed passes"    "tok" "$REC_BASE"        0 "::notice title=Hotfix lane::"

# -- THE ESCAPE-LANE CENSUS, BIDIRECTIONAL ------------------------------------
# THE DEFECT THIS EXISTS FOR: this workflow's exit-2 ::error told a blocked
# human "if it stays down, the hotfix! lane is the documented override", and
# merge-gates.md said in two places that without BARKPARK_TASK_TOKEN "the lane
# still passes". The token is unprovisioned and the `hotfix!` label DOES exist,
# so following that advice engaged a lane whose only surviving step exits 1 —
# a required context turned into a guaranteed red, at 2am, by the gate's own
# instructions. Prose and behaviour disagreed and nothing could notice.
#
# THE LAW, in both directions:
#   the lane REFUSES  =>  no surface may promise it as an escape (zero hits)
#   the lane PASSES   =>  some surface must document the escape (>= one hit)
# Side A is a PROCESS EXIT CODE (this workflow's own hotfix_record body, run
# verbatim). Side B is TEXT IN A DIFFERENT FILE. Neither can satisfy the other
# by construction, so this is not a tautology.
#
# HONEST LIMIT OF SIDE B — READ THIS BEFORE TRUSTING IT. The scan is a fixed,
# hand-maintained vocabulary of the KNOWN promissory phrasings ("still passes",
# "documented override", "the lane passes"). It catches DRIFT-BACK of those
# exact claims anywhere in the scanned surfaces; it is NOT a complete census of
# escape promises, and a freshly-worded promise ("the label waives the check")
# would pass it unseen. Widen PROMISES when you meet a new phrasing. What the
# guard does guarantee is that the three sentences this slice deleted cannot
# quietly return.
#
# SENTENCE-SCOPED, NOT LINE-SCOPED. merge-gates.md soft-wraps prose, so
# origin/main's promise reads "the lane still\npasses" and a line-scoped grep
# found 1 of the 3 promises — a vacuously partial green. The fixtures below pin
# that difference with the pre-fix bytes themselves, and with a promise wrapped
# across FOUR lines.
promise_count() { # promise_count <line|sentence> <file>... -> hit count
  python3 - "$@" <<'PY'
import re, sys
mode, paths = sys.argv[1], sys.argv[2:]
# The hand-maintained vocabulary. See the honest-limit note above.
PROMISES = [
    r"still\s+passes",
    r"documented\s+override",
    r"lane\s+(?:still\s+)?passes",
]
hits = 0
for p in paths:
    text = open(p, encoding="utf-8").read()
    if mode == "line":
        units = text.splitlines()
    else:
        # Rejoin every wrapped line into one flat stream, then cut it into
        # sentence-ish windows. A promise split across any number of lines
        # lands inside exactly one window.
        units = re.split(r"(?<=[.;:])\s", re.sub(r"\s+", " ", text))
    for u in units:
        if any(re.search(r, u, re.I) for r in PROMISES):
            hits += 1
print(hits)
PY
}

# SIDE A — BEHAVIOUR. Run the workflow's own hotfix_record body with NO token
# against a HEALTHY ledger stub. Healthy is deliberate: if a refactor ever moves
# the token check below the curl, this case must red rather than quietly measure
# an outage at the same exit 1. Hence the assertion is on the emitted ::error
# TITLE and on the missing-secret wording, never on the bare RC.
lane_out="$fixtures/census.laneA.out"
: > "$lane_out"
( GITHUB_STEP_SUMMARY="$fixtures/census.laneA.summary" LEDGER_BASE="$REC_BASE" TASK_TOKEN="" \
  PR_NUMBER=4242 PR_TITLE="urgent: the roof is on fire" \
  PR_URL="https://github.com/example/repo/pull/4242" \
  bash --noprofile --norc -e -o pipefail "$fixtures/body.hotfix_record" ) > "$lane_out" 2>&1
lane_rc=$?
lane_title="$(sed -n 's/.*::error title=\([^:]*\)::.*/\1/p' "$lane_out" | head -1)"
lane_can_pass=0
[ "$lane_rc" = "0" ] && lane_can_pass=1
if [ "$lane_rc" = "0" ]; then
  fail=$((fail+1)); printf 'FAIL %-40s the lane PASSED with no token — the census law inverts, and the doc must now document it\n' "census A: no-token lane refuses"
elif [ "$lane_title" != "Hotfix override not recorded" ]; then
  fail=$((fail+1)); printf 'FAIL %-40s exit %s but the annotation title was [%s]\n' "census A: no-token lane refuses" "$lane_rc" "$lane_title"
elif ! grep -qF -- 'BARKPARK_TASK_TOKEN is not set' "$lane_out"; then
  fail=$((fail+1)); printf 'FAIL %-40s reds for the wrong reason (no missing-secret wording; the token check may have moved below the curl)\n' "census A: no-token lane refuses"
elif grep -qF -- 'returned HTTP' "$lane_out"; then
  fail=$((fail+1)); printf 'FAIL %-40s reported a LEDGER OUTAGE against a healthy stub — this case is measuring the wrong failure\n' "census A: no-token lane refuses"
else
  pass=$((pass+1)); printf 'ok   %-40s (exit %s, title=%s)\n' "census A: no-token lane refuses" "$lane_rc" "$lane_title"
fi

# SIDE B — PROSE. The doc that owns the topic, plus this workflow's own ::error
# strings (the text a blocked human actually reads).
census_errors="$fixtures/census.workflow-errors.txt"
grep -F '::error' "$WORKFLOW" > "$census_errors" || :
[ -s "$census_errors" ] || { echo "TEST HARNESS FAIL: no ::error strings found in $WORKFLOW — side B would be vacuous" >&2; exit 99; }
census_doc="docs/ops/merge-gates.md"
[ -f "$census_doc" ] || { echo "TEST HARNESS FAIL: $census_doc not found — side B would be vacuous" >&2; exit 99; }
promises="$(promise_count sentence "$census_doc" "$census_errors")"

if [ "$lane_can_pass" = "0" ] && [ "$promises" != "0" ]; then
  fail=$((fail+1)); printf 'FAIL %-40s the lane REFUSES but %s surface(s) still promise it as an escape (scan: %s + %s ::error strings)\n' "census law: refusal => no promises" "$promises" "$census_doc" "$WORKFLOW"
elif [ "$lane_can_pass" = "1" ] && [ "$promises" = "0" ]; then
  fail=$((fail+1)); printf 'FAIL %-40s the lane PASSES but no surface documents the escape\n' "census law: passing => documented"
else
  pass=$((pass+1)); printf 'ok   %-40s (lane_can_pass=%s, promises=%s)\n' "census law holds in both directions" "$lane_can_pass" "$promises"
fi

# NECESSITY OF THE SENTENCE SCAN, pinned on the PRE-FIX BYTES. These three are
# origin/main verbatim, wraps included: two from merge-gates.md and the one that
# lived in this workflow's exit-2 ::error.
prefix_doc="$fixtures/census.prefix.md"
cat > "$prefix_doc" <<'EOF'
   **hotfix lane** — a `hotfix!` label passes AND auto-files an override
   task (needs the `BARKPARK_TASK_TOKEN` secret; without it the lane still
   passes but logs that the record was not filed);
- **`BARKPARK_TASK_TOKEN`** repo secret — a guerrilla write token, so the
  `hotfix!` lane can auto-file its override task. Without it the lane still
  passes (logs a warning); the token only closes the record-keeping gap.
EOF
prefix_err="$fixtures/census.prefix.err"
cat > "$prefix_err" <<'EOF'
            echo "::error title=Ledger unreachable::Re-run this check once the ledger is up; if it stays down, the hotfix! lane is the documented override (docs/ops/merge-gates.md)." | tee -a "$GITHUB_STEP_SUMMARY"
EOF
got_sentence="$(promise_count sentence "$prefix_doc" "$prefix_err")"
got_line="$(promise_count line "$prefix_doc" "$prefix_err")"
if [ "$got_sentence" = "3" ]; then
  pass=$((pass+1)); printf 'ok   %-40s (3 of 3 on the pre-fix bytes)\n' "census B: sentence scan finds all 3"
else
  fail=$((fail+1)); printf 'FAIL %-40s wanted 3 promises on the pre-fix bytes, got %s\n' "census B: sentence scan finds all 3" "$got_sentence"
fi
if [ "$got_line" = "1" ]; then
  pass=$((pass+1)); printf 'ok   %-40s (line scan sees 1 of 3 — the wrapped ones are invisible)\n' "census B: line scan is insufficient"
else
  fail=$((fail+1)); printf 'FAIL %-40s the line-scoped variant was expected to find exactly 1 of 3 (got %s); if it now finds 3 the sentence scan is untested, if 0 the fixture drifted\n' "census B: line scan is insufficient" "$got_line"
fi

# ...and a promise soft-wrapped across FOUR lines, which is the shape a future
# `fmt` pass produces and which no line-scoped grep can ever see.
wrapped="$fixtures/census.wrapped.md"
cat > "$wrapped" <<'EOF'
Note that when the secret is absent the
lane
still
passes, which is why nobody worries about it.
EOF
if [ "$(promise_count sentence "$wrapped")" = "1" ] && [ "$(promise_count line "$wrapped")" = "0" ]; then
  pass=$((pass+1)); printf 'ok   %-40s (caught across 4 wrapped lines; line scan blind)\n' "census B: 4-line wrap is caught"
else
  fail=$((fail+1)); printf 'FAIL %-40s sentence=%s line=%s (want 1 and 0)\n' "census B: 4-line wrap is caught" "$(promise_count sentence "$wrapped")" "$(promise_count line "$wrapped")"
fi

# -- the refusal must be MACHINE-READABLE, not just human-readable -------------
# A red required check exposed output.title=null, output.summary=null and one
# annotation reading `Process completed with exit code 1.` — while fail() had the
# exact remediation in hand and wrote it to plain stderr, where GitHub's log
# parser does not look. The missing piece was the WORKFLOW COMMAND, not the
# stream: proven 2026-07-28 on a live throwaway run, an `::error title=…::`
# written to stderr from inside a called script's fail(), invoked exactly as this
# workflow invokes it, landed as `[failure] title=… | pr-task-gate: FAIL: …`
# while a plain stderr line produced no annotation at all.
#
# ANNOTATION-ORDER TRAP, for whoever consumes this next: the authored annotation
# is NOT annotations[0]. The runner's own `Process completed with exit code 1.`
# and actions/checkout's Node-20 deprecation warning both PRECEDE it in
# `gh api .../check-runs/<id>/annotations`. Select on a non-empty `.title`
# (`jq '[.[] | select(.title != null and .title != "")] | .[0]'`), never on index.
check_says "no task ref annotates"  1 '::error title=PR is not task-backed::' 'TASK_ID='
check_says "violation annotates"    1 '::error title=PR is not task-backed::' 'TASK_ID=openone'
# UNCHECKED (exit 2) must NOT wear the "not task-backed" title: it is not a
# finding about the PR, and the workflow raises its own ::error for it.
: > "$fixtures/says.out"
( TASK_ID=active LEDGER_BASE=http://127.0.0.1:1 PR_TASK_GATE_RETRIES=1 bash "$GATE" ) \
  > "$fixtures/says.out" 2>&1
if grep -qF -- 'title=PR is not task-backed' "$fixtures/says.out"; then
  fail=$((fail+1)); printf 'FAIL %-40s an outage was annotated as a PR fault\n' "outage is not a PR fault"
else
  pass=$((pass+1)); printf 'ok   %-40s (no false accusation)\n' "outage is not a PR fault"
fi

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
