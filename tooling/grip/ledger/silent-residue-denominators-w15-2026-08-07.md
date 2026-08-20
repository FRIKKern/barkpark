# Silent-residue denominators — wave 15 verify (2026-08-07)

Re-derivation recipes for the residue counts. Host `178.105.92.191`, container
`cloud-db-1`, db `barkpark_cloud_prod`. NOTE: `psql -f /tmp/x.sql` FAILS — the
container has its own `/tmp`. Pipe on stdin instead (`< /tmp/x.sql`).

## Sanity total + the four mandated probes (ALL ZERO)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
SELECT count(*) AS sanity_total FROM deployments;\""
# -> 30956

ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
SELECT count(*) FILTER (WHERE failure_reason LIKE '%instance unreachable%'
                          AND failure_reason NOT LIKE '%is unreachable%') AS reaper_unreachable,
       count(*) FILTER (WHERE failure_reason LIKE '%gave up waiting for a deploy lock%') AS exit15,
       count(*) FILTER (WHERE failure_reason LIKE '%exceeded its deadline and was force-closed%') AS exit_minus2,
       count(*) FILTER (WHERE failure_reason LIKE 'SWITCH failed%') AS exit16,
       count(*) FILTER (WHERE failure_reason LIKE '%no dist/%') AS exit13,
       count(*) FILTER (WHERE status='cancelled' AND failure_reason IS NOT NULL) AS cancelled_with_reason,
       count(*) FILTER (WHERE status IN ('queued','building','pushing')) AS inflight
  FROM deployments;\""
# -> 0 | 0 | 0 | 0 | 0 | 0 | 0
```

## The anti-vacuity control (proves the LIKE machinery CAN match)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
SELECT count(*) FILTER (WHERE failure_reason LIKE '%(exit %') AS any_exit_code,
       count(*) FILTER (WHERE failure_reason LIKE '%BUILD failed%') AS build_failed,
       count(*) FILTER (WHERE failure_reason LIKE '%HEALTH gate%') AS health_gate,
       count(*) FILTER (WHERE failure_reason LIKE '%unreachable%') AS any_unreachable
  FROM deployments;\""
# -> 5264 | 1580 | 3688 | 126   (so the zeros above are REAL zeros)
```

## Exit codes that production has ever produced

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
SELECT substring(failure_reason from '\\(exit (-?[0-9]+)\\)') AS exit_code, count(*)
  FROM deployments WHERE failure_reason LIKE '%(exit %' GROUP BY 1 ORDER BY 2 DESC;\""
# -> 14: 3688 | 12: 1575 | 10: 1     (11 of exit_label/1's 14 templates: zero population)
```

## Statuses that have EVER existed (only three)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
SELECT status, count(*), count(failure_reason) AS with_reason,
       min(inserted_at), max(inserted_at) FROM deployments GROUP BY 1 ORDER BY 2 DESC;\""
# -> failed 18622 (18622 w/reason) | live 10330 (0) | deferred 2004 (2004, first 2026-08-05 21:27:11)
# 'cancelled', 'queued', 'building', 'pushing' -> ZERO rows, ever.
```

## The EXACT UNCLASSIFIED residue (every classify/2 arm replicated in SQL)

Arms replicated from `git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex`
(`classify/2` :233-278, `health_gate?/1` :541, `source_unfetchable?/1` :557).

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
SELECT left(failure_reason,70) AS reason, stage, count(*) FROM deployments
WHERE status='failed'
  AND failure_reason NOT LIKE 'the instance refused the deploy (HTTP%'
  AND NOT (failure_reason LIKE '%bp-doc-id%')
  AND NOT (stage='HEALTH' AND (failure_reason LIKE 'HEALTH gate failed%' OR failure_reason LIKE 'HEALTH failed%'))
  AND NOT (stage='BUILD' AND failure_reason LIKE 'BUILD failed (exit%')
  AND NOT (failure_reason LIKE 'missing site source dir%'
        OR failure_reason LIKE 'artifact: artifact_url is empty%'
        OR failure_reason LIKE '%fetch failed%')
  AND failure_reason NOT LIKE '%is unreachable%'
  AND failure_reason NOT LIKE 'the build did not finish in time%'
  AND failure_reason NOT LIKE 'exceeded max deploy claim attempts%'
  AND failure_reason NOT LIKE 'deploy process died abnormally%'
  AND failure_reason NOT LIKE 'github push builds require%'
GROUP BY 1,2 ORDER BY 3 DESC;\""
# -> nixpacks build: exit status 1 (2) | BUILD failed — \x1B[22m (1)
#    BUILD failed — at async #getPathsForRoute (1) | docker run: exit status 125 (1)
# TOTAL 5 all-time, 0 in 7d. 5 / 18,622 failed = 0.027%.
```

## Per-day cohort split (the deferred re-bucketing)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
SELECT date_trunc('day', inserted_at)::date AS day,
       count(*) FILTER (WHERE status='failed') AS failed,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       count(*) FILTER (WHERE status='live') AS live,
       round(100.0*count(*) FILTER (WHERE status='live')/count(*),2) AS live_pct
  FROM deployments WHERE inserted_at > now() - interval '10 days' GROUP BY 1 ORDER BY 1;\""
# 08-01 12.81 | 08-02 12.24 | 08-03 13.05 | 08-04 15.37 | 08-05 14.24 | 08-06 25.67 | 08-07 26.20
# 08-07: deferred 1109 / 1527 attempts = 72.63%
```
