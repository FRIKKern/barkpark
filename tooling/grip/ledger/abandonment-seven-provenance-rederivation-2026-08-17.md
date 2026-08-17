# Re-derivation recipe — the SEVEN abandonments, and charter :1585's cause split

Wave 35 verifier, 2026-08-17. Target: `cloud-db-1` on `barkpark.cloud` (control plane).
Everything below was RUN on 2026-08-17; the outputs are in the wave 35 Paper's proofs.

Transport (never paste a password; the container carries its own creds):

    cat > /tmp/q.sql <<'EOF'
    <query>
    EOF
    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod" < /tmp/q.sql

## R1 — the status reader is VACUOUS, not evidence

    select status, count(*) from deployments group by 1 order by 2 desc;

Reads `failed 18657 | live 11208 | deferred 3670`. **`abandoned` has never been a
`status` value in this schema.** A query for `status='abandoned'` returns 0 BY
CONSTRUCTION and proves nothing. Do not quote it.

## R2 — the anchored-text reader, exactly as the producer writes it

The one true anchor is `deploy_ledger.ex:774`:
`~r/ — and it has now refused \d+ rebuilds in a row for this site,/`
(leading em-dash and TRAILING COMMA are load-bearing).

    select
     count(*) filter (where failure_reason ~ ' — and it has now refused [0-9]+ rebuilds in a row for this site,') as exact_anchor_regex,
     count(*) filter (where failure_reason like '%rebuilds in a row%' or detail like '%rebuilds in a row%') as loose_like,
     count(*) as total_rows
    from deployments;

Reads `7 | 7 | 33539`. The loose LIKE is the anti-vacuity control: it can return
more than the regex, and does not — the two bases are the same seven rows.

## R3 — the seven, itemised (this is the re-derivation the exit reading may print)

    select id, site_id, status, inserted_at, deferral_depth, deferral_bound, deferral_cause
    from deployments
    where failure_reason like '%rebuilds in a row%' order by inserted_at;

1× `BOX_BUSY_DEFERRED` depth/bound **6/6** at 2026-08-05 22:57:53 (site `7c2025a5`),
6× `BOX_AT_CAPACITY_DEFERRED` depth/bound **12/12** 2026-08-07 01:20:14 → 03:41:33
across five sites. All seven `status='failed'`.

## R4 — the columns are NO LONGER NULL, and that overturns D195's ruling clause

Migration `20260809180000_backfill_abandonment_deferral_structure.exs`
(commit `cc10b0c0fc`, PR #11426) HAS RUN in production.

    select count(*) filter (where deferral_depth >= 12) as depth_ge_12,
           count(*) filter (where deferral_depth = deferral_bound) as eq_pred,
           count(*) filter (where deferral_depth > deferral_bound) as overshoot,
           count(*) filter (where deferral_cause is not null) as cause_not_null,
           count(*) filter (where status='deferred' and deferral_depth = deferral_bound) as deferred_at_bound,
           max(deferral_depth) filter (where status='deferred') as max_deferred_depth
    from deployments;

Reads `6 | 7 | 0 | 1862 | 0 | 9`.

- D195 :3793 "NEVER key on `deferral_depth >= 12`, **which returns zero forever**" —
  the parenthetical is **DEAD**. It returns **6**. The RULING (prefer the class /
  anchored clause) still stands; only its justification is stale.
- D544 "`deferral_depth = deferral_bound` is unsatisfiable by construction" is now
  true only of the **deferred** population (`deferred_at_bound = 0`). Table-wide it
  reads **7**. Say which population.
- `dr-w34-bl-abandonment-predicate-is-gte-not-equals` holds: `deferral_cause IS NOT
  NULL` reads **1,862** today (it was 1,665 when filed), not 7. Overshoot is 0
  today, so `=` and `>=` agree AT THIS INSTANT — that agreement is a coincidence of
  the corpus, not a licence to ship `=`.

## R5 — charter :1585 is TRUE IN ITS WINDOW; it needs a DATE, not a retraction

D76 :1585 says `BOX_AT_CAPACITY_DEFERRED` "has never fired in production (all 528
are `BOX_BUSY_DEFERRED`)". The `deferral_cause` column cannot test this — its first
stamp is 2026-08-07 10:12:35, after the window. Infer the cause from the row's text:

    select count(*) as deferred_in_window,
           count(*) filter (where failure_reason like '%box_at_capacity%' or detail like '%box_at_capacity%') as text_capacity,
           count(*) filter (where failure_reason like '%already_running%' or detail like '%already_running%') as text_busy
    from deployments where status='deferred'
      and inserted_at >= timestamp '2026-08-05 21:24:00'
      and inserted_at <  timestamp '2026-08-06 14:16:00';

Reads `528 | 0 | 528` — **D76's number and its cause split reproduce exactly**, two
weeks later, on the live table. :1585 is not inverted and must not be retracted.

The inversion is a DIFFERENT window plus a DIFFERENT reader:

    select count(*) as deferred_all,
           count(*) filter (where failure_reason like '%box_at_capacity%' or detail like '%box_at_capacity%') as text_capacity,
           count(*) filter (where failure_reason like '%already_running%' or detail like '%already_running%') as text_busy
    from deployments where status='deferred';
    select deferral_cause, count(*) from deployments where deferral_cause is not null group by 1;

All-time TEXT reader: `3673 | 2975 | 698` (4.26 : 1).
All-time COLUMN reader: `BOX_AT_CAPACITY_DEFERRED 1859 | BOX_BUSY_DEFERRED 1`.
**Two readers, same question, 3.5x apart** — the column reader is blind to the 1,818
pre-2026-08-07 rows. Any published cause split must name its reader AND its window.

## R6 — there is no alternate source to check

`git grep -ln "deployments" -- api/priv/repo/migrations` is EMPTY: the guerrilla
(content-API) side has no `deployments` table. The control plane is the only host
that has ever carried this population. No vanished-rows story exists.
