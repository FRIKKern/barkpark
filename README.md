<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

**The workspace your AI works in.** A headless CMS built for AI agents: an AI stores, sorts, and structures content — **tasks, papers, media** — while you edit the same documents in a browser Studio. The agent drives the API; you drive the panes — both in real time.

## Try it now

**[Open the live Studio →](https://api.barkpark.cloud/studio)** — no account, no setup. That's Barkpark running right now.

## Install & connect

Install the `bp` CLI; `bp setup` connects you to a server — or brings one up locally:

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup          # local · deploy · connect — pick one, it does the rest
bp task ready     # see what's ready to work
```

Windows: `irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex`, then `.\scripts\setup-windows.ps1`.

[Quickstart](docs/setup/QUICKSTART.md) · [Learn & own](docs/learn/README.md) · [Windows](docs/setup/WINDOWS.md) · [From source](docs/setup/SETUP.md)

## What you can do

Everything is a document in one content model. The built-ins:

- **Tasks — your AI's board** (the headline use case). A lifecycle (`open → in_progress → done`, `blocked`, `cancelled`), dependencies, priorities, labels, and an atomic claim/close contract for concurrent workers:
  ```bash
  bp task next agent-1                      # atomically claim the next ready task
  bp task claim t1 a1 --resources lib/x.ex  # fence files against parallel workers
  bp task close t1 agent-1 1                # CAS on the claim epoch
  ```
  In `/studio` the same queue is the **Tasks** pane — you set priority/assignee while the agent claims and closes over HTTP. A root task is a goal; subtasks nest via `parent_id`. Guide: [`TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md).
- **Papers** — long-form docs read at `/papers/:slug`, written by agents over a token-gated ingest API (the Bulldocs plugin).
- **Media** — an asset library with signed URLs and a processing pipeline.
- **Sheets** — collaborative spreadsheets at `/sheets/:slug`, formulas and all.
- **Codebase intelligence** — point Barkpark at a repo and your code becomes browsable, scored content: one paper per file across 13 quality dimensions, an interconnected graph you explore in Studio.
  ```bash
  node tooling/cody/cody.mjs preflight       # where am I, is my codebase analyzed?
  node tooling/status/status.mjs --publish   # score every file + publish into Barkpark
  ```
- **Workspaces** — one call spins up an isolated workspace (own project, dataset, schemas, tasks, papers, media); nothing leaks into your real work:
  ```bash
  bp workspace create Spike
  ```

## Four ways in

| Surface | What it is |
|---|---|
| **`bp` CLI** | One static binary speaking the whole API — `bp <noun> <verb>`, assembled live from `GET /v1/capabilities`. Same binary as the TUI. |
| **Web Studio** | Multi-pane LiveView desk at `/studio` — drill, filter, edit-with-autosave, publish. Real-time across tabs. |
| **Terminal TUI** | The same desk, keyboard-driven (`bp` with no args). |
| **REST API** | Public reads, token-authed writes, Sanity-compatible mutations, SSE change stream. |

## Go live

Any Ubuntu 22.04+ box → HTTPS + CLI login. Point a DNS A record at the box, then run `deploy.sh` (installs Barkpark + Caddy/TLS, prints your admin token):

```bash
scp deploy.sh root@SERVER_IP:/root/
ssh root@SERVER_IP "DOMAIN=app.example.com BARKPARK_SEED_PROFILE=clean bash /root/deploy.sh"
```

`DOMAIN` = public hostname, never an IP. Full walkthrough + ops: [`GO-LIVE.md`](docs/setup/GO-LIVE.md).

## How it works

- **Built for agents.** `bp capabilities -o json` teaches the whole API in one call; JSON defaults when piped; atomic batch writes via `-f`; stable exit codes.
- **One schema, many surfaces.** A single SchemaDefinition drives the Studio panes, the TUI desk, the REST contract, and the CLI.
- **Manifest-driven contract.** The server projects nouns, verbs, and routes into `GET /v1/capabilities`; every client reads the same projection — default-deny, existence-hiding, keyed on the caller's auth tier.
- **The plugin highway.** Plugins are first-party Elixir modules on the `Barkpark.Plugin` behaviour — schemas, routes, workers, cron, CLI verbs travel module → manifest → `bp` shell with no client code. **With all plugins off, Barkpark still works** — the fresh-install invariant is the test of correctness.

Stack: Elixir / Phoenix LiveView · PostgreSQL · Oban · Go (CLI + TUI, one binary) · Caddy. Bundled plugins: **Tasks · Bulldocs · Media · OnixEdit** (ONIX 3.0 + Bokbasen) **· Sheets · Frt**. 3300+ mix tests, 89 HTTP integration tests.

## Codebase grade — B+ · 81 / 100

Barkpark grades *itself* — **Cody**, its 13-critic Codebase-Intelligence suite ([`tooling/`](tooling/README.md)), recomputes these live:

| Critic | | Critic | | Critic | |
|---|--:|---|--:|---|--:|
| Architecture | 85 | Consistency | 78 | Tested | 87 |
| Duplication | 100 | Reliability | 65 | **Hotspots** | **64** |
| Dead-code | 100 | Evaluated | 100 | Modularity | 66 |
| Contract | 100 | Dependencies | 94 | **Bloat** | **78** |
| **Aesthetics** | **84** | | | | |

Honest: Architecture counts 5 real layering violations (not 100); the grade keys maintainability, not runtime, and pairs an *agent critique* → [`GRADE-CRITIQUE.md`](tooling/quality/GRADE-CRITIQUE.md). Lowest: Hotspots 64, Reliability 65, Modularity 66.

## Documentation

| Doc | What |
|---|---|
| [`INDEX.md`](docs/INDEX.md) | Catalog of every card, contract, and runbook |
| [`GO-LIVE.md`](docs/setup/GO-LIVE.md) · [`TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) | Deploy a public instance · the task system |
| [`tooling/`](tooling/README.md) · [`cody/`](tooling/cody/README.md) | Codebase Intelligence · Cody + `barkpark.json` |
| [`HANDBOOK.md`](docs/cli/HANDBOOK.md) · [`cheatsheets/`](docs/cheatsheets/) | Full `bp` manual · one-pagers |
| [`api-v1.md`](docs/api-v1.md) · [`auth.md`](docs/auth.md) | HTTP contract · tokens and tiers |
| [`plugins.md`](docs/cards/plugins.md) | Build a plugin (contract: `api/lib/barkpark/plugin.ex`) |

## License

MIT
