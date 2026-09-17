#!/usr/bin/env bash
# Hermetic test for scripts/file-ci-failure-issue.sh — stands up a fake GitHub
# REST API on localhost so no network, no token and no real repository are
# needed. Proves every path in the alerting contract BY MUTATION: each check
# flips exactly one input and asserts the script's observable behaviour
# (exit code, ::error:: on stderr, and the requests the fake API actually
# received) changes accordingly.
#
# The request log is the point. Asserting only the exit code would let a
# notifier that silently no-ops pass this suite — the same class of defect the
# script exists to prevent. So idempotency is proven by "the API received ZERO
# POST /issues on the second failure", not by a green exit.
#
# Run: bash scripts/file-ci-failure-issue.test.sh   (exit 0 = all green)

set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT="scripts/file-ci-failure-issue.sh"

work="$(mktemp -d)"
trap 'kill "${SRV_PID:-0}" 2>/dev/null; rm -rf "$work"' EXIT

MODE_FILE="$work/mode"
LOG_FILE="$work/requests.log"
BODY_FILE="$work/bodies.jsonl"
: >"$LOG_FILE"
: >"$BODY_FILE"
printf 'no-existing-issues' >"$MODE_FILE"

# --- fake GitHub API -------------------------------------------------------
# Reads $MODE_FILE per request, so a single long-lived server can play every
# scenario. Appends "<METHOD> <PATH>" to $LOG_FILE for every request received,
# and one {"path":…,"body":…} line per request WITH a body to $BODY_FILE — the
# request log alone cannot tell a routed issue from an unrouted one.
cat >"$work/fake-github.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE_FILE, LOG_FILE, BODY_FILE = sys.argv[1], sys.argv[2], sys.argv[3]
STATE_FILE = sys.argv[4]
TITLE = "CI failure: proof-workflow"

# STATEFUL ARM. Every mode above answers from a fixed script, which cannot
# express "the Nth consecutive firing" — the property the escalation is about.
# The `sequence` mode instead keeps the repository's real state in a file the
# server reads and writes: whether the issue exists, its title, its labels and
# its comment COUNT. The subject then walks a planted run of firings against a
# world that actually changes underneath it, and the counts asserted afterwards
# are what the API received, not what the test arranged.
def state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {"open": False}

def put_state(st):
    with open(STATE_FILE, "w") as f:
        json.dump(st, f)

def mode():
    with open(MODE_FILE) as f:
        return f.read().strip()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _record(self):
        with open(LOG_FILE, "a") as f:
            f.write(f"{self.command} {self.path.split('?')[0]}\n")

    def _send(self, code, payload):
        raw = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._record()
        m = mode()
        if m == "sequence":
            st = state()
            if not st.get("open"):
                return self._send(200, [])
            return self._send(200, [{
                "number": 42,
                "title": st.get("title", TITLE),
                "assignees": [{"login": a} for a in st.get("assignees", [])],
                "comments": st.get("comments", 0),
                "created_at": "2026-09-01T00:00:00Z",
                "labels": [{"name": n} for n in st.get("labels", ["ci-failure"])],
            }])
        if m == "list-500":
            return self._send(500, {"message": "Internal Server Error"})
        if m in ("issue-already-open", "assign-patch-rejected"):
            # The shape #5658 has: open, labelled, and nobody assigned. The
            # list response is where the comment path learns that.
            return self._send(200, [{"number": 42, "title": TITLE,
                                     "assignees": []}])
        if m == "issue-already-open-assigned":
            return self._send(200, [{"number": 42, "title": TITLE,
                                     "assignees": [{"login": "acme"}]}])
        if m == "only-a-pull-request":
            # A PR whose title collides must NOT be mistaken for the issue.
            return self._send(200, [
                {"number": 7, "title": TITLE, "pull_request": {"url": "x"}}
            ])
        if m == "unrelated-issue-open":
            return self._send(200, [{"number": 9, "title": "CI failure: other"}])
        return self._send(200, [])

    def _read_body(self):
        body = {}
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                raw = self.rfile.read(n)
                body = json.loads(raw)
                with open(BODY_FILE, "a") as f:
                    f.write(json.dumps(
                        {"path": self.path.split("?")[0], "body": body}) + "\n")
        except Exception:
            pass
        return body

    def do_PATCH(self):
        # The comment path's route-once assignment. GitHub answers a successful
        # issue edit with 200 and the updated issue.
        self._record()
        body = self._read_body()
        if mode() == "sequence":
            st = state()
            if "labels" in body:
                st["labels"] = list(body["labels"])
            if "title" in body:
                st["title"] = body["title"]
            if "assignees" in body:
                st["assignees"] = list(body["assignees"])
            put_state(st)
            return self._send(200, {"number": 42, "labels": [
                {"name": n} for n in st.get("labels", [])]})
        if mode() == "assign-patch-rejected":
            return self._send(422, {"message": "Validation Failed",
                                    "errors": [{"field": "assignees"}]})
        return self._send(200, {"number": 42, "assignees": [
            {"login": a} for a in (body.get("assignees") or [])]})

    def do_POST(self):
        self._record()
        m = mode()
        body = self._read_body()
        assignees = body.get("assignees") or []
        if m == "sequence":
            st = state()
            if self.path.endswith("/comments"):
                st["comments"] = st.get("comments", 0) + 1
                put_state(st)
                return self._send(201, {"id": 999})
            # A create. The ESCALATION issue carries its own title/label and
            # must NOT become the thing the dedupe lookup finds next firing.
            if (body.get("title") or "").startswith("CI escalation:"):
                st["escalations"] = st.get("escalations", 0) + 1
                put_state(st)
                return self._send(201, {"number": 4242, "assignees": []})
            st.update({"open": True, "comments": 0, "title": body.get("title"),
                       "labels": list(body.get("labels") or []),
                       "assignees": list(assignees)})
            put_state(st)
            return self._send(201, {"number": 42, "assignees": [
                {"login": a} for a in assignees]})
        if m == "create-422":
            return self._send(422, {"message": "Validation Failed"})
        if self.path.endswith("/comments"):
            return self._send(201, {"id": 999})
        # GitHub rejects the WHOLE create when an assignee cannot be assigned.
        if m == "assignee-rejected" and assignees:
            return self._send(422, {"message": "Validation Failed",
                                    "errors": [{"field": "assignees"}]})
        # …and in other shapes accepts the create and silently drops them.
        if m == "assignee-dropped":
            return self._send(201, {"number": 123, "assignees": []})
        return self._send(201, {"number": 123,
                                "assignees": [{"login": a} for a in assignees]})

HTTPServer(("127.0.0.1", 0), H).serve_forever()
PY

STATE_FILE="$work/state.json"
python3 "$work/fake-github.py" "$MODE_FILE" "$LOG_FILE" "$BODY_FILE" "$STATE_FILE" &
SRV_PID=$!

# Discover the assigned port from the socket the child is listening on.
port=""
for _ in $(seq 1 50); do
  port="$(python3 - "$SRV_PID" <<'PY' 2>/dev/null || true
import sys, subprocess, re
out = subprocess.run(["lsof","-Pan","-p",sys.argv[1],"-iTCP","-sTCP:LISTEN"],
                     capture_output=True, text=True).stdout
m = re.search(r":(\d+) \(LISTEN\)", out)
print(m.group(1) if m else "")
PY
)"
  [ -n "$port" ] && break
  sleep 0.1
done
[ -n "$port" ] || { echo "TEST HARNESS FAIL: could not find fake API port" >&2; exit 99; }
API="http://127.0.0.1:$port"

# --- assertions ------------------------------------------------------------
pass=0 fail=0
out=""; err=""; got=0

run() { # run <mode> [env overrides...]
  printf '%s' "$1" >"$MODE_FILE"; shift
  : >"$LOG_FILE"
  : >"$BODY_FILE"
  out="$work/out"; err="$work/err"
  ( eval "GITHUB_API_URL=\"$API\" \
          GITHUB_SERVER_URL=https://github.test \
          GITHUB_TOKEN=fake-token \
          GITHUB_REPOSITORY=acme/widgets \
          GITHUB_WORKFLOW=proof-workflow \
          GITHUB_RUN_ID=555 \
          GITHUB_JOB=audit \
          GITHUB_EVENT_NAME=schedule \
          $* bash \"$SCRIPT\"" ) >"$out" 2>"$err"
  got=$?
}

ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

want_exit() { # want_exit <label> <expected>
  if [ "$got" = "$2" ]; then ok "$1 (exit $got)"; else bad "$1 — want exit $2 got $got"; fi
}
want_loud() { # want_loud <label> — degrade must be ::error::, never a quiet pass
  if grep -q '^::error' "$err"; then ok "$1 (::error:: emitted)"
  else bad "$1 — no ::error:: on stderr; stderr was: $(head -c 200 "$err")"; fi
}
want_not_loud() {
  if grep -q '^::error' "$err"; then bad "$1 — unexpected ::error::"; else ok "$1"; fi
}
want_warn() { # want_warn <label> — the SOFT degrade: routing lost, alarm kept
  if grep -q '^::warning' "$err"; then ok "$1 (::warning:: emitted)"
  else bad "$1 — no ::warning:: on stderr; stderr was: $(head -c 200 "$err")"; fi
}
want_not_warn() {
  if grep -q '^::warning' "$err"; then bad "$1 — unexpected ::warning::"; else ok "$1"; fi
}
want_requests() { # want_requests <label> <expected count> <grep pattern>
  local n; n="$(grep -c -- "$3" "$LOG_FILE" 2>/dev/null || true)"
  if [ "$n" = "$2" ]; then ok "$1 ($3 x$n)"; else bad "$1 — want $2 '$3' got $n"; fi
}
# A create call's payload, as the fake API actually received it. `which` is
# first|last, because a rejected assignment retries and the two payloads differ.
want_create_field() { # want_create_field <label> <first|last> <jq filter> <expected>
  local got
  got="$(jq -r 'select(.path | endswith("/issues")) | .body' "$BODY_FILE" 2>/dev/null \
        | jq -sr "$2 | $3" 2>/dev/null)"
  if [ "$got" = "$4" ]; then ok "$1 ($2 create: $3 = $got)"
  else bad "$1 — want $2 create '$3' = '$4' got '$got'"; fi
}
# The same assertion for any other request that carries a body — the comment
# path's comment and its route-once assignment PATCH.
want_body_field() { # want_body_field <label> <path suffix> <first|last> <jq> <expected>
  local got
  got="$(jq -r --arg suf "$2" 'select(.path | endswith($suf)) | .body' "$BODY_FILE" 2>/dev/null \
        | jq -sr "$3 | $4" 2>/dev/null)"
  if [ "$got" = "$5" ]; then ok "$1 ($2 $3: $4 = $got)"
  else bad "$1 — want $2 $3 '$4' = '$5' got '$got'"; fi
}

echo "--- happy path: a new failure files an issue"
run no-existing-issues
want_exit      "new failure exits 0" 0
want_not_loud  "new failure is not a degrade"
want_requests  "new failure POSTs one issue" 1 "POST /repos/acme/widgets/issues"

echo
echo "--- ROUTING: the create carries a human, derived from GITHUB_REPOSITORY"
# Filed is not routed. An UNSUBSCRIBED owner is notified only when assigned,
# participating or @mentioned, so the create must carry the assignee itself —
# asserted against the payload the API RECEIVED, not against the exit code.
run no-existing-issues
want_create_field "create assigns the repository owner" last '.assignees | join(",")' "acme"
want_create_field "create @mentions them in the body"   last '.body | test("@acme")' "true"
want_not_warn     "a routed create warns about nothing"

echo
echo "--- ROUTING: CI_FAILURE_ASSIGNEE overrides the derived owner"
run no-existing-issues 'CI_FAILURE_ASSIGNEE=octocat'
want_exit         "explicit assignee exits 0" 0
want_create_field "create assigns the explicit login" last '.assignees | join(",")' "octocat"

echo
echo "--- ROUTING: an EMPTY CI_FAILURE_ASSIGNEE is a deliberate opt-out"
run no-existing-issues 'CI_FAILURE_ASSIGNEE='
want_exit         "opt-out exits 0" 0
want_create_field "opt-out assigns nobody" last '.assignees | length' "0"
want_not_warn     "an opt-out is not a degrade"

echo
echo "--- DEGRADE: a REJECTED assignment still files the alarm, warns, exits 0"
# GitHub rejects the whole create for one bad login. The issue is the alarm:
# losing it to a routing problem would be strictly worse than filing it
# unrouted, so this is the one path that warns instead of dying.
run assignee-rejected
want_exit         "rejected assignment still exits 0" 0
want_not_loud     "rejected assignment is NOT a hard failure"
want_warn         "rejected assignment warns that it was filed but not routed"
want_requests     "rejected assignment refiles the issue" 2 "POST /repos/acme/widgets/issues$"
want_create_field "the rejected attempt carried the assignee" first '.assignees | join(",")' "acme"
want_create_field "the refile carries none"                   last  '.assignees | length' "0"

echo
echo "--- DEGRADE: an assignment SILENTLY DROPPED by the API also warns"
run assignee-dropped
want_exit      "dropped assignment exits 0" 0
want_not_loud  "dropped assignment is NOT a hard failure"
want_warn      "dropped assignment warns that nobody is assigned"
want_requests  "dropped assignment files exactly one issue" 1 "POST /repos/acme/widgets/issues$"

echo
echo "--- idempotency: the SAME ongoing failure must not mint a second issue"
run issue-already-open
want_exit      "recurring failure exits 0" 0
want_requests  "recurring failure POSTs NO new issue" 0 "POST /repos/acme/widgets/issues$"
want_requests  "recurring failure comments instead" 1 "POST /repos/acme/widgets/issues/42/comments"

echo
echo "--- ROUTING on the COMMENT path: an UNASSIGNED open issue gets routed once"
# The path a chronic red actually takes. #5658 proves the defect it closes:
# open since 2026-07-22, 8 comments, every one from github-actions, nobody
# assigned — so the alarm kept firing at nobody. Assign AND @mention, both
# gated on the same zero-assignee test, so the assignment silences the mention.
run issue-already-open
want_exit        "unassigned existing issue exits 0" 0
want_not_loud    "routing an existing issue is not a degrade"
want_not_warn    "an accepted assignment warns about nothing"
want_requests    "the unassigned issue is assigned exactly once" 1 "PATCH /repos/acme/widgets/issues/42$"
want_body_field  "the PATCH assigns the derived owner" "/issues/42" last '.assignees | join(",")' "acme"
want_requests    "the comment is still posted" 1 "POST /repos/acme/widgets/issues/42/comments"
want_body_field  "the comment @mentions them too" "/comments" last '.body | test("@acme")' "true"
want_body_field  "the comment still reports the ongoing failure" "/comments" last '.body | test("Still failing")' "true"
want_requests    "routing an existing issue mints no duplicate" 0 "POST /repos/acme/widgets/issues$"

echo
echo "--- ROUTING on the COMMENT path: an ALREADY-ASSIGNED issue is left alone"
# Route ONCE. The crown fires 6-hourly; mentioning on every comment would be
# ~4 notifications a day forever, which is how an alarm gets muted by a human.
run issue-already-open-assigned
want_exit      "assigned existing issue exits 0" 0
want_not_warn  "no routing was attempted, so nothing warns"
want_requests  "an assigned issue is NOT re-assigned" 0 "PATCH"
want_requests  "an assigned issue still gets its comment" 1 "POST /repos/acme/widgets/issues/42/comments"
want_body_field "the comment does NOT nag with a mention" "/comments" last '.body | test("@acme")' "false"

echo
echo "--- ROUTING on the COMMENT path: CI_FAILURE_ASSIGNEE= opts out of it"
run issue-already-open 'CI_FAILURE_ASSIGNEE='
want_exit      "comment-path opt-out exits 0" 0
want_requests  "opt-out assigns nobody" 0 "PATCH"
want_not_warn  "an opt-out is not a degrade on the comment path either"

echo
echo "--- DEGRADE: a REJECTED assignment on the comment path warns, comment stands"
run assign-patch-rejected
want_exit        "rejected assignment on the comment path exits 0" 0
want_not_loud    "rejected assignment is NOT a hard failure"
want_warn        "rejected assignment warns that nobody is assigned"
want_requests    "the comment is posted anyway" 1 "POST /repos/acme/widgets/issues/42/comments"
want_body_field  "the mention survives the rejection" "/comments" last '.body | test("@acme")' "true"
want_body_field  "the comment names the HTTP status that rejected it" "/comments" last '.body | test("HTTP 422")' "true"

echo
echo "--- an unrelated open ci-failure issue must not suppress this one"
run unrelated-issue-open
want_exit      "different key still files" 0
want_requests  "different key POSTs its own issue" 1 "POST /repos/acme/widgets/issues$"

echo
echo "--- a same-titled PULL REQUEST must not be mistaken for the issue"
run only-a-pull-request
want_exit      "PR collision still files" 0
want_requests  "PR collision POSTs the issue" 1 "POST /repos/acme/widgets/issues$"
want_requests  "PR collision does NOT comment on the PR" 0 "/issues/7/comments"

echo
echo "--- mutation: remove the token → must degrade LOUDLY, never pass quietly"
run no-existing-issues 'GITHUB_TOKEN='
want_exit      "missing token exits non-zero" 1
want_loud      "missing token is LOUD"
want_requests  "missing token contacts no API" 0 "POST"

echo
echo "--- mutation: remove the repository → loud"
run no-existing-issues 'GITHUB_REPOSITORY='
want_exit      "missing repository exits non-zero" 1
want_loud      "missing repository is LOUD"

echo
echo "--- mutation: API 500 on lookup → loud, and no blind issue is filed"
run list-500
want_exit      "list 500 exits non-zero" 1
want_loud      "list 500 is LOUD"
want_requests  "list 500 files nothing blindly" 0 "POST"

echo
echo "--- mutation: API 422 on create → loud (a rejected file must not read as sent)"
run create-422
want_exit      "create 422 exits non-zero" 1
want_loud      "create 422 is LOUD"

echo
echo "--- mutation: API unreachable → loud"
run no-existing-issues "GITHUB_API_URL=http://127.0.0.1:1"
want_exit      "unreachable API exits non-zero" 1
want_loud      "unreachable API is LOUD"

echo
echo "---"
# ── redaction: credential shapes never reach the public issue body ──────────
run no-existing-issues CI_FAILURE_DETAIL="'step log: token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig BARKPARK_ADMIN_TOKEN=bp_supersecret_value_123 note: DB_PASSWORD=hunter22 harmless=keep-me'"
want_exit "redaction: the create still succeeds" 0
if grep -q 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab' "$BODY_FILE"; then bad "redaction: a GitHub token reached the body"; else ok "redaction: GitHub token masked"; fi
if grep -q 'eyJhbGciOiJIUzI1NiJ9' "$BODY_FILE"; then bad "redaction: a Bearer value reached the body"; else ok "redaction: Bearer value masked"; fi
if grep -q 'bp_supersecret_value_123' "$BODY_FILE"; then bad "redaction: BARKPARK_ADMIN_TOKEN value reached the body"; else ok "redaction: *_TOKEN= value masked"; fi
if grep -q 'hunter22' "$BODY_FILE"; then bad "redaction: DB_PASSWORD value reached the body"; else ok "redaction: *_PASSWORD= value masked"; fi
if grep -q 'BARKPARK_ADMIN_TOKEN=\[REDACTED\]' "$BODY_FILE" && grep -q 'harmless=keep-me' "$BODY_FILE"; then ok "redaction: the key survives, the value does not, and plain text is untouched"; else bad "redaction: key/plain-text handling wrong: $(grep -o 'BARKPARK_ADMIN_TOKEN[^ ]*' "$BODY_FILE" | head -1) / $(grep -c 'harmless=keep-me' "$BODY_FILE")"; fi
# mutation: with redact() disabled the token MUST reach the body (proves the case can fail)
mut="$work/subject-unredacted.sh"; sed 's/^detail="\$(printf .%s. "\$detail" | redact)"$/: # redaction disarmed for the mutation/' "$SCRIPT" > "$mut"
if grep -q 'redaction disarmed' "$mut"; then
  SAVE_SCRIPT="$SCRIPT"; SCRIPT="$mut"; run no-existing-issues CI_FAILURE_DETAIL="'token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab'"; SCRIPT="$SAVE_SCRIPT"
  if grep -q 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab' "$BODY_FILE"; then ok "redaction mutation: without redact() the token reaches the body (the case can fail)"; else bad "redaction mutation: the disarmed subject still masked — the case is vacuous"; fi
else bad "redaction mutation: could not disarm redact() in the subject copy"; fi


echo
echo "--- ESCALATION: N repeats collapse into ONE escalation, then SILENCE (task-5753ff3072d00b67)"
# WHY. Measured 2026-09-17 against the live repository: 18 open ci-failure
# issues carry 2782 automated comments between them; #11714 (crown-reconcile)
# alone carries 1283 in 31 days, and NONE of the 18 has a ledger row. The
# append path is unbounded, so this arm plants a real run of firings against a
# STATEFUL fake repository and counts what the API received.
#
# N is READ OUT OF THE SUBJECT, never retyped: a test that carries its own copy
# of the threshold passes when the subject's copy changes.
N="$(sed -n 's/^escalate_after=\([0-9][0-9]*\)$/\1/p' "$SCRIPT" | head -1)"
if [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null; then
  ok "escalation threshold read from the subject: escalate_after=$N (N > 0)"
else
  bad "escalation threshold: could not read a positive escalate_after= literal out of $SCRIPT (got '$N')"
  N=3
fi
# UPPER BOUND, because this arm plants N+3 REAL firings against a real socket.
# An escalate_after raised out of reach would not fail this suite, it would HANG
# it — a disarm experiment with escalate_after=999999 planted a million firings
# and had to be killed. A threshold nobody can sit through is itself the defect
# (the spiral is back), so name it rather than run it.
if [ "$N" -gt 25 ] 2>/dev/null; then
  bad "escalation threshold: escalate_after=$N is too high to be an escalation — $N repeat notifications IS the spiral this bounds. Cap it at 25."
  N=25
fi

# fire — one firing against the LIVE state file, appending to the shared logs.
# `run` truncates them, which would erase the very history this arm counts.
fire() {
  ( eval "GITHUB_API_URL=\"$API\" \
          GITHUB_SERVER_URL=https://github.test \
          GITHUB_TOKEN=fake-token \
          GITHUB_REPOSITORY=acme/widgets \
          GITHUB_WORKFLOW=proof-workflow \
          GITHUB_RUN_ID=555 \
          GITHUB_JOB=audit \
          GITHUB_EVENT_NAME=schedule \
          $* bash \"$SCRIPT\"" ) >>"$work/seq.out" 2>>"$work/seq.err"
  printf '%s\n' "$?" >>"$work/seq.codes"
}

# n_appends — "Still failing." comments the API actually received.
n_appends() { jq -r 'select(.path | endswith("/comments")) | .body.body' "$BODY_FILE" 2>/dev/null | grep -c '^Still failing' || true; }
n_esc_comments() { jq -r 'select(.path | endswith("/comments")) | .body.body' "$BODY_FILE" 2>/dev/null | grep -c 'no further automated comments' || true; }
n_esc_issues() { jq -r 'select(.path | endswith("/issues")) | .body.title' "$BODY_FILE" 2>/dev/null | grep -c '^CI escalation:' || true; }
n_parent_creates() { jq -r 'select(.path | endswith("/issues")) | .body.title' "$BODY_FILE" 2>/dev/null | grep -c '^CI failure: proof-workflow$' || true; }

sequence() { # sequence <total firings> — replays a cold repository from scratch
  printf 'sequence' >"$MODE_FILE"
  printf '{"open":false}' >"$STATE_FILE"
  : >"$LOG_FILE"; : >"$BODY_FILE"
  : >"$work/seq.out"; : >"$work/seq.err"; : >"$work/seq.codes"
  local i=0
  while [ "$i" -lt "$1" ]; do fire; i=$((i+1)); done
}

# N+3 firings: 1 create, then the appends, then the escalation, then the
# firings that must write NOTHING. This spans the N+2 point the row names and
# keeps going, because "stops appending" is only observable AFTER it stops.
total=$((N + 3))
sequence "$total"
echo "    planted $total consecutive failures on one key (escalate_after=$N)"
if [ "$(n_parent_creates)" = 1 ]; then ok "escalation: the FIRST failure opened exactly one issue (D8 — the alert can still fire)"
else bad "escalation: want 1 create of 'CI failure: proof-workflow', got $(n_parent_creates)"; fi
if [ "$(n_appends)" = "$N" ]; then ok "escalation: exactly N=$N 'Still failing.' appends over $total firings"
else bad "escalation: want $N appends, got $(n_appends) over $total firings"; fi
if [ "$(n_esc_comments)" = 1 ]; then ok "escalation: exactly ONE escalation comment"
else bad "escalation: want 1 escalation comment, got $(n_esc_comments)"; fi
if [ "$(n_esc_issues)" = 1 ]; then ok "escalation: exactly ONE 'CI escalation:' issue opened per key"
else bad "escalation: want 1 escalation issue, got $(n_esc_issues)"; fi
if ! grep -q '[^0]' "$work/seq.codes"; then ok "escalation: every firing exited 0"
else bad "escalation: a firing exited non-zero: $(tr '\n' ' ' <"$work/seq.codes") / $(grep '^::error' "$work/seq.err" | head -1)"; fi
# The retitle: count, age and the latest run URL all land on the issue itself.
#
# CAPTURE, THEN MATCH — never `jq … | grep -q`. `grep -q` exits on its first hit,
# jq takes SIGPIPE, and under `set -o pipefail` the pipeline returns 141, so a
# TRUE assertion reads FALSE. It is a race on the pipe buffer, so it fails
# intermittently and on the big payloads only: two of these arms failed exactly
# that way on their first run. Every match below is a glob against a captured
# string, which has no pipeline to poison.
has() { # has <haystack> <needle>
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}
esc_patch_title="$(jq -r 'select(.path == "/repos/acme/widgets/issues/42") | .body.title // empty' "$BODY_FILE" 2>/dev/null)"
esc_patch_body="$(jq -r 'select(.path == "/repos/acme/widgets/issues/42") | .body.body // empty' "$BODY_FILE" 2>/dev/null)"
esc_comment_body="$(jq -r 'select(.path | endswith("/comments")) | .body.body' "$BODY_FILE" 2>/dev/null)"
seq_err="$(cat "$work/seq.err" 2>/dev/null)"
if has "$esc_patch_title" "ESCALATED after $N repeats"; then
  ok "escalation: the issue is retitled with the repeat count"
else bad "escalation: the retitle does not carry the count: '$esc_patch_title'"; fi
if has "$esc_patch_body" "first seen:" && has "$esc_patch_body" "actions/runs/555"; then
  ok "escalation: the rewritten body carries the first-seen age and the latest run URL"
else bad "escalation: the rewritten body is missing the age or the run URL"; fi
if has "$esc_comment_body" "@acme"; then
  ok "escalation: the escalation comment @-mentions the assignee"
else bad "escalation: the escalation comment does not @-mention the assignee"; fi
# NO SILENT SUCCESS. Barkpark's intake drops Bot senders (Intake.bot_sender?/1),
# so the escalation issue mints no gh-<n> row. The comment must SAY that.
if has "$esc_comment_body" "LEDGER: NOT ADOPTED"; then
  ok "escalation: the comment states the ledger does NOT adopt it (bot-sender drop), rather than implying a mirror"
else bad "escalation: the escalation comment does not disclose the ledger drop"; fi
if has "$seq_err" "NO ledger row was created"; then
  ok "escalation: the run log warns that no ledger row was created"
else bad "escalation: no ::warning:: about the missing ledger row"; fi

echo
echo "--- ESCALATION: the alert can STILL fire after a key has escalated (D8)"
# The escalated issue is closed (or the key is new): state goes cold and the
# very next failure must open a fresh issue. An escalation that permanently
# silences a key would be a worse defect than the spiral it replaces.
: >"$BODY_FILE"; : >"$LOG_FILE"; : >"$work/seq.err"; : >"$work/seq.codes"
printf '{"open":false}' >"$STATE_FILE"
fire
if [ "$(n_parent_creates)" = 1 ]; then ok "post-escalation: a first failure on a cold key opens an issue again"
else bad "post-escalation: want 1 create, got $(n_parent_creates)"; fi
if [ "$(n_appends)" = 0 ]; then ok "post-escalation: it is a create, not an append"
else bad "post-escalation: it appended instead of creating"; fi

echo
echo "--- MUTATION: disarm the escalation arm → this suite must go RED"
# Raising the threshold out of reach is the smallest disarm that leaves the
# script otherwise identical. The counts above must then fail; if they do not,
# they were measuring nothing.
esc_mut="$work/subject-no-escalation.sh"
sed 's/^escalate_after=[0-9][0-9]*$/escalate_after=999999/' "$SCRIPT" >"$esc_mut"
if grep -q '^escalate_after=999999$' "$esc_mut"; then
  SAVE_SCRIPT="$SCRIPT"; SCRIPT="$esc_mut"
  sequence "$total"
  SCRIPT="$SAVE_SCRIPT"
  mut_appends="$(n_appends)"; mut_esc="$(n_esc_issues)"
  if [ "$mut_appends" != "$N" ] && [ "$mut_esc" = 0 ]; then
    ok "escalation mutation: disarmed, the subject appends $mut_appends times (not $N) and escalates 0 times — the arm can fail"
  else
    bad "escalation mutation: the disarmed subject still looks escalated (appends=$mut_appends escalations=$mut_esc) — the arm is VACUOUS"
  fi
else
  bad "escalation mutation: could not raise escalate_after in the subject copy"
fi

echo
echo "--- main-gate-watch reporter wiring (task-d1d19ca64ddd2f59) ---"
# WHY THIS ARM LIVES HERE. main-gate-watch.yml concluded FAILURE on NINE
# consecutive main runs (34710221041 .. 34749744107, 2026-09-12T18:07Z ..
# 2026-09-13T09:34Z) and reached nobody, because it had no reporter job wired to
# THIS script. The fix is three reporter jobs, and what has to stay true about
# them is a property of the WORKFLOW FILE, not of this script's runtime — so it
# is checked by PARSING the YAML. Every `needs:`, `if:` and `env:` below is read
# out of the file; nothing about the guards is retyped into this test. The
# scenario table then evaluates each reporter's real `if:` expression under the
# job results a fault / a scream / an absence / a green / a cancelled / a
# not-on-main run actually produce, so "fires for a fault, not for a green" is
# measured rather than asserted.
cat >"$work/mgw-reporter-wiring.py" <<'MGWPY'
import re, sys, yaml

wf_path = sys.argv[1]
wf = yaml.safe_load(open(wf_path))
jobs = wf["jobs"]
fail = []


def chk(cond, msg):
    if cond:
        print("  ok   " + msg)
    else:
        fail.append(msg)
        print("  BAD  " + msg)


# The three reporters, one per failing OUTCOME this workflow can produce.
REPORTERS = ["report-main-gate-watch-fault",
             "report-main-gate-watch-scream",
             "report-main-verdict-presence"]
for r in REPORTERS:
    chk(r in jobs, "workflow declares job %s" % r)
if fail:
    print("CANNOT READ: a reporter job is missing from %s" % wf_path)
    sys.exit(1)

keys = {}
for r in REPORTERS:
    j = jobs[r]
    last = j["steps"][-1] or {}
    env = last.get("env", {}) or {}
    perms = j.get("permissions", {}) or {}
    run = last.get("run", "") or ""
    chk(run.strip() == "bash scripts/file-ci-failure-issue.sh",
        "%s runs the filer verbatim" % r)
    chk(perms.get("issues") == "write",
        "%s carries JOB-LEVEL issues: write" % r)
    chk(bool(env.get("CI_FAILURE_KEY")), "%s sets CI_FAILURE_KEY" % r)
    chk(len((env.get("CI_FAILURE_DETAIL") or "").strip()) > 100,
        "%s sets a substantive CI_FAILURE_DETAIL" % r)
    # The filer reads GITHUB_TOKEN and nothing else — GH_TOKEN is the known slip.
    chk("GITHUB_TOKEN" in env, "%s sets GITHUB_TOKEN (not GH_TOKEN)" % r)
    keys[r] = env.get("CI_FAILURE_KEY")
chk(len(set(keys.values())) == len(REPORTERS),
    "the three CI_FAILURE_KEYs are DISTINCT (dedupe is per key): %s"
    % sorted(set(keys.values())))

# `issues: write` must never be granted workflow-wide: that would re-scope the
# breakglass-token jobs above it.
chk("issues" not in (wf.get("permissions", {}) or {}),
    "no top-level issues: grant was added")


def ancestors(job, seen=None):
    seen = seen if seen is not None else set()
    # `needs:` is a STRING when a job names exactly one dependency and a LIST
    # otherwise — main-gate-watch uses the string form. Iterating the string
    # walks its CHARACTERS and raises KeyError: 'm'; this test caught exactly
    # that on its first run, which is why the normalisation is spelled out.
    needs = jobs[job].get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    for n in needs:
        if n not in seen:
            seen.add(n)
            ancestors(n, seen)
    return seen


def evaluate(job, results, ref):
    """True when GitHub would RUN this job — its `if:` read from the file."""
    anc = ancestors(job)
    expr = str(jobs[job].get("if", "true")).strip()
    for term in [t.strip() for t in re.split(r"&&", expr)]:
        if term in ("true", "always()"):
            v = True
        elif term == "failure()":
            v = any(results.get(a) == "failure" for a in anc)
        elif term == "success()":
            v = all(results.get(a) == "success" for a in anc)
        elif term == "cancelled()":
            v = any(results.get(a) == "cancelled" for a in anc)
        else:
            m = re.match(r"^(\S+)\s*(==|!=)\s*'([^']*)'$", term)
            if not m:
                raise SystemExit(
                    "CANNOT READ: unparseable if-term %r in %s" % (term, job))
            lhs, op, lit = m.groups()
            n = re.match(r"^needs\.([A-Za-z0-9_-]+)\.result$", lhs)
            if n:
                actual = results.get(n.group(1))
            elif lhs == "github.ref":
                actual = ref
            elif lhs == "github.event_name":
                actual = results.get("__event", "schedule")
            else:
                raise SystemExit(
                    "CANNOT READ: unknown operand %r in %s" % (lhs, job))
            v = (actual == lit) if op == "==" else (actual != lit)
        if not v:
            return False
    return True


MAIN = "refs/heads/main"
S = "success"
SCENARIOS = [
    # rc 3: the fault job reds and SKIPS its sibling (that sibling's own `if:`
    # excludes rc 3), so only the fault key may be filed.
    ("CONFIGURATION FAULT on main", MAIN,
     {"main-gate-watch-fault": "failure", "main-gate-watch": "skipped",
      "main-verdict-presence": S},
     {"report-main-gate-watch-fault"}),
    # rc 1: the watch screams about main's tip.
    ("scream on main", MAIN,
     {"main-gate-watch-fault": S, "main-gate-watch": "failure",
      "main-verdict-presence": S},
     {"report-main-gate-watch-scream"}),
    ("verdict absence on main", MAIN,
     {"main-gate-watch-fault": S, "main-gate-watch": S,
      "main-verdict-presence": "failure"},
     {"report-main-verdict-presence"}),
    ("green on main files NOTHING", MAIN,
     {"main-gate-watch-fault": S, "main-gate-watch": S,
      "main-verdict-presence": S},
     set()),
    # failure() is FALSE for cancelled, deliberately: a run collapsed by the
    # concurrency group executed nothing and has nothing to report.
    ("cancelled on main files NOTHING", MAIN,
     {"main-gate-watch-fault": "cancelled", "main-gate-watch": "cancelled",
      "main-verdict-presence": "cancelled"},
     set()),
    # workflow_dispatch is dispatchable against ANY ref; a topic-branch debug run
    # already has a human attached and must mint no public issue. (The schedule
    # arm can only ever run on the default branch, so the guard passes there.)
    ("scream on a NON-main dispatch files NOTHING", "refs/heads/topic",
     {"main-gate-watch-fault": S, "main-gate-watch": "failure",
      "main-verdict-presence": S},
     set()),
]

for label, ref, results, expected in SCENARIOS:
    fired = set(r for r in REPORTERS if evaluate(r, results, ref))
    chk(fired == expected,
        "%s -> fires %s (expected %s)"
        % (label, sorted(fired) or "nothing", sorted(expected) or "nothing"))

print("mgw reporter wiring: %d failed" % len(fail))
sys.exit(1 if fail else 0)
MGWPY

MGW_WF=".github/workflows/main-gate-watch.yml"
if python3 "$work/mgw-reporter-wiring.py" "$MGW_WF"; then
  ok "mgw wiring: the parsed guards fire on fault/scream/absence and NOT on green/cancelled/non-main"
else
  bad "mgw wiring: see the BAD lines above"
fi

# MUTATION: strip the ref guard from the reporters. The non-main scenario must
# then fire and this arm must go RED — a scenario table that stays green under a
# disarmed guard is measuring nothing.
mgw_mut="$work/main-gate-watch.mutated.yml"
sed "s/github\.ref == 'refs\/heads\/main'/true/g" "$MGW_WF" >"$mgw_mut"
if [ "$(grep -c "github.ref == 'refs/heads/main'" "$mgw_mut")" = 0 ] \
   && [ "$(grep -c "github.ref == 'refs/heads/main'" "$MGW_WF")" -ge 3 ]; then
  if python3 "$work/mgw-reporter-wiring.py" "$mgw_mut" >"$work/mgw-mut.out" 2>&1; then
    bad "mgw mutation: the ref guard was stripped and the arm STILL passed — vacuous"
  elif grep -q 'NON-main dispatch' "$work/mgw-mut.out"; then
    ok "mgw mutation: stripping the ref guard reds this arm on the non-main scenario (the case can fail)"
  else
    bad "mgw mutation: reddened, but not on the non-main scenario: $(grep BAD "$work/mgw-mut.out" | head -3)"
  fi
else
  bad "mgw mutation: could not disarm the ref guard in the workflow copy"
fi

echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
