# @barkpark/engine

Run Barkpark inside a Node.js app. One call starts a Barkpark release and a private Postgres for a data folder, and resolves once the server answers.

```js
import { startBarkpark } from '@barkpark/engine'

const barkpark = await startBarkpark({
  dataDir: '/path/to/app-data/barkpark',
  plugins: ['bulldocs'],
})
// barkpark.url    http://127.0.0.1:<port>
// barkpark.token  the admin token for this data folder
await barkpark.stop()
```

npm installs the engine folder for the machine with the package: `@barkpark/engine` lists `@barkpark/engine-darwin-arm64`, `-linux-x64` and `-linux-arm64` as optional dependencies, and npm fetches only the one whose `os` and `cpu` match. `startBarkpark` finds it on its own. To run a folder you built, pass `release` or set `BARKPARK_ENGINE_RELEASE`.

The packages are private for now. Publishing them needs the owner's npm rights for the `@barkpark` scope.

## Options

| Option | Default | Meaning |
|---|---|---|
| `dataDir` | required | Folder the engine owns. Created if missing. |
| `plugins` | every plugin in the release | Names passed as `BARKPARK_PLUGINS`. `[]` turns every plugin off. Media is always added to a non-empty list by the server. |
| `port` | the port this folder used last, else a free one | HTTP port on 127.0.0.1. |
| `release` | `BARKPARK_ENGINE_RELEASE`, else the installed platform package | Engine folder to run. |
| `startupTimeoutMs` | 180000 | How long one boot may take. |
| `retries` | 3 | Restarts allowed per start, for failed boots and for a server that stops answering. |
| `healthIntervalMs` | 5000 | Interval between health checks once ready. |

The returned object has `url`, `token`, `port`, `dataDir`, `commit` (the Barkpark commit of the release), `status()` and `stop()`.

## What the engine owns

- **A private Postgres cluster** in `<dataDir>/pgdata`, created on first start with password authentication and reachable on 127.0.0.1 only, with no Unix socket. It is started and stopped with `pg_ctl` against that folder only.
- **Migrations** on every start, through the release's `Barkpark.Release.migrate()`.
- **A clean seed on the first start only** (`BARKPARK_SEED_PROFILE=clean`) with a generated admin token. The token is passed to the seed through its environment, returned to the caller, and redacted from every log. Later starts return the same token and do not reseed.
- **Secrets** in `<dataDir>/secrets.json`, readable by the owner only: the database password and the admin token. The server's keys (`SECRET_KEY_BASE`, `BARKPARK_KEK` and the others a production release needs) are derived from the database password.
- **Ports.** `PORT` and `PHX_PORT` are both set to the chosen port, so absolute URLs the server hands out, media URLs included, carry the port. The server listens on 127.0.0.1 only (`BARKPARK_HTTP_IP`), so the local network cannot reach it.
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

`engine.json` in the folder names the commit, platform, Erlang, Elixir and Postgres versions, and the system libraries the release needs. On macOS the folder needs nothing outside the system. On Linux it uses the system's glibc, OpenSSL 3, libstdc++, libtinfo and zlib, as listed in `engine.json` under `sharedLibraries`. The `engine-release` workflow builds the folder for macOS arm64, Linux x64 and Linux arm64 on every push to main and boots each one on a runner with no Elixir or Postgres.

## Packing for npm

```sh
(cd js/packages/engine && pnpm build)
node scripts/engine/pack.mjs launcher --out /tmp/npm
node scripts/engine/pack.mjs platform --engine /tmp/engine --out /tmp/npm
```

`launcher` packs this package and adds the three platform packages as optional dependencies at the same version. They are not in the workspace `package.json`, because pnpm cannot lock a package the registry does not have yet. `platform` turns an engine folder into its platform package. npm packs no symbolic links and no empty folders, so the script copies each link as the file it points to and marks each empty folder with `.keep`. The `engine-release` workflow packs both on every platform, installs them into a scratch app with `npm install` and boots Barkpark with `startBarkpark({ dataDir })` alone. Run it by hand (workflow_dispatch) and its `npm` job checks that the four tarballs agree on one version and runs `npm publish --dry-run` on each; choosing `publish` instead publishes the platform packages, then `@barkpark/engine`, under the `dist_tag` input (default `preview`, as in `release.yml`), and needs `NPM_TOKEN`, `main` and a version above 0.0.0.

## Tests

`pnpm test` runs the unit tests for options, the lease, the runtime record and secrets. The integration test runs when `BARKPARK_ENGINE_RELEASE` names an engine folder: it starts the engine on a temporary folder, reads `/status.json` and `/v1/tokens/current` with the returned token, checks that a second start is refused, stops, recovers a stale lock, restarts without reseeding, checks the logs hold no secret, and stops.

## Later stages

- `bp build` for a custom Barkpark plugs into `resolveRelease` in `src/release.ts` as one more source.
- Windows x64 is in progress (task-efbf914de2e8ab25). The launcher runs `bin/barkpark.bat` under `cmd.exe`, stops the server with `taskkill /T`, reads process start times through PowerShell and gives every child a fixed system PATH with `SystemRoot`. `scripts/engine/build-postgres.mjs` cuts Postgres from EnterpriseDB's binary zip, and `api/mix.exs` leaves out `:expty`, so the Studio terminal reports itself not enabled. The `engine-release` workflow builds and boots it only when run by hand with `windows` set to `also`. Such a run's `npm` job then also publishes (or dry-runs) `@barkpark/engine-win32-x64`, from the tarball the Windows boot installed.
- A custom build still needs a C compiler (argon2): MSVC on Windows. Dropping that is a later stage of the plan in `/papers/the-engine-2026-10-05`.
