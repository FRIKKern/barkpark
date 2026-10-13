<!-- doc-tier: agent | canonical-for: systemd-token-rotation | budget: 300tok -->
# systemd units

The weekly `public-read` token rotation is **no longer a systemd unit**. It is the core Oban job `Barkpark.Auth.PublicReadRotationWorker` (Mondays 03:00 UTC), off unless `BARKPARK_PUBLIC_READ_ROTATION=on`; manual run: `api/start.sh rotate-public-read`. See [Retired: `barkpark-rotate-public-token`](#retired-barkpark-rotate-public-token).

For prod host identity (IP, paths, service name) see `docs/ops/PROD_OPS.md`.

Other units here are installed **by the deploy**, not by hand: `barkpark-slot@` (blue/green app slots), `barkpark-agent` (monitoring beat), `barkpark-mcp` (`/mcp`), `barkpark-connectors` (the Connectors bridge behind `/connectors` — runbook: `docs/ops/connectors-deploy.md`). See `deploy/README.md`.

## `barkpark-agent` — the two token files

| File | Mode | Written by | Missing ⇒ |
|---|---|---|---|
| `/etc/barkpark/agent.token` | 0600 | provision (`agentInstallStep`) | unit exits — no beat at all |
| `/etc/barkpark/agent.health.token` | 0600 | provision (`agentInstallStep`) | `req_per_s` / `p95_ms` / `err_5xx_per_s` stay `-1` (unmetered); the beat runs |

The unit passes `--health-token-file` (a **path**, never a value). The health token is the box's own admin bearer — the same credential the health gate already presents to the same box's `GET /v1/instance/request-stats`. Backfill on a box provisioned before this existed: write that box's admin bearer to `/etc/barkpark/agent.health.token`, `chmod 600`, `systemctl restart barkpark-agent`. Confirm with `journalctl -u barkpark-agent | grep 'health token'` — the agent prints which source answered.

## Site plane — `barkpark-builder` + `barkpark-runtime`

These two are **not** prod units. Their host is **the site's own box** — the managed box that serves that site. The build plane is *co-located* with the runtime by design: the builder writes the image tarball to `/var/lib/barkpark-builder/images` and the runtime reads it from the same local filesystem, so the handoff is a file move, never a registry push or a cross-host copy.

| Unit | Role | Identity |
|---|---|---|
| `barkpark-builder.service` | claims queued deployments, nixpacks-builds the site image (`--platform` = the box's own arch) | the box's agent token (`/etc/barkpark/agent.token`, fixed) |
| `barkpark-runtime.service` | executes the deployment on the box: loads the image, runs it, rewrites the Caddyfile | the box's agent token (fixed) |

Both units authenticate with the box's **own per-box agent token** — never the shared fleet `WORKER_TOKEN`, which was retired from boxes when the `/v1/builder/*` routes moved to `require_agent` (#13251; that shared secret also opens `/v1/internal/*` — list/deprovision any box). **Never place a `worker.token` on a box.**

### `WORKER_TOKEN` rotation — the order is not optional

1. **Control plane first**: the `require_agent` builder routes are merged (#13251).
2. **Rerun `site-runtime-install` on every box** before rotating. A box still presenting the old worker token 401s and its container builds freeze **silently** — queued rows sit forever with no error — until its rerun repoints the builder unit at `agent.token`. The rerun does **not** delete `/etc/barkpark/worker.token`: the stale file stays on disk, still holding the live fleet secret, until rotation invalidates it (which is why rotation must follow, never lead).
3. **Rotate `WORKER_TOKEN` last**, handing the provisioner host the new value in the same step — provisioning breaks otherwise. Rotating before a box's rerun freezes that box exactly as in step 2.

Installed by `deploy/site-runtime-install.sh`, which is streamed to the box as **exactly one file** by the cp-ops `site-runtime-install` operation — so it carries the units as inline heredocs rather than reading them from the repo. The files here are the canonical copies (placeholder `__PLATFORM__` intact — there is no token placeholder); `deploy/site-runtime-install_test.sh` byte-diffs script against staged file offline, so the two cannot drift. **Edit both sides or the gate goes red.**

## Failure handling — `barkpark-unit-failure-alert@`

The scheduled unit carries `OnFailure=barkpark-unit-failure-alert@%n.service`. **On the `.service`, never the `.timer`**: a timer's `OnFailure=` fires only if the *timer* fails to activate — the job's failure lands on the service it triggered, so a timer-side handler is installed, looks right, and is silent for exactly these failures. One `@`-template serves both (same convention as `barkpark-slot@` / `barkpark-site@`); `%n` passes the failing unit's name in as `%i`. Neither guarded unit sets `Restart=`, so its first non-zero exit is final and the handler fires at once — with `Restart=`, systemd only enters `failed` after the restart budget is exhausted.

The handler runs `/usr/local/bin/barkpark-unit-failure-alert` (`barkpark-unit-failure-alert.sh`). It **always** records: journald at `err` under tag `barkpark-alert`, plus a stamp under `/var/lib/barkpark/failed-units/` (a weekly job's failure must outlive journal rotation). It **delivers** by POSTing to `$BARKPARK_ALERT_WEBHOOK` from `/etc/barkpark/alert.env` — and when that is unset or the POST fails it logs `ALERT NOT DELIVERED` at `err` rather than no-opping quietly. **No channel existed on either box before this**: the control host's `/etc/barkpark-provisioner.env` and the prod box's `/opt/barkpark/.env` carry no GitHub credential and no usable MTA, and the two units run on *different hosts*.

Install the handler alongside whichever unit it guards:

```bash
sudo install -m 0644 deploy/systemd/barkpark-unit-failure-alert@.service /etc/systemd/system/
sudo install -m 0755 deploy/systemd/barkpark-unit-failure-alert.sh /usr/local/bin/barkpark-unit-failure-alert
sudo systemctl daemon-reload
# optional, and the only thing that reaches a human:
printf 'BARKPARK_ALERT_WEBHOOK=%s\n' "$URL" | sudo tee /etc/barkpark/alert.env >/dev/null
sudo chmod 600 /etc/barkpark/alert.env
```

Verify a firing without waiting for a real failure: `sudo systemctl start barkpark-unit-failure-alert@barkpark-image-bake.service`, then `journalctl -t barkpark-alert -p err -n 20`.

`deploy/systemd-onfailure_test.sh` is the offline guard — every `.timer`'s target `.service` carries an `OnFailure=`, the handler it names exists here, and no scheduled service sets `Restart=` other than `no`. It proves it can fail on every run. **`deploy/cp-deploy.sh` does not yet install the handler** (it installs only the image-bake pair); until it does, the `OnFailure=` on the control host names a unit that is not there.

## Retired: `barkpark-rotate-public-token`

The `.service`/`.timer` pair was staged here and never installed, so the rotation never ran. The same work (mint `public-read-<date>`, write `/opt/barkpark/.env.public_token` 0600, POST `VERCEL_DEPLOY_HOOK`, purge rows past 8 days) is now `Barkpark.Auth.PublicRead.rotate/1`, run weekly by the core job when switched on. A box that did install the pair should remove it:

```bash
sudo systemctl disable --now barkpark-rotate-public-token.timer
sudo rm /etc/systemd/system/barkpark-rotate-public-token.{service,timer}
sudo systemctl daemon-reload
```
