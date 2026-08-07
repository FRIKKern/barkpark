# Re-derivation recipe — after-measurement taken THROUGH `DeployLedger.census/2`

Verifier, deploy-reliability wave 6, 2026-08-06. Every number below is re-derivable
by the command beside it. Node = `cloud-control_plane_blue-1` on `178.105.92.191`.

## 0. The window pair (pinned, half-open `from <= inserted_at < to`)

- BEFORE `2026-08-05T17:00:00Z` → `2026-08-05T21:24:00Z`
- AFTER  `2026-08-05T21:24:00Z` → `2026-08-06T17:03:00Z`

## 1. psql pin (the raw `status` column)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i -e PGPASSWORD=78d44f09ad1663acdc470864e3cea1bc cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c "select status,count(*) from deployments where inserted_at>=timestamp '"'"'2026-08-05 21:24:00'"'"' and inserted_at<timestamp '"'"'2026-08-06 17:03:00'"'"' group by 1;"'
```

→ `deferred|602  failed|852  live|493` (total 1947).

## 2. The same window THROUGH the instrument

Write the script locally, `scp` to the host, `docker cp` into the container, then
run it with **`rpc`** — NOT `eval`. `eval` starts a bare VM with no Repo and dies
with `could not lookup Ecto repo BarkparkCloud.Repo because it was not started`.

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker cp /tmp/census.exs cloud-control_plane_blue-1:/tmp/census.exs && \
   docker exec cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc "Code.eval_file(\"/tmp/census.exs\")"'
```

`census.exs`:

```elixir
{:ok, f, _} = DateTime.from_iso8601("2026-08-05T21:24:00Z")
{:ok, t, _} = DateTime.from_iso8601("2026-08-06T17:03:00Z")
c = BarkparkCloud.DeployLedger.census(f, t)
IO.puts("VOLUME=#{c.volume} FAILED=#{c.failed}")
IO.inspect(c.failure_rate, label: "FAILURE_RATE")
Enum.each(c.classes, &IO.puts("C|#{&1.class}|#{&1.count}"))
Enum.each(c.deferred, &IO.puts("D|#{&1.class}|#{&1.count}"))
Enum.each(c.not_attempted, &IO.puts("N|#{&1.class}|#{&1.count}"))
Enum.each(c.sites, &IO.puts("S|#{&1.site_id}|vol=#{&1.volume}|failed=#{&1.failed}|def=#{&1.deferred}|pct=#{inspect(&1.failure_rate.pct)}|refused=#{&1.failure_rate.refused}"))
```

→ `VOLUME=1947 FAILED=852 pct=43.76 sample=1947 refused=false`, deferred
`BOX_BUSY_DEFERRED|602`, `not_attempted` EMPTY. Census == psql, exactly.

## 3. The three conventions, one script

Same harness, `doct.exs` — prints OLD (`(failed+deferred)/volume`), SHIPPED-AS-IS
(`failed/volume`), and SHIPPED-MATCHED (BEFORE with its 269 `BOX_BUSY_409` rows
moved to the deferred cohort, which is what the driver settles them as today):

```
OLD-CONVENTION  BEFORE=89.38 AFTER=74.68
SHIPPED-AS-IS   BEFORE=89.38 AFTER=43.76
SHIPPED-MATCHED BEFORE=41.77 AFTER=43.76
BOX_500 per attempt BEFORE=49/565=8.67 AFTER=298/1947=15.31
```

## 4. Naming the failure mass (no OTHER_FAIL bucket exists)

```
... psql -A -F"|" -c "select stage,left(coalesce(failure_reason,'(nil)'),60),count(*) from deployments where status='failed' and inserted_at>=timestamp '2026-08-05 21:24:00' and inserted_at<timestamp '2026-08-06 17:03:00' group by 1,2 order by 3 desc limit 25;"
```

Top rows: BOX_500 `internal_error` 221 BUILD + 54 PLAN + 23 HEALTH = 298;
`bp-doc-id marker is empty` 181 + 20 = 201; Turbopack 144 + `getPathsForRoute`
23 + tail = 183; `503: feature_not_configured — site deploys are not enabled on
this instance (set BARKPARK_SITE_DEPLOY_APPLY=1)` = 138, spread over all five hot
sites. Class counts sum to 852 = `failed`; `UNCLASSIFIED` is absent.

## 5. Determinism cross-check against the charter's own D76 pin

Same harness at `21:24Z → 2026-08-06T14:16:00Z` reproduces D76 byte-for-byte:
`vol=1718 failed=748 deferred=528 pct=43.54 old=74.27`.
