# Coalesce positive control — insert seam vs perform seam (wave 22 verify)

Derived 2026-08-08 08:29Z against cloud-db-1 (178.105.92.191) and `origin/main`.

## Host recipe

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -f - < /tmp/coalesce.sql"
```

`/tmp/coalesce.sql` is scp'd first:
`scp -i ~/.ssh/barkpark_indx <local>.sql root@178.105.92.191:/tmp/coalesce.sql`

## The two statements that decide it

```sql
-- INSERT SEAM (Oban unique-conflict, stamped by ContentPublish.mark_enqueued/2)
select count(*) as total, count(*) filter (where not enqueued) as not_enqueued
from content_publishes where received_at > '2026-08-07 13:00';
-- 345 | 89

-- PERFORM SEAM (the coalesced_attempts column on the in-flight row)
select sum(coalesced_attempts), count(*),
       count(*) filter (where coalesced_attempts > 0),
       count(*) filter (where coalesced_attempts is null)
from deployments where inserted_at > '2026-08-07 13:00';
-- 9 | 841 | 1 | 0
```

All-time sanity (same session):

```sql
select count(*), count(*) filter (where not enqueued), min(received_at), max(received_at)
from content_publishes;                      -- 460 | 125 | 2026-08-07 08:15:26 | 2026-08-08 08:25:51
select sum(coalesced_attempts), count(*), count(*) filter (where coalesced_attempts > 0)
from deployments;                            -- 15 | 31697 | 2
```

Per-site not-enqueued (5 webhook-bound sites, exactly 69 deliveries each — the fan-out
is 1 row per site, so 345 = 69 human publishes x 5 sites):

```sql
select site_id, count(*), count(*) filter (where not enqueued)
from content_publishes where received_at > '2026-08-07 13:00' group by 1 order by 2 desc;
-- d8e9c2c7 69|18   7c2025a5 69|19   15684026 69|19   31060916 69|15   0cf76788 69|18
```

## Code anchors (git-shown, not worktree)

- `git show origin/main:cloud/lib/barkpark_cloud/registry/content_publish.ex | sed -n '140,150p'`
  — `enqueued?({:ok, %{conflict?: true}}) -> false`; catch-all `enqueued?(_other) -> false`.
- `git show origin/main:cloud/lib/barkpark_cloud/publish_clock.ex | sed -n '666,682p'`
  — `coalesced_node/1` already counts `enqueued == false`; reached from `census/3:392`
  and thence `site_node/4:427`.
- `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '6755,6765p'`
  — `publish_clock: publish_clock_node(site, opts[:before])` on `GET /v1/sites/:id/deployments`.
- Reader absence: `git grep -n "publish_clock" origin/main -- internal/ cloud/priv/static`
  returns NOTHING.
