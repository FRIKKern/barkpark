<!-- doc-tier: agent | canonical-for: prod-operations | budget: 1500tok -->
# Production operations

## Production environment (canonical)

| Fact | Value |
|---|---|
| Host | `89.167.28.206` — Hetzner cax11, ARM64, Ubuntu 22.04. Not a `deploy.yml` target: a merge is NOT live until pulled |
| App dir | `/opt/barkpark` (server tracks `origin/main`, `core.hooksPath=.githooks`) |
| Service | systemd `barkpark.service`; wrapper `api/start.sh` (sources ASDF + `.env`) |
| Proxy | Caddy on :80 → `localhost:4000` (`/etc/caddy/Caddyfile`) |
| Erlang/Elixir | ASDF, pinned by repo-root `.tool-versions`: `erlang 27.3.4` / `elixir 1.18.4-otp-27` (Erlang Solutions: no ARM pkgs) |
| Go | `/usr/local/go/bin/go` (official ARM64 tarball) |
| Env file | `/opt/barkpark/.env` (`DATABASE_URL`, `SECRET_KEY_BASE`, `BARKPARK_EXTRA_ORIGINS` ws origins) |
| Logs | `journalctl -u barkpark -f` |

Deploy: `ssh root@89.167.28.206`, then on the box `cd /opt/barkpark && git pull` (the post-merge hook rebuilds + restarts; `make deploy` wraps it). Golden Rules 2/3/6 apply (`CLAUDE.md`).

**The toolchain pin is a production change.** The box's asdf resolves repo-root
`.tool-versions` from `/opt/barkpark` (the running BEAM reports elixir
1.18.4-otp-27 / erts-15.2.7), so editing it moves prod — never in a PR that
changes anything else. `elixir.yml`'s `mix-prod-compile` + `mix-test` matrices
carry the same 1.18.4, so a green prod-compile means "compiles on the box"; they
pin `otp: "27.0"` below the box's 27.3.4 on purpose (wider blast radius).

## The postcheck rule

A misbooted or stopped node looks identical to a healthy one from outside, so
any workflow touching `systemctl barkpark` on prod **must** end with
`api/scripts/prod-postcheck.sh` and confirm `PASS prod healthy …`. Prefer
`systemctl restart` to stop-then-start (document a deliberate stop), and a make
target (`make deploy` / `rebuild` / `restart`) to ad-hoc `systemctl`.

```bash
ssh root@<prod-host> "cd /opt/barkpark && ./api/scripts/prod-postcheck.sh"
# QUOTED, or the cd runs on your laptop. On the box: drop the ssh wrapper.
```

Exit 0 = healthy; non-zero writes a `systemctl status` tail to stderr. It checks
service active (if inactive it STARTS it — a guardrail, not a monitor), a 2 s
delay to bind `:4000`, and HTTP 200 from `/api/schemas` (unauth JSON; swap to
`/studio` if retired, never the admin-gated `/v1/schemas/production`). On FAIL
read that tail, then `journalctl -u barkpark -n 200 --no-pager` — never retry
blindly. After a deploy tail `journalctl -u barkpark -f` >=60 s for boot errors,
supervisor restart loops and 5xx.

## Operator one-shots (live box)

`mix barkpark.*` one-shots boot the Repo + their own deps only
(`Barkpark.MixBoot`) — never the Endpoint, Oban, plugin workers or the codelist
seeders, so an inherited `PHX_SERVER` binds nothing. Fix for guerrilla
2026-09-02 (`barkpark.edges.backfill`: dry-run 08:32:41Z, apply 08:34:58Z,
+1260/-1199 edges), where `app.start` bound :4001 against the live node, started
a second Oban on the live queues, and timed a codelist seed out. Run them cool
anyway:

```bash
ssh root@89.167.28.206; cd /opt/barkpark/api
. "$HOME/.asdf/asdf.sh"               # same toolchain init as api/start.sh
set -a; . /opt/barkpark/.env; set +a  # env SOURCE: the slot's .env, not yours
MIX_ENV=prod MIX_BUILD_ROOT=<active slot build root> nice -n 19 \
  mix barkpark.edges.backfill         # dry run; --apply writes
```

`MIX_BUILD_ROOT` at the ACTIVE slot's build root reuses the warm build (a cold
compile took load 1.9 → 6.3 on this 2-core box); `nice -n 19` keeps the sweep
behind live traffic.

## Prod migrations — validated live 2026-06-10

The hook DOES migrate: `deploy-rebuild.sh` runs `ecto.migrate` on new code while
the old build serves, aborting the swap on failure (exit 13). By hand keep that
order — new code selecting an unmigrated column 500s every request:

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
window: stop, migrate, deploy, start. Never `make reset-db` or `mix ecto.reset`
on prod; a migration that fails mid-way is stop-and-forward-fix, never an edit
to an applied one.

**The hook cannot report failure.** It exits 0 even when the rebuild fails (old
build keeps serving), so `prod-postcheck.sh` PASSes against that old build: grep
its output for `WARN: deploy-rebuild failed`. A green postcheck proves the
service is up, never that your code deployed; a no-op on `.slots` boxes.

## Phoenix server rollback

Revert source; never reset the server checkout. On a BRANCH (main refuses a
direct push — GH006 is correct) `git revert <bad-sha>`, push, merge via
`scripts/bp-merge.sh`; then on the box `cd /opt/barkpark && git pull` (the hook
rebuilds + restarts) and run the postcheck. Never `git reset --hard` or
force-push the prod checkout; rebuild only via `make rebuild` (aside into
`api/_build_next`, swaps on success), never a hand-rolled partial clean — that
serves stale BEAM/HEEx (Past Mistakes #1-3). Rolling back code does NOT undo a
schema change; write a compensating migration.

## Code anchors

- `api/scripts/prod-postcheck.sh` — the postcheck script
- `.githooks/post-merge` — rebuild + migrate + restart on server `git pull`
- `Makefile` — `rebuild` / `deploy` / `migrate` / `restart` targets
- `api/start.sh` — systemd wrapper sourcing ASDF + `.env`
