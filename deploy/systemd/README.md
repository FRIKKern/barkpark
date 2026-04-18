# systemd units — `barkpark-rotate-public-token`

These unit files rotate the weekly `public-read` API token consumed by the
hosted Next.js demo at `barkpark.dev`. They are **staged in-repo** under
`deploy/systemd/` for review; they are **not** installed by `git pull`.

## What the units do

* `barkpark-rotate-public-token.service` — `Type=oneshot` unit that runs
  `/opt/barkpark/api/start.sh rotate-public-read`, which sources ASDF +
  `/opt/barkpark/.env` and invokes the `mix barkpark.rotate_public_read`
  task. That task:

    1. Generates a 32-byte random token (URL-safe base64, no padding).
    2. Inserts an `api_tokens` row with permissions `["public-read"]` and
       label `public-read-<ISO date>`.
    3. Writes the plaintext token to `/opt/barkpark/.env.public_token`
       with mode `0600`.
    4. If `VERCEL_DEPLOY_HOOK` is set in the environment, POSTs the new
       token as JSON (`{"public_read_token": "<new>"}`) to trigger a
       Vercel rebuild of `barkpark.dev`.
    5. Deletes any `public-read-*` row older than 8 days, giving the
       previous deploy a 24 h grace window before its token is revoked.

* `barkpark-rotate-public-token.timer` — weekly Monday 03:00 UTC with a
  600 s random jitter and `Persistent=true` so missed runs (e.g. from
  reboots) are caught up.

## Install

Run once on the production host (`89.167.28.206`, as root):

```bash
sudo cp deploy/systemd/barkpark-rotate-public-token.service \
        /etc/systemd/system/barkpark-rotate-public-token.service
sudo cp deploy/systemd/barkpark-rotate-public-token.timer \
        /etc/systemd/system/barkpark-rotate-public-token.timer

sudo systemctl daemon-reload
sudo systemctl enable --now barkpark-rotate-public-token.timer
```

## Required environment

Set in `/opt/barkpark/.env` (read by `EnvironmentFile=` in the service):

| Variable              | Purpose                                                          |
|-----------------------|------------------------------------------------------------------|
| `DATABASE_URL`        | Inherited from `barkpark.service` — Ecto needs it.               |
| `SECRET_KEY_BASE`     | Inherited from `barkpark.service`.                               |
| `VERCEL_DEPLOY_HOOK`  | Optional. Full Vercel deploy-hook URL. Missing → rotation still |
|                       | succeeds; rebuild notify is skipped with a warning log.          |

## One-shot manual rotation

```bash
sudo systemctl start barkpark-rotate-public-token.service
sudo journalctl -u barkpark-rotate-public-token.service -n 50
```

## Validation

```bash
# Confirm files installed correctly
sudo systemctl cat barkpark-rotate-public-token.service
sudo systemctl cat barkpark-rotate-public-token.timer

# Confirm timer is scheduled
sudo systemctl list-timers --all | grep barkpark-rotate-public-token

# Static analysis against the installed paths
sudo systemd-analyze verify \
  /etc/systemd/system/barkpark-rotate-public-token.service \
  /etc/systemd/system/barkpark-rotate-public-token.timer

# Inspect last run
sudo systemctl status barkpark-rotate-public-token.service
sudo journalctl -u barkpark-rotate-public-token.service --since "7 days ago"
```

## start.sh dispatch

`api/start.sh` is extended to branch on its first argument. The timer
invokes it as `start.sh rotate-public-read`, which exports the ASDF
shims, sources `/opt/barkpark/.env`, and `exec`s the mix task under
`MIX_ENV=prod`. No argument (or anything unrecognised) falls through to
the existing `mix phx.server` path — the production boot path is
unchanged.

## Uninstall

```bash
sudo systemctl disable --now barkpark-rotate-public-token.timer
sudo rm /etc/systemd/system/barkpark-rotate-public-token.{service,timer}
sudo systemctl daemon-reload
```
