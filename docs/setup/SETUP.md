<!-- doc-tier: human | canonical-for: standalone-setup | budget: 1700tok -->
# Barkpark — Standalone Setup

> **Installing Barkpark to *use* it?** Start at [`QUICKSTART.md`](QUICKSTART.md) — `curl | sh` + `bp setup`. This guide is for running the Phoenix API **from a clone** (contributors, plugin authors).

> Tested 2026-05-28 on Elixir 1.19.5 / Postgres 17.9 / macOS.

Barkpark is a Phoenix API backed by a PostgreSQL document substrate. This guide takes you from a clean clone to a running server on `localhost:4000`, with a seeded database you can verify. Every command below was run and returned exit 0 in test.

## Tested versions

| Component | Tested version | Floor |
|---|---|---|
| Elixir | 1.19.5 (Erlang/OTP 28) | `~> 1.15` |
| PostgreSQL | 17.9 | 14+ |
| libvips | 8.18.2 | — (required) |

## Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| Homebrew Elixir/Erlang | The toolchain (`/opt/homebrew/bin`) | `which mix` |
| PostgreSQL on `localhost:5432` | The document store | `brew services start postgresql@17` or Postgres.app |
| libvips | The `image` dep needs it or media probing fails | `brew install vips` |
| `postgres` role w/ password `postgres` | `config/dev.exs` hardcodes this | see below |

### The Postgres role gotcha (verified, real)

`config/dev.exs` connects as the `postgres` role with password `postgres`. A bare `psql` on macOS uses your **login** role, not `postgres` — so "psql works" does not mean barkpark will connect. Verify the role barkpark actually uses:

```bash
PGPASSWORD=postgres psql -h localhost -U postgres -d postgres -tAc "SELECT current_user;"
# → postgres
```

If your Mac Postgres lacks that role, create it (with a `postgres`-password login) or override the credentials in `config/dev.exs`.

## Setup sequence

Each step exited 0 in test:

```bash
git clone https://github.com/FRIKKern/barkpark.git && cd barkpark
brew install vips                  # if not already present
# ensure Postgres is up (brew services start postgresql@17, or Postgres.app)
cd api
mix deps.get                       # → "All dependencies have been fetched"
mix ecto.setup                     # create + migrate + seed (see below)
mix phx.server                     # serves on :4000
```

`mix ecto.setup` is the `mix.exs` alias:

```elixir
["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"]
```

So one command creates the database, runs every migration, and runs the seed script.

## CRITICAL — the *service* `make` targets are prod-only

The database and systemd targets are **prod/Linux wrappers** for the Hetzner box, not local dev commands.

| Target | What it actually does | Use locally instead |
|---|---|---|
| `make seed` / `make migrate` / `make reset-db` | Wrap `start.sh`, which hardcodes `/root/.asdf` paths and `MIX_ENV=prod` | `mix ecto.setup` / `mix ecto.migrate` / `mix ecto.reset` (in `api/`) |
| `make restart` / `make stop` / `make status` / `make logs` | `systemctl` / `journalctl` against the prod unit | nothing — useless on macOS |

For database work, always run bare `mix` commands inside `api/`.

**The rest of the Makefile is local-first by design** — a whole `Local development` section (`make dev`, `api`, `run`, `tui`, `web`, `build`) plus every target whose `make help` line starts `LOCAL:` (`update`, `doctor`, `test`, `reap-test-dbs`, `cli-install`). Run `make help` for the live list. Two worth knowing now: `make update` — `git pull`, then a diff-driven refresh (rebuild + reinstall `bp` if Go changed, `mix deps.get` if the lockfile changed, `mix ecto.migrate` if migrations landed, `pnpm install` in `web/`/`js/` if their manifests changed), ending with a digest of what came in and what to re-read. Run it instead of a bare `git pull` to stay current; `SINCE=<old-head> make update` does the refresh + digest without pulling. And `make test` — see below.

## Test database partitioning (multi-agent / multi-lane hosts)

Concurrent agents sharing one Postgres each need their own test database, or their runs collide and produce cross-lane failures that look like real bugs. `MIX_TEST_PARTITION=<lane>` (read in `config/test.exs`) makes `mix test` use `barkpark_test<lane>` instead of the shared `barkpark_test` — set a short, unique value per lane/worktree before running tests:

```bash
cd api && MIX_TEST_PARTITION=mylane mix test
```

`BARKPARK_TEST_POOL_SIZE` (default 20) caps that lane's Ecto pool; lower it (e.g. `BARKPARK_TEST_POOL_SIZE=6`) on a host running many concurrent lanes to leave headroom under Postgres's `max_connections`.

**The leak this creates, and the fix.** Nothing ever dropped a partitioned database on its own — every lane's `barkpark_test<lane>` accumulated forever (314 of them measured 2026-08-24, `task-1a7e52b811dabc3c`). Two independent, complementary fixes:

- `make test` (`MIX_TEST_PARTITION=<lane> make test`, or `ARGS="test/some_test.exs" MIX_TEST_PARTITION=<lane> make test` for a subset) runs the suite exactly as `mix test` would, then drops that lane's database afterward in a **detached background process** — it never blocks on or fails the test run itself. Prefer this over bare `mix test` for a partitioned run. (Bare `mix test`/`mix ecto.setup` etc. are still correct for the shared, unpartitioned `barkpark_test` a solo dev iterates against.)
- `make reap-test-dbs` (dry run; `APPLY=1` to drop, `HOURS=N` to retune the age threshold) is the backstop age-based sweep for lanes that get killed before any teardown runs — it only drops a database with **zero active connections AND** an on-disk age past the threshold, never on either signal alone. `doctor.sh` surfaces the live orphan count at session start.

Both matter: `make test` shrinks the population the sweep has to catch; the sweep is what makes the count converge for a lane that never exits cleanly. Neither raises `max_connections` — that masks the leak rather than fixing it, and is out of scope here (see `scripts/reap-test-databases.sh`'s header for the full incident history).

## What seeding produces

`priv/repo/seeds.exs` dispatches on `BARKPARK_SEED_PROFILE` (`Barkpark.Seeds.run/0`). Raw `mix` defaults to `demo` (everything below); `bp setup` defaults to `clean`:

| | `demo` (mix default) | `clean` (bp setup default) |
|---|---|---|
| Schemas | 8 legacy types + plugin schemas | plugin schemas only (paper, media) |
| Documents | 27 demo docs | 1 welcome paper (`/papers/welcome`) |
| Token | `barkpark-dev-token` | one admin token, printed ONCE (or minted from `BARKPARK_SEED_ADMIN_TOKEN`) |
| Codelists | EDItEUR + Thema | none |

Both profiles bootstrap tenancy and are idempotent on re-run. Demo counts, verified from a clean database:

| Object | Count | Notes |
|---|---|---|
| `schema_definitions` | varies | 8 legacy content types (seeded directly) + plugin-contributed schemas registered on boot via `Plugins.Bootstrap.register_all_schemas/0` (`paper`, the single `task` schema, plus any other enabled plugins' schemas, e.g. media/onixedit/frt). Run `SELECT count(*), count(distinct name) FROM schema_definitions;` against a freshly-seeded DB for the exact tally — it tracks the enabled plugin set. |
| `documents` | 27 | post 9, page 5, project 4, author 3, category 3, colors/navigation/siteSettings 1 each |
| Workspaces | 1 | Default Workspace |
| Projects | 1 | Default Project (slug `default`) |
| Datasets | 1 | `production` |
| API tokens | 1 | `barkpark-dev-token` |

Details worth knowing:

- **`paper` registered 2×** — one NULL-scoped (`dataset=paperflow`, from migration `20260524131000_papers_as_documents`) plus one tenant-scoped (`dataset=production`, from `Plugins.Bootstrap` stamped with the Default workspace/project). On a fresh install both are present after `mix ecto.setup`. This is expected and not a bug. (On databases migrated from pre-papers state with papers in multiple datasets, additional rows may appear.)
- **Zero task documents** — seeds populate only legacy content. The single `task` schema exists; no rows are seeded into it.
- **Tenancy is bootstrapped at MIGRATE time** (migration `20260527110200_backfill_default_tenancy`), not lazily. The Default Workspace/Project/datasets exist after `mix ecto.migrate`, before any write.
- **`barkpark-dev-token`** has label `dev-studio` and perms read/write/admin. It is stored **sha256-hashed** — the plaintext above is what you send on the wire.

## Verify it's running

There is **no `/health` endpoint**. The token-free liveness probe is `/api/schemas` — deliberately not token-gated, and the same probe the blue/green deploy health gate and the uptime monitor use. It carries legacy headers (`Deprecation: true` / `Sunset: Wed, 31 Dec 2026 23:59:59 GMT`) and 404s after that sunset; it lists **public** schemas only:

```bash
curl -s localhost:4000/api/schemas | head -c 200
# → [{"name":"author",...}]
```

**`/v1/schemas/production` is not a liveness probe.** It is the canonical *schema-management* route, on the `:flat_admin_api` pipeline — it needs an **admin** token, so an unauthenticated `curl` returns `401`, not the list (and `curl -s` still exits 0, so the failure looks like a dead server):

```bash
curl -s localhost:4000/v1/schemas/production -H 'Authorization: Bearer barkpark-dev-token' | head -c 200
```

The Studio UI is served at the scoped URL (e.g. `http://localhost:4000/w/default/p/default/d/production/studio`). Both root `/` and `/studio` 302-redirect there automatically — the exact target depends on your session token and the Default Workspace/Project/Dataset resolution rule. Writes require auth:

```
Authorization: Bearer barkpark-dev-token
```

## Keep-alive on macOS

There is **no canonical service mechanism** for local dev — the systemd `make` targets are prod-only. To survive logout/reboot, use a LaunchAgent. The local foreground options (`make api`, tmux `make dev`, `./run.sh`) do **not** survive a session end.

Create `~/Library/LaunchAgents/dev.pelle.barkpark.plist` running `mix phx.server` with:

- `WorkingDirectory` = the `api/` directory
- Environment: `PORT=4000`, `MIX_ENV=dev`
- `RunAtLoad` = true, `KeepAlive` = true
- `StandardOutPath` = `~/.barkpark/barkpark-server.out.log`
- `StandardErrorPath` = `~/.barkpark/barkpark-server.err.log`

`KeepAlive=true` means launchd respawns the server if it dies. This is the only approach that survives logout/reboot.

## Gotchas

- **libvips required.** The `image` dependency needs it; without it media probing fails. `brew install vips`.
- **NULL `dataset_id` docs are invisible to scoped reads.** Documents written with no tenancy scope (e.g. the NULL-scoped `paper` registration for dataset `paperflow`) drop out of strict dataset-scoped reads. Stamp the Default dataset on docs you want visible.
- **The `drafts.` prefix model.** Create writes to `drafts.{id}`; publish copies it to `{id}`. A freshly created doc lives under the `drafts.` prefix until published.
- **`web/` is a separate Next.js demo**, not part of the API setup. It's a self-contained Vercel app (`pnpm install && pnpm dev` inside `web/`) that reads the Phoenix API read-only — skip it for backend setup.
- **`:4000` port conflicts.** If the server won't bind, something else owns the port.

## Troubleshooting

- **Server won't connect to Postgres / `ecto.setup` fails on auth.** You don't have the `postgres` role with password `postgres`. Run the verify command in [Prerequisites](#the-postgres-role-gotcha-verified-real); create the role or override `config/dev.exs`.
- **`localhost:4000` not responding.** Confirm the server is up with `curl -s localhost:4000/api/schemas` (the token-free probe). There is no `/health` endpoint. Do **not** probe with `/v1/schemas/production` — it is admin-gated, so its `401` tells you nothing about liveness. Check for a port conflict on `:4000`.
- **`mix deps.get` or media operations fail mentioning `vips`/`image`.** libvips isn't installed: `brew install vips`, then `mix deps.get` again.
