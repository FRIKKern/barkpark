<!-- doc-tier: agent | canonical-for: prod-operations | budget: 1500tok -->
# Production operations

## Production environment (canonical)

| Fact | Value |
|---|---|
| Host | `89.167.28.206` — Hetzner cax11, ARM64 (aarch64), Ubuntu 22.04 |
| App dir | `/opt/barkpark` (server tracks `origin/main`, `core.hooksPath=.githooks`) |
| Service | systemd `barkpark.service`; wrapper `api/start.sh` (sources ASDF + `.env`) |
| Proxy | Caddy on :80 → `localhost:4000` (`/etc/caddy/Caddyfile`) |
| Erlang/Elixir | via ASDF (Erlang Solutions has no ARM packages) |
| Go | `/usr/local/go/bin/go` (official ARM64 binary) |
| Env file | `/opt/barkpark/.env` (`DATABASE_URL`, `SECRET_KEY_BASE`, `BARKPARK_EXTRA_ORIGINS` ws origins) |
| Logs | `journalctl -u barkpark -f` |

Deploy: `ssh root@89.167.28.206`, then on the box `cd /opt/barkpark && git pull` (the post-merge hook rebuilds + restarts; `make deploy` wraps it). Golden Rules apply verbatim — never partial-clean `_build`, never skip `systemctl restart`, always test after deploy.

## The postcheck rule

A misbooted or stopped Phoenix node looks identical to a healthy one from
outside the box — systemd returned, SSH closed, no error surfaced. So any
workflow touching `systemctl barkpark` on prod **must** end with
`api/scripts/prod-postcheck.sh`, which probes the public HTTP surface.

- **Atomic transitions:** prefer `systemctl restart` over stop-then-start;
  document a deliberate stop before you run it.
- **No silent ops:** SSH'd in to patch something? Run the script before you
  log out. The point is to refuse "looks fine, didn't check."

## How to run

```bash
# from a workstation — QUOTED, so the cd runs on the remote side:
ssh root@<prod-host> "cd /opt/barkpark && ./api/scripts/prod-postcheck.sh"
# on the box itself:
cd /opt/barkpark && ./api/scripts/prod-postcheck.sh
```

Exit code 0 = healthy. Non-zero = unhealthy; the script writes a tail of
`systemctl status barkpark` to stderr before exiting.

## What it checks

1. **Service is active.** `systemctl is-active --quiet barkpark`; if inactive
   the script STARTS it — a recovery guardrail, not a passive monitor. Run it
   only when "service should be running" is the desired end state.
2. **Boot delay.** Sleeps 2 s so the BEAM can bind `:4000` after a start.
3. **HTTP 200 from `/api/schemas`.** Legacy unauth path, returns JSON when
   Phoenix is alive. Swap to `/studio` (HTML 200) if it is ever retired;
   never to `/v1/schemas/production` (admin-token gated).

## Operational checklist

- Prefer a Makefile target (`make deploy`, `make rebuild`, `make restart`)
  over ad-hoc `systemctl` invocations.
- Run `./api/scripts/prod-postcheck.sh`. Confirm `PASS prod healthy …`.
- Tail `journalctl -u barkpark -f` for at least 60 s and watch for boot
  errors, repeated supervisor restarts, or 5xx-emitting controllers.
- If the postcheck FAILs: read the `systemctl status` tail it printed, then
  `journalctl -u barkpark -n 200 --no-pager`. Do not retry the same
  `systemctl` invocation blindly.

## Prod migrations — validated live 2026-06-10 (95 commits, 5 migrations)

The hook DOES migrate: `deploy-rebuild.sh` runs `ecto.migrate` on new code
while the old build serves, aborting the swap on failure (exit 13; its
header names the box it bricked). By hand keep that order — new code
selecting an unmigrated column 500s every request:

```bash
ssh root@89.167.28.206   # then ON THE BOX — never `&&`, that cd's on your laptop
cd /opt/barkpark
set -a; . ./.env; set +a                    # backup: ecto:// -> postgresql://
pg_dump "${DATABASE_URL/ecto:/postgresql:}" | gzip > /root/pre-deploy.sql.gz
git checkout -- bin/barkpark bin/barkpark-pg go.sum  # dirtied artifacts abort the pull
git -c core.hooksPath=/dev/null pull --ff-only  # NO hook — old code keeps serving
make migrate               # start.sh mix ecto.migrate (ASDF + .env)
bash .githooks/post-merge  # rebuild + migrate + restart — SEE WARNING BELOW
./api/scripts/prod-postcheck.sh
```

Destructive migrations (drop/rename) have no zero-downtime order — schedule
a window: stop, migrate, deploy, start.

**The hook cannot report failure.** It exits 0 even when the rebuild fails
(old build keeps serving), so `prod-postcheck.sh` PASSes against that old
build: grep its output for `WARN: deploy-rebuild failed`. A green postcheck
proves the service is up, never that your code deployed. It is also a no-op
on a `.slots` (blue/green) box — not this host yet.

Never run `make reset-db` (drop + recreate) or `mix ecto.reset` on prod. If a
migration fails mid-way, stop — read `journalctl -u barkpark -n 200`, do not
retry blindly, and prefer a forward-fix over editing an applied migration.

## Phoenix server rollback

Roll back by reverting source, never by resetting the server checkout:

```bash
# Workstation, on a BRANCH — main refuses a direct push (GH006 is correct):
git revert <bad-sha>          # forward-moving revert commit
git push -u origin <branch>   # open a PR; merge: scripts/bp-merge.sh

# On the server:
ssh root@89.167.28.206
cd /opt/barkpark
git pull                      # post-merge hook rebuilds + restarts
# or: make deploy (wraps the same pull)
./api/scripts/prod-postcheck.sh
```

Rules: never `git reset --hard` or force-push on the prod checkout; the
rebuild must go through `make rebuild` (builds aside into `api/_build_next`,
swaps on success) — never a hand-rolled partial clean, which serves stale
BEAM/HEEx (Past Mistakes #1–3). If the bad
commit included a migration, rolling back code does NOT undo the schema;
write a compensating migration if the schema change itself must be undone.
npm/SDK rollback: `docs/ops/npm-rollback-playbook.md`.

## Code anchors

- `api/scripts/prod-postcheck.sh` — the postcheck script
- `.githooks/post-merge` — auto-rebuild on server `git pull` (no migrate step)
- `Makefile` — `rebuild` / `deploy` / `migrate` / `restart` targets
- `api/start.sh` — systemd wrapper sourcing ASDF + `.env`
