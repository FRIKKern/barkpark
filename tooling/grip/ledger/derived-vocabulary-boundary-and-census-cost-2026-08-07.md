# Re-derivation recipes — derived vocabulary boundary + second-window census cost (2026-08-07)

Wave 16 verifier, leg 2. Every row below is a command that re-derives one fact from
scratch against prod (`cloud-db-1`, 31,064 rows at time of measurement). Read-only.

Host prefix (used by every row):

    SSH="ssh -i ~/.ssh/barkpark_indx root@178.105.92.191"
    PSQL="docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod"

## 1. The 2026-08-05 vocabulary boundary is DATA-DERIVABLE, not migration-derivable

    $SSH "$PSQL -At -c \"select min(inserted_at) from deployments where status='deferred'\""
    # -> 2026-08-05 21:27:11.41321   (stable across every run this session)

    $SSH "$PSQL -c \"explain analyze select min(inserted_at) from deployments where status = 'deferred'\""
    # -> Index Only Scan using deployments_status_inserted_at_index, Heap Fetches: 0
    #    Execution Time: 0.214 ms

There is NO migration for this boundary. It came from a code commit (charter D229:
`@statuses` gained `deferred` at `2154e695f`, `#9615`). `publish_clock`'s
`@recorder_since_sql` pattern does not apply — nothing in `schema_migrations` marks it:

    $SSH "$PSQL -At -F'|' -c \"select version,inserted_at from schema_migrations order by version desc limit 12\""
    # nearest neighbours: 20260805190000 @ 21:22:58 (index rekey) and
    #                     20260805210000 @ 21:53:53 (last_error backfill) — neither is the vocabulary change.

## 2. The 2026-08-07 deferral_cause boundary IS migration-derivable (the @recorder_since_sql shape)

    $SSH "$PSQL -At -c \"select inserted_at from schema_migrations where version = 20260807150000\""
    # -> 2026-08-07 10:02:23

    $SSH "$PSQL -At -F'|' -c \"select coalesce(deferral_cause,'(NULL)'),count(*),min(inserted_at),max(inserted_at) from deployments where status='deferred' group by 1 order by 2 desc\""
    # -> (NULL)|1818|2026-08-05 21:27:11.41321|2026-08-07 10:01:54.507774
    #    BOX_AT_CAPACITY_DEFERRED|256|2026-08-07 10:12:35.033826|2026-08-07 16:13:02.45933
    # 10:02:23 sits strictly between last-NULL and first-stamped -> a clean separator.
    # The migration explicitly does NOT backfill (git show origin/main:cloud/priv/repo/migrations/20260807150000_add_deferral_structure_to_deployments.exs).

## 3. THE TRAP — a naive per-status derivation invents boundaries on transient statuses

    $SSH "$PSQL -c \"explain analyze select status, min(inserted_at) from deployments group by status\""
    # -> GroupAggregate over deployments_status_inserted_at_index, Execution Time: 9.836 ms
    #    failed 2026-07-14 11:28:18 | live 2026-07-14 14:08:58 | deferred 2026-08-05 21:27:11.41321
    #    | building 2026-08-07 16:16:05.121223   <-- NOT a boundary

    # Ninety seconds later the whole `building` GROUP is gone:
    $SSH "$PSQL -At -F'|' -c \"select now(), status, count(*), min(inserted_at) from deployments where status in ('building','deferred') group by 2\""
    # 16:16:24Z -> deferred|2080|2026-08-05 21:27:11.41321   (building absent)
    # 16:17:54Z -> deferred|2080|2026-08-05 21:27:11.41321   (building absent)
    # `deferred` min is invariant; a transient status's min is whatever is in flight.

## 4. Second-window census cost (the doubled group_by)

Census shape re-derived verbatim from `census/3` (`deploy_ledger.ex:590`):
`group_by [site_id, stage, status, failure_reason]`.

    $SSH "$PSQL -c '\\timing on' \
      -c \"select count(*) from (select site_id,stage,status,failure_reason,count(id) from deployments where inserted_at >= '2026-08-06 17:00:00' and inserted_at < '2026-08-07 17:00:00' group by 1,2,3,4) q\" \
      -c \"select count(*) from (select site_id,stage,status,failure_reason,count(id) from deployments where inserted_at >= '2026-08-05 17:00:00' and inserted_at < '2026-08-06 17:00:00' group by 1,2,3,4) q\""
    # trailing 24h : 83 groups  / 2,202 rows / 26.0 ms cold, 8.2 ms warm  (explain: 6.97 ms)
    # prior    24h : 128 groups / 2,512 rows /  8.6 ms warm               (explain: 18.03 ms cold)
    # 38-day (all) : 1,491 groups / 31k rows / 50.7 ms warm  <- worst case for a wide window

Both windows ride `deployments_status_inserted_at_index` via a Bitmap Index Scan.
A second, equal-length window therefore costs ~1x the first: +8 ms on a 24h census,
+50 ms if an operator asks for the whole table. The derived-boundary query adds 0.2 ms.

## 5. BOX_BUSY_DEFERRED is NOT zero-rows-ever (it is zero only in the new COLUMN)

    $SSH "$PSQL -At -F'|' -c \"select case when failure_reason like '%box_at_capacity%' then 'CAP' when failure_reason like '%already_running%' then 'ALREADY_RUNNING' else 'OTHER' end, count(*), min(inserted_at), max(inserted_at) from deployments where status='deferred' group by 1 order by 2 desc\""
    # -> CAP|1379|2026-08-06 22:29:27.295491|2026-08-07 16:14:03.619536
    #    ALREADY_RUNNING|698|2026-08-05 21:27:11.41321|2026-08-07 08:16:29.728033
    # The 698 carry the anchored prefix `the instance refused the deploy (HTTP 409): already_running — …`,
    # which classify_deferred/2 (deploy_ledger.ex:~450) maps to BOX_BUSY_DEFERRED.
