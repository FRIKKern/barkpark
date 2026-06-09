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
| Env file | `/opt/barkpark/.env` (`DATABASE_URL`, `SECRET_KEY_BASE`) |
| Logs | `journalctl -u barkpark -f` |

Deploy: `ssh root@89.167.28.206`, `cd /opt/barkpark`, `git pull` (post-merge hook auto-rebuilds + restarts) or `make deploy`. Golden Rules apply verbatim — never partial-clean `_build`, never skip `systemctl restart`, always test after deploy.

## Why the postcheck exists

Any `systemctl` operation on production — `restart`, `stop`, `reload`,
`daemon-reload`, even an interrupted `start` — can leave the service in a
state the operator did not intend. Without a verification step, a stopped
or misbooted Phoenix node looks identical to a healthy one from outside
the box: the systemd command returned, the SSH session closed, no error
surfaced. The only signal is users hitting an empty API or a blank
Studio.

`api/scripts/prod-postcheck.sh` closes that gap. It guarantees that every
ops workflow ends with a probe of the public HTTP surface, so an
unhealthy node is detected at the moment it happens, not when traffic
discovers it.

## The rule

Any workflow that touches `systemctl barkpark` on production **must** end
with a run of `api/scripts/prod-postcheck.sh`.

Two corollaries:

- **Use atomic transitions.** Prefer `systemctl restart barkpark` over
  `stop` followed by a separate `start`. If a maintenance window genuinely
  requires a stop without a restart, document it before running the stop —
  do not assume someone else will start it back up.
- **No silent ops.** If you SSH in to apply a patch, run the script before
  you log out. The whole point is to refuse "looks fine, didn't check."

## How to run

From a workstation:

```bash
ssh root@<prod-host> "cd /opt/barkpark && ./api/scripts/prod-postcheck.sh"
```

On the box itself:

```bash
cd /opt/barkpark
./api/scripts/prod-postcheck.sh
```

Exit code 0 = healthy. Non-zero = unhealthy; the script writes a tail of
`systemctl status barkpark` to stderr before exiting so you have an
immediate diagnostic without a second SSH round-trip.

## What it checks

1. **Service is active.** `systemctl is-active --quiet barkpark`. If the
   unit is inactive the script starts it — the script is a recovery
   guardrail, not a passive monitor. Run it only when "service should be
   running" is the desired end state.
2. **Boot delay.** Sleeps 2 s before the HTTP probe so the BEAM has time
   to bind `:4000` after a fresh start.
3. **HTTP 200 from `/api/schemas`.** Legacy unauth path. Returns JSON
   when Phoenix is alive, no auth header required. Probe path can be
   swapped to `/studio` (HTML 200) if the legacy schemas endpoint is ever
   retired; do not swap to `/v1/schemas/production` (admin-token gated).

## Operational checklist

- Apply the change via the documented Makefile target (`make deploy`,
  `make rebuild`, `make restart`) rather than ad-hoc `systemctl` invocations
  where possible.
- Run `./api/scripts/prod-postcheck.sh`. Confirm `PASS prod healthy …`.
- Tail `journalctl -u barkpark -f` for at least 60 s and watch for boot
  errors, repeated supervisor restarts, or 5xx-emitting controllers.
- If the postcheck FAILs: read the `systemctl status` tail it printed,
  then `journalctl -u barkpark -n 200 --no-pager` for the surrounding
  context. Do not retry the same `systemctl` invocation blindly.

## Prod migrations — **DRAFT, untested until next deploy window**

The post-merge hook compiles and restarts but does **NOT** run migrations.
A deploy that ships a migration is a manual two-step:

```bash
ssh root@89.167.28.206
cd /opt/barkpark
git pull                 # hook rebuilds + restarts (new code may briefly boot on old schema)
make migrate             # = cd api && bash start.sh mix ecto.migrate (start.sh sources ASDF + .env)
make restart             # re-boot the BEAM on the migrated schema
./api/scripts/prod-postcheck.sh
```

Never run `make reset-db` (drop + recreate) or `mix ecto.reset` on production.
If a migration fails mid-way, stop — read `journalctl -u barkpark -n 200`,
do not retry blindly, and prefer a forward-fix migration over editing an
applied one.

## Phoenix server rollback — **DRAFT, untested until next deploy window**

Roll back by reverting source, never by resetting the server checkout:

```bash
# On a workstation (ask before pushing, per repo rules):
git revert <bad-sha>          # forward-moving revert commit on main
git push

# On the server:
ssh root@89.167.28.206
cd /opt/barkpark
git pull                      # post-merge hook rebuilds + restarts
# or explicitly: make deploy  (git pull + full clean rebuild + restart)
./api/scripts/prod-postcheck.sh
```

Rules: never `git reset --hard` or force-push on the prod checkout; the
rebuild must be the full `make rebuild` clean path (nuke `api/_build/prod`)
— a partial clean serves stale BEAM/HEEx (Past Mistakes #1–3). If the bad
commit included a migration, rolling back code does NOT undo the schema;
write a compensating migration if the schema change itself must be undone.
npm/SDK rollback is a separate runbook: `docs/ops/rollback-playbook.md`.

## Code anchors

- `api/scripts/prod-postcheck.sh` — the postcheck script
- `.githooks/post-merge` — auto-rebuild on server `git pull` (no migrate step)
- `Makefile` — `rebuild` / `deploy` / `migrate` / `restart` targets
- `api/start.sh` — systemd wrapper sourcing ASDF + `.env`
