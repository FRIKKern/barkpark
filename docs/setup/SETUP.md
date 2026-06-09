# Barkpark — Standalone Setup

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

## CRITICAL — do not use the `make` targets locally

The `make` targets are **prod/Linux systemd wrappers** for the Hetzner box, not local dev commands.

| Target | What it actually does | Use locally instead |
|---|---|---|
| `make seed` / `make migrate` / `make reset-db` | Wrap `start.sh`, which hardcodes `/root/.asdf` paths and `MIX_ENV=prod` | `mix ecto.setup` / `mix ecto.migrate` / `mix ecto.reset` (in `api/`) |
| `make restart` / `make stop` / `make status` / `make logs` | `systemctl` / `journalctl` against the prod unit | nothing — useless on macOS |

Locally, always run bare `mix` commands inside `api/`.

## What seeding produces

Verified counts from a clean database:

| Object | Count | Notes |
|---|---|---|
| `schema_definitions` | varies | 8 legacy content types (seeded directly) + plugin-contributed schemas registered on boot via `Plugins.Bootstrap.register_all_schemas/0` (`paper`, the single `task` schema, plus any other enabled plugins' schemas, e.g. media/onixedit/frt). Run `SELECT count(*), count(distinct name) FROM schema_definitions;` against a freshly-seeded DB for the exact tally — it tracks the enabled plugin set. |
| `documents` | 27 | post 9, page 5, project 4, author 3, category 3, colors/navigation/siteSettings 1 each |
| Workspaces | 1 | Default Workspace |
| Projects | 1 | Default Project (slug `default`) |
| Datasets | 2 | `production`, `paperflow` |
| API tokens | 1 | `barkpark-dev-token` |

Details worth knowing:

- **`paper` registered 3×** — one NULL-scoped plus two dataset-scoped. This is the known media/tenancy pattern, **not a bug**.
- **Zero task documents** — seeds populate only legacy content. The single `task` schema exists; no rows are seeded into it.
- **Tenancy is bootstrapped at MIGRATE time** (migration `20260527110200_backfill_default_tenancy`), not lazily. The Default Workspace/Project/datasets exist after `mix ecto.migrate`, before any write.
- **`barkpark-dev-token`** has label `dev-studio` and perms read/write/admin. It is stored **sha256-hashed** — the plaintext above is what you send on the wire.

## Verify it's running

There is **no `/health` endpoint**. The real liveness probe is the schemas list:

```bash
curl -s localhost:4000/api/schemas | head -c 200
# → [{"name":"author",...}]
```

The Studio UI is at `http://localhost:4000/studio` (root `/` redirects there). Writes require auth:

```
Authorization: Bearer barkpark-dev-token
```

## Keep-alive on macOS

There is **no canonical service mechanism** for local dev — the `make` targets are prod-only. To survive logout/reboot, use a LaunchAgent. Foreground options (`make api`, tmux `make dev`, `run.sh`) do **not** survive a session end.

Create `~/Library/LaunchAgents/dev.pelle.barkpark.plist` running `mix phx.server` with:

- `WorkingDirectory` = the `api/` directory
- Environment: `PORT=4000`, `MIX_ENV=dev`
- `RunAtLoad` = true, `KeepAlive` = true
- `StandardOutPath` = `~/.paperflow/barkpark-server.out.log`
- `StandardErrorPath` = `~/.paperflow/barkpark-server.err.log`

`KeepAlive=true` means launchd respawns the server if it dies. This is the only approach that survives logout/reboot.

## Gotchas

- **libvips required.** The `image` dependency needs it; without it media probing fails. `brew install vips`.
- **NULL `dataset_id` docs are invisible to scoped reads.** Documents written with no tenancy scope (e.g. one of the three `paper` registrations) drop out of strict dataset-scoped reads. Stamp the Default dataset on docs you want visible.
- **The `drafts.` prefix model.** Create writes to `drafts.{id}`; publish copies it to `{id}`. A freshly created doc lives under the `drafts.` prefix until published.
- **`web/` is a separate Next.js demo**, not part of the API setup. It's a self-contained Vercel app (`pnpm install && pnpm dev` inside `web/`) that reads the Phoenix API read-only — skip it for backend setup.
- **`:4000` port conflicts.** If the server won't bind, something else owns the port.

## Troubleshooting

- **Server won't connect to Postgres / `ecto.setup` fails on auth.** You don't have the `postgres` role with password `postgres`. Run the verify command in [Prerequisites](#the-postgres-role-gotcha-verified-real); create the role or override `config/dev.exs`.
- **`localhost:4000` not responding.** Confirm the server is up with `curl -s localhost:4000/api/schemas`. There is no `/health` endpoint — the schemas list is the probe. Check for a port conflict on `:4000`.
- **`mix deps.get` or media operations fail mentioning `vips`/`image`.** libvips isn't installed: `brew install vips`, then `mix deps.get` again.
