# Re-derivation recipes — the 2026-08-08 10:00–14:55Z five-site guerrilla outage: what reported it

Verifier row, wave 26 (deploy-reliability). Ground: origin/main @ `0239dd4ee`. All commands
run 2026-08-09 ~00:20–00:40Z. Every row below is a literal command; none is arithmetic.

Prelude for every psql row (heredoc avoids the `chr()`/quoting trap that made the
assignment's MUST-RUN one-liner die with `syntax error at or near "("`):

```
cat > /tmp/q.sql <<'SQL'
<the SQL>
SQL
ssh -o BatchMode=yes -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|"' < /tmp/q.sql
```

Window bounds are epoch-anchored so no timezone literal is parsed twice:
`to_timestamp(1786179600)::timestamp` = 2026-08-08 09:00Z, `to_timestamp(1786204800)::timestamp`
= 2026-08-08 16:00Z. `notification_deliveries.inserted_at` and `deployments.inserted_at` are
`timestamp WITHOUT time zone` and store UTC.

## R1 — the alert instrument DID fire, and it fired at exactly one tenant address

```
select event, recipient, team_id, status, http_status, attempts, count(*) as n
from notification_deliveries
where inserted_at >= to_timestamp(1786179600)::timestamp
  and inserted_at <  to_timestamp(1786204800)::timestamp
group by 1,2,3,4,5,6 order by n desc;
```

Expect exactly two rows, both `recipient=frikk@guerrilla.no`, both `team_id=506f035e-…`,
both `status=sent`, `http_status` NULL: `deployment_failed` n=18, `agent_unreachable` n=12.
30 rows total. If a platform/operator address ever appears here, this row has changed.

## R2 — the corrected numerator (D375 is refuted)

```
select count(*) as failed_total, max(inserted_at) as last_failed from deployments where status='failed';
select date_trunc('day',inserted_at) d, status, count(*)
from deployments where inserted_at > to_timestamp(1786060800)::timestamp group by 1,2 order by 1,2;
```

Expect `18640|2026-08-08 14:55:28.776961`, and the day rollup to carry
`2026-08-08|failed|18` beside `2026-08-08|live|238` / `deferred|502`.

## R3 — five sites, one team

```
select s.name, s.team_id, d.status, count(*) n, min(d.inserted_at), max(d.inserted_at)
from deployments d join sites s on s.id=d.site_id
where d.status='failed' and d.inserted_at >= to_timestamp(1786179600)::timestamp
group by 1,2,3 order by n desc;
```

`search-capstone` 6 · `search-ember` 5 · `live-auto` 4 · `search` 2 · `astro-search` 1;
all `team_id=506f035e-08f4-4b49-9038-86735eb4c0ef`.

Causes (`failure_reason`, first 90 chars): `instance guerrilla is unreachable …` 8,
`HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty …` 6,
`deploy process died abnormally` 2, + 2 singletons. All `trigger=content-auto`, `source=box-build`.

## R4 — the operator digest is a permanent silent no-op

```
select kind, event, count(*) n, max(inserted_at) from notification_deliveries group by 1,2 order by n desc;
select id, state, inserted_at, completed_at from oban_jobs where worker like '%DailyDigest%' order by inserted_at;
```

First: seven `(kind,event)` pairs lifetime, and **no `fleet_digest` row exists at all**.
Second: exactly four completed jobs — 08-02, 08-04, 08-05, 08-07 — none on 2026-08-08 (the
outage day) and none since. Cause, one hop away:

```
ssh … root@barkpark.cloud 'docker exec cloud-control_plane_green-1 sh -c "printenv | grep -i -E \"PLATFORM_ADMIN|ADMIN_EMAIL\" || echo NO_PLATFORM_ADMIN_ENV"'
```

Prints `NO_PLATFORM_ADMIN_ENV`; `Notifications.deliver_fleet_digest/1`
(cloud/lib/barkpark_cloud/notifications.ex:350-357) takes the `[] -> {:ok, :no_admins}`
branch, logs, and writes nothing. The job is `completed` either way.

## R5 — zero GitHub signal

```
gh run list --workflow deploy.yml --limit 200 --json conclusion,createdAt \
  -q '[.[]|select(.createdAt>"2026-08-08T09:00:00Z" and .createdAt<"2026-08-08T16:00:00Z")]|group_by(.conclusion)|map({c:.[0].conclusion,n:length})'
```

Expect `[{"c":"cancelled","n":14},{"c":"success","n":14}]` — zero `failure`. Issues:

```
gh issue list --state all --limit 200 --json number,title,createdAt \
  -q '[.[]|select(.createdAt>"2026-08-08T09:00:00Z" and .createdAt<"2026-08-08T16:00:00Z")]|length'
```

185 — all wave-56 findings; none names the outage (checked via
`gh issue list --search "outage in:title"` and `--search "deployment_failed"`).

## R6 — the ~23:51Z control-plane restart was a DEPLOY, and it ate a sampler tick

```
ssh … root@barkpark.cloud 'docker ps -a --format "{{.Names}}|{{.Status}}|{{.CreatedAt}}"; \
  docker inspect -f "{{.Name}} started={{.State.StartedAt}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}" cloud-control_plane_green-1; uptime'
```

`cloud-control_plane_blue-1 | Exited (137) | 2026-08-08 23:48:20` and
`cloud-control_plane_green-1 started=2026-08-08T23:51:03Z restarts=0 oom=false exit=0`;
host `up 40 days`; `cloud-db-1` untouched since 2026-07-23. Blue/green cutover, not a crash,
not an OOM. Corroborated by `gh run list --limit 30` → `Deploy (production) success 0239dd4e`
finishing `2026-08-08T23:54:21Z`.

The tick it ate (`usage_samples` is a 15-minute cadence):

```
select date_trunc('minute', inserted_at) m, count(*) from usage_samples
where inserted_at >= to_timestamp(1786231200)::timestamp and inserted_at < to_timestamp(1786234800)::timestamp
group by 1 order by 1;
```

Expect `23:22|8`, `23:37|8`, `00:07|8`, `00:22|…` — **23:52 absent**. One scheduled tick lost
per control-plane deploy, and nothing reports it.

## R7 — the restart also destroyed the delivery proof

```
ssh … root@barkpark.cloud 'docker logs cloud-postfix-1 2>&1 | grep -c .'
```

Returns `7`. `cloud-postfix-1` started `2026-08-08T23:51:01Z` in the same cutover, so the
maillog covering the outage's 30 alert sends no longer exists anywhere. `status='sent'` in
`notification_deliveries` is a *mailer-accepted* claim with `http_status` NULL — there is no
surviving evidence any of the 30 emails reached a human.
