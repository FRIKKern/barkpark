# @barkpark/engine

Run Barkpark inside a Node.js app. One call starts a Barkpark release and a private Postgres for a data folder, and resolves once the server answers.

```js
import { startBarkpark } from '@barkpark/engine'

const barkpark = await startBarkpark({
  dataDir: '/path/to/app-data/barkpark',
  plugins: ['bulldocs'],
  release: '/path/to/engine-folder', // or set BARKPARK_ENGINE_RELEASE
})
// barkpark.url    http://127.0.0.1:<port>
// barkpark.token  the admin token for this data folder
await barkpark.stop()
```

The package is private for now. Publishing it needs the owner's npm rights for the `@barkpark` scope.

## Options

| Option | Default | Meaning |
|---|---|---|
| `dataDir` | required | Folder the engine owns. Created if missing. |
| `plugins` | every plugin in the release | Names passed as `BARKPARK_PLUGINS`. `[]` turns every plugin off. Media is always added to a non-empty list by the server. |
| `port` | the port this folder used last, else a free one | HTTP port on 127.0.0.1. |
| `release` | `BARKPARK_ENGINE_RELEASE` | Engine folder to run. |
| `startupTimeoutMs` | 180000 | How long one boot may take. |
| `retries` | 3 | Restarts allowed per start, for failed boots and for a server that stops answering. |
| `healthIntervalMs` | 5000 | Interval between health checks once ready. |

The returned object has `url`, `token`, `port`, `dataDir`, `commit` (the Barkpark commit of the release), `status()` and `stop()`.

## What the engine owns

- **A private Postgres cluster** in `<dataDir>/pgdata`, created on first start with password authentication and reachable on 127.0.0.1 only, with no Unix socket. It is started and stopped with `pg_ctl` against that folder only.
- **Migrations** on every start, through the release's `Barkpark.Release.migrate()`.
- **A clean seed on the first start only** (`BARKPARK_SEED_PROFILE=clean`) with a generated admin token. The token is passed to the seed through its environment, returned to the caller, and redacted from every log. Later starts return the same token and do not reseed.
- **Secrets** in `<dataDir>/secrets.json`, readable by the owner only: the database password and the admin token. The server's keys (`SECRET_KEY_BASE`, `BARKPARK_KEK` and the others a production release needs) are derived from the database password.
- **Ports.** `PORT` and `PHX_PORT` are both set to the chosen port, so absolute URLs the server hands out, media URLs included, carry the port.
- **Health.** A start resolves when `/status.json` reports `database`, `migrations` and `plugins` as operational. After that a check runs on an interval, and three misses in a row restart the server and the database.
- **One owner per folder.** `<dataDir>/engine.lock` refuses a second start while its owner's process lives (`EngineBusyError`). A lock left by a process that is gone is moved aside and taken over. A server or database left running by such a process is stopped first, proven by its process id and start time.
- **Logs** in `<dataDir>/logs`: `server.log` (release output, secrets redacted), `postgres.log` and `engine.log` (failed boots and restarts).

The engine sets `BARKPARK_SHAPE=app` and turns off the Studio terminal console and Claude chat.

## Building an engine folder

From a clean Barkpark checkout with Elixir, Erlang, a C toolchain and Node:

```sh
node scripts/engine/build-release.mjs --out /tmp/engine
node scripts/engine/build-postgres.mjs --out /tmp/postgres
node scripts/engine/build-release.mjs --add-postgres /tmp/engine /tmp/postgres
```

`engine.json` in the folder names the commit, platform, Erlang, Elixir and Postgres versions, and the system libraries the release needs. On macOS the folder needs nothing outside the system; on Linux it needs glibc and OpenSSL 3 from the system. The `engine-release` workflow builds the folder for macOS arm64, Linux x64 and Linux arm64 on every push to main and boots each one on a runner with no Elixir or Postgres.

## Tests

`pnpm test` runs the unit tests for options, the lease, the runtime record and secrets. The integration test runs when `BARKPARK_ENGINE_RELEASE` names an engine folder: it starts the engine on a temporary folder, reads `/status.json` and `/v1/tokens/current` with the returned token, checks that a second start is refused, stops, recovers a stale lock, restarts without reseeding, checks the logs hold no secret, and stops.

## Later stages

- The release is found by path today. Platform packages (`@barkpark/engine-<platform>-<arch>`) and `bp build` for a custom Barkpark plug into `resolveRelease` in `src/release.ts`.
- Windows is not supported yet, and a custom build still needs a C compiler (argon2). Both come in later stages of the plan in `/papers/the-engine-2026-10-05`.
- The release's HTTP listener binds every interface, as prod does. Binding it to 127.0.0.1 needs a setting in `api/config/runtime.exs`.
