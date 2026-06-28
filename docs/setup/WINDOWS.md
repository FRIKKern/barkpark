<!-- doc-tier: human | canonical-for: windows-setup | budget: 2200tok -->
# Barkpark on Windows

Two things you can do on Windows, each **one command**:

1. **Run a local Barkpark server** (Phoenix API + Studio) — `scripts\setup-windows.ps1`
2. **Install the `bp` CLI** to drive a server / the TUI — a PowerShell one-liner

Everything below is PowerShell (5.1 or 7+). Tested end-to-end on Windows 11 with Erlang/OTP 28, Elixir 1.20, PostgreSQL 18.

---

## 1. Run a local server — one command

**Prerequisites:** 64-bit Windows 10/11, `git`, and a clone of this repo. That's it — the script installs the rest (no admin, no Visual Studio).

```powershell
git clone https://github.com/FRIKKern/barkpark.git
cd barkpark
.\scripts\setup-windows.ps1
```

The script is idempotent and does the whole job:

- installs **Scoop** (user-scoped package manager) if missing
- installs **Erlang/OTP + Elixir + PostgreSQL** via Scoop
- pins that toolchain ahead of any stale system Erlang/Elixir on your PATH
- initializes + starts a local **Postgres** cluster (trust auth, `postgres` superuser)
- fetches deps, **compiles**, and **creates + migrates + seeds** the database
- starts **Phoenix** in its own window and waits until the API answers

When it finishes you get:

| | |
|---|---|
| Studio | `http://localhost:4000/studio` |
| API | `http://localhost:4000/api/schemas` (liveness probe — there is no `/health`) |
| Reader | `http://localhost:4000/papers/<slug>` |
| Token | `barkpark-dev-token` (read+write+admin; `demo` profile) |

### Create a paper

```powershell
irm http://localhost:4000/v1/plugins/bulldocs/papers -Method Post `
  -Headers @{Authorization='Bearer barkpark-dev-ingest-token'} `
  -ContentType 'application/json' `
  -Body '{"slug":"hello","style":"article","blocks":[{"type":"heading","level":1,"text":"Hello from Windows"},{"type":"paragraph","content":[{"type":"text","value":"Made on a native Windows dev server."}]}]}'
```

Then open `http://localhost:4000/papers/hello`. Note the block shapes: **headings carry `text`**, paragraphs carry `content` (inline nodes).

### Daily use

```powershell
.\scripts\setup-windows.ps1 start     # start Postgres + server (after first setup)
.\scripts\setup-windows.ps1 status    # toolchain + Postgres + API health
.\scripts\setup-windows.ps1 stop      # stop Postgres (close the server window to stop Phoenix)
```

**Always start the server through this script.** It sets PATH correctly each run, so you never fight the stale system Erlang/Elixir that Windows keeps ahead of Scoop in fresh shells.

| Flag | Effect |
|---|---|
| `-Profile clean` | papers + media schemas only, one admin token printed once (default is `demo`) |
| `-Port 4001` | bind a different port (dev now honors `PORT`) |
| `-Recreate` | drop + recreate the DB (DESTRUCTIVE) |
| `-NoStart` | set up everything but don't launch the server |

---

## 2. Install the `bp` CLI

For connecting to a server, the TUI, and the setup wizard:

```powershell
irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
bp version
```

Auto-detects arch, **verifies the sha256** against the release `checksums.txt` (hard-fails on mismatch), installs to `%LOCALAPPDATA%\Barkpark\bin`, and adds it to PATH. Then point it anywhere:

```powershell
bp setup --target connect --server https://api.example.com --token $env:BARKPARK_TOKEN
bp whoami
```

| Env var | Effect |
|---|---|
| `BARKPARK_BIN_DIR` | install dir (default `%LOCALAPPDATA%\Barkpark\bin`) |
| `BARKPARK_CLI_VERSION` | pin a release, e.g. `1.0.1` |

> The `irm | iex` form runs in-process and is **not** blocked by a Restricted execution policy.

---

## Media on Windows (ImageMagick)

Image renditions normally use `vix`/libvips, which has **no Windows prebuilt NIF**. So on Windows Barkpark uses an **ImageMagick backend** instead: `mix.exs` drops the `image` dep, and `Barkpark.Media.ImageBackend.Magick` shells out to the `magick` CLI — a plain executable, no NIF. (`Barkpark.Media.ImageBackend` is the behaviour interface; the concrete Windows implementation is the `.Magick` submodule.) `scripts\setup-windows.ps1` installs it (`scoop install imagemagick`); the backend is selected automatically by OS.

All presets work natively — **thumb / preview / hero / og, JPEG and WebP**. macOS, Linux, Docker, and CI keep using libvips unchanged (byte-identical output there).

Prefer libvips on Windows anyway? Install libvips + a C toolchain and build with `BARKPARK_WITH_IMAGE=1`, or use Docker.

---

## Docker alternative

If you prefer containers (or want media without a C toolchain), use Docker Desktop:

```powershell
bp setup --target local --docker --yes
```

This runs Postgres + the API in `docker compose`, fully isolated. Requires Docker Desktop running (`docker version` must succeed). If the CLI can't reach the engine, your Docker Desktop is likely outdated — update it.

---

## Manual setup (without the script)

The Phoenix-from-clone steps are the same as Linux/macOS once a modern toolchain is present — see [`SETUP.md`](SETUP.md). The Windows-specific deltas the script handles for you: install via Scoop (`scoop install erlang elixir postgresql imagemagick`), start Postgres with `pg_ctl`, prepend the Scoop dirs to PATH, and rely on the auto-dropped `image` dep. For native-from-clone backend work you can also use **WSL2** and follow `SETUP.md` inside Ubuntu.

---

## Troubleshooting (Windows)

- **`bp` not recognized** — open a new terminal (PATH applies to *new* sessions), or run `& "$env:LOCALAPPDATA\Barkpark\bin\bp.exe" version`.
- **`mix` / `erl` resolve to an old version** — a stale system Erlang/Elixir is ahead of Scoop on PATH. The setup script side-steps this by always prepending the Scoop toolchain; use it to run the server. To fix permanently, uninstall the old Erlang/Elixir or move the Scoop dirs earlier in PATH.
- **Port 4000 in use** — `setup-windows.ps1 start -Port 4001`.
- **Postgres won't start** — check `~\scoop\apps\postgresql\current\pg.log`; `setup-windows.ps1 status` shows whether it's up.
- **`curl` does the wrong thing** — in PowerShell `curl` aliases `Invoke-WebRequest`; use `irm` or `curl.exe`.
- **SmartScreen flags `bp.exe`** — unsigned single binary; the installer's sha256 check is the integrity guarantee. Allow it or pin `BARKPARK_CLI_VERSION`.

Canon: [`QUICKSTART.md`](QUICKSTART.md) (cross-platform) · [`SETUP.md`](SETUP.md) (from-source) · [`../cards/cli.md`](../cards/cli.md) (`bp` semantics).
