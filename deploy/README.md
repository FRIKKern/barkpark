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
        every deploy: build-before-swap → health-check → auto-rollback if unhealthy
```

| Target | Trigger paths | Script | Mechanism |
|---|---|---|---|
| Control plane | `cloud/**` | `deploy/cp-deploy.sh` | tag rollback image → `git pull` → `docker compose build` (old container still serving) → `up -d` (auto-migrates) → health `:4100` → rollback on fail. Provisioner cross-built by the runner (`cmd/barkpark-provisioner`, linux/amd64) and shipped (Go is not on the box). |
| Content instance | `api/**`, `internal/**` | `deploy/instance-deploy.sh` | `git pull` → backfill required secret keys → clean `_build/prod` + `deps.compile --force` + `compile` (old service still up) → `ecto.migrate` → restart → health `:4000` → rollback on fail. |

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
- Rollback is automatic on an unhealthy boot; a script also leaves the prior
  commit reachable (`git reset --hard <old>`) and, for the control plane, a
  `cloud-control_plane:rollback` image tag.
