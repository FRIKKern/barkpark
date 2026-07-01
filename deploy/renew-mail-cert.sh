#!/usr/bin/env bash
# Renew the Let's Encrypt cert for mail.barkpark.cloud (the self-hosted
# outbound mail relay, cloud/postfix/) via DNS-01 against Hetzner Cloud DNS,
# then deploy it into the postfix_tls volume on barkpark-cp and reload
# postfix. See cloud/postfix/README.md for the manual version of this flow.
#
#   HETZNER_TOKEN=... CP_HOST=... DEPLOY_SSH_KEY_FILE=... bash renew-mail-cert.sh
#
# HETZNER_TOKEN needs Cloud DNS access (same token/project as the
# barkpark.cloud zone — see docs/ops/barkpark-cloud-go-live.md Gate 2 and
# the guerrilla-instance-dns-control note in project memory: this is a
# DIFFERENT token than barkpark-cp's own server credential).
set -euo pipefail

: "${HETZNER_TOKEN:?HETZNER_TOKEN is required (Hetzner Cloud DNS-capable token)}"
: "${CP_HOST:?CP_HOST is required}"
SSH_KEY="${DEPLOY_SSH_KEY_FILE:-$HOME/.ssh/id_rsa}"
DOMAIN="mail.barkpark.cloud"

log() { echo "[renew-mail-cert $(date -u +%H:%M:%S)] $*"; }

ACME="$HOME/.acme.sh/acme.sh"
if ! command -v acme.sh >/dev/null 2>&1 && [ ! -x "$ACME" ]; then
  log "installing acme.sh"
  curl -s https://get.acme.sh | sh -s email=admin@barkpark.cloud
fi
command -v acme.sh >/dev/null 2>&1 && ACME=acme.sh

log "issuing cert for ${DOMAIN} via DNS-01 (Hetzner Cloud DNS)"
export HETZNER_TOKEN
"$ACME" --issue --dns dns_hetznercloud -d "$DOMAIN" --server letsencrypt --force

CERT_DIR="$HOME/.acme.sh/${DOMAIN}_ecc"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known"
SCP="scp -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known"

log "shipping cert to ${CP_HOST}"
$SSH "root@${CP_HOST}" 'mkdir -p /root/tls-renew-tmp'
$SCP "$CERT_DIR/fullchain.cer" "$CERT_DIR/${DOMAIN}.key" "root@${CP_HOST}:/root/tls-renew-tmp/"

log "seeding cloud_postfix_tls volume + reloading postfix"
$SSH "root@${CP_HOST}" "
  set -e
  docker run --rm -v cloud_postfix_tls:/tls -v /root/tls-renew-tmp:/seed alpine sh -c '
    cp /seed/fullchain.cer /tls/fullchain.pem
    cp /seed/${DOMAIN}.key /tls/privkey.pem
    chmod 600 /tls/privkey.pem
  '
  rm -rf /root/tls-renew-tmp
  CID=\$(docker compose -f /opt/barkpark/cloud/docker-compose.yml ps -q postfix)
  docker exec \"\$CID\" postfix reload
  echo 'reloaded; live cert now:'
  docker exec \"\$CID\" sh -c 'echo | openssl s_client -connect localhost:587 -starttls smtp -servername ${DOMAIN} 2>/dev/null | openssl x509 -noout -subject -dates'
"
log "DONE"
