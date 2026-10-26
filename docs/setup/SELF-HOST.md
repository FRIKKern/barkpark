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
