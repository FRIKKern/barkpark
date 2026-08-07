# Re-derivation recipe — deploy-reliability W5: the AFTER measurement taken THROUGH the shipped census

Taken 2026-08-06 14:52–15:05Z. Control plane 178.105.92.191, `uptime` load
average 0.49–0.79 printed before AND after every measuring run (D-measure-on-a-
quiet-host). Every number below comes out of `BarkparkCloud.DeployLedger.census/2`
itself or out of the `deployments.status` column it folds — never out of a hand
replication.

## 0. The HTTP route is DARK — it 403s for every human on prod

```sh
curl -s -H "Authorization: Bearer $(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")" \
  'https://barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-05T17:00:00Z&to=2026-08-05T21:24:00Z'
# {"error":"forbidden","scope":"platform","required":"platform_operator"}  HTTP 403

curl -s -H "Authorization: Bearer $TOKEN" https://barkpark.cloud/v1/me   # "platform_operator": false

ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec cloud-control_plane_blue-1 sh -lc "env | grep -iE \"PLATFORM|ADMIN\""; echo rc=$?'
# rc=1  → PLATFORM_ADMIN_EMAILS unset in the RUNNING container
```

`cloud/config/runtime.exs:337-340` reads `System.get_env("PLATFORM_ADMIN_EMAILS", "")`
into `:platform_admin_emails`; `Notifications.platform_admin_emails/0`
(notifications.ex:428) resolves that allowlist to registered users. Empty env →
empty allowlist → `Auth.require_platform_operator` fails closed for EVERYONE.
There is also no non-HTTP reader: `git grep -n 'deploy-ledger' origin/main --
internal/ js/ web/` returns nothing.

## 1. The instrument, run directly on the live node

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'uptime; docker exec \
  cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc "
{:ok,f,_}=DateTime.from_iso8601(\"<FROM>\");{:ok,t,_}=DateTime.from_iso8601(\"<TO>\");
c=BarkparkCloud.DeployLedger.census(f,t);
d=Enum.reduce(c.deferred,0,fn r,a -> r.count+a end);
IO.puts(\"vol=#{c.volume} failed=#{c.failed} pct=#{c.failure_rate.pct} deferred=#{d} old=#{Float.round((c.failed+d)*100/c.volume,2)}\");
IO.puts(inspect(Enum.map(c.classes, fn r -> {r.class, r.count} end), limit: :infinity))
"; uptime'
```

| window | vol | failed | shipped pct | deferred | old-convention pct |
|---|---|---|---|---|---|
| BEFORE 2026-08-05T17:00Z → 21:24Z | 565 | 505 | **89.38** | 0 | 89.38 |
| AFTER 21:24Z → 2026-08-06T14:16Z | 1718 | 748 | **43.54** | 528 | **74.27** |
| AFTER 21:24Z → 2026-08-06T14:30Z | 1728 | 752 | 43.52 | 531 | 74.25 |

The `to = 14:16Z` row is pinned to the survey's own n: row 1718 of the AFTER
cohort has `inserted_at = 2026-08-06 14:14:50.720115`, row 1719 is 14:16:50.
At that identical pin the survey reported 43.42 / 74.16 / 746 failed / 528
deferred. The instrument says **748 failed, 43.54, 74.27**. The deferred count
matches exactly; the failed count is off by 2, i.e. the survey headline is a
hand-replication that is 0.12pp / 0.11pp wrong. Both bounds sit ≥19 min behind
wall clock per D34(b).

## 2. Classifier vs status column — exact, and STRUCTURALLY near-vacuous

```sh
ssh … 'docker exec -i -e PGPASSWORD=<pw> cloud-db-1 psql -U barkpark_cloud \
  -d barkpark_cloud_prod -A -F"|" -c "select status, count(*) from deployments
  where inserted_at >= \$\$2026-08-05T21:24:00\$\$::timestamp
    and inserted_at <  \$\$2026-08-06T14:16:00\$\$::timestamp group by 1;"'
# failed|748  deferred|528  live|442
```

Census `failed` 748 == status `failed` 748; census deferred cohort 528 == status
`deferred` 528. Agreement is total — and it is guaranteed by construction, not
observed: `classify/1` dispatches on `status` FIRST (deploy_ledger.ex:202-212),
`@classes` (line ~90-105) and `@deferred_classes` (line 133-137) are disjoint,
so a deferred row can never enter the numerator and a failed row can never leave
it. The ONE escape hatch is `@not_attempted_classes = ["GITHUB_PUSH_UNBUILDABLE"]`
(line 110), which drops a `status:"failed"` row out of `volume` entirely:

```sql
select count(*) from deployments where inserted_at >= '2026-08-05T21:24:00'
  and inserted_at < '2026-08-06T14:16:00'
  and failure_reason like 'github push builds require%';   -- 0   (D19/D34: report the zero)
```

Deferred tail control — deferred rows whose reason is NOT an anchored 409:

```sql
select count(*) from deployments where … and status='deferred'
  and (failure_reason is null
       or failure_reason not like 'the instance refused the deploy (HTTP 409)%');  -- 0
```

So all 528 are `BOX_BUSY_DEFERRED`; `BOX_AT_CAPACITY_DEFERRED` is **0 rows** —
the concurrent-build cap (#9827) has not merged, so that arm has never fired in
production.

## 3. Per-site n≥200: the BEFORE window must reach ~35 h back, and one site never clears

```sql
with b as (select site_id, inserted_at,
             row_number() over (partition by site_id order by inserted_at desc) rn
           from deployments where inserted_at < '2026-08-05T21:24:00')
select s.slug, b.inserted_at t200,
       round(extract(epoch from ('2026-08-05T21:24:00'::timestamp - b.inserted_at))/3600,1) hours_back
from b join sites s on s.id=b.site_id where b.rn = 200;
```

| site | AFTER n | BEFORE 17:00–21:24 n | 200th row before 21:24 | hours back needed |
|---|---|---|---|---|
| live-auto | 351 | 110 | 2026-08-04 10:30:02 | 34.9 |
| search-capstone | 348 | 112 | 2026-08-04 10:25:02 | 35.0 |
| astro-search | 343 | 113 | 2026-08-04 10:33:17 | 34.8 |
| search | 341 | 112 | 2026-08-04 10:25:02 | 35.0 |
| search-ember | 329 | 114 | 2026-08-04 10:33:16 | 34.8 |
| perfect-proof | 16 | 4 | — (165 rows in ALL history) | never |

Every per-site rate in the 4.4 h BEFORE window is REFUSED by `min_sample 200`.
AFTER already clears it for the five busy sites. perfect-proof can never clear it
in any window and must print its refusal.

## 4. Naming the two big AFTER classes

```sql
select left(translate(failure_reason, chr(10)||chr(13), '  '),120), count(*)
from deployments where … and status='failed' and stage='BUILD' group by 1 order by 2 desc;
```

- **Turbopack, 144 rows** — `BUILD failed (exit 12): Error: Turbopack build failed
  with 29 errors:`. 144 of 144 belong to **search-capstone** and to no other site.
  A constant-count compile error in one site's own source. It is NOT box pressure
  and must not be read as one.
- **BOX_500, 298 rows** — `the instance refused the deploy (HTTP 500):
  internal_error — unknown error`, spread over all five busy sites and three
  stages (BUILD 221, PLAN 54, HEALTH 23 = 298). Already root-caused on the ledger as
  `task-cbde37238506ed7c`: a Postgrex `DBConnection.ConnectionError` on guerrilla
  under swap thrashing from concurrent builds. THIS one is the wish's box.
- `FORBIDDEN_403` is 0 in AFTER (35 in BEFORE); `DOC_ID_EMPTY` fell 116 → 161 is
  not a fall — it is the third-largest AFTER class.

## 5. The census is a ONE-BOX census

```sql
select b.slug, count(*), string_agg(s.slug,',') from sites s
  join barkparks b on b.id=s.barkpark_id group by 1;
-- guerrilla|12|…   jarl|1|jarl-website
```

Every site producing a deployment row lives on guerrilla. "Fleet failure rate"
is guerrilla's failure rate with a fleet's name on it.

## 6. Ex-search-capstone reading (D34's "constant, not a variable")

search-capstone: volume 347, failed 243 (70.03%), deferred 99 — 32.5 % of all
AFTER failures. Removing it: failed 505 / volume 1371 = **36.83 %** shipped,
(505+429)/1371 = **68.13 %** old convention.
