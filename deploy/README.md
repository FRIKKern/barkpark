<!-- doc-tier: human | canonical-for: cd-pipeline | budget: 1200tok -->
# Continuous deployment

A merge to `main` updates the affected **production** host automatically.
`.github/workflows/deploy.yml` runs after the merge (CI/merge-gates already
vetted the change) and is **path-filtered** so a docs-only commit never rebuilds
a server.

```
merge to main
   ├─ cloud/**  changed → deploy CONTROL PLANE  (barkpark.cloud / barkpark-cp)
   └─ api/** | internal/** changed → deploy CONTENT INSTANCE (guerrilla)
        every deploy: build the IDLE blue/green slot (active one keeps serving)
        → health-gate it → flip Caddy's upstream (graceful reload) → stop old.
        Unhealthy new slot = it's stopped again, no swap — ZERO downtime either way.
```

The path filter diffs from the **last successful run of this workflow**, not the
previous push: the concurrency group keeps one pending run, so burst merges cancel
intermediate runs before they deploy — anchoring to the last success makes the
surviving run deploy the UNION of every push since (no cancelled range is ever
skipped), while a docs-only stretch still resolves to a no-op.

| Target | Trigger paths | Script | Mechanism |
|---|---|---|---|
| Control plane | `cloud/**` | `deploy/cp-deploy.sh` | flock-serialized. Compose slots behind profiles: `blue`=:4100, `green`=:4101, one up at a time. Tag rollback image → `git pull` → `docker compose build` → boot idle slot (auto-migrates on boot) → health-gate → flip Caddy → stop old slot (kept for instant `docker start` rollback). Provisioner cross-built by the runner (`cmd/barkpark-provisioner`, linux/amd64) and shipped (Go is not on the box). |
| Content instance | `api/**`, `internal/**` | `deploy/instance-deploy.sh` | flock-serialized (queued runs coalesce). systemd slots `barkpark-slot@blue`=:4000/`@green`=:4001, per-slot build roots (`api/_build_blue`/`_build_green` via `MIX_BUILD_ROOT`) of one checkout. Hook-suppressed `git pull` (the box's post-merge hook would rebuild+restart the live tree — the pre-blue/green outage) → backfill secret keys → clean-build idle slot's root (active slot serving its own, never rebuilt under the live BEAM) → `ecto.migrate` → boot idle slot → health-gate `/api/schemas` → flip Caddy → retire old slot + legacy `barkpark` unit. |

Both hosts overlap old+new code on the new schema for the swap window, so
migrations must be expand/contract (backward-compatible).

**Maintenance page (no raw 502 when the app is down).** Every Caddy site block
carries a `handle_errors` handler serving a branded 503 "Back in a moment" +
`Retry-After` while the upstream is unreachable — blue/green keeps deploys
seamless, this covers crashes/restarts outside deploys. Baked into the renderers
(`internal/caddyfile/caddyfile.go`, `internal/cli/setup/caddy.go`,
`internal/cli/setup/assets/deploy.sh`) so every provisioned instance gets it, and
armed on running boxes by `instance-deploy.sh` (idempotent, `caddy validate`d,
auto-reverting; port-flip-safe). Reference block + manual arming:
`deploy/caddy/barkpark-maintenance.caddy`. Offline test harness for the deploy
script (slot selection, flip, failure semantics): `deploy/instance-deploy_test.sh`.

A change to `deploy/**` redeploys both (the deploy logic itself changed).

The control plane's `cloud/docker-compose.yml` also ships a self-hosted mail
relay (`postfix` service) — see `cloud/postfix/README.md` for its DNS/TLS/
Hetzner-port-25 setup; nothing extra is needed in this deploy pipeline.
Its TLS cert renews on its own schedule — see below.

## Required GitHub secrets (one-time, human-only)

Add under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DEPLOY_SSH_KEY` | The private key that can `ssh root@` both hosts (the Barkpark account key — locally `~/.ssh/barkpark_indx`). Paste the full PEM, including the BEGIN/END lines. |
| `CP_HOST` | Control-plane IP — `178.105.92.191` |
| `GUERRILLA_HOST` | Content-instance IP — `157.180.90.121` |
| `HETZNER_DNS_TOKEN` | Hetzner Cloud DNS-capable API token (the `barkpark.cloud`-zone project's token, NOT `CP_HOST`'s own server token — see `cloud/postfix/README.md` §1). Only used by `renew-mail-cert.yml`. |

The workflow uses an `environment: production` — to require a click-to-approve
before every prod deploy, add **required reviewers** to that environment in
GitHub (Settings → Environments → production). Leaving it without reviewers keeps
deploys fully automatic.

## Adding another host

1. Put its IP in a new secret (e.g. `PROD_HOST`).
2. If it's a content instance, reuse `instance-deploy.sh`; if a control plane,
   `cp-deploy.sh`. Add a job mirroring the matching one in `deploy.yml`.
   (The CLAUDE.md prod box `89.167.28.206` is a candidate once the deploy key is
   added to its `authorized_keys`.)

## Mail relay TLS renewal

`.github/workflows/renew-mail-cert.yml` runs `deploy/renew-mail-cert.sh` on
its own monthly schedule (unrelated to the push-triggered deploy above) —
re-issues the mail relay's Let's Encrypt cert via DNS-01, ships it to
`barkpark-cp`, reseeds the volume, reloads postfix. Manual re-run: **Actions
→ Renew mail relay TLS cert → Run workflow**.

## Manual / emergency

- Re-run from the **Actions** tab → the failed run → *Re-run jobs*.
- Run a deploy script directly on a box: `ssh root@<host>` then
  `bash /opt/barkpark/deploy/<script>.sh` (control plane also takes a prebuilt
  provisioner path arg).
- Rollback is automatic on an unhealthy boot (the new slot is stopped; the
  active one was never touched); scripts also leave the prior commit reachable
  (`git reset --hard <old>`) and, for the control plane, a
  `cloud-control_plane:rollback` image tag.
- Instant manual rollback after a bad-but-healthy swap: flip the port in
  `/etc/caddy/Caddyfile` back (4100↔4101 / 4000↔4001), `systemctl reload
  caddy`, start the old slot (`docker start …` / `systemctl start
  barkpark-slot@<slot>`).
