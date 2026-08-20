# D252 reproduces exactly — and is a volatile instantaneous sample, not a property

Snapshot: `2026-08-07 17:48:41 UTC`, control-plane Postgres `cloud-db-1` on `178.105.92.191`.
Verdict: **not drift, not a mis-derivation — D252's number is right AND unrepeatable.**

## Re-derivation recipes

Charter text:

```
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n 'D252' -A 20
```

DB access shape (all queries below go through this):

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"' < FILE.sql
```

### 1. The D252 unit — latest PRODUCTION deploy per site

```sql
WITH latest AS (
  SELECT DISTINCT ON (site_id) site_id, status
  FROM deployments WHERE environment = 'production'
  ORDER BY site_id, inserted_at DESC)
SELECT status, count(*) FROM latest GROUP BY status ORDER BY 2 DESC;
```

Result: `live 10 / failed 2` (deferred 0). **Identical** with the `environment` filter dropped, and
identical when ordered `became_live_at DESC NULLS LAST, inserted_at DESC`. The mis-derivation
hypotheses are all refuted — there is only one derivation and it gives D252's number.

### 2. Why two surveyors got 7/2/2-3 — replay the same query at 30-min cutoffs

```sql
WITH cutoffs AS (SELECT generate_series(now()::timestamp - interval '48 hours', now()::timestamp, interval '30 minutes') AS t),
per AS (
  SELECT c.t,
    count(*) FILTER (WHERE l.status='live') AS live,
    count(*) FILTER (WHERE l.status='failed') AS failed,
    count(*) FILTER (WHERE l.status='deferred') AS deferred
  FROM cutoffs c CROSS JOIN LATERAL (
    SELECT DISTINCT ON (d.site_id) d.site_id, d.status FROM deployments d
    WHERE d.environment='production' AND d.inserted_at <= c.t
    ORDER BY d.site_id, d.inserted_at DESC) l
  GROUP BY c.t)
SELECT live, failed, deferred, count(*) AS samples FROM per GROUP BY 1,2,3 ORDER BY 4 DESC;
```

22 distinct triples over 97 samples. `10/2/0` is the modal state at only **19.6%**. `live` ranges
4..10; `deferred` ranges 0..5. Both measurements are true readings of the same query at different
minutes.

### 3. The denominator (12 vs 13)

```sql
SELECT s.slug, count(d.id) FROM sites s LEFT JOIN deployments d ON d.site_id=s.id GROUP BY 1 ORDER BY 2 DESC;
SELECT coalesce(d.status,'<null>') , count(*) FROM sites s LEFT JOIN deployments d ON d.id=s.current_deployment_id GROUP BY 1;
```

`sites` = 13; `count(DISTINCT site_id)` in `deployments` = 12; `auto-proof` has 0 rows. A third unit,
`sites.current_deployment_id`, yields `live 10 / NULL 3` (`auto-proof`, `nodeproof-20260718-73191`,
`perfect-demo`). One team owns everything: `506f035e-08f4-4b49-9038-86735eb4c0ef`, 13/13 sites.

### 4. The D229 boundary and its derivation-method sensitivity

```sql
SELECT (SELECT min(inserted_at) FROM deployments WHERE status='deferred'),
       (SELECT min(inserted_at) FROM deployments WHERE deferral_cause IS NOT NULL);
SELECT date_trunc('hour', inserted_at), count(*) FROM deployments WHERE status='deferred' GROUP BY 1 ORDER BY 1 LIMIT 6;
```

`min(inserted_at) WHERE status='deferred'` = **2026-08-05 21:27:11.41321** (matches the charter to the
microsecond). `min(inserted_at) WHERE deferral_cause IS NOT NULL` = **2026-08-07 10:12:35** — 37 hours
later. The boundary is a function of its derivation method, so the method belongs in the envelope
beside the instant. It also slides on deletion: the first hour holds only **4** rows, the first three
hours **124**.

### 5. D252's other half, and its cost figure

```sql
SELECT count(*), count(*) FILTER (WHERE became_live_at IS NOT NULL) FROM deployments WHERE status='deferred';
SELECT date_trunc('day',inserted_at)::date, count(*), count(*) FILTER (WHERE status='live'),
       round(count(*)::numeric/NULLIF(count(*) FILTER (WHERE status='live'),0),2)
FROM deployments WHERE inserted_at >= now() - interval '9 days' GROUP BY 1 ORDER BY 1;
```

`2124 deferred / 0 with became_live_at` — re-derives TRUE at the new N. Attempts-per-live by day:
4.66, 8.64, 8.58, 7.81, 8.17, 7.66, 6.51, 7.02, 3.90, **3.71**. The charter's "~3.2" is not
reproduced anywhere in the window; the best day is 3.71 and the mean is far worse.

### 6. Two vacuity facts found in the same snapshot

```sql
SELECT status, count(*), min(inserted_at), max(inserted_at) FROM deployments GROUP BY status;
```

The **entire lifetime status vocabulary of 31,137 rows is three values**: `failed` 18,622, `live`
10,391, `deferred` 2,124. `cancelled` has never existed (0), and no `queued`/`building` row is
persisted at this instant either.
