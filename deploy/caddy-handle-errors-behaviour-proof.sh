#!/usr/bin/env bash
# MEASURES the handle_errors status-list incident on a REAL Caddy. Not a grep.
#
# WHY THIS EXISTS. deploy/caddy/barkpark-maintenance.caddy states the incident as
# fact ("every miss on every spawned static site answered this 503 instead of
# 404") and deploy/caddy-handle-errors-scope-check.sh enforces the fix as a
# repo-wide predicate. Both are STATIC: one is prose, the other is a grep. Until
# this script, nothing in the tree had ever OBSERVED the behaviour the fix is
# for. The filing row (task-d06e8a2a42f1ed2f) says so in its own words: "I did
# not walk a live box. The reachability above is read off the code paths, not
# observed." A rule nobody has watched fire is a belief.
#
# WHAT IT PROVES, on one real caddy binary, in one run, two arms:
#   ARM BARE   — `handle_errors {`             : a file_server 404 inside an
#                armed `handle_path /sites/<slug>/*` is SWALLOWED and answers the
#                branded 503. This is the incident, reproduced.
#   ARM SCOPED — `handle_errors 502 503 504 {` : the same request answers 404.
#                The maintenance page still fires on the dead upstream (503), so
#                the fix costs nothing it was there to do.
# Plus two CONTROLS that must behave IDENTICALLY under both arms, so a green is
# never "the scoped config simply serves less":
#   CONTROL HIT  — an existing static file answers 200 under BOTH arms.
#   CONTROL DEAD — a request to the proxied path answers 503 under BOTH arms.
#
# Usage:  bash deploy/caddy-handle-errors-behaviour-proof.sh
# Exit 0 = every expectation met. Exit 1 = a mismatch (printed) or a broken rig.
# Exit 0 with a loud SKIP banner if no `caddy` binary is on PATH — CI runners
# have none, and a skip that is silent is the same failure this file is about.
set -euo pipefail

if ! command -v caddy >/dev/null 2>&1; then
  echo "[handle_errors-behaviour] SKIPPED — no \`caddy\` on PATH."
  echo "  This proof needs a real Caddy (>=2.x). Install it and re-run; it is NOT"
  echo "  a substitute for deploy/caddy-handle-errors-scope-check.sh, which is the"
  echo "  standing gate and needs no binary."
  exit 0
fi
echo "[handle_errors-behaviour] caddy: $(caddy version | head -1)"

RIG="$(mktemp -d "${TMPDIR:-/tmp}/bp-handle-errors-proof.XXXXXX")"
PIDFILE="$RIG/caddy.pid"
cleanup() {
  if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
  rm -rf "$RIG"
}
trap cleanup EXIT

# A port nothing listens on: the "upstream is down" half of the rig.
DEAD_PORT=45999
# The site port. Picked high and checked, not assumed free.
SITE_PORT=45871
while nc -z 127.0.0.1 "$SITE_PORT" 2>/dev/null; do SITE_PORT=$((SITE_PORT + 1)); done
if nc -z 127.0.0.1 "$DEAD_PORT" 2>/dev/null; then
  echo "[handle_errors-behaviour] FAIL (broken rig) — something is LISTENING on the"
  echo "  designated dead upstream port $DEAD_PORT. The 'upstream down' arm would be"
  echo "  measuring that process, not a dial failure."
  exit 1
fi

mkdir -p "$RIG/root"
printf 'static site index\n' > "$RIG/root/index.html"
# NOTE: no missing.css is created. That miss is the subject of the whole proof.

render() { # $1 = handle_errors header line
  cat <<EOF
{
	auto_https off
	admin off
}
http://127.0.0.1:$SITE_PORT {
	handle_path /sites/demo/* {
		root * $RIG/root
		file_server
	}
	reverse_proxy 127.0.0.1:$DEAD_PORT
	$1
		header Retry-After "15"
		header Content-Type "text/html; charset=utf-8"
		respond 503 {
			body "BARKPARK_MAINTENANCE_PAGE"
			close
		}
	}
}
EOF
}

boot() { # $1 = config path
  caddy run --adapter caddyfile --config "$1" >"$RIG/caddy.log" 2>&1 &
  echo $! > "$PIDFILE"
  local i
  for i in $(seq 1 60); do
    if nc -z 127.0.0.1 "$SITE_PORT" 2>/dev/null; then return 0; fi
    sleep 0.25
  done
  echo "[handle_errors-behaviour] FAIL (broken rig) — caddy never listened on $SITE_PORT."
  sed -n '1,40p' "$RIG/caddy.log"
  return 1
}
halt() {
  [ -f "$PIDFILE" ] || return 0
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  wait "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
  local i
  for i in $(seq 1 40); do
    nc -z 127.0.0.1 "$SITE_PORT" 2>/dev/null || return 0
    sleep 0.25
  done
  return 0
}

status_of() { curl -s -o "$RIG/body.out" -w '%{http_code}' "http://127.0.0.1:$SITE_PORT$1"; }

fails=0
probe() { # $1 arm  $2 label  $3 path  $4 expected status
  local got; got="$(status_of "$3")"
  if [ "$got" = "$4" ]; then
    printf '    %-7s %-13s GET %-28s -> %s  (expected %s)  OK\n' "$1" "$2" "$3" "$got" "$4"
  else
    printf '    %-7s %-13s GET %-28s -> %s  (expected %s)  *** MISMATCH ***\n' "$1" "$2" "$3" "$got" "$4"
    echo "      body was: $(head -c 120 "$RIG/body.out")"
    fails=$((fails + 1))
  fi
}

echo "[handle_errors-behaviour] rig: dead upstream 127.0.0.1:$DEAD_PORT, site http://127.0.0.1:$SITE_PORT"
echo "[handle_errors-behaviour] route under test: handle_path /sites/demo/* { root * <rig>; file_server }"
echo

render 'handle_errors {' > "$RIG/bare.caddy"  # handle-errors-scope-check: deliberate-bare
render 'handle_errors 502 503 504 {' > "$RIG/scoped.caddy"

echo "  ARM BARE   — handle_errors {           (the pre-fix shape)"  # handle-errors-scope-check: deliberate-bare
boot "$RIG/bare.caddy"
probe BARE   "INCIDENT"    /sites/demo/missing.css  503
probe BARE   "CONTROL HIT" /sites/demo/index.html   200
probe BARE   "CONTROL DEAD" /                       503
halt
echo

echo "  ARM SCOPED — handle_errors 502 503 504 {   (the fix)"
boot "$RIG/scoped.caddy"
probe SCOPED "INCIDENT"    /sites/demo/missing.css  404
probe SCOPED "CONTROL HIT" /sites/demo/index.html   200
probe SCOPED "CONTROL DEAD" /                       503
halt
echo

if [ "$fails" -gt 0 ]; then
  echo "[handle_errors-behaviour] FAIL — $fails expectation(s) unmet."
  exit 1
fi
echo "[handle_errors-behaviour] OK — the bare form swallows a file_server 404 into the"
echo "  branded 503; the status-scoped form lets it be a 404 while keeping the branded"
echo "  503 on the dead upstream. Both controls behaved identically under both arms, so"
echo "  the difference is the status list and nothing else."
exit 0
