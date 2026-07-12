# telemetry-inventory — reproducibility transcripts

Repo-side evidence backing the guerrilla paper `telemetry-inventory` (Perfect-Plan
research wave, charter D12, open question 6). The paper is the deliverable and lives
on guerrilla at `/papers/telemetry-inventory`; this file is the durable, greppable
record of the commands that produced its verdict so a reviewer can re-run them.

Verdict: **SETTLED — a per-workspace telemetry dimension is confirmed greenfield.**

## System inventory (file:line)

- **api/ Prometheus core** — `api/lib/barkpark_web/telemetry.ex:41-116`
  (`prometheus_metrics/0`, 8 curated metrics). Served Bearer-gated at
  `GET /v1/instance/metrics` — `api/lib/barkpark_web/router.ex:1397`,
  `api/lib/barkpark_web/controllers/metrics_controller.ex:21-27`. The larger
  `metrics/0` list (telemetry.ex:118+) feeds LiveDashboard only (`if dev_routes`).
- **cloud/ usage meters** — `cloud/lib/barkpark_cloud/usage.ex:161-200`
  (`compose/1`, 13-meter vocabulary) fed by `BarkparkCloud.Telemetry.normalize/1`
  (`cloud/lib/barkpark_cloud/telemetry.ex:64-89`). Grain = per-INSTANCE; every
  `usage_samples` row keys on `barkpark_id` (usage.ex:380,460,542).

## Headline — live label-key scrape (guerrilla)

```
$ curl -s https://guerrilla.barkpark.cloud/v1/instance/metrics \
    -H "Authorization: Bearer $TOK" \
  | grep -oE '\{[^}]*\}' | grep -oE '[a-z_]+=' | sort -u
event=
le=
module=
op=
route=

$ curl -s .../v1/instance/metrics -H "Authorization: Bearer $TOK" \
  | grep -oE '\{[^}]*\}' | grep -oE '[a-z_]+=' | grep -E '(workspace|tenant|dataset)='
$ echo "exit=$?"
exit=1        # zero per-workspace label key
```

`:dataset` appears ONLY inside a `route="/v1/data/mutate/:dataset"` label value — a
route-template segment (one series across all tenants), never an aggregation key.

## Source-side tag sweep (both systems)

```
$ grep -rnE 'tags:\s*\[:(route|op|event|module|surface|result)' \
    api/lib/barkpark_web/telemetry.ex | wc -l
8
$ grep -rnE 'tags:\s*\[[^]]*(workspace|tenant|dataset)' \
    api/lib/barkpark_web/telemetry.ex \
    cloud/lib/barkpark_cloud/telemetry.ex \
    cloud/lib/barkpark_cloud/usage.ex ; echo "exit=$?"
exit=1
```

## db_size sentinel — closed

```
$ git merge-base --is-ancestor f5554231 origin/main && echo LIVE
LIVE                                # PR #2648: db_size_meter guards n >= 0
$ git merge-base --is-ancestor 30f59a6c origin/main || echo 'NOT on main (retire pin)'
NOT on main (retire pin)
$ grep -n 'PGSizeProbe' cmd/barkpark-agent/main.go
(no match — ReportConfig lines 72-93 never wires it)
$ grep -n 'PGSizeBytes' internal/agent/report.go
57:  PGSizeBytes int64 `json:"pg_size_bytes"`
194:  PGSizeBytes:     -1,               # default; unchanged when probe unwired
244:  if cfg.PGSizeProbe != nil {         # dead branch on the shipped agent
```

→ guerrilla `db_size` honestly reads `unmetered`, source `telemetry.pg_size_bytes`.

## felix-findings-telemetry — adjacent, not covering

Full-text of `/papers/felix-findings-telemetry`: `db_size` 0, `pg_size` 0,
`per-workspace` 0 occurrences. It is Phoenix/Ecto/LiveView observability
(tenant-id-in-logs proposals), disjoint from this metering inventory. Linked as
adjacent from the paper.

## Recommendation

Extend existing emission with a `:workspace_id` tag on the content mutate/lifecycle
spans (api/) and a per-workspace roll-up off the same agent beat (cloud/). Never a
new telemetry system. This is the shared-cells pressure-score input — one tag away.
