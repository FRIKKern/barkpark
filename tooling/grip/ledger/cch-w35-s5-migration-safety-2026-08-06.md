# cch-w35 verify [s5-migration-safety] — re-derivation recipes (2026-08-06)

Verifier lane: confirm `cch-w34-s5-detail-column-is-text`'s premise still holds
and its diff is safe to dispatch. Baseline: `origin/main` = `c73bbc07c`.

The primary checkout is 474 commits behind origin/main and does NOT contain the
tests under discussion. Every run below is executed in a DETACHED WORKTREE at
origin/main against an isolated test-DB partition (`MIX_TEST_PARTITION=w35v`).

## Setup (once)

    git worktree add --detach /tmp/wt-main origin/main
    cd /tmp/wt-main/cloud
    export CC=clang MIX_TEST_PARTITION=w35v
    MIX_ENV=test mix deps.get && MIX_ENV=test mix compile
    MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate

## R1 — the column is still varchar(255), no superseding migration

    git show origin/main:cloud/priv/repo/migrations/20260703100000_add_detail_to_deployments.exs
    psql -h localhost -U postgres -d barkpark_cloud_testw35v -c \
      "select data_type, character_maximum_length from information_schema.columns \
       where table_name='deployments' and column_name='detail';"

Expect: `add :detail, :string` / `character varying | 255`.

## R2 — the certifying test passes on origin/main (the defect is live)

    cd /tmp/wt-main/cloud && CC=clang MIX_TEST_PARTITION=w35v \
      mix test test/barkpark_cloud/registry_test.exs

Expect: `94 tests, 0 failures` (includes the assert_raise at :1152).

## R3 — the raise is genuinely 22001 at the DB

    psql -h localhost -U postgres -d barkpark_cloud_testw35v -c \
      "insert into deployments (id, site_id, status, detail, inserted_at, updated_at) \
       values (gen_random_uuid(), gen_random_uuid(), 'queued', repeat('y',5000), now(), now());"

Expect: `ERROR:  value too long for type character varying(255)`.

## R4 — MUTATION: the pinning test CAN lose (it must flip in the migration's commit)

    psql -h localhost -U postgres -d barkpark_cloud_testw35v -c \
      "alter table deployments alter column detail type text;"
    cd /tmp/wt-main/cloud && CC=clang MIX_TEST_PARTITION=w35v \
      mix test test/barkpark_cloud/registry_test.exs

Expect: `94 tests, 1 failure` — ONLY `registry_test.exs:1152`,
"Expected exception Postgrex.Error but nothing was raised".
That single failure IS the complete in-file blast radius of the migration.

## R5 — the brief's line numbers are stale by exactly +111, and #9739 caused it

    git show origin/main:cloud/test/barkpark_cloud/registry_test.exs \
      | grep -n 'a caption ABOVE the column limit\|a caption at the column limit'
    PAR=$(git rev-parse 'c73bbc07c^'); git show "${PAR}:cloud/test/barkpark_cloud/registry_test.exs" \
      | grep -n 'a caption ABOVE the column limit\|a caption at the column limit'

Expect: origin/main → :1131 / :1152; parent of #9739 → :1020 / :1041.
The task body and acceptance criterion 5 cite :1041 / :1020 — correct when
written, invalidated by the very merge the task declares itself to wait on.

Which test each line actually selects (ExUnit resolves a line to its enclosing test):

    cd /tmp/wt-main/cloud && CC=clang MIX_TEST_PARTITION=w35v \
      mix test test/barkpark_cloud/registry_test.exs:1041 --trace 2>&1 | tr '\r' '\n' | tail -3

Expect: the executed (timed) test is `[L#1033]` "the ring drop DISCLOSES its
cumulative count on the oldest survivor" — an UNRELATED console ring test.

## R6 — varchar(255) -> text is metadata-only (criterion 1's claim, pre-verified)

    psql -h localhost -U postgres -c "create database bp_w35_rewrite_probe;"
    psql -h localhost -U postgres -d bp_w35_rewrite_probe <<'SQL'
    create table t (id serial primary key, detail varchar(255));
    insert into t (detail) select repeat('a', 100) from generate_series(1,27000);
    select 'BEFORE relfilenode=' || relfilenode from pg_class where relname='t';
    alter table t alter column detail type text;
    select 'AFTER  relfilenode=' || relfilenode from pg_class where relname='t';
    SQL

Expect: BEFORE and AFTER relfilenode IDENTICAL (no table rewrite).
Measured on PostgreSQL 17.9 with 27,000 rows: `2208300` both sides.

## R7 — the prior art the brief does not cite

    git show origin/main:cloud/lib/barkpark_cloud/registry/env_var.ex | sed -n '92,102p'
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '954,965p'

Expect: `validate_length(:comment, max: 255)` (cch-w22-s3 — same 22001 class,
fixed by CAPPING AT THE COLUMN, not by widening it) and `short_detail/1`, which
already clamps `detail` to 255 with an ellipsis for both terminal deploy writers.
Charter D251 is the governing ruling (effective cap = min(validate_length,
column width, downstream derivations)).

## Teardown

    psql -h localhost -U postgres -c "drop database bp_w35_rewrite_probe;"
    psql -h localhost -U postgres -c "drop database barkpark_cloud_testw35v;"
    git worktree remove --force /tmp/wt-main
