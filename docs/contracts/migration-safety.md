<!-- doc-tier: agent | canonical-for: migration-safety | budget: 700tok -->
# Migration safety on growing tables

**Rule.** A migration that touches `revisions` or `documents` (or any table that grows with content) does not run a per-row backfill inside the DDL transaction. Use these instead:

- `@disable_ddl_transaction true` and `@disable_migration_lock true`;
- `create index(..., concurrently: true)`;
- a backfill batched by primary-key range, or a separate job.

Never rewrite an applied migration. Fix forward.

**Precedent: `20260719010000_add_cycle_correction_quarantine_promotion.exs`.** It opens one transaction and does all of this inside it:

1. ALTERs `revisions` and `documents`.
2. Backfills `revisions.document_id` with a correlated subquery that joins every revision to the whole `documents` table on full-jsonb content equality.
3. Builds a non-concurrent index.
4. Runs two more `DISTINCT ON` backfills.

It was safe only because the tables were small (about 6.6 MiB and 18 MiB at pds-w12-measure). It spawned five fix migrations the same day, including `20260719020200`, which repaired a cascading FK that was deleting revision history. Do not copy its shape.

**Signals that require an online or batched plan before review approves.** Measure them on the target host first:

```sql
SELECT pg_size_pretty(pg_total_relation_size('revisions')), count(*) FROM revisions;
SELECT pg_size_pretty(pg_total_relation_size('documents')), count(*) FROM documents;
```

- **Size.** The table is over 64 MiB or 100k rows. Below that, a single-statement backfill can still be acceptable.
- **Lock.** Any `UPDATE … FROM`, or a correlated subquery over the whole table. Any index built without `CONCURRENTLY`. Any `ALTER` that rewrites the table. Each of these holds a lock for the full statement.
- **Duration.** Time the backfill on a prod-sized copy. If it runs past a few seconds, it blocks every write for that long and needs batching.
