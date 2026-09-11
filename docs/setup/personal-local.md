<!-- doc-tier: human | canonical-for: personal-local-stack | budget: 800tok -->
# Personal-local Barkpark (`barkpark up`)

The whole stack in one command — no manual Postgres, no hand-rolled secrets.
Everything Barkpark-private lives under `$BARKPARK_HOME` (default `~/.barkpark`).

## One command

```bash
cd api && mix deps.get && cd ..   # once per fresh clone/worktree — see Traps
bin/barkpark up
bin/barkpark token                # the key to /studio — printed ONCE
```

`up` does, in order:

1. **Secrets** (`Barkpark.Release.Secrets`) — writes `SECRET_KEY_BASE`,
   `PREVIEW_JWT_SECRET`, `BARKPARK_CLOAK_KEY`, `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET`,
   `BARKPARK_KEK` (the envelope KEK — `:prod` raises without it) and
   `BARKPARK_ALLOW_BUNDLE_IMPORT=1` into `~/.barkpark/.env`, `chmod 0600`. Re-runs
   top up only *missing* keys; existing values are never overwritten or printed.
2. **Managed Postgres** (`bin/barkpark-pg start`) — Barkpark-private, **port
   5433**, `127.0.0.1` only, data dir `~/.barkpark/pgdata`, `initdb`d once then
   reused. Never touches a system/dev Postgres on 5432.
3. **Migrate** — `mix ecto.migrate` against the managed instance.
4. **Boot** — `mix phx.server` under `MIX_ENV=prod`, then prints the URL **and
   whether this box has an admin credential yet**. Safe to re-run: a running
   Postgres and server are left alone.

| Command | Effect |
|---|---|
| `barkpark up` | secrets → PG → migrate → boot → URL + credential state |
| `barkpark token` | mint this box's admin credential (idempotent), print it once |
| `barkpark reload` | restart the server so config changes take effect |
| `barkpark stop` | stop the server and the managed Postgres |
| `barkpark status` | report Postgres + server state |
| `barkpark psql …` | psql shell on the managed Postgres |

## Getting an admin token

`up` never mints one, so a fresh box boots with `api_tokens` empty: `/studio`
302s to a `/login` offering Email+Password against **0 users** and API token
against **0 tokens**, and there is no `/register`. `bin/barkpark token` is the key.

It runs the **clean** seed profile (pinned — the `demo` default would install a
shared plaintext dev token), mints `bp_admin_<24B base64url>` scoped
`read,write,admin`, stores only its SHA-256, and prints it **once**. Paste it into
`/login` → *API token*, or hand it to `bp setup --target connect --server
http://localhost:PORT --token bp_admin_…`. Re-running is safe: the seed skips
while an unrevoked admin token is present, so it never mints a second key beside
a live one. `bp login` is a **cloud** verb and cannot target a local box.

## Traps

- **`mix deps.get` first, once per fresh clone/worktree.** `up` never runs it, and
  step 1 shells out to `mix run --no-start -e …` in `api/`, so with no `deps/` it
  dies in a compile error that names nothing real.
- **`CC=/usr/bin/clang` if a NIF fails to build** — a `cc` shim on `PATH` shadows
  the real compiler.
- **Keep `$BARKPARK_HOME` short (under ~85 chars).** `barkpark-pg` puts the Unix
  socket dir inside it (`-k`) and socket paths cap near 104 bytes; a deep path
  fails inside `pg_ctl`, nowhere that explains itself.
- **Never pipe `up` into `tail`/`head`.** It leaves a detached server holding the
  pipe's write end, so the pipeline never returns — it looks like a hung launcher.
- **Postgres tools** resolve via `$BARKPARK_PG_BIN`, Postgres.app, Homebrew
  `postgresql@NN` kegs, `PATH`; the data dir's major.minor is pinned in
  `~/.barkpark/PG_VERSION_PINNED` and a different *major* fails fast.
- **`.env` is read at BOOT ONLY** — nothing re-reads it while running, so editing
  it (most commonly `BARKPARK_INGEST_TOKEN`) is a silent no-op against the live
  server. `bin/barkpark reload` is the fix: a full stop + start of the server
  process, Postgres untouched.

## Overrides

| Env var | Default | Meaning |
|---|---|---|
| `BARKPARK_HOME` | `~/.barkpark` | data dir, env file, logs, pidfile (keep it SHORT) |
| `BARKPARK_PG_PORT` | `5433` | managed Postgres port |
| `BARKPARK_PG_BIN` | autodetect | force a Postgres `bin/` |
| `PORT` | `4000` | HTTP port the server listens on |
| `PHX_HOST` | `localhost` | host for `Endpoint` URL + `check_origin` |
| `BARKPARK_MIX_ENV` | `prod` | env `up`/`reload` boot under |
| `BARKPARK_KEK` | generated | envelope KEK; `:prod` raises without it — never hand-edit a live one |
| `BARKPARK_MEDIA_DIR` | `api/uploads` | media blob root — read at boot; `reload` picks it up |
| `BARKPARK_ALLOW_BUNDLE_IMPORT` | `1` (set by `up`) | allow bundle import here; fail-closed elsewhere |

## Pulling cloud data down (blob push)

The twin is a **pull target**: `bp cloud workspace import` copies a cloud
workspace's rows in; blobs are re-pointed via an admin-gated raw-blob write,
`PUT /api/workspaces/:workspace_slug/media/blob/*path` (bytes verbatim at a
strictly-validated relative path; traversal/absolute refused `422`).
"Admin-gated" means the token from `barkpark token`. A bare infra route, absent
from the manifest. A media row whose blob is not pushed yet serves an honest
`404`, so a mid-flight import degrades cleanly.
