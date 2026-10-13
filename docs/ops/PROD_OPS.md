<!-- doc-tier: agent | canonical-for: prod-operations | budget: 1500tok -->
# Production operations

## Production hosts (canonical)

| Fact | Value |
|---|---|
| Content instance | guerrilla `157.180.90.121`, https://guerrilla.barkpark.cloud; `deploy.yml` → `deploy/instance-deploy.sh` on merge |
| Control plane | barkpark-cp `178.105.92.191`, https://barkpark.cloud; `deploy.yml` → `deploy/cp-deploy.sh` (Docker Compose slots) |
| Retired | barkpark-cms `89.167.28.206`, the pull-deployed box, deleted 2026-10-03 (snapshot 439115764). Docs calling it prod are history. |
| App dir (guerrilla) | `/opt/barkpark`, one checkout, per-slot build roots `api/_build_blue`/`_build_green` |
| Service | systemd `barkpark-slot@blue` (:4000) / `@green` (:4001), one live at a time; `ExecStart` `api/start.sh` (ASDF + `.env`) |
| Proxy | Caddy; the `/etc/caddy/Caddyfile` upstream names the live slot — read it; smoke by the PUBLIC URL |
| Erlang/Elixir | ASDF, pinned by repo-root `.tool-versions`: `erlang 27.3.4` / `elixir 1.18.4-otp-27` (Past Mistake #6) |
| Env file | `/opt/barkpark/.env` (`DATABASE_URL`, `SECRET_KEY_BASE`, `BARKPARK_EXTRA_ORIGINS` ws origins) + `.slots/<slot>.env` |
| Logs | `U='-u barkpark -u barkpark-slot@blue -u barkpark-slot@green'; journalctl $U -f` — all three; which exists varies. `-- No entries --` = "could not look", not "none": re-run unfiltered, quote the total. |

Pipeline, routing and slot flips: `deploy/README.md`. Golden Rules 2/3/6 apply.

**The toolchain pin is a production change.** A box's asdf reads repo-root
`.tool-versions` from `/opt/barkpark`, so editing it moves prod — never in a PR
touching anything else. `elixir.yml` carries the same 1.18.4 (green
prod-compile = "compiles on the box") and pins `otp: "27.0"` below the box's
27.3.4 on purpose: wider blast radius.

## The postcheck rule

A misbooted or stopped node looks identical to a healthy one from outside —
systemd returned, SSH closed, nothing surfaced. So any workflow touching
`systemctl barkpark` on prod **must** end with `api/scripts/prod-postcheck.sh`,
which probes the public HTTP surface.

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
end state; sleeps 2 s for the BEAM to bind its port; then requires HTTP 200 from
`/api/schemas` (unauth JSON — swap to `/studio` if retired, never admin-gated
`/v1/schemas/production`). Exit 0 = `PASS prod healthy …`; non-zero writes a
`systemctl status` tail to stderr — read it, then `journalctl $U -n 200
--no-pager` (`$U` above), never retry blindly. After a deploy also tail
`journalctl $U -f` >=60 s for boot errors, restart loops, 5xx controllers.

## Operator one-shots

`barkpark.edges.backfill` (and `media.backfill`, `paper.backfill_block_ids`,
`paper.composition_migrate`) boot a NARROWED tree (`Barkpark.OneShot`) — no
Endpoint, so an inherited `PHX_SERVER` cannot bind the live slot's port, as on
guerrilla 2026-09-02 ("port 4001 already in use"). Mix still COMPILES. ON THE
BOX, in `/opt/barkpark`:

```bash
slot=$(systemctl is-active --quiet barkpark-slot@green && echo green || echo blue)
set -a; . ./.env; . ./.slots/$slot.env; set +a  # unit env; sets MIX_BUILD_ROOT
cd api && MIX_ENV=prod nice -n 19 mix barkpark.edges.backfill  # dry run
```

`MIX_BUILD_ROOT` must be the ACTIVE slot's warm root with the checkout at its
sha, or mix recompiles under the serving BEAM; `nice` — that boot took the
2-core box from load 1.9 to 6.3. No `.slots/`: `. ./.env` alone, default
`_build`. Bare = dry run, `--apply` writes.

## Prod migrations

`instance-deploy.sh` runs `ecto.migrate` from the idle slot's new build while
the live slot serves, and on failure exits 13 without a flip (checkout reset).
The control plane migrates when its idle Compose slot boots. Old and new code
share the new schema during the swap, so migrations must be expand/contract.
Destructive migrations (drop/rename) have no zero-downtime order — schedule a
window. Never `make reset-db`/`mix ecto.reset` on prod; a mid-way failure gets
a forward fix, never an edit to an applied one.

## Rollback

Roll back by reverting source (`git revert <bad-sha>`, as a PR); its merge
redeploys through `deploy.yml`. For an immediate flip back, both scripts carry
`--rollback` (`instance-deploy.sh --rollback-preflight` first). Never
`git reset --hard` or force-push a prod checkout by hand, and never hand-roll a
partial clean, which serves stale BEAM/HEEx (Past Mistakes #1-3). Reverting
code does NOT undo a schema change; write a compensating migration.

## Code anchors

- `api/scripts/prod-postcheck.sh` — the postcheck
- `deploy/instance-deploy.sh` — content-instance deploy, migrate, flip, rollback
- `Makefile` — `rebuild`/`deploy`/`migrate`/`restart` (single-checkout boxes)
- `api/start.sh` — systemd wrapper (ASDF + `.env`)
