# Re-derivation recipe — prod census of the lifecycle-state register (wave 54)

Taken 2026-08-08 10:59:32Z against the CLOUD control plane (178.105.92.191,
`cloud-db-1` / `barkpark_cloud_prod`). Quiet-host discipline: the whole census
returned in **0.817s wall**, so no result here is a stale-measurement artifact.

## One command

Put the SQL in a FILE and pipe it — a command substitution inside a loop has
lost PATH on this host before.

```sh
ssh -o BatchMode=yes -o ConnectTimeout=15 -i ~/.ssh/barkpark_indx \
  root@178.105.92.191 \
  'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F"|" -f -' \
  < census.sql
```

## census.sql

```sql
SELECT 'now', now();
SELECT 'barkparks_total', count(*) FROM barkparks;
SELECT 'suspended_true', count(*) FROM barkparks WHERE suspended = true;
SELECT 'suspended_false', count(*) FROM barkparks WHERE suspended = false;
SELECT 'suspended_at_notnull', count(*) FROM barkparks WHERE suspended_at IS NOT NULL;
SELECT 'suspended_reason_hist', coalesce(suspended_reason,'<null>'), count(*) FROM barkparks GROUP BY 1,2;
SELECT 'subs_status_hist', status, count(*) FROM subscriptions GROUP BY 1,2;
SELECT 'subs_canceled_at_notnull', count(*) FROM subscriptions WHERE canceled_at IS NOT NULL;
SELECT 'subs_cancel_at_period_end_true', count(*) FROM subscriptions WHERE cancel_at_period_end = true;
SELECT 'audit_lifecycle_verb_count', count(*) FROM audit_events
  WHERE action ILIKE '%suspend%' OR action ILIKE '%resume%' OR action ILIKE '%cancel%';
SELECT 'env_vars_total', count(*) FROM env_vars;
SELECT 'oban_billing_any', count(*) FROM oban_jobs
  WHERE worker ILIKE '%bill%' OR worker ILIKE '%dunn%' OR worker ILIKE '%grace%' OR worker ILIKE '%suspend%';
SELECT 'nuptupd', relname, n_tup_ins, n_tup_upd, n_tup_del, n_live_tup
  FROM pg_stat_user_tables WHERE relname IN ('barkparks','subscriptions','env_vars','audit_events','teams')
  ORDER BY relname;
```

## Two traps this recipe encodes

1. **`GROUP BY 1` groups by the string literal, not the column.** Every
   histogram above puts the label in position 1, so the grouping key must be
   `GROUP BY 1,2` (or `GROUP BY 2`). `GROUP BY 1` alone errors with
   *"column must appear in the GROUP BY clause"* — a loud failure, but on a
   query shaped slightly differently it would silently collapse to one row.
2. **An all-zero census is a broken query until a total proves otherwise.**
   That is what the `nuptupd` row is for: `barkparks` shows
   `n_tup_ins=65 / n_tup_upd=145569 / n_live_tup=8`, so the zeros below are
   *data*, not a query that read nothing. (The briefed prior reading was
   145479; +90 updates in the interval independently proves the table is live.)

## Result, 2026-08-08 10:59:32Z

| fact | value |
|---|---|
| barkparks total / managed / self_hosted | 8 / 7 / 1 |
| `suspended = true` | **0** |
| `suspended = false` | 8 (`suspended IS NULL` = 0) |
| `suspended_at` / `suspended_reason` non-null | 0 / 0 |
| subscriptions | 22, **all `active`** |
| `canceled_at` non-null / `cancel_at_period_end = true` | 0 / 0 |
| audit rows total | 327 |
| audit rows with suspend/resume/cancel verb | **0** |
| **`env_vars` rows** | **0** (`n_tup_ins = 0` — never written, ever) |
| oban jobs on any billing/dunning/grace/suspend worker | **0** of 85022 |
| teams / users | 27 / 27 |

Sanity totals: `barkparks` 65 ins / 145569 upd / 8 live · `subscriptions`
23/4/22 · `env_vars` 0/0/0 · `audit_events` 327/0/327 · `teams` 30/56/27.

## Hand-set reachability

No operator/admin surface can set `suspended = true`. Route-table scan of
`cloud/lib/barkpark_cloud/web/router.ex` finds exactly two routes matching
suspend|resume and both are `/v1/{admin,operator}/autoupdate/resume` (rollout,
not lifecycle). The web layer only READS the column (router.ex:9116-9117,
:9254). Every writer is internal: `Registry.suspend_team_barkparks/2`
(billing.ex:855 cancel, :882 past-due) and `Registry.suspend_barkpark/2`
(billing.ex:321 quota reconciler). Verdict: **latent, not one-click.**

```sh
git grep -nE '^\s*(get|post|put|patch|delete)[( ]"' origin/main \
  -- cloud/lib/barkpark_cloud/web/router.ex | grep -i 'suspend\|resume'
```

## The env-var decoy worth naming

The one env-shaped audit row on prod is `site.env_changed`
(`target_type = "site"`, router.ex:7127) — the **Sites** env blob, a different
mechanism from the console's team/instance `env_vars` table. `env_vars` itself
has never had a row inserted.
