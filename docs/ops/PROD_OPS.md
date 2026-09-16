<!-- doc-tier: agent | canonical-for: prod-operations | budget: 1500tok -->
# Production operations

## Production environment (canonical)

| Fact | Value |
|---|---|
| Host | `89.167.28.206` — Hetzner cax11, ARM64, Ubuntu 22.04; pull-deployed, **not a `deploy.yml` target** (a merge is NOT live until pulled) |
| App dir | `/opt/barkpark` (server tracks `origin/main`, `core.hooksPath=.githooks`) |
| Service | systemd `barkpark.service`; wrapper `api/start.sh` (sources ASDF + `.env`) |
| Proxy | Caddy on :80 → `localhost:4000` (`/etc/caddy/Caddyfile`) |
| Erlang/Elixir | ASDF, pinned by repo-root `.tool-versions`: `erlang 27.3.4` / `elixir 1.18.4-otp-27` (Erlang Solutions has no ARM packages) |
| Go | `/usr/local/go/bin/go` (official ARM64 binary) |
| Env file | `/opt/barkpark/.env` (`DATABASE_URL`, `SECRET_KEY_BASE`, `BARKPARK_EXTRA_ORIGINS` ws origins) |
| Logs | `journalctl -u barkpark -f` |

Deploy: on the box, `cd /opt/barkpark && git pull` (post-merge hook
rebuilds + restarts; `make deploy` wraps it). Golden Rules 2/3/6 apply.

**The toolchain pin is a production change.** The box's asdf resolves repo-root
`.tool-versions` from `/opt/barkpark` (`asdf current` and the BEAM agree), so
editing it moves prod — never in a PR that changes anything else. `elixir.yml`'s
Elixir matrices carry the same 1.18.4 (green prod-compile = "compiles on the
box") and pin `otp: "27.0"` below the box's 27.3.4 on purpose: wider blast
radius.

## The postcheck rule

A misbooted or stopped Phoenix node looks identical to a healthy one from
outside — systemd returned, SSH closed, nothing surfaced. So any
workflow touching `systemctl barkpark` on prod **must** end with
`api/scripts/prod-postcheck.sh`, which probes the public HTTP surface.

- **Atomic transitions:** prefer `systemctl restart` to stop-then-start
  (document a deliberate stop), and a Makefile target to ad-hoc `systemctl`.
- **No silent ops:** SSH'd in to patch something? Run the script before you log
  out; refuse "looks fine, didn't check."

```bash
ssh root@<prod-host> "cd /opt/barkpark && ./api/scripts/prod-postcheck.sh"
# QUOTED, or the cd runs on your laptop. On the box: drop the ssh.
```

It runs `systemctl is-active --quiet barkpark`, STARTING an inactive service —
a guardrail, not a monitor: run it only when "should be running" is the desired
end state; sleeps 2 s for the BEAM to bind `:4000`; then requires HTTP 200 from
`/api/schemas` (unauth JSON — swap to `/studio` if retired, never admin-gated
`/v1/schemas/production`). Exit 0 = `PASS prod healthy …`; non-zero writes a
`systemctl status` tail to stderr — read it, then `journalctl -u barkpark -n
200 --no-pager`, never retry blindly. After a deploy also tail
`journalctl -u barkpark -f` >=60 s for boot errors, supervisor restart loops,
5xx controllers.

## Operator one-shots

`barkpark.edges.backfill` (and `media.backfill`, `paper.backfill_block_ids`,
`paper.composition_migrate`) boot a NARROWED tree (`Barkpark.OneShot`) — no
Endpoint, so an inherited `PHX_SERVER` cannot bind the live slot's port, as it
did on guerrilla 2026-09-02 08:28-08:35Z ("port 4001 already in use"; that run
dry-ran 08:32:41Z, applied 08:34:58Z, +1260/-1199 edges). Mix still COMPILES.
ON THE BOX, in `/opt/barkpark`:

```bash
slot=$(systemctl is-active --quiet barkpark-slot@green && echo green || echo blue)
set -a; . ./.env; . ./.slots/$slot.env; set +a  # unit env; sets MIX_BUILD_ROOT
cd api && MIX_ENV=prod nice -n 19 mix barkpark.edges.backfill  # dry run
```

`MIX_BUILD_ROOT` must be the ACTIVE slot's warm root with the checkout at its
sha, or mix recompiles under the serving BEAM; `nice` — that boot took the
2-core box from load 1.9 to 6.3. No `.slots/` on this host: `. ./.env` alone,
default `_build`. Bare = dry run, `--apply` writes.

## Prod migrations — validated live 2026-06-10

The hook DOES migrate: `deploy-rebuild.sh` runs `ecto.migrate` on new code
while the old build serves, aborting the swap on failure (exit 13). By hand,
keep that order — new code selecting an unmigrated column 500s every request:

```bash
ssh root@89.167.28.206   # then ON THE BOX — never `&&`
cd /opt/barkpark
set -a; . ./.env; set +a  # backup: ecto:// -> postgresql://
pg_dump "${DATABASE_URL/ecto:/postgresql:}" | gzip > /root/pre-deploy.sql.gz
git checkout -- bin/barkpark bin/barkpark-pg go.sum  # dirt aborts the pull
git -c core.hooksPath=/dev/null pull --ff-only  # NO hook — old code serves on
make migrate              # start.sh mix ecto.migrate (ASDF + .env)
bash .githooks/post-merge # rebuild + migrate + restart — SEE WARNING BELOW
./api/scripts/prod-postcheck.sh
```

Destructive migrations (drop/rename) have no zero-downtime order — schedule a
window: stop, migrate, deploy, start. Never `make reset-db` or `mix ecto.reset`
on prod; a mid-way failure gets a forward fix, never an edit to an applied one.

**The hook cannot report failure.** It exits 0 even when the rebuild fails (old
build keeps serving), so `prod-postcheck.sh` PASSes against that old build:
grep it for `WARN: deploy-rebuild failed`. A green postcheck proves the service
is up, never that your code deployed. No-op on a `.slots` (blue/green) box,
which this host is not yet.

## Phoenix server rollback

Roll back by reverting source (`git revert <bad-sha>`, as a PR), never by
resetting the server checkout; then on the box `git pull` and
`./api/scripts/prod-postcheck.sh`. Never `git reset --hard` or force-push
the prod checkout; rebuild only via `make rebuild` (aside into
`api/_build_next`, swaps on success) — never a hand-rolled partial clean, which
serves stale BEAM/HEEx (Past Mistakes #1-3). Reverting code does NOT undo a
schema change; write a compensating migration.

## Code anchors

- `api/scripts/prod-postcheck.sh` — the postcheck
- `.githooks/post-merge` — rebuild + migrate + restart on server `git pull`
- `Makefile` — `rebuild`/`deploy`/`migrate`/`restart`
- `api/start.sh` — systemd wrapper (ASDF + `.env`)
