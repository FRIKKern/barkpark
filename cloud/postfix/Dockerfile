# Self-hosted outbound-only mail relay for Barkpark Cloud transactional email
# (password resets, invites). Debian + apt packages only — no third-party
# image — this container holds DKIM private keys and SMTP auth secrets. See
# ./README.md for DNS records, TLS cert, and Hetzner port-25 prerequisites.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      postfix \
      opendkim \
      opendkim-tools \
      sasl2-bin \
      libsasl2-modules \
      openssl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /etc/opendkim/keys  — DKIM keypair, generated on first boot, never in git
# /var/spool/postfix  — mail queue, survives restarts
# /etc/postfix/tls    — TLS cert/key for the submission listener
VOLUME ["/etc/opendkim/keys", "/var/spool/postfix", "/etc/postfix/tls"]

EXPOSE 587

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
