# Personal-local Barkpark (`barkpark up`)

Wave 5 of the convergence project: run the whole stack with one command, no
manual Postgres, no hand-rolled secrets. Everything Barkpark-private lives under
`$BARKPARK_HOME` (default `~/.barkpark`).

## One command

```bash
bin/barkpark up
```

That does, in order:

1. **Secrets** (`Barkpark.Release.Secrets`) — first run generates `SECRET_KEY_BASE`,
   `PREVIEW_JWT_SECRET`, and `BARKPARK_CLOAK_KEY` into `~/.barkpark/.env` and
   `chmod 0600`s it. Re-runs only top up *missing* keys — existing values are
   never overwritten and never printed.
2. **Managed Postgres** (`bin/barkpark-pg start`) — a Barkpark-private Postgres
   on **port 5433**, bound to `127.0.0.1` only, with its data dir at
   `~/.barkpark/pgdata`. First run `initdb`s it; later runs detect and reuse the
   existing data dir. It never touches a system/dev Postgres on 5432.
3. **Migrate** — `mix ecto.migrate` against the managed instance.
4. **Boot** — `mix phx.server` in `MIX_ENV=prod` (so `config/runtime.exs` reads
   the managed `DATABASE_URL` and the generated secrets), then prints the URL.

`barkpark up` is safe to re-run: an already-running Postgres and server are
detected and left alone.

| Command | Effect |
|---|---|
| `barkpark up` | ensure secrets → start PG → migrate → boot → print URL |
| `barkpark reload` | restart the server so config changes take effect (PG stays up) |
| `barkpark stop` | stop the server and the managed Postgres |
| `barkpark status` | report Postgres + server state |
| `barkpark psql …` | psql shell on the managed Postgres |

### Locating Postgres tools

`barkpark-pg` finds `initdb`/`pg_ctl`/`psql` in this priority order:

1. `$BARKPARK_PG_BIN` (explicit override),
2. Postgres.app bundled versions (newest),
3. Homebrew `postgresql@NN` kegs (newest),
4. whatever is on `PATH`.

The Postgres **major.minor** that created the data dir is pinned in
`~/.barkpark/PG_VERSION_PINNED`. Starting against a different *major* version
fails fast with a clear message rather than a cryptic `pg_ctl` error, because
Postgres cannot open a data dir across major versions.

## CONFIG-RELOAD FOOTGUN (read this)

Barkpark reads its secrets and tokens from `~/.barkpark/.env` **at boot only**.
Neither `mix phx.server` nor a `mix release` hot-reloads `config/*.exs` or
re-reads the env file while running. So when you change a value in
`~/.barkpark/.env` — most commonly `PAPERFLOW_INGEST_TOKEN` — the running server
keeps the **old** value until it is restarted.

That is why `barkpark reload` exists. It is a full stop + start of the server
process (Postgres keeps running), which re-sources `~/.barkpark/.env` and
re-runs `config/runtime.exs`:

```bash
$EDITOR ~/.barkpark/.env      # change PAPERFLOW_INGEST_TOKEN
bin/barkpark reload           # new token now in effect
```

Editing the env file without `reload` is a silent no-op against the running
server — the single most common Wave-5 footgun, and the reason this command is
not just `up` run twice.

## Overrides

| Env var | Default | Meaning |
|---|---|---|
| `BARKPARK_HOME` | `~/.barkpark` | root for data dir, env file, logs, pidfile |
| `BARKPARK_PG_PORT` | `5433` | managed Postgres port |
| `BARKPARK_PG_BIN` | autodetect | force a specific Postgres `bin/` |
| `PORT` | `4000` | HTTP port the server listens on |
| `PHX_HOST` | `localhost` | host for `Endpoint` URL + `check_origin` |
| `BARKPARK_MIX_ENV` | `prod` | the env `up`/`reload` boot under |
