# dr-w15-v8 — post-#10015 capability size (re-derivation recipes)

Verifier assignment `post-10015-capability-size`, wave 15, 2026-08-07.
Every row below is a command that re-derives the fact from scratch. Nothing here is a reading.

## 1. Present-tense capability signal (the number that replaces 138)

```sh
D=$(mktemp -d); cat > $D/v8.sql <<'EOF'
SELECT count(*) AS sanity_total FROM deployments;
SELECT count(*) FILTER (WHERE failure_reason LIKE '%feature_not_configured%') AS fnc_all,
       count(*) FILTER (WHERE failure_reason LIKE '%feature_not_configured%'
                          AND inserted_at > '2026-08-07 06:52Z') AS fnc_post_fix,
       count(*) FILTER (WHERE failure_reason LIKE '%runner_unavailable%') AS runner_unavail
  FROM deployments;
EOF
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -f -' < $D/v8.sql
```

NOTE THE TRAP: `scp`ing the file to the host and running `psql -f /tmp/v8.sql` FAILS with
`psql: error: /tmp/v8.sql: No such file or directory` — psql runs INSIDE container `cloud-db-1`,
whose `/tmp` is not the host's. Always pipe the SQL in on stdin with `-f -`.

Observed 2026-08-07 14:33Z: `sanity_total=30956`, `fnc_all=265`, `fnc_post_fix=0`, `runner_unavail=0`.

## 2. The fnc timeline (proves the count is pre-fix, not window drift)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "
SELECT max(inserted_at) AS last_fnc, min(inserted_at) AS first_fnc FROM deployments WHERE failure_reason LIKE '"'"'%feature_not_configured%'"'"';"'
```

Observed: last_fnc = `2026-08-07 03:19:21.786192`, i.e. 3h33m BEFORE the 06:52Z merge of d73c5b526.
Per-day: 08-07=3, 08-06=212, 08-05=21, 08-03=8, 08-01=2, 07-31=6.

## 3. Post-fix outcome mix (where the volume actually goes now)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "
SELECT status, count(*) FROM deployments WHERE inserted_at > '"'"'2026-08-07 06:52Z'"'"' GROUP BY 1 ORDER BY 2 DESC;"'
```

Observed: `deferred=336`, `live=145`, `failed=4` (485 total). The dominant `failure_reason` in that
window is `box_at_capacity` at 335 rows — and all-time `box_at_capacity` is `deferred=1306 / failed=6`.
`feature_not_configured` is all-time `failed=265 / 0 deferred`.

## 4. Guerrilla actually runs the fix, on both slots

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'systemctl is-active barkpark-slot@blue barkpark-slot@green; cat /opt/barkpark/.slots/blue.sha /opt/barkpark/.slots/green.sha; git -C /opt/barkpark log -1 --format=%H'
git -C <repo> merge-base --is-ancestor d73c5b526 <slot-sha> && echo CONTAINS-FIX
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl show barkpark-slot@blue -p ActiveEnterTimestamp -p SubState'
```

Observed: blue `active`/`running`, green `inactive`; blue.sha=`8e770a08efdb…` (== repo HEAD),
green.sha=`77cf2060cf5e…`; d73c5b526 is an ancestor of BOTH. Active BEAM entered at
`Fri 2026-08-07 14:02:33 UTC` — after the fix, so the running code carries it.

## 5. Is the 5,000 ms caller budget itself fixed, or only relabelled?

```sh
git grep -n 'trigger_call_timeout_ms' origin/main          # EXHAUSTIVE — 7 hits, whole repo
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '188,200p;340,348p;434,440p'
```

Observed: `@trigger_call_timeout_ms 30_000` (:200) and `trigger/1` passes it explicitly (:345), so the
TIMEOUT is genuinely fixed, not just the label. BUT `safe_call/3`'s default is still `5_000` (:437) and
`status/1` (:426) takes it with fallback `idle_status(slug)` — a wedged Runner reports `state: :idle`.
And the ONLY test reference is `api/test/barkpark_web/controllers/site_deploy_controller_test.exs:217`,
which SETS `trigger_call_timeout_ms: 25`. Nothing observes the 30_000 default: mutating it back to
5_000 leaves the suite green.

## 6. Does the running BEAM expose "can I deploy sites"?

```sh
git grep -ni 'site_deploy\|deploy_apply\|DeployRunner' origin/main -- \
  api/lib/barkpark_web/controllers/capabilities_controller.ex api/lib/barkpark/capabilities.ex
```

Observed: ZERO hits. `/v1/capabilities` does not carry the deploy capability today.

## 7. Where the flag lives on guerrilla

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'grep BARKPARK_SITE_DEPLOY_APPLY /opt/barkpark/.env /opt/barkpark/.slots/blue.env /opt/barkpark/.slots/green.env'
```

Observed: set to `1` in ALL THREE — `/opt/barkpark/.env`, `blue.env`, `green.env`.
