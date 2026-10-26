<!-- doc-tier: human | canonical-for: self-host-container | budget: 2500tok -->
# Run Barkpark from the container image

This page covers an instance that runs the `api/Dockerfile` image on a container platform, such as Azure Container Apps with one replica and a managed PostgreSQL server. It is experimental: the first such instance is Gyldendal's Pensum instance. For a single Ubuntu server, use [GO-LIVE.md](GO-LIVE.md) instead.

## Health probes

| Path | Answers | Use it for |
|---|---|---|
| `GET /livez` | Always `200 {"status":"ok"}` while the BEAM serves HTTP. It reads no database. | Liveness probe |
| `GET /readyz` | `200` when the database answers `SELECT 1`, no migration is pending and Oban is running; otherwise `503`. The body names each check: `{"status":"ready","checks":{"database":true,"migrations":true,"oban":true}}`. | Readiness and startup probes |
| `GET /status.json` | Component health, running commit, migration state and `uptime_seconds`. | Uptime monitors and people |

Neither probe needs a token or counts against rate limits. Point the liveness probe at `/livez` so a slow Postgres takes the replica out of traffic through `/readyz` instead of restarting it. The first boot runs migrations and seeds, so give the startup probe a window of at least 300 seconds, the same `start_period` the root `docker-compose.yml` uses.

```yaml
probes:
  - type: Liveness
    httpGet: { path: /livez, port: 4000 }
  - type: Readiness
    httpGet: { path: /readyz, port: 4000 }
  - type: Startup
    httpGet: { path: /readyz, port: 4000 }
    periodSeconds: 10
    failureThreshold: 30
```

## What the instance reports without barkpark-agent

On the managed Hetzner boxes, `barkpark-agent` (`internal/agent/report.go`) sends host health to the control plane. A container instance runs no agent and no control plane. The instance serves the signals it can measure itself, and Azure measures the host.

| Agent report field | Where to read it on a container instance |
|---|---|
| `health_checks`, `health_status` | `GET /readyz` and `GET /status.json` |
| `git_commit`, `version` | `GET /status.json` keys `commit` and `version` |
| `req_per_s`, `p95_ms`, `err_5xx_per_s` | `GET /v1/instance/request-stats` with a token |
| `beam_pss_bytes`, `mem_used_percent` | `vm_memory_total` in `GET /v1/instance/metrics` (operator token), and the Container Apps metric `WorkingSetBytes` |
| `cpu_percent` | Container Apps metric `UsageNanoCores` |
| `service_restarts` | Container Apps metric `RestartCount`. `uptime_seconds` in `/status.json` also resets at each restart. |
| `pg_size_bytes`, `disk_used_percent` | PostgreSQL Flexible Server metrics `storage_used` and `storage_percent`; Azure Files share capacity for media |
| `backup_state` | Flexible Server automated backups for the database; media backups need their own schedule |

The agent's load, swap, runaway-process and systemd slot fields describe a shared Linux host and have no meaning inside one container.

## Features that start local processes

The image ships the BEAM release, `bash`, `wget` and Debian's base tools. It has no `git`, `node`, `npm`, `claude`, `codex`, `bp`, `tmux`, `systemd`, `xmllint` or `procps` (`ps`, `kill`). The features below start one of those programs from the API node. Turn off each one you do not use.

| Feature | Module that starts the process | Program | Setting that turns it off |
|---|---|---|---|
| Studio chat with Claude, chat titles, readiness probe | `Barkpark.StudioChat.Provider.Claude`, `.Titles`, `.Probe` | `claude`, `kill` | `BARKPARK_CAPABILITIES_OFF=studio_chat` (or `BARKPARK_CLAUDE_CHAT=off` for the Claude provider only) |
| Studio chat with Codex | `Barkpark.StudioChat.Runtime.Codex.Session`, `.Readiness` | `codex` | `BARKPARK_CAPABILITIES_OFF=studio_chat` |
| Studio chat repository context | `Barkpark.StudioChat.ContextIdentity` | `git` | `BARKPARK_CAPABILITIES_OFF=studio_chat` |
| Cycle fleet release capture | `Barkpark.CycleFleet.ReleaseCaptureAdapter` | `bp` | `BARKPARK_CAPABILITIES_OFF=cycle_fleet` (turning off `epic_fleet` also refuses cycle routes) |
| Site builder | `Barkpark.Sites.DeployRunner` | `bash deploy/site-deploy.sh`, which runs `npm ci`, under `systemd-run` when present | Off unless `BARKPARK_SITE_DEPLOY_APPLY=1` |
| Site serving commit | `Barkpark.Sites.ServingMemory` | `git rev-parse HEAD` | Set `BARKPARK_GIT_SHA`; without `git` the commit reads as unknown |
| Self-update | `Barkpark.SelfUpdate.Runner` | `bash scripts/self-update.sh`, `git`, `mix` | Off unless `BARKPARK_SELF_UPDATE_APPLY=1` |
| Studio terminal | `BarkparkWeb.Studio.TmuxConsole` | `tmux` | `BARKPARK_TMUX_CONSOLE=off` |
| ONIX export validation | `Barkpark.Plugins.OnixEdit.Export.Validator` | `xmllint` | Leave `onixedit` out of `BARKPARK_PLUGINS` |
| Workspace export cleanup | `Barkpark.Tenancy.WorkspaceBundle.Janitor` | `ps` | No setting. Without `ps` the janitor keeps every stale bundle file instead of deleting it. |
| Workspace export space check | `Barkpark.Tenancy.WorkspaceBundle.Archive` | `df` | No setting needed; `df` is in the image. |
| Image processing on Windows | `Barkpark.Media.ImageBackend.Magick` | `magick` | Linux uses the libvips NIF and starts no process. |

`Barkpark.PortReaper` runs `kill` only for the chat, cycle, site and self-update processes above. Two more features need something outside the image without starting a process from the API. Connectors (Slack, Linear) talk to a separate Node bridge and stay off while `CONNECTORS_CONNECT_SECRET` is unset. Indx search stays idle without `INDX_API_BASE`; if you use it, set `BARKPARK_INDX_STATE_DIR` to persistent storage such as the Azure Files mount, because the image's default path is lost when the replica restarts.

For a Pensum-only instance with core, media and Studio, set:

```bash
BARKPARK_PLUGINS=media
BARKPARK_CAPABILITIES_OFF=studio_chat,cycle_fleet,epic_fleet
BARKPARK_TMUX_CONSOLE=off
```

Leave `BARKPARK_SITE_DEPLOY_APPLY`, `BARKPARK_SELF_UPDATE_APPLY`, `CONNECTORS_CONNECT_SECRET` and `INDX_*` unset. An empty `BARKPARK_PLUGINS` is the plugin kill switch and turns off media too, so name `media` explicitly.

## Rotate keys held in Azure Key Vault

`api/config/runtime.exs` reads the keys below. Keep each in Key Vault behind a Container Apps secret reference, and use a versioned secret URI. A versionless URI restarts the replica on its own within 30 minutes of a new version, which breaks the KEK order below. A versioned URI changes only when you point it at a new version and restart:

```bash
az containerapp secret set -g "$RG" -n "$APP" \
  --secrets "barkpark-kek=keyvaultref:$KV_URL/secrets/barkpark-kek/$VERSION,identityref:system"
az containerapp revision restart -g "$RG" -n "$APP" --revision "$REVISION"
```

| Variable | What it protects | What a rotation ends | Re-key command |
|---|---|---|---|
| `BARKPARK_KEK` with `BARKPARK_KEK_PREVIOUS` and `BARKPARK_KEK_VERSION` | Wraps the per-workspace data keys in the `data_keys` table. Those data keys encrypt workspace secrets and fields marked `encrypted: true`. | Nothing, when you follow the steps below | `Barkpark.Crypto.DataKeys.rewrap_all()` |
| `BARKPARK_CLOAK_KEY` | Cloak fields: TOTP secrets, SSO and social sign-in client secrets, plugin settings, instance-wide secrets, login tickets and token sign-in sessions | Every value above. Rows sealed under the old key no longer load. | None. See below. |
| `SECRET_KEY_BASE` | Session cookies, LiveView and `Phoenix.Token` signatures, and media signed URLs unless `MEDIA_SIGNING_SECRET` is set | Every browser session, so editors sign in again. A passkey ceremony in progress fails. Signed media URLs stop working. | None needed |
| `PREVIEW_JWT_SECRET` | Draft preview tokens (JWTs), not the stored `/preview-links` | Preview tokens issued before the change. They last `PREVIEW_JWT_TTL_SECONDS`, 600 seconds by default. | None needed |

To rotate `SECRET_KEY_BASE` or `PREVIEW_JWT_SECRET`, add a Key Vault version, point the reference at it and restart. Give `MEDIA_SIGNING_SECRET` its own Key Vault secret if signed media URLs must survive a `SECRET_KEY_BASE` rotation. API tokens are stored as SHA-256 hashes and survive every rotation. Passkeys depend on `PHX_HOST`, not on a key. A passkey registered under one host stops working when `PHX_HOST` changes to another domain.

### Rotate the KEK

The KEK wraps the data keys, not the content, so a rotation re-wraps those keys and re-encrypts no content. Run the steps in order, so every restart can still read every data key.

1. Store the current KEK value as a new Key Vault secret `barkpark-kek-previous`. Set `BARKPARK_KEK_PREVIOUS` to reference it and restart. `/status.json` must show the `kek_previous` component as `operational`. A malformed entry shows as `degraded`.
2. Add a new version of `barkpark-kek` with the value from `openssl rand -base64 32`. Point the reference at that version, raise `BARKPARK_KEK_VERSION` by one, and restart. Old data keys still unwrap with the previous key.
3. Re-wrap every data key from a shell in the running replica:

   ```bash
   az containerapp exec -g "$RG" -n "$APP" --command /bin/bash
   bin/barkpark rpc 'IO.inspect(Barkpark.Crypto.DataKeys.rewrap_all())'
   ```

   `{:ok, n}` means all `n` data keys use the new KEK. `{:error, {:unwrap_failed, id}}` rolls back the run and names a key neither KEK opens. Stop there and keep both keys.
4. Remove `BARKPARK_KEK_PREVIOUS` and restart. Disable the old Key Vault version. Purge it only after a backup taken after step 3 has been restored once.

### Cloak key

`Barkpark.Vault` configures one AES-GCM cipher and no retired cipher, and no command re-encrypts Cloak fields. Keep `BARKPARK_CLOAK_KEY` unchanged. After a change, every row sealed under the old key fails to load, including the user row of anyone with TOTP. Recovering from a leaked Cloak key therefore means clearing each Cloak column and entering the secrets again, and no tool does that today.
