# Uptime Kuma — Barkpark hosted-demo status board

Self-hosted status board colocated on the cax11 VPS (same host as
`barkpark.service`). Roughly 80 MB RAM idle. **Local-only** — bound to
`127.0.0.1:3001` until a TLS domain is set up.

## Install

```bash
cd /opt/barkpark/deploy/uptime-kuma   # or wherever this directory is mounted
docker compose up -d
docker compose logs -f uptime-kuma
```

First-run setup is through the web UI. SSH-tunnel to reach it:

```bash
# From your laptop:
ssh -L 3001:127.0.0.1:3001 root@89.167.28.206
# Then open http://localhost:3001 on your laptop.
```

Create the admin user, then add the monitors below.

## Validate the compose file

```bash
docker compose -f /opt/barkpark/deploy/uptime-kuma/docker-compose.yml config
```

## Monitors

All three use the default **60 s interval**. Replace `$ADMIN_TOKEN` with
the value from `/opt/barkpark/.env` — never paste it into the URL, use
Kuma's **HTTP — Headers** field.

### 1. Liveness — `/healthz`

| Field                 | Value                                  |
|-----------------------|----------------------------------------|
| Monitor Type          | HTTP(s)                                |
| URL                   | `http://127.0.0.1:4000/healthz`        |
| Interval              | 60 s                                   |
| Accepted status codes | `200-299`                              |

Equivalent curl:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://127.0.0.1:4000/healthz
# expect: 200
```

### 2. Schema endpoint — `/api/schemas`

Covers auth + DB + schema compilation. Requires an admin token header.

| Field                 | Value                                                  |
|-----------------------|--------------------------------------------------------|
| Monitor Type          | HTTP(s)                                                |
| URL                   | `http://127.0.0.1:4000/api/schemas`                    |
| Interval              | 60 s                                                   |
| Headers               | `Authorization: Bearer $ADMIN_TOKEN`                   |
| Accepted status codes | `200-299`                                              |

```bash
curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://127.0.0.1:4000/api/schemas | head -c 200
# expect: JSON payload starting with [{"name":...
```

### 3. Public query — `/v1/data/query/production/post?perspective=published`

End-to-end: query parsing, perspective filter, JSON render.

| Field                 | Value                                                                               |
|-----------------------|-------------------------------------------------------------------------------------|
| Monitor Type          | HTTP(s) — Keyword                                                                   |
| URL                   | `http://127.0.0.1:4000/v1/data/query/production/post?perspective=published`         |
| Interval              | 60 s                                                                                |
| Keyword               | `count`                                                                             |
| Accepted status codes | `200-299`                                                                           |

```bash
curl -sS "http://127.0.0.1:4000/v1/data/query/production/post?perspective=published" \
  | grep -q '"count"' && echo OK || echo FAIL
```

## Notifications

Kuma configures notification channels **post-install via the UI**
(Settings → Notifications). A single webhook channel is enough for the
demo. Suggested env for the ops runbook:

```bash
# /opt/barkpark/.env (optional; documents the expected target)
NOTIFICATION_EMAIL_WEBHOOK=https://example.invalid/kuma-webhook
```

Drop the value into Kuma's **Webhook** notification type → attach the
channel to all three monitors. `ntfy.sh` and Discord webhooks are both
no-account options that match the demo scope. Email via Resend is a
fine secondary but adds DNS (SPF/DKIM) work — defer.

## Exposing through Caddy (later, once a domain exists)

```caddy
status.barkpark.dev {
    reverse_proxy 127.0.0.1:3001
}
```

Until then the board is reachable only via SSH tunnel, which is the
intended posture for a single-operator demo.
