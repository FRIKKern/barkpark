# Re-derivation recipe — chain closed-live rate (v2-chain-closed-live-rate)

Wave 12, deploy-reliability. Measured 2026-08-07 08:40–08:43Z against `cloud-db-1`
on `178.105.92.191` (DB `barkpark_cloud_prod`, user `barkpark_cloud`).

## How to re-run

```bash
scp -i ~/.ssh/barkpark_indx chain_census.sql root@178.105.92.191:/tmp/
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker cp /tmp/chain_census.sql cloud-db-1:/tmp/ && \
   docker exec -e PGPASSWORD=\$(docker exec cloud-db-1 printenv POSTGRES_PASSWORD) cloud-db-1 \
   psql -U barkpark_cloud -d barkpark_cloud_prod -f /tmp/chain_census.sql"
```

Scripts used (scratchpad, not committed): `chain_census.sql` (chains + four
successor rules + cause cross-tab + cutover segmentation), `chain_control.sql`
(chain-vs-no-chain control), `chain_control2.sql` (time-matched control, fence
rows, hourly split).

## Chain definition (the one that matters)

`grp = sum(status <> 'deferred') OVER (PARTITION BY site_id ORDER BY inserted_at, id
ROWS UNBOUNDED PRECEDING)` computed over the FULL production stream, THEN filtered
to `status='deferred'`. **Filtering to deferred first collapses every site into one
group** — that bug produced a bogus "1 chain, depth 19" line before it was caught.

Cause is classified in SQL by prefix-anchored regex mirroring
`DeployLedger.classify_deferred/2`
(`^the instance refused the deploy \((HTTP )?409\):\s*box_at_capacity` → CAPACITY;
`already_running` or bare 409 → BUSY).

## Headline results (2026-08-07 08:40Z)

| Window | chains | live | failed | closed-live |
|---|---|---|---|---|
| 7d (the briefed figure) | 634 | 324 | 307 | 51.1% |
| 24h | 431 | 306 | 122 | 71.0% |

Successor rule is IRRELEVANT: loose / 15-min-bounded / trigger+source-matched all
return 306 live · 122 failed; loose-vs-matched agree on 431/431 chains. Successor
gap p50 60.8s, max 103.4s (the 60s debounce). D162's attribution class does not bite.

Cause split (24h, loose): CAPACITY 299 chains → 93.6% closed-live; BUSY 132 chains
→ 19.7%. **But the causes are disjoint ERAS, not concurrent populations**:
`already_running` ends 2026-08-06 19:xxZ, `box_at_capacity` begins 22:29:27Z, one
overlap row. Time-matched control since 22:29:27Z: after_CAPACITY_chain 5.4% fail
(n=298) vs no_chain 3.6% (n=83). Busy era (08-06 08:41→22:29Z): after_BUSY_chain
80.9% (n=131) vs no_chain 62.5% (n=624).

## Fence

`failure_reason LIKE '%in a row%'` returns **7 rows table-wide** — 1 busy
(2026-08-05 22:57:53Z, `search`) and 6 capacity (2026-08-07 01:20:14 → 03:41:33Z).
Charter D126's "the 12-cap has fired ZERO times" is STALE.
