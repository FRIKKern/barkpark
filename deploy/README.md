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
script (121 checks: slot selection, flip, failure semantics, channel seam,
coalesce, rollback happy flip-back + typed refusals + unhealthy fail-closed,
/mcp route idempotence + the barkpark-mcp install guard):
`deploy/instance-deploy_test.sh`.

**Remote MCP endpoint (`/mcp`).** `instance-deploy.sh` arms an idempotent
path-based Caddy route (`handle /mcp /mcp/*` → `localhost:4010`, marker
`BARKPARK_MCP_ROUTE`) on the existing public site and — GUARDED, non-fatal —
installs/enables `deploy/systemd/barkpark-mcp.service` (`bp mcp serve --http`)
only when the just-built binary advertises `--http`, so the deploy step ships
independently of the bearer transport slice. Forward-through auth: the unit and
`/etc/barkpark/mcp.env` hold NO token; the caller's own bearer is the only
credential and a bogus one fails closed downstream. Port 4010 is deliberately
outside the blue/green slot ports — the flip sed and ACTIVE_PORT greps match
slot ports exactly and pass over it.

**Rollback (W6).** Every deploy stamps `.slots/<target>.sha` so the box knows
what its idle slot holds. `instance-deploy.sh --rollback-preflight` (read-only)
answers whether a rollback is possible: exit 0 prints `TARGET_SLOT=`/
`TARGET_SHA=`; typed refusals — 21 `no_previous_slot`, 22 `not_supported`
(pre-stamp box), 23 deploy lock held. `instance-deploy.sh --rollback` flips to
the idle slot at its recorded sha: `git reset --hard <stamp>` first (a bare
port flip lies — both slots share ONE checkout, so a slot restart would
recompile NEW source into the old build root), reboot the slot, health-gate it
on its own port, flip Caddy only on green, rewrite `.instance-deploy-last`.
Unhealthy = fail closed: slot re-disabled, Caddy untouched, checkout reset
back, exit 24. Schema stays forward — rolling back code does NOT undo a
migration; write a compensating one.

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

## Staging channel — prove a Barkpark build before the fleet gets it

`staging.barkpark.cloud` is one disposable box that runs Barkpark **itself**, so a
new build is smoke-tested BEFORE the merge train auto-deploys it everywhere. It is
NOT local dev, NOT guerrilla (the content + `bp`-task server, role untouched), NOT
old prod, NOT the control plane — it owns its DNS/TLS, Postgres, `.env`, and a
throwaway dataset, and is resettable without touching any prod data.

**One script, two channels.** `instance-deploy.sh` picks its behaviour from a
marker file — the **fail-closed safety boundary**:

| Channel | `/opt/barkpark/.staging` | Trigger | Ref it deploys |
|---|---|---|---|
| guerrilla / prod | **absent** | merge → `deploy.yml` | strict **fast-forward `origin/main`** only |
| staging | **present** | on-demand only — never a merge job | `DEPLOY_REF` (any branch, or a PR as `pull/<n>/head`) from `DEPLOY_REMOTE` (default `origin`), hard reset |

Marker absent, the script refuses any non-ff move — every fleet box can only ever
advance along `main`, so a random branch can never be pushed to it. Present, it
opts that ONE box into arbitrary-ref, hard-reset deploys. The boundary is the file,
not a flag: no marker, no non-`main` deploy, ever.

**The verb.** `bp cloud deploy staging [--branch <x> | --pr <n>] [--clean]` sshes
the staging host and runs `instance-deploy.sh` with `DEPLOY_REF` set (default: the
current `main`). It writes **zero** `bp` config — your active server
(`~/.config/barkpark/`, = guerrilla) is untouched and `bp` never defaults to
staging; staging content ops use an **ephemeral** target instead
(`bp -s https://staging.barkpark.cloud …`, never a remembered server).

- `--branch <x>` / `--pr <n>` — deploy that ref instead of `main`. This is the
  whole point of staging: try a build **before** the auto-deploy-on-merge train.
- `--clean` — `rm /opt/barkpark/.instance-deploy-last` first, forcing a full
  rebuild even when the ref looks unchanged (skips the coalesce no-op check).

**The canary loop** — how a Barkpark change reaches the fleet safely:

```
1. worktree branch     git worktree add ../wt -b fix/x
2. deploy to staging   bp cloud deploy staging --branch fix/x
3. smoke the box       curl -s  https://staging.barkpark.cloud/api/schemas | head
                       curl -sL https://staging.barkpark.cloud/studio | grep -E 'pane-layout|Sign in'
                       curl -s  https://staging.barkpark.cloud/v1/data/query/production/post | grep count
4. merge the PR        green smokes → merge to main
5. fleet auto-deploys  deploy.yml ships main to guerrilla/prod (pipeline at top)
```

**Identity + data.** The staging build serves a `BARKPARK_ENV=staging` banner in
Studio so a human can never mistake it for prod. Its Postgres is its own and
**disposable** — reset it freely (a `bp cloud deploy staging --reset` verb lands in
wave 2; today reset is manual on the box).

**Adding the staging host** (mirrors *Adding another host*):

1. Trust the operator key: the verb sshes as `root` with `~/.ssh/barkpark_indx`
   (override: `BARKPARK_SSH_KEY_FILE`) — add its public half to the staging box's
   `authorized_keys`. (CI's `DEPLOY_SSH_KEY` is NOT involved — staging never
   deploys from a merge job.)
2. Point the verb at it — host resolution, first match wins: `--host <ip>`; the
   control-plane fleet row by name (needs `bp login`); `BARKPARK_STAGING_HOST`.
   No default — with none of the three it errors, naming all three paths.
3. Arm the channel ON THE BOX: `touch /opt/barkpark/.staging`. Without it the box
   stays strict-`main` and every staging deploy is refused — fail-closed by design.

## Instance mail (provisioner-injected)

Every provisioned instance must relay transactional mail (magic-link /
password-reset / verify-email) through the control-plane Postfix relay, or
`Barkpark.Mailer` falls back to the never-delivering Local adapter and identity
emails silently drop. The **provisioner** does this automatically: set these on
`barkpark-cp:/etc/barkpark-provisioner.env` (the worker's `EnvironmentFile`) and
each go-live writes them into the new box's `/opt/barkpark/.env`:

```
SMTP_RELAY_HOST=mail.barkpark.cloud
SMTP_RELAY_PORT=587
SMTP_RELAY_USERNAME=barkpark-cloud        # same SASL user as the CP's own postfix
SMTP_RELAY_PASSWORD=…                      # = cloud/.env SMTP_PASSWORD
```

Unset → instances provision without SMTP (no mail), same as before. A
partial/malformed relay is logged at worker startup (`mail relay DISABLED — …`)
and skipped rather than shipping a broken `.env`; a good one logs `mail relay
ENABLED`. The relay submission port (587) is published for instances by
`cloud/docker-compose.yml`; it is SASL-gated (not an open relay).

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
