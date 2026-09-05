<!-- doc-tier: human | canonical-for: self-hosted-mail-relay -->
# Self-hosted outbound mail relay

Postfix + OpenDKIM, hand-rolled (Debian + apt packages, no third-party
image) because this container holds DKIM private keys and the SMTP
submission password. It's a **sidecar** to the control plane
(`cloud/docker-compose.yml`) — `control_plane` talks to it over the internal
compose network only; it is never published to the host or the internet.

Goal: best-effort inbox-grade deliverability for transactional mail
(password resets, invites) without a paid provider (Resend/Postmark/SES).
The code stays provider-agnostic — see `SMTP_HOST`/`SMTP_VERIFY_PEER` in
`.env.example` — so switching to a provider later is just env vars, no code
change, if self-hosting doesn't work out.

## How it fits together

```
control_plane --(SMTP, internal docker network only, no TLS peer verify)--> postfix --(port 25, direct-to-MX, opportunistic TLS)--> recipient's mail server
```

`control_plane`'s mailer config (`cloud/config/runtime.exs`) reads
`SMTP_HOST=postfix` by default — the compose service name — and
`SMTP_VERIFY_PEER=false`, since that hop never leaves the docker network.
Postfix itself delivers outbound with real identity: HELO/DKIM d=/PTR all
line up on `MAIL_HOSTNAME` (default `mail.barkpark.cloud`).

## One-time setup (in order)

### 1. DNS zone access — resolved

`barkpark.cloud` **is** Hetzner Cloud DNS (zone id `1422829`), but under a
**different Hetzner project/token** than `barkpark-cp`'s own server token
(the `hcloud` CLI's `barkpark` context can't see it — `zone list` returns
empty for that token). The project holding the DNS zone also holds
`guerrilla`, `barkpark-cms`, and a few other servers, and is reachable via
the `HETZNER_API_TOKEN` env var already present in the shell this was set
up from. To manage records: `HCLOUD_TOKEN="$HETZNER_API_TOKEN" hcloud zone
rrset ...` (don't confuse this with the default `hcloud` context's token,
which only covers `barkpark-cp` and other servers, not DNS).

### 2. Reverse DNS (PTR) — done

```
hcloud server set-rdns barkpark-cp --ip 178.105.92.191 --hostname mail.barkpark.cloud
```

Confirmed live: `dig -x 178.105.92.191` → `mail.barkpark.cloud.`

### 3. DNS records — done, live in the zone

| Record | Value | Purpose |
|---|---|---|
| `barkpark.cloud` TXT | `v=spf1 ip4:178.105.92.191 ~all` | SPF — softfail to start (see rollout below) |
| `mail._domainkey.barkpark.cloud` TXT | `v=DKIM1; h=sha256; k=rsa; p=<pubkey>` | DKIM, selector `mail` |
| `_dmarc.barkpark.cloud` TXT | `v=DMARC1; p=none; rua=mailto:dmarc@barkpark.cloud; adkim=s; aspf=s` | DMARC — monitor mode first |
| `mail.barkpark.cloud` A | `178.105.92.191` | Forward record matching the PTR (FCrDNS) |

All four confirmed live via `dig ... @hydrogen.ns.hetzner.com`.

**Important — the published DKIM key must be the one that actually runs.**
The keypair was generated once locally (not on first-boot on the server) so
DNS and the running relay agree from the start:

```
# Same image build used in prod (cloud/postfix/Dockerfile), keypair only:
docker run --rm -e SMTP_USERNAME=x -e SMTP_PASSWORD=x \
  -v <a-throwaway-volume>:/etc/opendkim/keys <image> &
# then extract /etc/opendkim/keys/barkpark.cloud/{mail.private,mail.txt}
```

**Before the first prod deploy**, seed these exact key files into the
`postfix_dkim` named volume on `barkpark-cp` (e.g. `docker cp` them in, or
`scp` + `docker run --rm -v postfix_dkim:/etc/opendkim/keys -v
$(pwd):/seed alpine cp -r /seed/barkpark.cloud /etc/opendkim/keys/`) —
**do this before `docker compose up` creates the volume and the entrypoint
generates a fresh (mismatched) key on its own.** The private key was
generated on 2026-07-01 and handed off out-of-band (not committed to git);
whoever runs the first deploy needs it.

### 4. Hetzner outbound port 25 unblock

Hetzner blocks outbound SMTP (port 25) by default on new Cloud
servers/accounts as anti-abuse. This relay delivers direct-to-MX (no smart
host), so port 25 egress from `barkpark-cp` must be unblocked before mail
actually reaches recipients — everything else in this doc works without it
(the container boots, queues mail, retries).

This is account-identity-gated and self-service only from the Hetzner Cloud
Console (not scriptable via `hcloud`/API): **Console → barkpark-cp → select
server → Networking → request SMTP/port 25 unblock**, or via a support
ticket if that option isn't shown. Suggested justification text:

> Requesting outbound port 25 unblock for server barkpark-cp
> (178.105.92.191). This server runs Barkpark Cloud's control plane and
> sends low-volume transactional email only (password resets, account
> invites) via a self-hosted Postfix relay with SPF/DKIM/DMARC configured
> for barkpark.cloud. No bulk or marketing mail.

### 5. Real TLS cert for the submission listener — done, auto-renews

The container falls back to a self-signed cert for local/dev boot (fine,
since `SMTP_VERIFY_PEER=false` on that hop). Prod runs a real Let's Encrypt
cert for `mail.barkpark.cloud`, issued via DNS-01 against Hetzner Cloud DNS
(avoids needing port 80 open) and mounted at the `postfix_tls` volume
(`/etc/postfix/tls/{fullchain,privkey}.pem`) — the entrypoint only generates
its self-signed fallback if those files don't already exist, so a real cert
seeded in survives container recreates untouched.

Renewal is automated: `.github/workflows/renew-mail-cert.yml` runs
`deploy/renew-mail-cert.sh` monthly (LE certs last ~90 days; monthly is well
inside the 50/week per-domain rate limit and needs no persisted
renewal-due state across ephemeral runners). It re-issues via `acme.sh`
+ `dns_hetznercloud`, ships the result to `barkpark-cp` over the same SSH
path `deploy.yml` already uses, reseeds the volume, and reloads postfix.
Needs one GitHub secret beyond what `deploy.yml` already has — see
`deploy/README.md`. Manual re-run: **Actions → Renew mail relay TLS cert →
Run workflow**, or `bash deploy/renew-mail-cert.sh` directly with
`HETZNER_TOKEN`/`CP_HOST`/`DEPLOY_SSH_KEY_FILE` set.

First cert issued 2026-07-01, expires 2026-09-29.

## Rollout / deliverability

New sending IP + domain start with zero reputation. Plan:

1. Deploy with SPF `~all` and DMARC `p=none` (monitor only, doesn't affect
   delivery).
2. Verify: `opendkim-testkey` inside the container, a test send through
   [mail-tester.com](https://www.mail-tester.com), and a manual send to a
   real Gmail/Outlook inbox — check it lands in the inbox, not spam. Then
   confirm the *relay's own* verdict for that message with the lookup in
   [Did this message reach the destination MX?](#did-this-message-reach-the-destination-mx)
   below — the receiving MX's own `250` reply is quoted in the `status=sent`
   line, which is the only server-side proof; "it showed up in my inbox" is
   not reproducible by the next operator.
3. Watch DMARC aggregate reports (the `rua` address) for 1-2 weeks, confirm
   no unexpected fails, then tighten `p=quarantine` → `p=reject` and SPF to
   `-all`.
4. Password-reset mail is low-volume and transactional — favorable for
   building reputation versus bulk/marketing sends from a cold IP.

## Local testing

```
docker compose -f cloud/docker-compose.yml up --build
# trigger a password reset against the local control_plane, then:
docker compose -f cloud/docker-compose.yml logs postfix \
  | grep -E 'status=(sent|deferred|bounced)'
```

Real internet delivery can't be tested locally without port 25 open — this
only proves the control_plane → postfix submission hop (auth + STARTTLS +
DKIM-signing + queuing) works, and the outbound leg will read
`status=deferred`/`status=bounced` with a DNS or connection error rather
than `status=sent`.

To prove the *logging* itself end-to-end without any of the rest of the
stack, `./check-maillog.sh --live` builds this image, boots a throwaway
container, submits an authenticated message over 587 and asserts a real
`status=sent` line comes out of `docker logs`. It needs a working Docker
daemon and about a minute; without `--live` it runs the static config
assertions only, which is what CI executes.

## Reading the delivery log

Postfix logs to syslog by default and **this image has no syslog daemon**,
so until the `maillog_file` line in `entrypoint.sh` existed, the relay
emitted the entrypoint's DKIM banner and nothing else for its entire
lifetime — no `status=sent`, no `status=deferred`, no `status=bounced`,
ever. `maillog_file = /dev/stdout` (Postfix 3.4+; bookworm ships 3.7.x)
routes logging through the `postlogd` service, whose stdout is inherited
from the `postfix start-fg` master at PID 1, i.e. `docker logs`. Override
with `MAILLOG_FILE` if you would rather write to a file on a mounted
volume. If `master.cf` ever loses its `postlog unix-dgram` entry, Postfix
FATALs at boot ("missing 'postlog' service in master.cf") instead of
silently logging nothing again.

Container logs are capped at 10 MB × 5 files (`logging:` on the `postfix`
service in `cloud/docker-compose.yml`), so this history is roughly the last
few weeks at current volume, not forever. `docker logs` also does not
survive a container *recreate* — anything you need past a deploy has to be
copied out first.

### Did this message reach the destination MX?

Answer it from the relay host with one command. Set `RCPT` to the recipient
address; the last matching line is the verdict:

```bash
RCPT='someone@example.com'; docker logs --since 168h cloud-postfix-1 2>&1 \
  | grep -E "to=<${RCPT}>.*status=" | tail -3
```

Read the result:

| Line contains | Means |
|---|---|
| `status=sent` | The recipient's MX **accepted** it. Its own reply is quoted, e.g. `status=sent (250 2.0.0 OK 1725...  - gsmtp)`. This is the proof. |
| `status=deferred` | Still trying. The parenthesised text is the remote's temporary error; `postqueue -p` shows it queued. |
| `status=bounced` | Permanently rejected — the parenthesised text is the remote's 5xx, verbatim. |
| *(no output)* | The message never reached the relay at all. That is an app-side or submission-hop problem, not a delivery one — check `notification_deliveries` and the `postfix/submission/smtpd` lines below. |

`status=sent` here means the **next** hop accepted responsibility. It is not
a read receipt and it does not rule out the recipient's own spam folder —
but it does move the failure boundary past this relay, which is exactly what
was unanswerable before.

Related lookups on the same log:

```bash
# The whole life of one message, once you have its queue ID from the above.
docker logs cloud-postfix-1 2>&1 | grep '<QUEUE_ID>'

# Did the app's submission even arrive? (auth + STARTTLS on the 587 hop)
docker logs cloud-postfix-1 2>&1 | grep 'postfix/submission/smtpd'

# Everything currently stuck, with the reason.
docker exec cloud-postfix-1 postqueue -p
```

The app's own failure copy — "The delivery failed — the server log has the
transport detail", `label(:unknown)` in
`cloud/lib/barkpark_cloud/notifications/delivery_reason.ex` — means *this*
log. That sentence was written before the log existed; the lookups above are
what it now points at.
