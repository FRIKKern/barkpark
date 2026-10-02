#!/usr/bin/env bash
# bp-curl.test.sh — the harness behind scripts/lib/bp-curl.sh.
#
# A FAKE SERVER (python3 http.server, loopback, ephemeral port) answers a scripted
# sequence of responses and LOGS every request it receives. Each case asserts
# the FIXTURE first (the server is up, the request ARRIVED — an unreached server
# is a vacuous green) and only then the verdict. In one run it proves:
#   * 429 then 200 is retried and the second answer is the one returned;
#   * 500 is NOT retried (exactly one request arrives);
#   * the wait is the VALUE FROM THE RESPONSE — header 2 sleeps 2s, header 0
#     sleeps 0s, body retry_after 2 sleeps 2s — and a MUTANT helper with the
#     read replaced by a constant reds on that same case (the detector is
#     named: "waiting <N>s" must equal the header, and elapsed must agree);
#   * Retry-After above BP_CURL_MAX_WAIT_S is reported unslept; the attempt cap
#     and the total-wait ceiling both bound the loop (request counts measured);
#   * the flags the helper owns (-w/-D/-f, alone or in a cluster) are refused
#     with a CANNOT line and exit 64;
#   * bp_curl_body: 2xx -> body + 0; non-2xx -> empty stdout + 22; transport
#     failure -> nothing + curl's rc, so `|| echo 000` yields a clean 000.
# Exit 0 = every assertion held; 1 = at least one failed; 2 = CANNOT MEASURE.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/bp-curl.sh"
[ -f "$HELPER" ] || { echo "CANNOT MEASURE: $HELPER is missing"; exit 2; }
command -v python3 >/dev/null || { echo "CANNOT MEASURE: python3 is not on PATH (the fake server is python3)"; exit 2; }
command -v curl >/dev/null || { echo "CANNOT MEASURE: curl is not on PATH"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bp-curl-test.XXXXXX")"
SPEC="$TMP/spec"; LOG="$TMP/requests.log"; PORTF="$TMP/port"; SRVLOG="$TMP/server.log"
trap 'kill "${SRV_PID:-}" 2>/dev/null; wait "${SRV_PID:-}" 2>/dev/null; rm -rf "$TMP"' EXIT

cat > "$TMP/server.py" <<'PY'
import http.server, os, sys, json
SPEC, LOG, PORTF = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _serve(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n: self.rfile.read(n)
        with open(LOG, 'a') as f: f.write(f"{self.command} {self.path}\n")
        lines = [l for l in open(SPEC).read().split('\n') if l.strip()]
        idx = len(open(LOG).read().split('\n')) - 2  # requests served before this one
        line = lines[min(idx, len(lines) - 1)] if lines else '200||{"ok":true}'
        status, ra, body = line.split('|', 2)
        self.send_response(int(status))
        if ra: self.send_header('Retry-After', ra)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body.encode())))
        self.end_headers()
        self.wfile.write(body.encode())
    do_GET = _serve; do_POST = _serve; do_DELETE = _serve; do_PUT = _serve
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
open(PORTF, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
: > "$SPEC"; : > "$LOG"
python3 "$TMP/server.py" "$SPEC" "$LOG" "$PORTF" > "$SRVLOG" 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$PORTF" ] && break; sleep 0.25; done
[ -s "$PORTF" ] || { echo "CANNOT MEASURE: the fake server never published a port"; cat "$SRVLOG"; exit 2; }
PORT="$(cat "$PORTF")"; BASE="http://127.0.0.1:$PORT"

# FIXTURE GATE: the server answers and the request arrives, before any verdict.
printf '200||{"probe":true}\n' > "$SPEC"; : > "$LOG"
probe="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$BASE/probe" 2>&1)" || true
[ "$probe" = "200" ] || { echo "CANNOT MEASURE: the fake server answered '$probe' to the probe, not 200"; exit 2; }
grep -q '^GET /probe$' "$LOG" || { echo "CANNOT MEASURE: the probe did not reach the fake server's log"; exit 2; }
echo "fixture: fake server on $BASE answered 200 and logged the probe"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
arrived() { # $1 case name -> asserts >=1 request arrived (fixture before verdict)
  if [ -s "$LOG" ]; then return 0; fi
  fail "$1: FIXTURE — no request reached the fake server, the verdict below would be vacuous"; return 1
}
reqs() { grep -c . "$LOG"; }
set_spec() { printf '%s\n' "$@" > "$SPEC"; : > "$LOG"; }
now() { python3 -c 'import time;print(time.time())'; }
elapsed_ge() { python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])-float(sys.argv[2])>=float(sys.argv[3]) else 1)' "$1" "$2" "$3"; }
elapsed_lt() { python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])-float(sys.argv[2])<float(sys.argv[3]) else 1)' "$1" "$2" "$3"; }

# shellcheck disable=SC1090
. "$HELPER"

echo "case 1: 429 (Retry-After: 1) then 200 — retried, the 200 is what comes back"
set_spec '429|1|{"error":{"code":"rate_limited","details":{"retry_after":1}}}' '200||{"ok":true}'
t0="$(now)"; code="$(bp_curl_code -sS -m 5 -o "$TMP/b1" "$BASE/v1/tasks" 2>"$TMP/e1")"; rc=$?; t1="$(now)"
arrived "case 1" && {
  [ "$code" = "200" ] && ok "final code 200 (rc=$rc)" || fail "final code '$code' rc=$rc, expected 200"
  [ "$(reqs)" = 2 ] && ok "exactly 2 requests arrived (the retry happened)" || fail "$(reqs) requests arrived, expected 2"
  grep -q 'waiting 1s (the server asked for it)' "$TMP/e1" && ok "stderr names the 1s the server asked for" || { fail "stderr lacks the 1s line"; cat "$TMP/e1"; }
  grep -q '"ok":true' "$TMP/b1" && ok "-o file holds the FINAL body" || fail "-o file does not hold the 200 body"
  elapsed_ge "$t1" "$t0" 1 && ok "elapsed >= 1s (the sleep was real)" || fail "elapsed < 1s: no sleep happened"
}

echo "case 2: 500 is NOT retried"
set_spec '500||{"error":"boom"}' '200||{"ok":true}'
code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/tasks" 2>"$TMP/e2")"
arrived "case 2" && {
  [ "$code" = "500" ] && ok "code 500 returned as-is" || fail "code '$code', expected 500"
  [ "$(reqs)" = 1 ] && ok "exactly 1 request (no retry on 500)" || fail "$(reqs) requests, expected 1"
  ! grep -q 'waiting' "$TMP/e2" && ok "no waiting line on a 500" || fail "a 500 produced a waiting line"
}

echo "case 3: the header VALUE is the one honoured — Retry-After: 2 sleeps 2s, Retry-After: 0 sleeps 0s"
set_spec '429|2|{}' '200||{"ok":true}'
t0="$(now)"; code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/x" 2>"$TMP/e3a")"; t1="$(now)"
arrived "case 3a" && {
  [ "$code" = 200 ] && ok "3a: 200 after the 429" || fail "3a: code '$code'"
  grep -q 'waiting 2s (the server asked for it)' "$TMP/e3a" && ok "3a: stderr says waiting 2s" || { fail "3a: stderr does not say 2s"; cat "$TMP/e3a"; }
  elapsed_ge "$t1" "$t0" 2 && ok "3a: elapsed >= 2s" || fail "3a: elapsed < 2s"
}
set_spec '429|0|{}' '200||{"ok":true}'
t0="$(now)"; code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/x" 2>"$TMP/e3b")"; t1="$(now)"
arrived "case 3b" && {
  grep -q 'waiting 0s (the server asked for it)' "$TMP/e3b" && ok "3b: stderr says waiting 0s" || { fail "3b: stderr does not say 0s"; cat "$TMP/e3b"; }
  elapsed_lt "$t1" "$t0" 1 && ok "3b: elapsed < 1s (a hardcoded 1s sleep would fail here)" || fail "3b: elapsed >= 1s"
}

echo "case 4: body error.details.retry_after (no header) is honoured even under -o /dev/null, and body wins over header"
set_spec '429||{"error":{"code":"rate_limited","details":{"retry_after":"2"}}}' '200||{"ok":true}'
t0="$(now)"; code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/y" 2>"$TMP/e4")"; t1="$(now)"
arrived "case 4" && {
  grep -q 'waiting 2s (the server asked for it)' "$TMP/e4" && ok "4a: body retry_after 2 -> waiting 2s" || { fail "4a: stderr lacks 2s"; cat "$TMP/e4"; }
  elapsed_ge "$t1" "$t0" 2 && ok "4a: elapsed >= 2s" || fail "4a: elapsed < 2s"
}
set_spec '429|3|{"error":{"details":{"retry_after":0}}}' '200||{"ok":true}'
code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/y" 2>"$TMP/e4b")"
arrived "case 4b" && { grep -q 'waiting 0s' "$TMP/e4b" && ok "4b: body 0 wins over header 3" || { fail "4b: body did not win"; cat "$TMP/e4b"; }; }

echo "case 5: no retry_after anywhere -> the 1s default, named as ours"
set_spec '429||{}' '200||{"ok":true}'
code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/z" 2>"$TMP/e5")"
arrived "case 5" && { grep -q 'waiting 1s (no retry_after given, using our default)' "$TMP/e5" && ok "default 1s named as ours" || { fail "default line missing"; cat "$TMP/e5"; }; }

echo "case 6: Retry-After: 3600 is a quota — reported unslept, 429 returned, one request"
set_spec '429|3600|{}' '200||{"ok":true}'
t0="$(now)"; code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/q" 2>"$TMP/e6")"; t1="$(now)"
arrived "case 6" && {
  [ "$code" = 429 ] && ok "429 surfaces to the caller" || fail "code '$code', expected 429"
  [ "$(reqs)" = 1 ] && ok "exactly 1 request" || fail "$(reqs) requests"
  grep -q 'BP-CURL-RATE-LIMITED' "$TMP/e6" && ok "BP-CURL-RATE-LIMITED line emitted" || fail "no RATE-LIMITED line"
  grep -q 'longer than this program will ever wait' "$TMP/e6" && ok "give-up names the ceiling" || fail "give-up reason missing"
  elapsed_lt "$t1" "$t0" 2 && ok "elapsed < 2s (not slept)" || fail "slept on a 3600"
}

echo "case 7: the attempt cap bounds the loop — 429/Retry-After:0 forever -> exactly BP_CURL_ATTEMPTS requests"
set_spec '429|0|{}'
code="$(bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/cap" 2>"$TMP/e7")"
arrived "case 7" && {
  [ "$(reqs)" = "$BP_CURL_ATTEMPTS" ] && ok "$(reqs) requests = BP_CURL_ATTEMPTS ($BP_CURL_ATTEMPTS)" || fail "$(reqs) requests, expected $BP_CURL_ATTEMPTS"
  [ "$code" = 429 ] && ok "429 returned after the cap" || fail "code '$code'"
  grep -q 'attempt cap of 4 is spent' "$TMP/e7" && ok "give-up names the attempt cap" || fail "cap reason missing"
}

echo "case 8: the total-wait ceiling bounds the loop — ceiling 1, Retry-After:1 -> 2 requests"
set_spec '429|1|{}'
code="$(BP_CURL_MAX_TOTAL_WAIT_S=1 bp_curl_code -sS -m 5 -o /dev/null "$BASE/v1/tot" 2>"$TMP/e8")"
arrived "case 8" && {
  [ "$(reqs)" = 2 ] && ok "2 requests (one 1s wait fits, a second would exceed 1s)" || fail "$(reqs) requests, expected 2"
  grep -q 'total-wait budget' "$TMP/e8" && ok "give-up names the total-wait budget" || fail "budget reason missing"
}

echo "case 9: the flags the helper owns are refused (CANNOT + 64), no request sent"
set_spec '200||{}'
for bad in -w -f --fail -D -sSf -fsSL; do
  out="$(bp_curl_code "$bad" x -sS -m 5 -o /dev/null "$BASE/v1/r" 2>&1)"; rc=$?
  [ "$rc" = 64 ] && printf '%s' "$out" | grep -q 'CANNOT run' && ok "'$bad' refused with CANNOT and 64" || fail "'$bad': rc=$rc out=$out"
done
[ ! -s "$LOG" ] && ok "no request reached the server during refusals" || fail "a refused call still sent a request"
out="$(bp_curl_code -sS -m 5 -o /dev/null -XPOST "$BASE/v1/r" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = 200 ] && ok "control: '-XPOST' (no f/w/D) is NOT refused" || fail "control: -XPOST refused or failed: rc=$rc out=$out"

echo "case 10: bp_curl_body — 2xx body on stdout + 0; 404 -> empty + 22; 429 then 200 -> body"
set_spec '200||{"docs":[1,2]}'
out="$(bp_curl_body -sS -m 5 "$BASE/v1/b" 2>"$TMP/e10a")"; rc=$?
arrived "case 10a" && { [ "$rc" = 0 ] && [ "$out" = '{"docs":[1,2]}' ] && ok "200 body on stdout, rc 0" || fail "rc=$rc out='$out'"; }
set_spec '404||{"error":"nope"}'
out="$(bp_curl_body -sS -m 5 "$BASE/v1/b" 2>"$TMP/e10b")"; rc=$?
arrived "case 10b" && {
  [ "$rc" = 22 ] && ok "404 -> rc 22 (curl -f's own code)" || fail "404 rc=$rc"
  [ -z "$out" ] && ok "404 -> nothing on stdout" || fail "404 leaked a body: '$out'"
  grep -q 'HTTP 404' "$TMP/e10b" && ok "404 named on stderr" || fail "status not named"
}
set_spec '429|0|{}' '200||{"after":"429"}'
out="$(bp_curl_body -sS -m 5 "$BASE/v1/b" 2>"$TMP/e10c")"; rc=$?
arrived "case 10c" && { [ "$rc" = 0 ] && [ "$out" = '{"after":"429"}' ] && [ "$(reqs)" = 2 ] && ok "429 then 200 -> the 200 body, 2 requests" || fail "rc=$rc out='$out' reqs=$(reqs)"; }
set_spec '200||{"posted":true}'
out="$(bp_curl_body -sS -m 5 -X POST -H 'Content-Type: application/json' --data '{"a":1}' "$BASE/v1/mut" 2>&1)"; rc=$?
arrived "case 10d" && { [ "$rc" = 0 ] && grep -q '^POST /v1/mut$' "$LOG" && ok "POST with --data reaches the server as POST" || fail "POST: rc=$rc out=$out log=$(cat "$LOG")"; }

echo "case 11: transport failure — nothing on stdout, curl's rc, so '|| echo 000' yields a clean 000"
dead="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
out="$(bp_curl_code -sS -m 3 -o /dev/null "http://127.0.0.1:$dead/v1/x" 2>/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok "closed port: rc=$rc, stdout empty" || fail "closed port: rc=$rc out='$out'"
out="$(bp_curl_code -sS -m 3 -o /dev/null "http://127.0.0.1:$dead/v1/x" 2>/dev/null || echo 000)"
[ "$out" = "000" ] && ok "the || echo 000 idiom yields exactly 000 (not 000000)" || fail "idiom yields '$out'"
out="$(bp_curl_body -sS -m 3 "http://127.0.0.1:$dead/v1/x" 2>/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$rc" != 22 ] && [ -z "$out" ] && ok "bp_curl_body: transport rc=$rc (not 22), stdout empty" || fail "bp_curl_body transport: rc=$rc out='$out'"

echo "case 12: MUTATION — a helper that ignores the response's retry_after reds case 3a"
MUT="$TMP/bp-curl-mutant.sh"
sed 's|asked="$(bp_curl__retry_after "$body" "$hdr")"|asked=1|' "$HELPER" > "$MUT"
if diff -q "$HELPER" "$MUT" >/dev/null; then fail "the mutation anchor matched nothing — the mutant is byte-identical"; else
  [ "$(grep -c 'asked=1$' "$MUT")" = 1 ] && ok "mutation anchor matched exactly once" || fail "mutation anchor matched $(grep -c 'asked=1$' "$MUT") times"
  set_spec '429|2|{}' '200||{"ok":true}'
  t0="$(now)"; mout="$(bash -c ". '$MUT'; bp_curl_code -sS -m 5 -o /dev/null '$BASE/v1/x'" 2>"$TMP/e12")"; t1="$(now)"
  arrived "case 12" && {
    [ "$mout" = 200 ] && ok "mutant still returns 200 (it retries — the OLD detector, code alone, stays green)" || fail "mutant code '$mout'"
    ! grep -q 'waiting 2s' "$TMP/e12" && grep -q 'waiting 1s' "$TMP/e12" && ok "detector reds: the mutant says 'waiting 1s' against a Retry-After: 2" || { fail "the mutant was not caught"; cat "$TMP/e12"; }
    elapsed_lt "$t1" "$t0" 2 && ok "detector reds: elapsed < 2s under the mutant" || fail "mutant elapsed >= 2s"
  }
fi

echo
echo "bp-curl.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
