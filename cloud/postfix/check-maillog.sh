#!/usr/bin/env bash
# Guards the ONE fact this relay's observability rests on: Postfix's delivery
# log leaves the container. It did not, for two months — the image has no
# syslog daemon, maillog_file was empty, and `docker logs` held 1262 bytes of
# entrypoint banner and zero status= lines, which made "did that email
# arrive?" unanswerable server-side.
#
#   ./check-maillog.sh             static assertions only (what CI runs)
#   ./check-maillog.sh --live      also builds the image, boots a throwaway
#                                  container, submits a real authenticated
#                                  message over 587, and asserts a real
#                                  `status=sent` line comes out of docker logs.
#   ./check-maillog.sh --recreate  --live, and then DESTROYS the container and
#                                  boots a new one on the same named volume,
#                                  asserting the earlier delivery line is STILL
#                                  readable. This is the dr-w26 guard: a
#                                  control-plane deploy recreates this service
#                                  and `docker logs` is per-container, so once
#                                  a writer exists its whole output goes with
#                                  the container on the next deploy.
#
# The --live/--recreate arms are the ones that matter: a config change with no
# OBSERVED log line is exactly the failure mode this script exists to prevent,
# so the static arm alone is never sufficient evidence.
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
# The postconf line interpolates $MAILLOG_FILE, so the value to judge is that
# variable's DEFAULT — what the container uses when compose sets nothing.
# shellcheck disable=SC2016  # the sed script is literal on purpose: it MATCHES the
# text `${MAILLOG_FILE:=...}` in entrypoint.sh; expanding it here would read
# this script's own environment instead of the file's default.
val="$(sed -n 's/^: "\${MAILLOG_FILE:=\(.*\)}"$/\1/p' "$ENTRYPOINT")"
case "$val" in
  '')              fail "entrypoint.sh has no MAILLOG_FILE default — cannot tell where the log goes" ;;
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

# 5. dr-w26 — THE DURABILITY CHECK, the one this file previously did not make.
#    Checks 1-4 only prove the log is WRITTEN and CAPPED; they are all
#    satisfied by a log that a deploy deletes. `docker logs` is per-container
#    state (/var/lib/docker/containers/<id>/), and deploy/cp-deploy.sh's
#    `compose_up_repair "db/postfix up" db postfix` recreates this service on
#    any image or config change. The 2026-08-08 23:51Z cutover did exactly
#    that, and `docker logs` read 7 lines after it — though that day's 30
#    outage alerts were never logged in the first place (maillog_file EMPTY,
#    no syslog), so what that cutover proves is the MECHANISM, not a specific
#    loss. Now that a writer exists, the loss is the live risk. So the default
#    log path must sit on a directory compose mounts from a NAMED VOLUME,
#    which a recreate does not touch. Both halves are asserted: the
#    entrypoint's default, and the mount that makes it durable.
if [ "$val" = "/dev/stdout" ]; then
  fail "MAILLOG_FILE defaults to /dev/stdout — the log dies with the container on the next deploy"
elif [ ! -f "$COMPOSE" ]; then
  fail "cannot read $COMPOSE to check the maillog is on a persistent volume"
else
  logdir="$(dirname "$val")"
  # The mount line inside the postfix service block only: `<name>:<logdir>`.
  mount="$(awk -v d=":$logdir\$" '
    /^  postfix:/ { f = 1; next }
    f && /^  [a-z_]+:/ { exit }
    f && $0 ~ d { print $NF; exit }
  ' "$COMPOSE")"
  vol="${mount%%:*}"
  vol="${vol#- }"
  if [ -z "$vol" ]; then
    fail "the postfix service mounts nothing at $logdir — $val dies with the container on a recreate"
  elif ! awk '/^volumes:/ { f = 1; next } f && /^[a-z]/ { exit } f { print }' "$COMPOSE" \
         | grep -qE "^  ${vol}:"; then
    fail "$logdir is mounted from '$vol', which is not a declared top-level volume (a bind or a typo)"
  else
    pass "the maillog lives on the named volume '$vol' — it outlives a container recreate"
  fi
fi

if [ "${1:-}" != "--live" ] && [ "${1:-}" != "--recreate" ]; then
  echo
  [ "$fails" -eq 0 ] && echo "static checks passed ($fails failures). Re-run with --live to OBSERVE a status= line, or --recreate to prove it survives a deploy." \
                     || echo "$fails static failure(s)."
  exit $((fails > 0))
fi

echo
echo "== live (builds an image and boots a throwaway container) =="
command -v docker >/dev/null || { echo "  FAIL docker not available"; exit 1; }

IMG="bp-postfix-maillog-check:$$"
CNT="bp-postfix-maillog-check-$$"
# The stand-in for the compose named volume. The whole dr-w26 point is that
# this outlives `docker rm -f`, so it is created and destroyed by THIS script,
# never by the container lifecycle.
VOL="bp-postfix-maillog-check-log-$$"
LOGDIR="$(dirname "$val")"
PORT="${MAILLOG_CHECK_PORT:-15870}"
cleanup() {
  docker rm -f "$CNT" >/dev/null 2>&1 || true
  docker rm -f "${CNT}-b" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  docker rmi -f "$IMG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -q -t "$IMG" "$HERE" >/dev/null
docker volume create "$VOL" >/dev/null
docker run -d --name "$CNT" -p "$PORT:587" -v "$VOL:$LOGDIR" \
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

if [ "${1:-}" = "--recreate" ]; then
  echo
  echo "== recreate (destroys the container, keeps the volume — what a CP deploy does) =="

  # What the old container could prove, addressed by CONTENT so the assertion
  # cannot pass on a line the second container wrote itself.
  before="$(docker logs "$CNT" 2>&1 | grep -c 'status=sent' || true)"

  # This is the deploy. `docker compose up` on a changed image does exactly
  # this: the container (and with it every json-file log generation under
  # /var/lib/docker/containers/<id>/) is removed; the named volumes are not.
  docker rm -f "$CNT" >/dev/null
  docker run -d --name "${CNT}-b" -v "$VOL:$LOGDIR" \
    -e SMTP_USERNAME=probe -e SMTP_PASSWORD=probepass \
    -e MAIL_HOSTNAME=mail.example.test -e MAIL_DOMAIN=example.test \
    "$IMG" >/dev/null

  for _ in $(seq 1 60); do
    docker exec "${CNT}-b" test -f "$val" >/dev/null 2>&1 && break
    sleep 1
  done

  # NEGATIVE ARM FIRST — it is what makes the positive one mean anything. The
  # NEW container's `docker logs` must NOT contain the old delivery: if it
  # did, the check below would pass without the volume doing any work.
  if [ "$(docker logs "${CNT}-b" 2>&1 | grep -c 'status=sent' || true)" -eq 0 ]; then
    pass "the recreated container's docker logs has NO prior status=sent (the loss this guards)"
  else
    fail "the recreated container's docker logs already carries a status= line — this check is vacuous"
  fi

  after="$(docker exec "${CNT}-b" grep -c 'status=sent' "$val" 2>/dev/null || true)"
  if [ "${before:-0}" -gt 0 ] && [ "${after:-0}" -ge "${before:-0}" ]; then
    pass "the delivery line SURVIVED the recreate: $after status=sent line(s) still on $val"
    printf '       %s\n' "$(docker exec "${CNT}-b" grep -m1 'status=sent' "$val" 2>/dev/null || true)"
  else
    fail "delivery evidence did NOT survive the recreate (before=$before after=${after:-0} on $val)"
  fi
fi

echo
[ "$fails" -eq 0 ] && echo "all checks passed." || echo "$fails failure(s)."
exit $((fails > 0))
