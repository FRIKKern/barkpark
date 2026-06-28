<!-- doc-tier: agent | canonical-for: systemd-token-rotation | budget: 300tok -->
# systemd units — `barkpark-rotate-public-token`

Rotates the weekly `public-read` API token consumed by the hosted demo at `barkpark.dev`. **Staged in-repo** — not installed by `git pull`.

For prod host identity (IP, paths, service name) see `docs/ops/PROD_OPS.md`.

## What the units do

`barkpark-rotate-public-token.service` (Type=oneshot) runs `api/start.sh rotate-public-read`, which:

1. Generates a 32-byte random URL-safe base64 token.
2. Inserts an `api_tokens` row with `["public-read"]` permissions + label `public-read-<ISO date>`.
3. Writes the plaintext token to `/opt/barkpark/.env.public_token` (mode `0600`).
4. If `VERCEL_DEPLOY_HOOK` is set, POSTs the new token to trigger a Vercel rebuild.
5. Deletes any `public-read-*` row older than 8 days (24h grace window for the prior deploy).

`barkpark-rotate-public-token.timer` — weekly Monday 03:00 (server local time; assumes UTC host), 600 s random jitter, `Persistent=true`.

## Install

```bash
sudo cp deploy/systemd/barkpark-rotate-public-token.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now barkpark-rotate-public-token.timer
```

## Validate

```bash
sudo systemctl cat barkpark-rotate-public-token.service
sudo systemctl list-timers --all | grep barkpark-rotate-public-token
sudo systemd-analyze verify /etc/systemd/system/barkpark-rotate-public-token.{service,timer}
sudo journalctl -u barkpark-rotate-public-token.service --since "7 days ago"
```

## One-shot manual rotation

```bash
sudo systemctl start barkpark-rotate-public-token.service
```

## Uninstall

```bash
sudo systemctl disable --now barkpark-rotate-public-token.timer
sudo rm /etc/systemd/system/barkpark-rotate-public-token.{service,timer}
sudo systemctl daemon-reload
```
