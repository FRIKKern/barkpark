# Re-derivation recipe — run-based deploy journeys + the ABANDONED rate (2026-08-07, deploy-reliability wave 9)

Host: cloud-db-1 @ 178.105.92.191, db `barkpark_cloud_prod`. origin/main at 95642c550.
All queries run via: `ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod' < FILE.sql`

## 0. The assigned query is TIME-REVERSED (finding, not a nit)

`order by inserted_at desc` + `rows between unbounded preceding and 1 preceding` makes `grp`
count terminals among NEWER rows, so each group's terminal row is its OLDEST member — the
non-terminals in the group came AFTER the terminal, not before. Structural proof: with that
ordering `max(inserted_at) filter (terminal) - min(inserted_at)` is **0.0 s for every group**
(the terminal IS the min). Correct grouping is `order by inserted_at asc`.

Assigned (desc) output: `journeys 1345 | attempts_per_journey 1.7263940520446097 | abandoned 89`.
Corrected (asc): 695 live journeys / 645 failed / 3 open tail; abandoned 60 (live) + 16 (failed).

## 1. Corrected journey query (asc)

```sql
with s as (select site_id, status, content_rev, inserted_at,
  sum(case when status in ('live','failed') then 1 else 0 end)
    over (partition by site_id order by inserted_at asc rows between unbounded preceding and 1 preceding) grp
  from deployments where inserted_at > now() - interval '24 hours'),
j as (select site_id, grp, count(*) n,
   count(*) filter (where status not in ('live','failed')) n_nonterm,
   max(status) filter (where status in ('live','failed')) term_status,
   max(content_rev) filter (where status in ('live','failed')) term_rev,
   min(inserted_at) first_at,
   max(inserted_at) filter (where status in ('live','failed')) term_at,
   (array_agg(content_rev order by inserted_at asc))[1] head_rev
 from s group by 1,2)
select ...
```

Note `head_rev` MUST be `(array_agg(... order by inserted_at asc))[1]`, never `min(content_rev)` —
content_rev is a sha256 prefix, so lexicographic min is not the first attempt.

## 2. Headline numbers (24 h to 2026-08-07 03:10Z)

| cohort | journeys | attempts incl. terminal | median TTL | p95 TTL | abandoned | unmetered |
|---|---|---|---|---|---|---|
| terminal = live | 695 | 2.00 | 0.0 s | 364.7 s | 60 | 4 |
| terminal = failed | 645 | 1.43 | 0.0 s | 185.1 s | 16 | 67 |
| live, multi-attempt only | 196 | 4.55 | 183.0 s | — | 60 (30.9% of metered) | 2 |

Split at the blue/green cutover 2026-08-06 22:24:16Z (live journeys only):

| side | journeys | attempts | med TTL | p95 TTL | abandoned % |
|---|---|---|---|---|---|
| A pre-cutover | 478 | 1.12 | 0.0 s | 61.2 s | 0.6% |
| B post-cutover | 218 | 3.95 | 153.0 s | 546.4 s | 26.1% |

## 3. Why the abandoned rate is NOT shippable as a fleet headline

- 43x regime swing across a 4.5 h old change (0.6% -> 26.1%). A 24 h aggregate blends two systems.
- 55/60 abandoned runs are forward (newer rev shipped); **5/60 shipped a rev first-seen EARLIER
  than the run head** — i.e. the release went live with older content. The naive
  `term_rev <> head_rev` test folds "shipped stale" into "abandoned" silently.
- All 7 sites share the identical content projection (`default/default/production`, doc_type
  `paper`) — see `sites` table — so content_rev is byte-identical across sites by construction
  (`select content_rev, count(distinct site_id) ...` shows 6 sites per rev). The 60 abandonments
  are ~one fleet-wide correlated signal, not 60 independent facts.
- 78 rows in 24 h carry `content_rev IS NULL` (0 carry the `@unknown_content_rev` empty string);
  67 failed journeys and 4 live journeys are therefore UNMETERED and must print UNMETERED.

## 4. Supporting greps (origin/main, never the worktree — local checkout is 528 behind)

```
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '440,510p'   # content_rev_probe
gh pr diff 10014 | grep -inE "abandon"                                             # 0 hits: no collision
```
