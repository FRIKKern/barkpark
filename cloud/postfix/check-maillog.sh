#!/usr/bin/env bash
# Guards the ONE fact this relay's observability rests on: Postfix's delivery
# log leaves the container. It did not, for two months — the image has no
# syslog daemon, maillog_file was empty, and `docker logs` held 1262 bytes of
# entrypoint banner and zero status= lines, which made "did that email
# arrive?" unanswerable server-side.
#
#   ./check-maillog.sh          static assertions only (what CI runs)
#   ./check-maillog.sh --live   also builds the image, boots a throwaway
#                               container, submits a real authenticated
#                               message over 587, and asserts a real
#                               `status=sent` line comes out of docker logs.
#
# The --live arm is the one that matters: a config change with no OBSERVED log
# line is exactly the failure mode this script exists to prevent, so the static
# arm alone is never sufficient evidence.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$HERE/entrypoint.sh"
COMPOSE="$HERE/../docker-compose.yml"
fails=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

echo "== static =="

# 1. The setting exists at all.
if grep -qE '^postconf -e "maillog_file = ' "$ENTRYPOINT"; then
  pass "entrypoint.sh sets maillog_file"
else
  fail "entrypoint.sh does NOT set maillog_file — the relay logs nothing"
fi

# 2. Its value is one Postfix will accept. maillog_file_prefixes defaults to
#    "/var, /dev/stdout"; a path outside those is REFUSED at startup, and a
#    path Postfix accepts but nothing reads (a file on no volume) is the same
#    silent nothing we started with.
val="$(sed -n 's/^postconf -e "maillog_file = \(.*\)"$/\1/p' "$ENTRYPOINT")"
case "$val" in
  *'/dev/stdout'*) pass "maillog_file resolves to /dev/stdout (reaches docker logs): $val" ;;
  /var/*)          pass "maillog_file is under /var, an allowed prefix: $val" ;;
  *)               fail "maillog_file='$val' is outside maillog_file_prefixes (/var, /dev/stdout)" ;;
esac

# 3. The entrypoint must not disable the postlog service while stripping
#    master.cf listeners — postlogd is what maillog_file routes through, and
#    Postfix FATALs at boot without it.
if grep -qE '^sed -i.*postlog' "$ENTRYPOINT"; then
  fail "entrypoint.sh edits the postlog line in master.cf — postlogd is required by maillog_file"
else
  pass "entrypoint.sh leaves master.cf's postlog service alone"
fi

# 4. Now that the container logs per message, its log must be capped.
if [ -f "$COMPOSE" ] && awk '/^  postfix:/{f=1} f&&/max-size/{print;exit} f&&/^  [a-z_]+:/&&!/^  postfix:/{exit}' "$COMPOSE" | grep -q max-size; then
  pass "docker-compose.yml caps the postfix container log size"
else
  fail "docker-compose.yml does not cap the postfix log — it now grows per message"
fi

if [ "${1:-}" != "--live" ]; then
  echo
  [ "$fails" -eq 0 ] && echo "static checks passed ($fails failures). Re-run with --live to OBSERVE a status= line." \
                     || echo "$fails static failure(s)."
  exit $((fails > 0))
fi

echo
echo "== live (builds an image and boots a throwaway container) =="
command -v docker >/dev/null || { echo "  FAIL docker not available"; exit 1; }

IMG="bp-postfix-maillog-check:$$"
CNT="bp-postfix-maillog-check-$$"
PORT="${MAILLOG_CHECK_PORT:-15870}"
cleanup() { docker rm -f "$CNT" >/dev/null 2>&1 || true; docker rmi -f "$IMG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker build -q -t "$IMG" "$HERE" >/dev/null
docker run -d --name "$CNT" -p "$PORT:587" \
  -e SMTP_USERNAME=probe -e SMTP_PASSWORD=probepass \
  -e MAIL_HOSTNAME=mail.example.test -e MAIL_DOMAIN=example.test \
  "$IMG" >/dev/null

# Wait for the master to announce itself ON STDOUT. If maillog_file is broken
# this banner never appears and the check times out — which is the detection,
# not an infrastructure flake.
for _ in $(seq 1 60); do
  docker logs "$CNT" 2>&1 | grep -q 'postfix/master.*daemon started' && break
  sleep 1
done
if docker logs "$CNT" 2>&1 | grep -q 'postfix/master.*daemon started'; then
  pass "postfix/master 'daemon started' reached docker logs"
else
  fail "no postfix log line ever reached docker logs"
  docker logs "$CNT" 2>&1 | tail -20
  exit 1
fi

# Deliver to root@localhost: mydestination=localhost, so the local agent
# accepts it and emits a genuine status=sent without needing port 25 egress.
python3 - "$PORT" <<'PY'
import smtplib, ssl, sys
from email.message import EmailMessage
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
m = EmailMessage()
m["From"] = "noreply@example.test"; m["To"] = "root@localhost"
m["Subject"] = "maillog check"
m.set_content("delivery-log observability check")
s = smtplib.SMTP("127.0.0.1", int(sys.argv[1]), timeout=30)
s.ehlo("check.local"); s.starttls(context=ctx); s.ehlo("check.local")
s.login("probe@mail.example.test", "probepass")
s.send_message(m); s.quit()
PY

for _ in $(seq 1 30); do
  docker logs "$CNT" 2>&1 | grep -q 'status=sent' && break
  sleep 1
done

if line="$(docker logs "$CNT" 2>&1 | grep -m1 'status=sent')"; then
  pass "observed a real delivery line:"
  printf '       %s\n' "$line"
else
  fail "message submitted but NO status= line appeared — the log is still going nowhere"
  docker logs "$CNT" 2>&1 | tail -30
fi

# The submission hop must be visible too — a missing status= line is only
# diagnosable if you can tell "never arrived" from "arrived and failed".
if docker logs "$CNT" 2>&1 | grep -q 'postfix/submission/smtpd.*sasl_username='; then
  pass "the authenticated submission hop is logged too"
else
  fail "no postfix/submission/smtpd line — submission failures stay invisible"
fi

echo
[ "$fails" -eq 0 ] && echo "all checks passed." || echo "$fails failure(s)."
exit $((fails > 0))
