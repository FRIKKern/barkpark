# door-rows-reconcile — the box's refusal log vs `deployments.deferral_cause` (W22 verify)

Read-only. Two authorities:

- **Control plane DB** (L1): `ssh -i ~/.ssh/barkpark_indx root@178.105.92.191` →
  `docker exec -i cloud-db-1 sh -c 'psql -U $POSTGRES_USER -d $POSTGRES_DB -A -F"|"'`
  (heredoc a `.sql` file into stdin; `psql -f /tmp/x.sql` FAILS — the file is on the host, not in the container).
- **The box** (L1): `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121`.
  **The unit is NOT `barkpark`.** Guerrilla runs blue/green: `barkpark-slot@blue.service` and
  `barkpark-slot@green.service`. `journalctl -u barkpark …` prints `-- No entries --` — a vacuous
  empty that reads exactly like "the box logs nothing". **Both slots must be summed**; over the
  post-migration window the split was 310 / 374, so a single-slot grep undercounts by 45%.
  Journal retention is real (3.6 G, back to 2026-07-29).

## Verdict

Over **2026-08-07 10:02:23 → 2026-08-08 08:30:33** (migration `20260807150000` applied →
measurement instant) the two sides reconcile **EXACTLY, on three independent axes**:
total 684 = 684, all 19 hourly buckets identical, all 6 slugs identical.
Over the full wish window (from 2026-08-06 22:29:27) box refusals 1,810 = DB 409-capacity rows
1,810 (**1,804 `deferred` + 6 `failed`**). No fail-open leak.

## Recipes

DB side — deferral cause census + sanity total (`q.sql`, piped on stdin):

```sh
cat > /tmp/q.sql <<'SQL'
select count(*) as total_rows_since from deployments where inserted_at >= '2026-08-06 22:29:27';
select status, count(*) from deployments where inserted_at >= '2026-08-06 22:29:27' group by 1 order by 2 desc;
select coalesce(deferral_cause,'(NULL)') c, count(*) from deployments
  where status='deferred' and inserted_at >= '2026-08-06 22:29:27' group by 1 order by 2 desc;
select version, inserted_at from schema_migrations where version >= 20260806000000 order by version;
select min(inserted_at), max(inserted_at), count(*) from deployments where deferral_cause is not null;
select status, count(*) from deployments
  where inserted_at >= '2026-08-06 22:29:27' and failure_reason like '%409%box_at_capacity%' group by 1;
SQL
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -A -F\"|\"'" < /tmp/q.sql
```

Box side — refusals, hourly and per-slug, BOTH slots (`j.sh`, `scp`'d then `sh`'d; never a command
substitution inside a loop):

```sh
cat > /tmp/j.sh <<'EOF'
S='2026-08-07 10:02:23'; U='2026-08-08 08:30:33'
for X in barkpark-slot@blue barkpark-slot@green; do
  echo -n "$X: "; journalctl -u $X -S "$S" -U "$U" --no-pager -g 'REFUSED' | grep -c 'build slot is'
done
{ journalctl -u barkpark-slot@blue  -S "$S" -U "$U" --no-pager -g 'REFUSED' -o short-iso
  journalctl -u barkpark-slot@green -S "$S" -U "$U" --no-pager -g 'REFUSED' -o short-iso; } \
  | grep 'build slot is' | awk '{print substr($1,1,13)}' | sort | uniq -c
{ journalctl -u barkpark-slot@blue  -S "$S" -U "$U" --no-pager -g 'REFUSED'
  journalctl -u barkpark-slot@green -S "$S" -U "$U" --no-pager -g 'REFUSED'; } \
  | grep 'build slot is' | sed 's/.*REFUSED "\([^"]*\)".*/\1/' | sort | uniq -c | sort -rn
EOF
scp -i ~/.ssh/barkpark_indx /tmp/j.sh root@157.180.90.121:/tmp/j.sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'sh /tmp/j.sh'
```

The log line the grep keys on (`api/lib/barkpark/sites/deploy_runner.ex:777-780`, `Logger.info`):

```
[site-deploy] REFUSED "search" at the door: the box's build slot is in use (1 of 1, in flight: astro-search)
```

Its sibling arm at `:833` (`the box's build lock … is held by a build this instance did not launch`)
has fired **0** times in the window, as has `prebuilt artifact REFUSED`.

## Residues the reconciliation exposes

1. **62% of the wish-window deferred cohort has NULL `deferral_cause`** (1,121 of 1,805) — every one
   of them pre-migration, none after `2026-08-07 10:12:35`. Pure residue, not a live writer bug.
   This settles all three acceptance criteria of the open backlog task
   `dr-w15-bl-deferral-cause-null-audit`.
2. **Six box-capacity refusals settled `failed`, not `deferred`** (`2026-08-07 01:20:14` →
   `03:41:33`), so they carry the 409 code but `deferral_cause IS NULL`. A reader that counts
   refusals as `status='deferred' AND deferral_cause='BOX_AT_CAPACITY_DEFERRED'` undercounts the
   door by 6/1,810 = 0.33%. The honest denominator is `failure_reason LIKE '%409%box_at_capacity%'`.
3. **`BOX_BUSY_DEFERRED` has zero column-era rows.** All 684 are `BOX_AT_CAPACITY_DEFERRED`;
   exactly one `already_running` deferral exists in the whole window and it predates the column.
   A two-arm taxonomy still running on one arm.
4. **`coalesced_attempts` is effectively dead**: 2 nonzero against 1,008 zero over 1,010
   post-migration rows.
5. `deferral_depth` tops out at **9** against a bound of **12** — no chain reached terminal
   abandonment in the column era.
