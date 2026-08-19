# Quota menu — isolation-semantics re-derivation recipe (2026-08-19)

Verifier lane `quota-menu-judgment`, wave `rate-limit-quota-atomicity-wave-2026-08-19`.
Every claim below is re-derivable from a scratch database in under a minute.
Local Postgres is 17.9 (Homebrew); CI + cloud-prod are PG15. Everything used
here (SSI, transition tables, `NOT VALID` CHECK) predates PG15.

## 0. Scratch schema (mirrors documents→workspaces, FK ON DELETE CASCADE)

    psql -d postgres -c "create database bp_quota_race_probe"
    psql -d bp_quota_race_probe <<'SQL'
    create table ws (id int primary key, quota int, doc_count int not null default 0);
    create table docs (id serial primary key,
      ws_id int not null references ws(id) on delete cascade);
    create index on docs(ws_id);
    insert into ws (id,quota,doc_count) values (1,3,2);
    insert into docs (ws_id) select 1 from generate_series(1,2);
    SQL

The real FK is confirmed cascading:

    psql -d barkpark_dev -Atc "select conname, confdeltype from pg_constraint \
      where conrelid='documents'::regclass and contype='f'"
    # documents_workspace_id_fkey|c

## 1. Two-session race harness (fifo-driven, deterministic ordering)

    mkfifo a.fifo b.fifo
    sleep 1000000 > a.fifo & sleep 1000000 > b.fifo &
    psql -d bp_quota_race_probe -a -f - < a.fifo > A.out 2>&1 &
    psql -d bp_quota_race_probe -a -f - < b.fifo > B.out 2>&1 &
    exec 3> a.fifo; exec 4> b.fifo
    # then `print -u3 "<sql>"` / `print -u4 "<sql>"` with sleeps to pin the interleave

## 2. Conditional INSERT under READ COMMITTED — DOES NOT HOLD

    G="insert into docs (ws_id) select 1 where
        (select count(*) from docs where ws_id=1) < (select quota from ws where id=1);"
    # A: begin isolation level read committed; $G
    # B: begin isolation level read committed; $G
    # A: commit;  B: commit;
    # => both "INSERT 0 1", both COMMIT, select count(*)=4 against cap 3.

## 3. Same interleave under SERIALIZABLE — DOES hold (B aborts 40001)

    # identical script, `begin isolation level serializable`
    # => B: ERROR: could not serialize access due to read/write dependencies
    #       DETAIL: Reason code: Canceled on identification as a pivot,
    #               during commit attempt.
    # final count = 3 = cap.

## 4. SIRead predicate locks escalate to RELATION at production magnitude

    insert into docs (ws_id) select 1 from generate_series(1,5942);
    psql -d bp_quota_race_probe -Atc "begin isolation level serializable;
      set local enable_seqscan=off;
      select count(*) from docs where ws_id=1;
      select locktype||' '||coalesce(c.relname,'?') from pg_locks l
        left join pg_class c on c.oid=l.relation where mode='SIReadLock';
      commit;"
    # => 'relation docs_ws_id_idx' among the page locks; at 100k rows
    #    both 'relation docs' and 'relation docs_ws_id_idx'.

Cross-tenant FALSE abort (A works workspace 1, B works workspace 2, disjoint rows):

    # A: select count(*) from docs where ws_id=1;   (t=0.5s)
    # B: select count(*) from docs where ws_id=2;   (t=2.0s)
    # A: insert into docs (ws_id) values (1);       (t=3.5s)
    # B: insert into docs (ws_id) values (2);       (t=4.3s)
    # A: commit;  B: commit;
    # => B aborts 40001 despite touching no row A touched.

## 5. Counter column + CHECK — DOES hold under READ COMMITTED, no retry

    alter table ws add constraint ws_quota_ck
      check (quota is null or doc_count <= quota) not valid;
    -- FOR EACH ROW variant
    create function bump() returns trigger as $$ begin
      if TG_OP='INSERT' then update ws set doc_count=doc_count+1 where id=NEW.ws_id;
      else update ws set doc_count=doc_count-1 where id=OLD.ws_id; end if;
      return null; end $$ language plpgsql;
    create trigger t_row after insert or delete on docs
      for each row execute function bump();
    -- STATEMENT variant (transition tables)
    create trigger t_ins after insert on docs referencing new table as newdocs
      for each statement execute function bump_stmt_ins();
    create trigger t_del after delete on docs referencing old table as olddocs
      for each statement execute function bump_stmt_del();

Race at cap 3 / count 2, plain `begin;` (READ COMMITTED), bare
`insert into docs (ws_id) values (1);` in both sessions:

    # A: INSERT 0 1, COMMIT
    # B: blocks on the ws row lock, then
    #    ERROR: new row for relation "ws" violates check constraint "ws_quota_ck"
    #    DETAIL: Failing row contains (1, 3, 4).  -> ROLLBACK
    # final: doc_count 3 / quota 3, rows=3.

Identical result for BOTH trigger granularities.

## 6. Cascade-delete cost of the two trigger granularities (5942 child rows)

    explain (analyze) delete from ws where id=3;

    no trigger        Execution Time: 2.558 ms
    FOR EACH ROW      Trigger t_row on docs: time=10.622 calls=5942 -> 12.563 ms
    FOR EACH STATEMENT Trigger t_del on docs: time=0.957 calls=1    ->  2.927 ms

## 7. Live quota cost + population

    psql -d barkpark_dev -c "explain (analyze,buffers) select count(*) from documents \
      where workspace_id = (select workspace_id from documents group by 1 \
      order by count(*) desc limit 1)"
    # Index Only Scan documents_workspace_id_index, rows=5942, Execution Time: 4.023 ms
    psql -d barkpark_dev -Atc "select slug, tier, quota from workspaces where quota is not null"
    # (zero rows)

## 8. In-tree facts the ranking rests on

    git show origin/main:api/lib/barkpark/audit.ex | sed -n '133,141p'   # pg_advisory_xact_lock crc32("audit:"<>ws)
    grep -rn "pg_advisory" api/lib                                       # 2nd keyspace: hashtext("task:"<>doc_id)
    grep -rn "serialization_failure\|40001\|isolation level" api/lib api/config  # (no matches)
    git show origin/main:api/lib/barkpark/media.ex | sed -n '120,132p'    # upload/3 inserts media_files only
    grep -rn "ensure_for_upload" api/lib                                 # plugins/media.ex:58 (after_media_upload) -> documents row
