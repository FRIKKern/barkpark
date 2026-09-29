<!-- doc-tier: agent | canonical-for: prod-microblock-pull-plan | budget: 2200tok -->

# Pulling 89.167.28.206 forward — the plan

**A plan for a human to approve and run by hand. Nothing here auto-executes.** Every step is
a command you type and read the output of before continuing. Conditional on the LIVE decision in
`task-dd27173ac5b52b0c` criterion 1 — if that is RETIRED or PINNED, this page does not apply.

## The gap this closes

Measured 2026-09-20. The box publishes its commit at `http://89.167.28.206/status.json`:

| | |
|---|---|
| served commit | `ca4534461` (`ca4534461fd29401bd4005fc9b31fdf297f9a206`, 2026-08-31) |
| ancestry | an ancestor of `origin/main` — behind, **not** forked |
| commits behind | ~2890 and rising; re-derive, never retype |
| pending migrations | **23** `.exs` files (the 24th added path is `MANIFEST.sha256`, a checksum file, not a migration) |
| every health surface | green. `curl http://89.167.28.206/api/schemas` returned 200 throughout the twenty-day gap. |

Re-derive all three before you start:

```bash
scripts/prod-microblock-staleness-check.sh      # exit 3 = BEHIND, 4 = CANNOT-READ, 5 = FORKED
```

Do not proceed on exit 4: the reader could not establish the box's state at all, and a pull
against an unknown starting point is not a plan.

## Step 1 — back up the database, then PROVE the backup

A backup nobody restored is not a backup. On the box:

```bash
ssh root@89.167.28.206
cd /opt/barkpark
ts="$(date -u +%Y%m%dT%H%M%SZ)"
# Read the real credentials from the service's own env; do not retype them.
set -a; . /opt/barkpark/.env; set +a
pg_dump --format=custom --no-owner --dbname="$DATABASE_URL" \
        --file="/var/backups/barkpark-pre-pull-$ts.dump"
ls -l "/var/backups/barkpark-pre-pull-$ts.dump"
```

Verification — all three, in order. A `pg_dump` that exited 0 over a broken connection still
writes a file.

```bash
# (a) the archive's table of contents parses, and names tables you recognise
pg_restore --list "/var/backups/barkpark-pre-pull-$ts.dump" | head -40
pg_restore --list "/var/backups/barkpark-pre-pull-$ts.dump" | grep -c 'TABLE DATA'

# (b) it RESTORES — into a scratch database, never over the live one
createdb barkpark_restore_probe
pg_restore --no-owner --exit-on-error --dbname=barkpark_restore_probe \
           "/var/backups/barkpark-pre-pull-$ts.dump"       # must exit 0

# (c) the restored copy carries the rows the live one does
psql -d barkpark_restore_probe -c 'select count(*) from documents;'
psql -d "$DATABASE_URL"        -c 'select count(*) from documents;'   # compare by eye
psql -d barkpark_restore_probe -c 'select max(version) from schema_migrations;'

dropdb barkpark_restore_probe
```

If (b) does not exit 0, **stop**: you have no rollback and Step 3 is irreversible in part.

Record the pre-pull migration high-water mark — the rollback needs it:

```bash
psql -d "$DATABASE_URL" -c 'select version from schema_migrations order by version desc limit 5;'
```

## Step 2 — enumerate the migrations, by command

Never retype this list. In a local checkout with `origin/main` fetched:

```bash
SERVED=$(curl -s http://89.167.28.206/status.json | jq -r .commit)
git diff --name-only --diff-filter=A "$SERVED..origin/main" -- api/priv/repo/migrations/ \
  | grep '\.exs$'
git diff --name-only --diff-filter=A "$SERVED..origin/main" -- api/priv/repo/migrations/ \
  | grep -c '\.exs$'
```

Read each one's `@moduledoc` before approving. As of 2026-09-20: 23 files dated 2026-08-24 to
2026-09-18 — mostly additive columns and indexes, plus one backfill
(`…backfill_twin_canonical_task_edges`) and one trigger-function replacement
(`…replace_bind_document_revision_trigger_function`).

### One of them is IRREVERSIBLE, and that is the point of saying so here

`20260904020000_drop_token_from_share_links.exs` **drops** `share_links.token`. Its own moduledoc
states the consequence: existing `/s/<token>` URLs keep resolving (resolution matches on
`token_hash`, untouched), but the plaintext is **dropped and unrecoverable**, and its `down`
re-adds a nullable column with every row NULL. There is no backfill and none is possible — the
plaintext cannot be derived from the SHA256 digest.

**So a code rollback does not undo this migration's effect.** The only recovery for that column
is the Step 1 dump — which is why Step 1 comes first and its verification is not optional. Others
carry `drop`/`remove`/`execute` in `down` (index drops, mostly reversible); some define no `down`
at all. Re-derive:

```bash
for f in $(git diff --name-only --diff-filter=A "$SERVED..origin/main" \
             -- api/priv/repo/migrations/ | grep '\.exs$'); do
  printf '%s  ' "$(basename "$f")"
  git show "origin/main:$f" | grep -cE '^\s*def (up|down)\b'
done
```

A `0` means the file uses `change/0` and Ecto infers the reversal — which it **cannot** do for a
raw `execute` or a `remove` with data.

## Step 3 — the pull, respecting the Golden Rules

`git pull` **is** the deploy on this box: `.githooks/post-merge` runs `scripts/deploy-rebuild.sh`,
which builds ASIDE in `api/_build_next`, migrates, and swaps. Do not pre-empt any of it.

```bash
ssh root@89.167.28.206
cd /opt/barkpark
git rev-parse HEAD                 # record it — this is your rollback target
git status --porcelain             # MUST be empty; local edits mean stop and ask
git pull                           # the post-merge hook does the clean rebuild + migrate + swap
```

Rules that bind here, from `CLAUDE.md`:

- **Never build by hand on prod.** The hook's aside build is the mechanism.
- **Never partially clean.** Do not `rm -rf api/_build/prod` (LIVE); do not clean a subtree —
  stale HEEx survives it. The engine nukes the whole aside root itself.
- **Never skip `systemctl restart`.** If the hook did not restart, the old BEAM still serves the
  old code from memory. `systemctl restart barkpark`, then `systemctl status barkpark`.

## Step 4 — the smoke. HTTP 200 is NOT the proof

The box answered 200 on every surface for the whole twenty-day gap. A 200 proves the box ANSWERS.
The smoke that matters asserts the **commit changed**:

```bash
# From anywhere. $BEFORE is the sha you recorded in Step 3.
curl -s http://89.167.28.206/status.json | jq -r .commit     # must NOT equal $BEFORE
curl -s http://89.167.28.206/status.json | jq -r .version    # must not be "unknown"
```

Then the reader, which is the whole point of this exercise:

```bash
scripts/prod-microblock-staleness-check.sh    # must now exit 0
```

Exit 0 is the acceptance. Exit 3 means the pull did not land what you think; exit 4 means you
cannot tell, and must be fixed before you believe anything. Also:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://89.167.28.206/api/schemas    # 200
ssh root@89.167.28.206 'psql -d "$DATABASE_URL" -c "select count(*) from schema_migrations;"'
ssh root@89.167.28.206 'journalctl -u barkpark -n 100 --no-pager'
```

Compare that migration count against Step 1's high-water mark: it must have risen by 23.

## Step 5 — the named rollback

**Target: `ca4534461fd29401bd4005fc9b31fdf297f9a206`** (or whatever Step 3's `git rev-parse HEAD`
printed — that value wins over this page).

Rolling code back does **not** roll the schema back. Decide which you are doing:

**(a) Code only** — the new code is bad, the schema is fine. The 23 migrations stay applied and
the old code must tolerate the newer schema. Additive columns and indexes generally are; a missing
`share_links.token` is **not** — code at `ca4534461` reads that column, so a code-only rollback
breaks share-link display paths. Expect it.

```bash
ssh root@89.167.28.206
cd /opt/barkpark
git -c advice.detachedHead=false checkout ca4534461fd29401bd4005fc9b31fdf297f9a206
scripts/deploy-rebuild.sh        # full aside rebuild — never a partial clean
systemctl restart barkpark
curl -s http://89.167.28.206/status.json | jq -r .commit     # assert it moved BACK
```

**(b) Code and schema** — the only honest full reversal, and it costs every write made since the
pull. Restore the Step 1 dump:

```bash
systemctl stop barkpark
dropdb barkpark_prod && createdb barkpark_prod        # DESTRUCTIVE. Owner sign-off required.
pg_restore --no-owner --exit-on-error --dbname=barkpark_prod \
           "/var/backups/barkpark-pre-pull-$ts.dump"
# then (a)'s checkout + rebuild + restart
```

`mix ecto.rollback` is **not** the route for the drop: its `down` re-adds the column with every
row NULL — a schema reversal without a data reversal. Only the dump recovers the data.

## Scope

This pull is its own piece of work, not folded into another branch. The reader
(`scripts/prod-microblock-staleness-check.sh`) ships separately and stays useful whichever way
the LIVE/RETIRED decision goes.
