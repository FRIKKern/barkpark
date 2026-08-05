#!/usr/bin/env bash
# Behavioral harness for deploy.sh's health-probe -> banner -> exit-code chain.
#
# The defect this pins: deploy.sh polled the API 30 times, and on 30 consecutive
# FAILURES fell through silently — no flag, no marker — after which the closing
# banner printed "  Barkpark is running!" unconditionally and the script exited
# 0. The measurement was taken and discarded. deploy.sh is go:embedded into `bp`
# (Makefile cli-assets-sync), so that sentence is what every curl-installed
# first-time server prints.
#
# It runs the REAL code: both sections are sliced out of deploy.sh itself by
# their section headers and executed, so a regression in deploy.sh reds here.
# The slice is fail-closed — if the headers move, extraction asserts and fails
# rather than silently testing nothing.
#
# The cases:
#   (a) CONTROL, pre-fix: the same slice taken from a PINNED REVISION prints
#       the banner and exits 0 over a dead port. This is what "reds before the
#       fix" means, kept permanently: if the assertions below ever stop
#       distinguishing old from new, THIS case fails loudly.
#
#       THE REVISION IS PINNED, NOT `origin/main` — that was a time bomb. The
#       control rewrites the pre-fix slice with three mandatory substitutions
#       ("localhost:4000", "seq 1 30", "sleep 2"), all of which this very slice
#       REMOVES from deploy.sh. So the first time the fix reached main,
#       `origin/main:deploy.sh` would no longer match, retarget_prefix_control
#       would FATAL, and the whole harness would exit 1 on every subsequent
#       run — a permanent red produced by the fix succeeding. A control has to
#       name the artifact it is a control FOR, and that artifact does not move.
#   (b) UNHEALTHY: dead port -> honest failure banner naming the port probed
#       and journalctl, and a NON-ZERO exit.
#   (c) HEALTHY: a server answering 200 -> "Ready!", today's banner, exit 0.
#   (d) SICK: a server answering 500 -> counted as unhealthy (the probe measures
#       a healthy response, not merely a reachable socket).
#
# `hostname` is shimmed on PATH in every case: deploy.sh's banner section runs
# `hostname -I`, which is Linux-only and, under `set -e`, dies ONE LINE BEFORE
# the banner on macOS — which reads as a fail-closed script and is not.
#
# Templated on scripts/install-cli.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEPLOY="$ROOT/deploy.sh"

fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

TMP="$(mktemp -d)"
cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  chmod -R u+w "$TMP" 2>/dev/null || true
  find "$TMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

# ── A PATH-only bin dir whose `hostname` answers like Linux's. ───────────────
FAKE="$TMP/fakebin"
mkdir -p "$FAKE"
cat > "$FAKE/hostname" <<'EOF'
#!/usr/bin/env bash
echo "203.0.113.7 fe80::1"
EOF
chmod +x "$FAKE/hostname"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# ── Slice the two real sections out of a deploy.sh and make them runnable. ───
# $1 = source deploy.sh, $2 = output script. Everything the sections read from
# the surrounding script is supplied by a prelude, so the slice is the ONLY
# code under test.
slice() {
  local src="$1" out="$2"
  local health done_sec
  health="$(awk '/^# ── 11\. Wait for healthy/{f=1} /^# ── 12\. TLS/{f=0} f' "$src")"
  done_sec="$(awk '/^# ── Done/{f=1} f' "$src")"

  # Fail-closed: a renamed section header must red HERE, not quietly test air.
  case "$health" in
    *"/api/schemas"*) : ;;
    *) echo "FATAL: health section not found in $src (section header moved?)"; exit 1 ;;
  esac
  case "$done_sec" in
    *"Barkpark is running!"*) : ;;
    *) echo "FATAL: banner section not found in $src (section header moved?)"; exit 1 ;;
  esac

  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'APP_DIR="%s"\n' "$TMP/app"
    printf 'DOMAIN="deploy-harness.invalid"\n'
    printf 'PHX_SCHEME="http"\n'
    printf 'TLS_READY=""\n'
    printf 'ADMIN_TOKEN="bp_admin_HARNESS"\n'
    printf 'APP_PORT="${APP_PORT:-4000}"\n'
    printf 'HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-3}"\n'
    printf 'HEALTH_INTERVAL="${HEALTH_INTERVAL:-1}"\n'
    printf '%s\n' "$health"
    printf '%s\n' "$done_sec"
  } > "$out"
}

# The pre-fix control needs two mechanical edits and NOTHING else: its loop is
# hardcoded to 30 iterations × 2s (60s per case) and to port 4000, which may be
# a live dev server on the machine running this. Both substitutions are
# asserted, so an unmatched sed can never quietly turn this case vacuous.
retarget_prefix_control() {
  local f="$1" port="$2"
  python3 - "$f" "$port" <<'PY'
import sys
path, port = sys.argv[1], sys.argv[2]
src = open(path).read()
subs = [("localhost:4000", "localhost:%s" % port), ("seq 1 30", "seq 1 3"), ("sleep 2", "sleep 1")]
for old, new in subs:
    if old not in src:
        sys.exit("FATAL: pre-fix control substitution %r did not match" % old)
    src = src.replace(old, new)
open(path, "w").write(src)
PY
}

run_slice() {
  # $1 = slice, $2 = APP_PORT, $3 = output file. Real loop, shimmed hostname.
  PATH="$FAKE:$PATH" APP_PORT="$2" HEALTH_ATTEMPTS=3 HEALTH_INTERVAL=1 \
    bash "$1" > "$3" 2>&1
}

mkdir -p "$TMP/app"
printf 'PORT=4000\n' > "$TMP/app/.env"

DEAD_PORT="$(free_port)"   # nothing bound: free_port closed the socket

# ── (a) CONTROL — the pre-fix script lies over a dead port ───────────────────
#
# PREFIX_REV is the last revision in which deploy.sh carried the defect: the
# 30-probe loop whose result nothing read. It is a fixed point in history, so
# this case keeps proving the same thing after the fix merges. Do NOT replace it
# with a branch name — see the header. Repointing it is only correct if the
# defect is re-introduced and re-fixed, which would be a new revision to pin.
PREFIX_REV="${PREFIX_REV:-5a7aa8616a0c84cb7bd9447847ea207f1e37bc76}"
echo "== (a) control: deploy.sh at $PREFIX_REV (pre-fix), dead port =="
if git -C "$ROOT" show "$PREFIX_REV:deploy.sh" > "$TMP/prefix-deploy.sh" 2>/dev/null; then
  slice "$TMP/prefix-deploy.sh" "$TMP/prefix.sh"
  retarget_prefix_control "$TMP/prefix.sh" "$DEAD_PORT" || exit 1
  PATH="$FAKE:$PATH" bash "$TMP/prefix.sh" > "$TMP/a.out" 2>&1
  a_rc=$?
  check "(a) pre-fix printed NO '   Ready!' (the probe failed every time)" \
    '! grep -q "Ready!" "$TMP/a.out"'
  check "(a) pre-fix printed the success banner anyway — the defect" \
    'grep -q "Barkpark is running!" "$TMP/a.out"'
  check "(a) pre-fix exited 0 over a dead API — the defect" "[ $a_rc -eq 0 ]"
else
  # Fail-closed, and name the likely cause: a shallow clone (CI's default
  # fetch-depth: 1) cannot reach a pinned historical revision.
  fail "(a) could not read $PREFIX_REV:deploy.sh — shallow clone? (needs fetch-depth: 0)"
fi

# ── (b) UNHEALTHY — the current script refuses ───────────────────────────────
echo "== (b) current: dead port =="
slice "$DEPLOY" "$TMP/cur.sh"
run_slice "$TMP/cur.sh" "$DEAD_PORT" "$TMP/b.out"
b_rc=$?
check "(b) no '   Ready!' line" '! grep -q "Ready!" "$TMP/b.out"'
check "(b) does NOT claim Barkpark is running" '! grep -q "Barkpark is running!" "$TMP/b.out"'
check "(b) says it is not answering" 'grep -q "NOT ANSWERING" "$TMP/b.out"'
check "(b) names the port it probed" 'grep -q "localhost:$DEAD_PORT/api/schemas" "$TMP/b.out"'
check "(b) offers journalctl as the next step" 'grep -q "journalctl -u barkpark" "$TMP/b.out"'
check "(b) still prints the once-only admin token" 'grep -q "bp_admin_HARNESS" "$TMP/b.out"'
check "(b) exits non-zero" "[ $b_rc -ne 0 ]"

# ── (c) HEALTHY — a server that answers 200 ──────────────────────────────────
echo "== (c) current: server answering 200 =="
OK_PORT="$(free_port)"
python3 - "$OK_PORT" 200 > "$TMP/srv.log" 2>&1 <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
code = int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"schemas":[]}')
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
SERVER_PID=$!
disown $SERVER_PID 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fs "http://localhost:$OK_PORT/api/schemas" >/dev/null 2>&1 && break
  sleep 0.3
done
run_slice "$TMP/cur.sh" "$OK_PORT" "$TMP/c.out"
c_rc=$?
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
check "(c) printed '   Ready!'" 'grep -q "Ready!" "$TMP/c.out"'
check "(c) printed the success banner" 'grep -q "Barkpark is running!" "$TMP/c.out"'
check "(c) did NOT print the failure banner" '! grep -q "NOT ANSWERING" "$TMP/c.out"'
check "(c) printed URLs on the port it probed" 'grep -q ":$OK_PORT/studio" "$TMP/c.out"'
check "(c) exits 0" "[ $c_rc -eq 0 ]"

# ── (d) SICK — a reachable socket that answers 500 is NOT healthy ────────────
echo "== (d) current: server answering 500 =="
SICK_PORT="$(free_port)"
python3 - "$SICK_PORT" 500 > "$TMP/srv2.log" 2>&1 <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
code = int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b'boom')
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
SERVER_PID=$!
disown $SERVER_PID 2>/dev/null || true
sleep 1
run_slice "$TMP/cur.sh" "$SICK_PORT" "$TMP/d.out"
d_rc=$?
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
check "(d) a 500 is not 'Ready!'" '! grep -q "Ready!" "$TMP/d.out"'
check "(d) refuses with the failure banner" 'grep -q "NOT ANSWERING" "$TMP/d.out"'
check "(d) exits non-zero" "[ $d_rc -ne 0 ]"

# ── (e) STATIC — the probe target is derived, not hardcoded ──────────────────
echo "== (e) static: no hardcoded probe port =="
check "(e) no 'localhost:4000' anywhere in deploy.sh" \
  '! grep -n "localhost:4000" "$DEPLOY"'
check "(e) the probe URL is built from \$APP_PORT" \
  'grep -q "localhost:\$APP_PORT/api/schemas" "$DEPLOY"'
check "(e) APP_PORT is re-read from the .env the service sources" \
  'grep -q "sed -n .s/\^PORT=//p" "$DEPLOY"'

echo ""
if [ "$fails" -eq 0 ]; then
  echo "deploy-health-banner: ALL CHECKS PASSED"
  exit 0
fi
echo "deploy-health-banner: $fails CHECK(S) FAILED"
exit 1
