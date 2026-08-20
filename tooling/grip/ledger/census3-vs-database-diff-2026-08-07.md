# census/3 vs the database — re-derivation recipe (2026-08-07, wave 17 verify)

VERDICT: `DeployLedger.census/3` reproduces cloud-db-1 exactly. Zero divergence.
No hand-transcription trust required — the live node's own `census/3` was run and
diffed against one SQL snapshot of the same window.

## 1. The SQL transcription (census/3's exact shape)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"' \
      < /tmp/census3_shape.sql

`/tmp/census3_shape.sql` materialises census/3's groups verbatim —

    CREATE TEMP TABLE census_groups AS
    SELECT d.site_id, d.stage, d.status, d.failure_reason, count(d.id) AS count
      FROM deployments d
     WHERE d.inserted_at >= timestamp '2026-08-07 00:00:00'
       AND d.inserted_at <  timestamp '2026-08-08 00:00:00'
     GROUP BY d.site_id, d.stage, d.status, d.failure_reason;

— then reads every cohort off it. The cohort predicates are STATUS-ONLY, and that
is derivable from the module, not an approximation:

* `not_attempted` (`GITHUB_PUSH_UNBUILDABLE`) is reachable ONLY from
  `status='failed'` + `failure_reason LIKE 'github push builds require%'`
  (deploy_ledger.ex classify/2, first cond arm).
* the `deferred` cohort is EXACTLY `status='deferred'` — `classify/1`'s deferred
  arm matches on that status alone, and every `classify_deferred/2` return is in
  `@deferred_classes`.
* `failed_rows` is `settled` with a non-nil class; `classify/1` answers `nil` for
  every status other than `failed`/`deferred`, so it is exactly `status='failed'`
  minus not_attempted.
* `live` / `in_flight` / `cancelled` are read off `status` positively.

Therefore residual = rows whose status is none of
`failed, deferred, live, queued, building, pushing, cancelled`, and the six
cohorts are DISJOINT subsets of `attempted` — residual is structurally
non-negative, not merely observed non-negative.

## 2. The instrument itself, on the live node

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'cat > /tmp/rpc.exs && docker cp /tmp/rpc.exs cloud-control_plane_green-1:/tmp/rpc.exs && \
       docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc \
       "Code.eval_file(\"/tmp/rpc.exs\")"' < /tmp/rpc.exs

with `/tmp/rpc.exs`:

    {:ok, f, t} = BarkparkCloud.DeployLedger.parse_window("2026-08-07","2026-08-08")
    c = BarkparkCloud.DeployLedger.census(f, t)
    IO.puts(inspect(Map.drop(c, [:classes, :deferred, :not_attempted, :sites]), pretty: true))

The container is `cloud-control_plane_green-1` (blue/green — re-read
`docker ps` before quoting a container name; the slot moves).

## 3. The diff, 2026-08-07 window

| key | SQL | live census/3 |
|---|---|---|
| volume | 1705 | 1705 |
| failed | 18 | 18 |
| deferred | 1227 | 1227 |
| live | 459 → 460 | 460 |
| in_flight | 1 → 0 | 0 |
| cancelled | 0 | 0 |
| residual | 0 | 0 |
| failure_rate.pct | 1.06 | 1.06 |
| live_rate.pct | 26.92 → 26.98 | 26.98 |

The only moving number between the two snapshots is the single `building` row
settling to `live` — volume constant, `live` +1, `in_flight` −1. That is the
consistency proof, not an error bar.

## 4. Per-day residual + the discontinuity series (same SQL file, probe 2)

    2026-07-31 vol 2708 failed 2392 deferred    0 live 316 residual 0  fail 88.33%
    2026-08-01 vol 2217 failed 1933 deferred    0 live 284 residual 0  fail 87.19%
    2026-08-02 vol 2042 failed 1792 deferred    0 live 250 residual 0  fail 87.76%
    2026-08-03 vol 1050 failed  913 deferred    0 live 137 residual 0  fail 86.95%
    2026-08-04 vol  527 failed  446 deferred    0 live  81 residual 0  fail 84.63%
    2026-08-05 vol  878 failed  629 deferred  124 live 125 residual 0  fail 71.64%
    2026-08-06 vol 2205 failed  866 deferred  773 live 566 residual 0  fail 39.27%
    2026-08-07 vol 1705 failed   18 deferred 1227 live 460 residual 0  fail  1.06%

All-time census over 31,130 attempted rows: 1,490 groups, residual 0,
not_attempted 7.

## 5. Facts this recipe pins

* `deployments` carries ZERO CHECK constraints (`pg_constraint … contype='c'`
  returns 0 rows) — the gauge is the only backstop.
* `cancelled`, `queued`, `pushing` have ZERO rows on prod, all-time-current-state.
* 2 `preview` rows exist all-time (both `failed`, 2026-07-31 02:34) against
  31,135 `production`. census/3 has no environment predicate; today that costs
  0 rows, on 2026-07-31 it cost 2 of 2,708 (0.07%).
* first deferred row ever: `2026-08-05 21:27:11.41321` — an INSTANT inside the
  day, not midnight (leg 3).
