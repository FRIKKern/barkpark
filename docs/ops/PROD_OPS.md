<!-- doc-tier: agent | canonical-for: prod-operations | budget: 1500tok -->
# Production operations

## Production environment (canonical)

| Fact | Value |
|---|---|
| Host | `89.167.28.206` — Hetzner cax11, ARM64, Ubuntu 22.04. **Not a `deploy.yml` target** — pull-deployed; a merge is NOT live until pulled |
| App dir | `/opt/barkpark` (server tracks `origin/main`, `core.hooksPath=.githooks`) |
| Service | systemd `barkpark.service`; wrapper `api/start.sh` (sources ASDF + `.env`) |
| Proxy | Caddy on :80 → `localhost:4000` (`/etc/caddy/Caddyfile`) |
| Erlang/Elixir | ASDF, pinned by repo-root `.tool-versions`: `erlang 27.3.4` / `elixir 1.18.4-otp-27` (Erlang Solutions has no ARM packages) |
| Go | `/usr/local/go/bin/go` (official ARM64 binary) |
| Env file | `/opt/barkpark/.env` (`DATABASE_URL`, `SECRET_KEY_BASE`, `BARKPARK_EXTRA_ORIGINS` ws origins) |
| Logs | `journalctl -u barkpark -f` |

Deploy: `ssh root@89.167.28.206`, then on the box `cd /opt/barkpark && git pull` (the post-merge hook rebuilds + restarts; `make deploy` wraps it). Golden Rules 2/3/6 apply verbatim (`CLAUDE.md`).

**The toolchain pin is a production change.** The box's asdf resolves repo-root
`.tool-versions` from `/opt/barkpark` — `asdf current` and the running BEAM
both report elixir 1.18.4-otp-27 / erts-15.2.7 — so editing it moves prod;
never in a PR that changes anything else. Enforced by asdf on the box and by
the `mix-prod-compile` + `mix-test` Elixir matrices in `elixir.yml`, which
carry the same 1.18.4 so a green prod-compile means "compiles on the box".
They pin `otp: "27.0"` below the box's 27.3.4 on purpose: wider blast radius.

## The postcheck rule

A misbooted or stopped Phoenix node looks identical to a healthy one from
outside the box — systemd returned, SSH closed, no error surfaced. So any
workflow touching `systemctl barkpark` on prod **must** end with
`api/scripts/prod-postcheck.sh`, which probes the public HTTP surface.

- **Atomic transitions:** prefer `systemctl restart` over stop-then-start;
  document a deliberate stop first.
- **No silent ops:** SSH'd in to patch something? Run the script before you
  log out; refuse "looks fine, didn't check."

## How to run

```bash
ssh root@<prod-host> "cd /opt/barkpark && ./api/scripts/prod-postcheck.sh"
# QUOTED, or the cd runs on your laptop. On the box: drop the ssh wrapper.
```

Exit 0 = healthy; non-zero writes a `systemctl status` tail to stderr.

## What it checks

1. **Service is active.** `systemctl is-active --quiet barkpark`; if inactive
   the script STARTS it — a guardrail, not a monitor. Run it only when
   "service should be running" is the desired end state.
2. **Boot delay.** Sleeps 2 s so the BEAM can bind `:4000`.
3. **HTTP 200 from `/api/schemas`.** Unauth, returns JSON while Phoenix is
   alive. Swap to `/studio` (HTML 200) if retired; never
   `/v1/schemas/production` (admin-token gated).

## Operational checklist

- Prefer a Makefile target (`make deploy` / `rebuild` / `restart`) over ad-hoc
  `systemctl`.
- Run `./api/scripts/prod-postcheck.sh`; confirm `PASS prod healthy …`.
- Tail `journalctl -u barkpark -f` >=60 s: boot errors, supervisor restart
  loops, 5xx-emitting controllers.
- If the postcheck FAILs: read the `systemctl status` tail it printed, then
  `journalctl -u barkpark -n 200 --no-pager`. Never retry blindly.

## Prod migrations — validated live 2026-06-10

The hook DOES migrate: `deploy-rebuild.sh` runs `ecto.migrate` on new code
while the old build serves, aborting the swap on failure (exit 13). By hand
keep that order — new code selecting an unmigrated column 500s every
request:

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

Destructive migrations (drop/rename) have no zero-downtime order — schedule a
window: stop, migrate, deploy, start.

**The hook cannot report failure.** It exits 0 even when the rebuild fails
(old build keeps serving), so `prod-postcheck.sh` PASSes against that old
build: grep its output for `WARN: deploy-rebuild failed`. A green postcheck
proves the service is up, never that your code deployed; and it is a no-op on
a `.slots` (blue/green) box, which this host is not yet.

Never run `make reset-db` (drop + recreate) or `mix ecto.reset` on prod. A
migration that fails mid-way: stop, forward-fix, never edit an applied one.

## Phoenix server rollback

Roll back by reverting source, never by resetting the server checkout:

```bash
# Workstation, on a BRANCH — main refuses a direct push (GH006 is correct):
git revert <bad-sha>          # forward-moving revert commit
git push -u origin <branch>   # PR; merge via scripts/bp-merge.sh
# On the server:
ssh root@89.167.28.206
cd /opt/barkpark && git pull  # post-merge hook rebuilds + restarts
./api/scripts/prod-postcheck.sh
```

Rules: never `git reset --hard` or force-push the prod checkout; rebuild only
via `make rebuild` (builds aside into `api/_build_next`, swaps on success) —
never a hand-rolled partial clean, which serves stale BEAM/HEEx (Past
Mistakes #1-3). Rolling back code does NOT undo a schema
change; write a compensating migration if that must be undone too.

## Code anchors

- `api/scripts/prod-postcheck.sh` — the postcheck script
- `.githooks/post-merge` — rebuild + migrate + restart on server `git pull`
- `Makefile` — `rebuild` / `deploy` / `migrate` / `restart` targets
- `api/start.sh` — systemd wrapper sourcing ASDF + `.env`
