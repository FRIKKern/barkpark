<!-- doc-tier: agent | canonical-for: systemd-token-rotation | budget: 300tok -->
# systemd units — `barkpark-rotate-public-token`

Rotates the weekly `public-read` API token consumed by the hosted demo at `barkpark.dev`. **Staged in-repo** — not installed by `git pull`.

For prod host identity (IP, paths, service name) see `docs/ops/PROD_OPS.md`.

Other units here are installed **by the deploy**, not by hand: `barkpark-slot@` (blue/green app slots), `barkpark-agent` (monitoring beat), `barkpark-mcp` (`/mcp`), `barkpark-connectors` (the Connectors bridge behind `/connectors` — runbook: `docs/ops/connectors-deploy.md`). See `deploy/README.md`.

## Site plane — `barkpark-builder` + `barkpark-runtime`

These two are **not** prod units. Their host is **the site's own box** — the managed box that serves that site. The build plane is *co-located* with the runtime by design: the builder writes the image tarball to `/var/lib/barkpark-builder/images` and the runtime reads it from the same local filesystem, so the handoff is a file move, never a registry push or a cross-host copy.

| Unit | Role | Identity |
|---|---|---|
| `barkpark-builder.service` | claims queued deployments, nixpacks-builds the site image (`--platform` = the box's own arch) | `__BUILDER_TOKEN__` — the shared worker token when the box has one, else the agent token |
| `barkpark-runtime.service` | executes the deployment on the box: loads the image, runs it, rewrites the Caddyfile | the box's agent token (fixed) |

Installed by `deploy/site-runtime-install.sh`, which is streamed to the box as **exactly one file** by the cp-ops `site-runtime-install` operation — so it carries the units as inline heredocs rather than reading them from the repo. The files here are the canonical copies (placeholders `__PLATFORM__` / `__BUILDER_TOKEN__` intact); `deploy/site-runtime-install_test.sh` byte-diffs script against staged file offline, so the two cannot drift. **Edit both sides or the gate goes red.**

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
