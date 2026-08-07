# Re-derivation recipe — chain-loss verdict (deploy-reliability wave 14, 2026-08-07)

Question: are post-boundary "abandoned chains" (deferred rows with no live/failed row
sharing their `(site_id, content_rev)`) silent content loss, or benign supersession?

Verdict: **benign.** 227/227 SETTLED abandoned chains have a later `live` row on the same
site; ZERO do not. The apparent "no later live" cases are chains still in flight at query
time — both such cases at 12:29Z went `live` with the *same* `content_rev` within 2 minutes.

## Boundary

`2026-08-05 21:24:00` (UTC, naive `inserted_at`) — charter W5 measurement boundary.
The first `deferred` row in the table ever is `2026-08-05 21:27:11.41321`.

## The SQL (put in a FILE, never inline)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -f -' < chain_verdict.sql
```

Settled-only census — the ONE query that decides it (excludes in-flight chains):

```sql
WITH pb AS (SELECT * FROM deployments WHERE inserted_at >= '2026-08-05 21:24:00'),
chains AS (SELECT site_id, coalesce(content_rev,'<NULL>') AS crev,
   count(*) FILTER (WHERE status='live') l, count(*) FILTER (WHERE status='failed') f,
   count(*) FILTER (WHERE status='deferred') d, max(inserted_at) last_at
   FROM pb GROUP BY 1,2),
ab AS (SELECT * FROM chains WHERE d>0 AND l=0 AND f=0
       AND last_at < now() - interval '30 minutes')
SELECT count(*) AS abandoned_settled,
  count(*) FILTER (WHERE EXISTS (SELECT 1 FROM deployments x
     WHERE x.site_id=ab.site_id AND x.status='live' AND x.inserted_at>ab.last_at))
     AS with_later_live
FROM ab;
```

**The `last_at < now() - interval '30 minutes'` clause is load-bearing.** Without it the
table is read mid-flight and in-flight chains masquerade as abandonments. A count taken
without it drifts *while the script runs*: successive queries in one psql session returned
230 → 229 → 228 → 227 for the same predicate.

## Why the chain key cannot be verified against a writer

There is no re-queue identity to verify. `Sites.Deploy.defer/3` calls
`requeue_rebuild(site.id)` — **site_id only**. `AutoDeployWorker` then calls
`Deploy.enqueue(site, bp, force: true, trigger: "content-auto")`, and `deploy.ex:190`
re-probes `content_rev` from the box (`content_rev = probed_rev || content_rev(site, bp)`).
`content_rev` is a sha256 of the site's *current published projection*, not a per-publish id.
`force: true` folds a nonce into `build_id`, so `build_id` is unique per row
(3,939 distinct build_ids / 3,939 post-boundary rows; **zero** build_ids shared between a
`deferred` and a later `live` row).

So `(site_id, content_rev)` is a COINCIDENCE key: it holds while the site's published
projection is unchanged and breaks the moment a new publish lands — which is precisely
benign supersession. Empirically, of 1,247 deferred rows whose successor was also deferred,
1,013 (81.2%) carry the same rev and 209 a different one, median gap 61.2s = the 60s debounce.

## Reconciling the two populations (they are disjoint BY CONSTRUCTION)

- **Fence corpus = 7 rows**, all-time, all post-boundary, all `status='failed'`.
  Anchor: `failure_reason ~ ' — and it has now refused [0-9]+ rebuilds in a row for this site,'`
  (written only by `Sites.Deploy.abandonment_reason/3`).
- **"Abandoned chains"** require `failed_rows = 0` in the group, so a fence row's chain can
  never be one. Measured overlap: 0. That zero is a tautology, not a fact about production.

## The pre/post comparison that must not be made

`deferred` did not exist before the boundary: 0 pre-boundary deferred rows, 15,122
pre-boundary chains, 0 pre-boundary "abandoned". Pre-boundary every 409 refusal settled
`failed` (8,081 rows over 19 days); post-boundary 1,934 settle `deferred` and 7 `failed`.
A "5.8% pre-boundary → 34.4% post-boundary" rise measures a status that did not exist,
not a regression.

## Reader hazard for the wave's reader slices

`deferral_depth` / `deferral_bound` / `deferral_cause` are populated on only **116 of 1,934**
post-boundary deferred rows (6.0%); first stamped row `2026-08-07 10:12:35.033826`.
A reader that renders "deepest chain" off `deferral_depth` reads NULL on 94% of the corpus.
Also: the column's chain notion (consecutive deferrals of the same CAUSE at the head of the
site's stream) is NOT the `(site_id, content_rev)` notion — a content-rev chain of length 4
carries a stamped depth of 5.
