<!-- doc-tier: cold | canonical-for: fleet-migration-lag-census-2026-09-19 | budget: 6000tok -->

# Fleet migration-lag re-census — 2026-09-19 (READ-ONLY)

> HISTORICAL RECORD (2026-09-19) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Re-read of the six boxes the 2026-09-02 box census (PR #14844, lead-pds worker
pds-w3) reported as stopped between `20260705260000` and `20260709203417`.
Task: `task-99db9faeb9576253`. Worker: deploy-w2 (lead-deploy, session s24).
All readings taken 2026-09-19 09:00Z–09:10Z.

**Every remote call was a `SELECT` / `git log` / `git reflog` / `systemctl show`
/ `journalctl` / `grep -c`. No migration, no deploy, no restart, no write was
run on any host.** No `.env` value was read: the env probe is a LINE COUNT of a
key NAME (`grep -c '^BARKPARK_RELEASE_CAPTURE_HMAC_SECRET='`), never the value.

## The census command (c2 — recount it verbatim)

```bash
SSH="ssh -i $HOME/.ssh/barkpark_indx -o BatchMode=yes -o ConnectTimeout=12 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

$SSH root@<ip> '
  hostname
  sudo -u postgres psql -d barkpark_prod -Atc "select max(version), count(*) from schema_migrations"
  sudo -u postgres psql -d barkpark_prod -Atc "select exists(select 1 from schema_migrations where version = 20260719010000)"
  git -C /opt/barkpark log -1 --format="%h %ci"
  git -C /opt/barkpark reflog --date=iso -5
  systemctl is-active barkpark.service
  systemctl show barkpark.service -p NRestarts --value
  journalctl -u barkpark.service -n 12 --no-pager
  echo "KEYLINES=$(grep -c "^BARKPARK_RELEASE_CAPTURE_HMAC_SECRET=" /opt/barkpark/.env 2>/dev/null; true)"
'
```

`-o UserKnownHostsFile=/dev/null` is not optional: Hetzner recycles IPs across
reprovisioning, so a stale `~/.ssh/known_hosts` refuses most of this fleet with
`REMOTE HOST IDENTIFICATION HAS CHANGED`. PR #14844 hit the same wall.

The box roster was taken from PR #14844's own per-box table (name / IP).
`bp cloud deployments` answers with SITE ids, not box addresses, and
`bp cloud sites` is not a verb (`missing site command`); `bp fleet roster`
returned one idle agent (`muscle-1`). None of the three enumerates box IPs.

## 89.167.28.206 (c2, second half)

Re-tested today, 2026-09-19 09:09Z:

```
$ ssh -i ~/.ssh/barkpark_indx -o BatchMode=yes root@89.167.28.206
root@89.167.28.206: Permission denied (publickey,password).      # exit 255
```

**PROPOSED RULING: permanently outside the fleet key set.** It refused
`~/.ssh/barkpark_indx` on 2026-09-02 (PR #14844) and refuses it again today,
17 days later, from a different operator session. It is the `CLAUDE.md` prod
micro-block box, deployed by `git pull` ON THE BOX, and it is not a
`deploy.yml` target. It is UNREAD here and will stay unread until someone with
its own credential reads it — that is a finding, not a gap: no claim in this
packet covers it.

## Per-box table

Names are as PR #14844 recorded them. `hostname (today)` is what the box
answers NOW — see finding 1.

| box (PR #14844 name) / IP | hostname (today) | reachable? | git HEAD (date) | max schema_migrations (count) | has 20260719010000? | HMAC env key lines | service / NRestarts |
|---|---|---|---|---|---|---|---|
| Gyldendal / 5.75.169.183 | `warm-94ca05cc` | yes | `c8016810` (2026-07-09) | `20260709203417` (129) | **no** | 0 | active / 1 |
| warm-1159cb1b / 116.203.86.242 | `warm-1159cb1b` | yes | `3cf1285e3` (2026-08-02) | `20260705260000` (114) | **no** | 0 | **activating (crashloop) / 585206** |
| warm-3af75472 / 116.203.98.0 | `warm-3af75472` | yes | `c54775da` (2026-07-06) | `20260706120000` (117) | **no** | 0 | active / 0 |
| warm-41d7add3 / 46.224.120.156 | `warm-ca8ef149` | yes | `bd27dba66` (2026-08-26) | `20260705260000` (114) | **no** | 0 | **activating (crashloop) / 208412** |
| warm-f36ee17a / 167.233.246.183 | `warm-de049be4` | yes | `1049d77c0` (2026-09-15) | `20260915090000` (209) | **YES** | 1 | active / — |
| warm-fbc9baa3 / 46.225.213.23 | `warm-fbc9baa3` | yes | `e0071ed50` (2026-08-24) | `20260705260000` (114) | **no** | 0 | **activating (crashloop) / 363216** |
| guerrilla / 157.180.90.121 (CONTROL) | `guerrilla` | yes | `d6cfa870d` (2026-09-19) | `20260918120000` (210) | **YES** | 1 | active / — |
| prod (CLAUDE.md) / 89.167.28.206 | — | **no** | — | — | — | — | — |

Last migrate log line: **none of the six carries one.** `journalctl -u
'barkpark*' | grep -i migrat` returns either nothing (Gyldendal,
warm-1159cb1b, warm-41d7add3, warm-f36ee17a) or ordinary HTTP request lines
whose PATH contains the word (`/sites/default/files/backup_migrate/...` on
warm-3af75472) — a false positive of the grep, not a migrate. The journals do
not reach back to the dates in question. **The absence of a migrate line is
NOT this packet's evidence; the 2×5 control below is.**

## The 2×5 control — why the lag exists

```
HOST=guerrilla       KEYLINES=1  max=20260918120000   <- current
HOST=warm-de049be4   KEYLINES=1  max=20260915090000   <- current
HOST=warm-94ca05cc   KEYLINES=0  max=20260709203417   <- stuck
HOST=warm-1159cb1b   KEYLINES=0  max=20260705260000   <- stuck
HOST=warm-3af75472   KEYLINES=0  max=20260706120000   <- stuck
HOST=warm-ca8ef149   KEYLINES=0  max=20260705260000   <- stuck
HOST=warm-fbc9baa3   KEYLINES=0  max=20260705260000   <- stuck
```

Two boxes carry `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET` in `/opt/barkpark/.env`;
both are current. Five do not; all five are stuck before `20260719010000`.
The split is exact, both directions, with two positive controls.

`api/config/runtime.exs:44` — added by `12c903782`, **2026-07-19 06:11:25**,
`feat(cycles): release-gate-v1 — public proof before succession`:

```elixir
case System.get_env("BARKPARK_RELEASE_CAPTURE_HMAC_SECRET") do
  secret when is_binary(secret) and byte_size(secret) >= 32 -> ...
  _ -> if config_env() == :prod do
         raise "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must contain at least 32 bytes"
       end
end
```

`raise` in `runtime.exs` under `MIX_ENV=prod` fires before Ecto boots, so on a
box missing that key **no `MIX_ENV=prod mix ecto.migrate` can run at all** —
not by hand, not from `scripts/deploy-rebuild.sh:115`, not from
`deploy/instance-deploy.sh:1293`. Live proof on three of them:

```
Sep 19 09:08:33 warm-1159cb1b start.sh[3745394]: ** (RuntimeError) BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must contain at least 32 bytes
Sep 19 09:08:33 warm-1159cb1b start.sh[3745394]:     /opt/barkpark/api/config/runtime.exs:44: (file)
Sep 19 09:08:33 warm-1159cb1b systemd[1]: barkpark.service: Main process exited, code=exited, status=1/FAILURE
```

Identical stack on `warm-ca8ef149` (restart counter 208412) and
`warm-fbc9baa3` (363216). `warm-94ca05cc` and `warm-3af75472` do NOT crashloop
only because they still run pre-`12c903782` code (HEADs of 2026-07-09 and
2026-07-06) — they are latently in the same state and will raise the moment
they pull past it.

`git pull` still fast-forwards on a box in this state (the post-merge hook runs
AFTER the merge has landed and `git pull` exits 0 whatever the hook does —
`.githooks/post-merge`, lines 10-22), which is why HEAD can be a month ahead of
`max(schema_migrations)`. That gap IS the deploy-defect signature:

| box | HEAD date | schema max date | gap |
|---|---|---|---|
| warm-1159cb1b | 2026-08-02 | 2026-07-05 | **28 days of code with no migrate** |
| warm-ca8ef149 (was warm-41d7add3) | 2026-08-26 | 2026-07-05 | **52 days** |
| warm-fbc9baa3 | 2026-08-24 | 2026-07-05 | **50 days** |
| warm-94ca05cc (was Gyldendal) | 2026-07-09 | 2026-07-09 | 0 — consistent |
| warm-3af75472 | 2026-07-06 | 2026-07-06 | 0 — consistent |

The reflogs show a NIGHTLY `git pull` (`merge origin/main: Fast-forward`, ~03:40
UTC daily) that ran for weeks after migrations had already frozen, then
stopped: last on 2026-08-02 (warm-1159cb1b), 2026-08-24 (warm-fbc9baa3),
2026-08-26 (warm-ca8ef149).

## PROPOSED rulings (c0) — the lead/main rules, not this worker

| box | PROPOSED ruling | evidence line |
|---|---|---|
| **warm-1159cb1b** / 116.203.86.242 | **DEPLOY DEFECT** | `** (RuntimeError) BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must contain at least 32 bytes` at `runtime.exs:44`, NRestarts=585206, `KEYLINES=0`; HEAD 28 days ahead of the schema |
| **warm-ca8ef149** (filed as warm-41d7add3) / 46.224.120.156 | **DEPLOY DEFECT** | same RuntimeError, NRestarts=208412, `KEYLINES=0`; HEAD 52 days ahead of the schema |
| **warm-fbc9baa3** / 46.225.213.23 | **DEPLOY DEFECT** | same RuntimeError, NRestarts=363216, `KEYLINES=0`; HEAD 50 days ahead of the schema |
| **warm-94ca05cc** (filed as Gyldendal) / 5.75.169.183 | **FROZEN, latently defective** | HEAD `c8016810` 2026-07-09 == schema max `20260709203417`; no pull since 2026-07-09 16:31Z; service active, NRestarts=1. Nothing skipped a migration here — nothing deployed. BUT `KEYLINES=0`, so its next `git pull` past `12c903782` becomes the crashloop above |
| **warm-3af75472** / 116.203.98.0 | **FROZEN, latently defective** | HEAD `c54775da` 2026-07-06 == schema max `20260706120000`; no pull since 2026-07-06 14:07Z; service active, NRestarts=0. Same latent trap: `KEYLINES=0` |
| **warm-de049be4** (filed as warm-f36ee17a) / 167.233.246.183 | **NO LONGER LAGGING — the filing is stale for this box** | max `20260915090000` (209 rows), `20260719010000` present, HEAD `1049d77c0` 2026-09-15, `KEYLINES=1`. It was re-provisioned between 2026-09-02 and today. This is the re-image path working, and the positive control for "the normal deploy path DOES migrate" |
| **89.167.28.206** | **PERMANENTLY OUT OF THE FLEET KEY SET** | `Permission denied (publickey,password).` on 2026-09-02 and again 2026-09-19 |

The re-image path that makes a frozen warm box harmless: `deploy/bake-server-image.sh`
pre-runs migrations into the baked image (line 205) and asserts the rows survive the
seed reset (line 241), so a *freshly provisioned* warm instance starts current —
`warm-de049be4` is that path's receipt. It does NOT repair an already-provisioned
box whose `.env` predates `12c903782`.

## c1 is BLOCKED — this worker did not and could not act

Criterion c1 asks that a defect box be brought current "by the normal deploy
path". **That path cannot run on any of the five.** `deploy-rebuild.sh:115` and
`instance-deploy.sh:1293` both invoke `MIX_ENV=prod mix ecto.migrate`, and that
raises at `runtime.exs:44` before Ecto starts. A config write must come FIRST:
`BARKPARK_RELEASE_CAPTURE_HMAC_SECRET` (>= 32 bytes) into `/opt/barkpark/.env`
on each box, from whatever holds the fleet's secrets. This worker is read-only
and did not write it, propose a value, or touch any `.env`.

Boxes needing that ruling: `warm-1159cb1b`, `warm-ca8ef149`, `warm-fbc9baa3`
(actively crashlooping) and, before any future pull, `warm-94ca05cc` and
`warm-3af75472`. The realistic alternative for a WARM-POOL box is to destroy
and re-provision it rather than repair it — `warm-de049be4` shows the pool
already does this. That choice is the lead's.

## What could NOT be read

- **89.167.28.206** — refuses the fleet key (above).
- **A migrate log line per box.** The journals have rotated past 2026-07;
  `grep -i migrat` returns nothing or HTTP-path false positives. The deploy
  outcome receipt (`/opt/barkpark/.git/barkpark-deploy-outcome`) does not exist
  on any of the six, and neither does `/opt/barkpark/.slots` or
  `.deploy-status` — these boxes predate both receipts, so there is no stored
  record of what their last deploy did.
- **Why migrations first stopped on 2026-07-05/06**, which is BEFORE
  `12c903782` (2026-07-19). The HMAC raise explains why they are stuck TODAY
  and cannot be unstuck by a deploy; it does not explain the original stop. A
  second, earlier cause is unidentified and unread.
- **`mix ecto.migrations` / any live migrate attempt** — a write; forbidden by
  this task's read-only fence.

## What the 2026-09-02 filing got WRONG

1. **The count is five, not six.** `warm-f36ee17a` / 167.233.246.183 is current
   (max `20260915090000`, 209 migrations, `20260719010000` present). The fleet
   moved under the row.
2. **Three of the six box NAMES no longer belong to those IPs.**
   5.75.169.183 answers `warm-94ca05cc`, not `Gyldendal`; 46.224.120.156
   answers `warm-ca8ef149`, not `warm-41d7add3`; 167.233.246.183 answers
   `warm-de049be4`, not `warm-f36ee17a`. Hetzner IP recycling means a box name
   from a 17-day-old census is not a key. Re-read the hostname every time.
3. **"Gyldendal paused/down per lead-deploy" is half right and misleading.**
   `warm-94ca05cc` at 5.75.169.183 is UP and serving (`active`, NRestarts=1,
   live HTTP 200s in its journal). It is frozen in CODE, not down.
4. **The row's framing — "either intentionally frozen or deploys are not
   running migrations" — is a false dichotomy.** Three boxes are neither: they
   are boxes where the app CANNOT BOOT, so the deploy path runs and FAILS at
   migrate while `git pull` keeps landing. The result looks like "frozen" from
   the schema side and "deploying" from the git side, simultaneously.
5. **The lag is a CONFIG defect, not a migration defect.** Nothing is skipping
   migrations. `runtime.exs:44` refuses to boot, so migrate never gets to run.
   A fix aimed at the migrate step would have missed it entirely.
