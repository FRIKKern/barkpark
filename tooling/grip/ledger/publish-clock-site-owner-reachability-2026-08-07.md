# Re-derivation recipe — PublishClock site-owner reachability (deploy-reliability wave 13, V-[publish-clock-site-owner-reachability])

Measured 2026-08-07 ~10:35Z against prod. Every row below is re-derivable by the command beside it.

## 1. Site / publish population (control plane, cloud-db-1)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' \
  -c 'select count(*) sites_total from sites;' \
  -c 'select count(distinct site_id) sites_with_publishes, count(*) rows_ from content_publishes;' \
  -c 'select min(received_at), max(received_at), count(*) from content_publishes;'"
```

Answer at the time: `sites_total 13`; `sites_with_publishes 5 | rows_ 70`;
`min 2026-08-07 08:15:26.02738 | max 2026-08-07 10:28:35.829137 | 70`.
The recorder is ~2h13m old — every "24h" number below is really a 2h13m number.

## 2. Per-site delivered count vs `@min_sample` 20

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"
SELECT p.site_id, count(*) publishes, count(d.id) delivered, count(*) FILTER (WHERE d.id IS NULL) unmatched
FROM content_publishes p
LEFT JOIN LATERAL (SELECT dd.id FROM deployments dd
  WHERE dd.site_id = p.site_id AND dd.became_live_at IS NOT NULL
    AND dd.became_live_at >= p.received_at AND dd.inserted_at >= p.received_at
  ORDER BY dd.became_live_at LIMIT 1) d ON TRUE
WHERE p.received_at > now() - interval '24 hours' GROUP BY 1 ORDER BY 2 DESC;\""
```

Answer: five rows, `14|13`, `14|14`, `14|13`, `14|14`, `14|14`. Every site is BELOW `min_sample` 20.
This is the join literally copied out of `@census_sql` on origin/main, minus the columns.

## 3. Per-site wait distribution (what a percentile would say if it were allowed)

Same host, replace the SELECT with `percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (d.became_live_at - p.received_at)))`
and an inner `JOIN LATERAL`. Answer: p50 128.9–280.5s, max 1342.3s, n=13–14 per site.

## 4. The false-green proxy — cloud secret vs guerrilla webhook

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"
select s.id, s.name, (s.content_webhook_secret_encrypted is not null) has_secret,
 (select count(*) from content_publishes p where p.site_id=s.id) pubs from sites s order by 3 desc, 2;\""
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -A -F'|' -c 'select name, active from webhooks order by name;'"
```

Answer: cloud says 6 of 13 sites carry a content-webhook secret; guerrilla holds 5 active
`site-autodeploy-<site_id>` rows. `auto-proof` (`8fa53cb3-…`) has a secret, zero publishes, and NO
guerrilla webhook. The cloud-local proxy overstates coverage by exactly one site.

## 5. Reader/caller census (code, level L3 — origin/main)

```
git grep -n 'PublishClock' origin/main -- | grep -v '_test.exs\|publish_clock.ex:'
git show origin/main:cloud/lib/barkpark_cloud/publish_clock.ex | grep -n '@min_sample\|@live_deploys_sql\|WHERE p.received_at'
git show origin/main:cloud/test/barkpark_cloud/publish_clock_test.exs | grep -c 'site_id'
```

Answer: the only non-test/non-self hit is the charter's own prose line. `@min_sample 20`.
`@census_sql`'s only WHERE is on `p.received_at` — no site predicate anywhere in the module.
`@live_deploys_sql` and `@live_sites_sql` are fleet-wide. The test file mentions `site_id` twice,
both as fixture setup; zero of the eleven tests assert a site-scoped property.

## 6. The pinned-SQL test is a CONTAINS test, not an equality test

```
git show origin/main:cloud/test/barkpark_cloud/publish_clock_test.exs | sed -n '67,81p'
```

Every assertion is `assert sql =~ "…"`. Adding a site predicate to `@census_sql` does NOT red it.
(Recorded because the opposite was assumed going in.)
