<!-- doc-tier: human | canonical-for: quickstart | budget: 1400tok -->
# Quickstart

From nothing to a running Barkpark with a clean paper + media workspace. Three routes, one wizard. Verified 2026-06-28 against `main`.

## Install bp

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp version
```

**Windows** (PowerShell) — see [WINDOWS.md](WINDOWS.md) for the full guide:

```powershell
irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
```

| Env | Effect |
|---|---|
| `BARKPARK_BIN_DIR` | install dir (default `/usr/local/bin`, fallback `~/.local/bin`) |
| `BARKPARK_CLI_VERSION` | pin a release, e.g. `1.0.1` (default: latest `cli-v*`) |

Binaries are sha256-verified against the release's `checksums.txt` (hard-fail on mismatch; if a release ships no checksums the installer warns and continues).

## First run

```bash
bp
```

With no config and a real terminal, bare `bp` launches the wizard and falls through into the TUI; `bp setup` runs the same wizard and exits when done. Non-TTY / `-o json` / `--yes` never prompt — `bp setup` without `--target` exits with code 2 and directs you to `bp setup -h`.

**Which route?** Already have a server → `connect` · just want it on this machine → `local` · stand up your own VPS → `deploy` / `provision`. Managed Cloud (no local deps, fastest to production) skips this wizard — [Cloud Quickstart](CLOUD-QUICKSTART.md).

| Target | Effect |
|---|---|
| `connect` | point bp at an existing server (non-destructive) |
| `local` | bring up a dev server on this machine |
| `deploy` | install on a server you own over SSH |
| `provision` | create a cloud host (hetzner / azure), then deploy |

## Local

**Destructive — runs `mix ecto.reset` (wipes the dev DB).** A running dev server holds DB connections and blocks the reset (`object_in_use`) — stop it first, or use `--target connect`.

```bash
bp setup --target local --yes
```

Native `mix` by default; `--docker` uses compose. With no existing checkout in a parent directory, bp clones to `${BARKPARK_HOME:-~/.barkpark}/src`. Missing prereqs print the exact install command — bp never runs brew/apt:

| Need | Why |
|---|---|
| Elixir/mix + git | build + clone |
| Postgres on `:5432` | the store — role gotcha: [SETUP.md](SETUP.md) |
| libvips | media probing (warn-only) |

## Deploy

```bash
bp setup --target deploy --ssh-host root@VPS_IP --domain api.example.com --yes
```

`--domain` must be the public DNS name — baking an IP behind an HTTPS name will break the Studio (`check_origin`; see [../ops/PROD_OPS.md](../ops/PROD_OPS.md)). Lands on the box: ASDF Erlang/Elixir, Postgres, the systemd `barkpark` unit.

## Connect

```bash
bp setup --target connect --server https://api.example.com --token $TOKEN
```

Re-running connect with no `--server` reconnects to the active saved server. `bp servers` lists saved servers; `bp use <name>` switches; `--name` saves a handle. A `.barkpark.json` at a repo's root (`{"server":"<saved-name-or-url>"}`, plus optional `workspace`/`project`/`dataset` — never a token) pins every `bp` command run inside that repo; flags and `BARKPARK_*` env still win.

## Provision

```bash
bp setup --target provision --provider hetzner --dry-run
```

Staged: plans only unless the provider CLI (`hcloud` / `az`), a credential, and `--yes` are all present. Chains into deploy.

## Headless / CI

```bash
bp setup --target local --dry-run -o json | head -c 400   # plan shows profile: clean
```

Every target supports `--dry-run` (plan only, runs nothing) and `-o json` (one machine-readable object).

## Verify

```bash
bp whoami                                   # active server + auth tier
bp capabilities -o json | head -c 400       # the API surface, via your saved config
curl -fsS localhost:4000/api/schemas | head -c 200   # local target only
```

## Demo data

Fresh installs seed the clean profile: a welcome paper at `/papers/welcome`, one admin token, the paper/media schemas — nothing else. The 8-schema / 27-document demo set is opt-in. **Caution:** the `bp` route re-runs local setup, which **resets the dev DB**; the raw-`mix` alternative below is additive and keeps your admin token:

```bash
bp setup --target local --profile demo --yes              # via bp
BARKPARK_SEED_PROFILE=demo mix run priv/repo/seeds.exs    # raw mix, in api/ — additive,
                                                          # keeps your admin token (ecto.reset would wipe it)
```

## Use it as a task system

The clean profile ships the Tasks plugin enabled — your AI gets a claimable, dependency-aware work queue out of the box:

```bash
bp task ready                                    # unblocked queue, priority-ordered
bp task next agent-1                             # atomically claim the next ready task
bp task claim t1 agent-1                         # …or claim a specific one
bp task close t1 agent-1 1                       # <id> <worker> <observed_epoch>
```

Full guide — agent loop, Studio collaboration, goals/phases, troubleshooting: [TASK-SYSTEM.md](TASK-SYSTEM.md).

## Golden path

- `--dry-run` before `--yes`, always.
- Local DB ops are bare `mix` in `api/` — never `make seed/migrate` (prod wrappers).
- Deploys take a DNS name in `--domain`, never an IP.
- The clean seed prints its admin token **once** — store it (bp saves it to `$XDG_CONFIG_HOME/barkpark/config.json` — default `~/.config` — 0600).
- Server updates: ssh in, `git pull` (the post-merge hook rebuilds + restarts).
- Reconfigure by re-running `bp setup`, not by hand-editing `config.json`.

Canon: [`../cli/HANDBOOK.md`](../cli/HANDBOOK.md) (bp semantics) · [`SETUP.md`](SETUP.md) (from-source) · [`../ops/PROD_OPS.md`](../ops/PROD_OPS.md) (server ops).
