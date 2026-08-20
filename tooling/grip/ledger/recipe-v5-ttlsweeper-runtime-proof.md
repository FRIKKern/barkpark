# Re-derivation recipe — v5-ttlsweeper-runtime-proof (PDS wave 23 verify)

All commands are READ-ONLY. `$PG` below is guerrilla's prod DB, reached as:

```sh
SSH='ssh -i ~/.ssh/barkpark_indx -o ConnectTimeout=25 root@157.180.90.121'
PG='set -a; . /opt/barkpark/.env; set +a; psql "$(echo $DATABASE_URL | sed s|^ecto://|postgres://|)"'
```

## R1 — TTL is the 900s default on guerrilla (no override)

```sh
$SSH 'grep -r TASK_ENGAGEMENT /opt/barkpark/.env 2>/dev/null || echo NOT_SET'   # => NOT_SET
grep -n "@default_engagement_ttl_seconds" api/lib/barkpark/tasks/ttl_sweeper.ex # => 900
```

## R2 — L1 proof: staged → engagement_lapsed exactly ~15 min later

```sh
$SSH "$PG -At -F'|' -c \"select id,doc_id,mutation,inserted_at from mutation_events
  where mutation in ('task.staged','task.engagement_lapsed') and doc_id like '%pds-%'
  order by doc_id,id\""
```

## R3 — the lost note is RECOVERABLE, verbatim, from BOTH events

```sh
$SSH "$PG -At -c \"select jsonb_pretty(document->'staged') from mutation_events where id=124105\""
$SSH "$PG -At -c \"select jsonb_pretty(document->'engagement_lapsed'->'engagement') from mutation_events where id=124308\""
```

## R4 — recovery scale (158 rows, 0 still carrying engagement)

```sh
$SSH "$PG -At -F'|' -c \"
with notes as (select distinct on (doc_id) doc_id, document->'staged'->>'note' note
  from mutation_events where mutation='task.staged'
    and document->'staged'->>'note' is not null order by doc_id,id desc)
select count(*), count(*) filter (where d.content ? 'engagement'),
       count(*) filter (where not (d.content ? 'engagement'))
from notes n join documents d on d.doc_id=n.doc_id and d.type='task'\""
```

## R5 — PDS-D298's 45 Truth-Grip parks: written, not missing

Same CTE, `where n.doc_id like 'tgw%'` → 45; add `and n.note ilike '%REACTIVATE%'` → 45.

## R6 — write ceiling, read-only lower bound (no mutation performed)

```sh
$SSH "$PG -At -F'|' -c \"select doc_id, length(content->>'disposition_reason'),
  pg_column_size(content), octet_length(content::text) from documents
  where type='task' and content ? 'disposition_reason' order by 2 desc limit 8\""
```
