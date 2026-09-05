#!/bin/bash
# Entrypoint for the self-hosted Postfix + OpenDKIM outbound relay.
#
# Idempotent: safe to re-run on every container start. Generates the DKIM
# keypair and a fallback self-signed TLS cert only if they don't already
# exist on the mounted volumes, so restarts don't rotate keys or invalidate
# published DNS records.
set -euo pipefail

: "${SMTP_USERNAME:?SMTP_USERNAME is required}"
: "${SMTP_PASSWORD:?SMTP_PASSWORD is required}"
: "${MAIL_HOSTNAME:=mail.barkpark.cloud}"
: "${MAIL_DOMAIN:=barkpark.cloud}"
: "${DKIM_SELECTOR:=mail}"
: "${MAILLOG_FILE:=/dev/stdout}"

# ── DKIM keypair ──────────────────────────────────────────────────────────
DKIM_DIR="/etc/opendkim/keys/${MAIL_DOMAIN}"
mkdir -p "$DKIM_DIR"

if [ ! -f "$DKIM_DIR/${DKIM_SELECTOR}.private" ]; then
  echo "postfix-entrypoint: generating DKIM keypair (selector=${DKIM_SELECTOR}) for ${MAIL_DOMAIN}"
  opendkim-genkey -b 2048 -d "$MAIL_DOMAIN" -D "$DKIM_DIR" -s "$DKIM_SELECTOR" -v
fi
chown -R opendkim:opendkim /etc/opendkim
chmod 600 "$DKIM_DIR/${DKIM_SELECTOR}.private"

echo "===================================================================="
echo "postfix-entrypoint: DKIM public key — publish as a TXT record at"
echo "  ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}"
cat "$DKIM_DIR/${DKIM_SELECTOR}.txt"
echo "===================================================================="

cat > /etc/opendkim/KeyTable <<EOF
${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN} ${MAIL_DOMAIN}:${DKIM_SELECTOR}:${DKIM_DIR}/${DKIM_SELECTOR}.private
EOF

cat > /etc/opendkim/SigningTable <<EOF
*@${MAIL_DOMAIN} ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}
EOF

# OpenDKIM decides sign-vs-verify by the SMTP CLIENT ip that connected to
# Postfix (i.e. control_plane's docker-network address), not the milter
# socket peer (always loopback). That address isn't predictable ahead of
# time (docker-compose assigns the bridge subnet per project/host), so trust
# all private ranges here rather than loopback alone — safe because this
# listener is never published to the host/internet (see docker-compose.yml)
# and Postfix's own smtpd_relay_restrictions already requires SASL auth to
# relay through it regardless of source IP.
cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
${MAIL_DOMAIN}
*.${MAIL_DOMAIN}
EOF

cat > /etc/opendkim.conf <<EOF
Syslog             yes
LogWhy             yes
UMask              002
Socket             inet:8891@127.0.0.1
PidFile            /run/opendkim/opendkim.pid
Mode                sv
# relaxed/relaxed, not relaxed/simple: "simple" body canonicalization is
# byte-exact and breaks (false-negative "body hash mismatch") the moment
# ANY intermediate hop touches whitespace — confirmed live against a real
# receiving MTA. "relaxed" tolerates that while still cryptographically
# proving the signed headers/body weren't tampered with.
Canonicalization   relaxed/relaxed
KeyTable           /etc/opendkim/KeyTable
# refile: enables the *@domain wildcard pattern matching used below — the
# bare path defaults to exact-match lookup, which silently never matches
# a wildcard SigningTable entry (no error, just "no signing table match").
SigningTable       refile:/etc/opendkim/SigningTable
ExternalIgnoreList /etc/opendkim/TrustedHosts
InternalHosts      /etc/opendkim/TrustedHosts
EOF
mkdir -p /run/opendkim && chown opendkim:opendkim /run/opendkim

# ── TLS for the submission (587) listener ───────────────────────────────
# A real cert for MAIL_HOSTNAME (Let's Encrypt DNS-01) should be mounted at
# /etc/postfix/tls in prod — see ./README.md. Falling back to a self-signed
# cert here only so the container boots for local/dev testing; the app talks
# to this hop with SMTP_VERIFY_PEER=false, so a self-signed cert doesn't
# block local delivery, but production MUST mount a real one.
mkdir -p /etc/postfix/tls
if [ ! -f /etc/postfix/tls/fullchain.pem ]; then
  echo "postfix-entrypoint: no TLS cert at /etc/postfix/tls — generating a self-signed fallback for ${MAIL_HOSTNAME} (dev only; mount a real cert in prod)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /etc/postfix/tls/privkey.pem \
    -out /etc/postfix/tls/fullchain.pem \
    -subj "/CN=${MAIL_HOSTNAME}"
fi

# ── SASL (submission auth) ──────────────────────────────────────────────
# Written to both paths since Debian's libsasl2 search path for the "smtpd"
# appname varies by build (/etc/sasl2 vs /usr/lib/<arch>/sasl2) — best-effort
# narrowing of the advertised mechanisms to PLAIN/LOGIN. Not security-critical
# either way: smtpd_tls_security_level=encrypt below makes STARTTLS mandatory
# on this listener before AUTH is even offered, so whichever mechanism the
# library ends up advertising, it's always negotiated inside TLS.
SASL_CONF_CONTENT=$(cat <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
EOF
)
mkdir -p /etc/sasl2
echo "$SASL_CONF_CONTENT" > /etc/sasl2/smtpd.conf
for d in /usr/lib/sasl2 /usr/lib/*/sasl2; do
  [ -d "$d" ] && echo "$SASL_CONF_CONTENT" > "$d/smtpd.conf"
done
echo "$SMTP_PASSWORD" | saslpasswd2 -p -c -u "$MAIL_HOSTNAME" "$SMTP_USERNAME"
chown postfix:sasl /etc/sasldb2
chmod 640 /etc/sasldb2
adduser postfix sasl >/dev/null 2>&1 || true

# ── Postfix main.cf ──────────────────────────────────────────────────────
# ── Delivery logging ─────────────────────────────────────────────────────
# WITHOUT THIS, THIS CONTAINER LOGS NOTHING. Postfix logs to syslog by
# default; this image has no syslog daemon (and no /dev/log), so every
# `status=sent` / `status=deferred` / `status=bounced` line — the ONLY
# server-side record of whether a message actually reached the recipient's
# MX — was silently discarded. `docker logs` held the entrypoint's DKIM
# banner and nothing else, so "did that password-reset email arrive?" was
# unanswerable from the box, and the app's own failure copy ("the server
# log has the transport detail", cloud/lib/barkpark_cloud/notifications/
# delivery_reason.ex `label(:unknown)`) pointed at a log that did not exist.
#
# maillog_file is Postfix 3.4+ and routes logging through the `postlogd`
# service instead of syslog. Three facts make it work HERE specifically:
#   1. Debian bookworm ships Postfix 3.7.x — new enough (verify with
#      `postconf mail_version` if the base image is ever bumped).
#   2. postlogd needs a `postlog unix-dgram` entry in master.cf, which the
#      stock Debian master.cf already carries; `postfix start-fg` runs
#      check-fatal, which FATALs "missing 'postlog' service in master.cf"
#      and refuses to start if it is ever absent — so a broken config fails
#      loudly at boot rather than silently logging nothing again.
#   3. postlogd is spawned by the master process, inheriting its stdout —
#      which under `exec postfix start-fg` (PID 1) is the container's
#      stdout, i.e. `docker logs`. /dev/stdout is allowed by the default
#      maillog_file_prefixes (`/var, /dev/stdout`).
# Left overridable so an operator can point it at a file on a mounted
# volume instead, but the default is the one the README documents.
postconf -e "maillog_file = ${MAILLOG_FILE:-/dev/stdout}"

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost"
postconf -e "relayhost ="
postconf -e "smtp_helo_name = ${MAIL_HOSTNAME}"
# Outbound (this relay -> recipient MX): opportunistic TLS, no smart host —
# we deliver direct-to-MX ourselves (needs Hetzner's outbound port 25 unblock).
postconf -e "smtp_tls_security_level = may"
postconf -e "smtp_tls_loglevel = 1"
# Inbound submission listener TLS (control_plane -> this relay).
postconf -e "smtpd_tls_cert_file = /etc/postfix/tls/fullchain.pem"
postconf -e "smtpd_tls_key_file = /etc/postfix/tls/privkey.pem"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_sasl_type = cyrus"
postconf -e "smtpd_sasl_path = smtpd"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_relay_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"
postconf -e "smtpd_milters = inet:127.0.0.1:8891"
postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"
postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 6"
# mynetworks stays loopback-only — the submission service below is the sole
# entry point and it requires SASL auth regardless.
postconf -e "mynetworks = 127.0.0.0/8, [::1]/128"

# This relay only sends outbound; it never needs to accept unauthenticated
# mail on 25. Disable Postfix's default `smtp inet` listener (master.cf ships
# it enabled) so the only inbound service is the SASL-gated submission one
# below — one less unauthenticated surface exposed inside the container.
sed -i '/^smtp[[:space:]]\+inet/s/^/#/' /etc/postfix/master.cf

# The stock master.cf runs the outbound `smtp`/`relay` delivery agents
# CHROOTED into /var/spool/postfix (5th column "y") — that jail has no
# /etc/resolv.conf, so MX lookups for outbound delivery fail ("Host or
# domain name not found... Host not found, try again") even though DNS
# works fine everywhere else in the container. Docker's own isolation
# already provides the security boundary this chroot was defense-in-depth
# for, so disable it rather than maintaining a synced resolv.conf inside
# the jail on every network change.
sed -i -E 's/^(smtp|relay)([[:space:]]+unix[[:space:]]+-[[:space:]]+-[[:space:]]+)y/\1\2n/' /etc/postfix/master.cf

# Enable the submission (587) service if this is the first boot of this
# container filesystem (master.cf isn't on a persisted volume, so re-running
# is safe either way, but avoid duplicate blocks on a re-exec).
if ! grep -q '^submission inet' /etc/postfix/master.cf; then
  cat >> /etc/postfix/master.cf <<'EOF'

submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
fi

mkdir -p /var/spool/postfix/pid

opendkim -x /etc/opendkim.conf -u opendkim &
exec postfix start-fg
