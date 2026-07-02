<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

[![Deploy with Barkpark](https://barkpark.cloud/button.svg)](https://barkpark.cloud/new?template=blog-starter)

**[Live Studio →](https://api.barkpark.cloud/studio)** · **[Install](#install--connect)** · **[Deploy](#be-your-own-cloud)** · **[Barkpark Cloud](https://barkpark.cloud)** · **[Docs](docs/INDEX.md)**

**A lightweight operating system for everything you and your AI make.** One content model —
tasks, papers, sheets, media, anything you can schema — with an AI agent driving the API while
you edit the same documents live in a browser Studio or a terminal. Installs in minutes anywhere.

**Barkpark is yours** — open source you run wherever you want: a laptop, a VPS, a box at
home. You own your content, your schema, your server, and your source
code — you should never have to rely on us. Host it yourself, with any third party, or on
**[Barkpark Cloud](https://barkpark.cloud)** — the official home: the **auth tunnel** (one login
for your whole fleet), ease of mind, a way to cheer the work on. [The full stance →](docs/PHILOSOPHY.md)

*Private. Collaborative. Incremental. Secure. Realtime. Yours.*

## Install & connect

Two commands on macOS / Linux (the live [Studio](https://api.barkpark.cloud/studio) needs none):

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup          # local · deploy · connect — pick one, it does the rest
```

Own a server? `bp setup --target deploy` installs over SSH.

Windows: `irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex`, then `.\scripts\setup-windows.ps1`.

[Quickstart](docs/setup/QUICKSTART.md) · [Learn & own](docs/learn/README.md) · [From source](docs/setup/SETUP.md)

## Create fast

Define a shape, get every surface — Studio pane, TUI desk, REST routes, CLI verbs — no client
code:

```bash
bp make schema recipe --out recipe.json   # commented skeleton — fill the blanks
bp schema apply --file recipe.json        # the type now exists on every surface
bp seed recipe --count 5 --publish        # schema-valid sample data, live
bp tinker                                 # REPL: query it, poke it
```

Minutes from idea to a typed, queryable API with a real editing UI on top.

## Your AI agent, unreasonably powerful

Point any agent at a Barkpark and it gains structured memory with hands:

- **The whole API in one call** — `bp capabilities -o json` teaches an agent every noun, verb,
  and route. No docs pasted into context.
- **A real task board** — lifecycle, dependencies, priorities, and an atomic claim/close
  contract built for concurrent workers:
  ```bash
  bp task next agent-1                      # atomically claim the next ready task
  bp task claim t1 a1 --resources lib/x.ex  # fence files against parallel workers
  bp task close t1 agent-1 1                # CAS on the claim epoch
  ```
  Because the board lives in Barkpark, not in the session, **an agent can disconnect, crash, or
  restart and still be on track** — it reclaims its work, context intact. Fleets coordinate
  through the same queue while you set priorities in Studio.
- **Papers** — agents write long-form docs over a token-gated ingest API; read at
  `/papers/:slug`, edit live.
- **No black boxes** — agents work in the open: you watch every change land live in Studio.
  SSE stream for anything that reacts.
- **Agent-grade plumbing** — JSON when piped, atomic batch writes via `-f`, stable exit codes.

This repo runs on it: our agents claim work from `bp task ready`, publish design papers, and
score the codebase into a browsable graph.

## Uses we didn't expect

We built it for content. Day to day it turned out to be:

- **a codebase X-ray** — [Cody](tooling/README.md) publishes one scored paper per source
  file — your repo as a browsable graph
- **a shared desk** — the AI structures, you refine, same document, same second
- **a spreadsheet** ([Sheets](docs/learn/plugins-catalog.md), formulas and all) · **a media
  library** (signed URLs, processing pipeline) · **a book-metadata pipeline** (ONIX 3.0)
- **a scratchpad with hard walls** — `bp workspace create Spike` spins up an isolated
  workspace (own project, dataset, schemas, tasks, papers, media); nothing leaks

## Four ways in

| Surface | What it is |
|---|---|
| **`bp` CLI** | One static binary speaking the whole API — `bp <noun> <verb>`, assembled live from `GET /v1/capabilities`. |
| **Web Studio** | Multi-pane LiveView desk at `/studio` — drill, filter, edit-with-autosave, publish, real-time. |
| **Terminal TUI** | The same desk, keyboard-driven (`bp` with no args). |
| **REST API** | Public reads, token-authed writes, Sanity-compatible mutations, SSE change stream. |

## Be your own cloud

Any Ubuntu 22.04+ box → HTTPS + CLI login. Point a DNS A record at the box, run `deploy.sh`
(installs Barkpark + Caddy/TLS, prints your admin token):

```bash
scp deploy.sh root@SERVER_IP:/root/
ssh root@SERVER_IP "DOMAIN=app.example.com BARKPARK_SEED_PROFILE=clean bash /root/deploy.sh"
```

`DOMAIN` = public hostname, never an IP. Walkthrough: [`GO-LIVE.md`](docs/setup/GO-LIVE.md).
Prefer it handled? **[Barkpark Cloud](https://barkpark.cloud)** runs it for you — one login
across your fleet, trustworthy because you can always leave, and using it supports the work.
Or run the control plane ([`cloud/`](cloud/README.md)) yourself.

## How it works

- **One schema, many surfaces.** A single SchemaDefinition drives Studio, TUI, REST, and CLI.
- **Manifest-driven contract.** The server projects nouns, verbs, and routes into
  `GET /v1/capabilities`; every client reads the same projection — default-deny,
  existence-hiding, keyed on auth tier.
- **The plugin highway.** Plugins are first-party Elixir modules on the `Barkpark.Plugin`
  behaviour — schemas, routes, workers, cron, CLI verbs travel module → manifest → `bp` shell.
  **With all plugins off, Barkpark still works.**

Stack: Elixir / Phoenix LiveView · PostgreSQL · Oban · Go (CLI + TUI, one binary) · Caddy.
Bundled plugins: **Tasks · Bulldocs · Media · OnixEdit · Sheets · Frt**. 3300+ tests.

## Codebase grade — B+ · 81 / 100

Barkpark grades *itself* — **Cody**, its 13-critic suite ([`tooling/`](tooling/README.md)),
recomputes these live:

| Critic | | Critic | | Critic | |
|---|--:|---|--:|---|--:|
| Architecture | 85 | Consistency | 78 | Tested | 87 |
| Duplication | 100 | Reliability | 65 | **Hotspots** | **64** |
| Dead-code | 100 | Evaluated | 100 | Modularity | 66 |
| Contract | 100 | Dependencies | 94 | **Bloat** | **78** |
| **Aesthetics** | **84** | | | | |

Honest: Architecture counts 5 real layering violations; critique in
[`GRADE-CRITIQUE.md`](tooling/quality/GRADE-CRITIQUE.md).

## Documentation

| Doc | What |
|---|---|
| [`GO-LIVE.md`](docs/setup/GO-LIVE.md) · [`TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) | Deploy a public instance · the task system |
| [`HANDBOOK.md`](docs/cli/HANDBOOK.md) · [`cheatsheets/`](docs/cheatsheets/) | Full `bp` manual · one-pagers |
| [`api-v1.md`](docs/api-v1.md) · [`auth.md`](docs/auth.md) | HTTP contract · tokens and tiers |
| [`plugins.md`](docs/cards/plugins.md) | Build a plugin (contract: `api/lib/barkpark/plugin.ex`) |

## License

MIT
