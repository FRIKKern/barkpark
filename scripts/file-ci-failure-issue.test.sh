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
TITLE = "CI failure: proof-workflow"

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

python3 "$work/fake-github.py" "$MODE_FILE" "$LOG_FILE" "$BODY_FILE" &
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

echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
