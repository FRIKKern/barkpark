<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

**The workspace your AI works in.** A headless CMS built for AI agents: an AI stores, sorts, and structures content — **tasks, papers, media** — while you edit the same documents in a browser Studio. The agent drives the API; you drive the panes — both in real time.

**Live demo:** https://api.barkpark.cloud/studio

## Codebase grade — B+ · 83 / 100

Barkpark grades *itself* — **Cody**, its 13-critic Codebase-Intelligence suite ([`tooling/`](tooling/README.md)), recomputes these live:

| Critic | | Critic | | Critic | |
|---|--:|---|--:|---|--:|
| Architecture | 85 | Consistency | 78 | Tested | 87 |
| Duplication | 100 | Reliability | 65 | **Hotspots** | **60** |
| Dead-code | 100 | Evaluated | 100 | Modularity | 80 |
| Contract | 100 | Dependencies | 94 | | |
| **Bloat** | **96** | **Aesthetics** | **99** | | |

Weighted **83 / 100 (B+)**. **Bloat** + **Aesthetics** are the *filebase* critics (root clutter, dead docs, artifact noise) — 96 / 99 after the mess they found was cleaned; **Modularity** 66→80 as the 5 biggest god-modules split. Honest: Architecture counts 5 real layering violations (not 100); the grade keys maintainability, not runtime, and pairs an *agent critique* → [`GRADE-CRITIQUE.md`](tooling/quality/GRADE-CRITIQUE.md). Lowest: Hotspots 60, Reliability 65.

## Get started

Install the `bp` CLI, then `bp setup` walks you through connecting to a server — or bringing one up locally:

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup          # local · deploy · connect — pick one, it does the rest
bp task ready     # see what's ready to work
```

Windows: `irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex`, then `.\scripts\setup-windows.ps1` (toolchain + Phoenix).

[Quickstart](docs/setup/QUICKSTART.md) · [Learn & own](docs/learn/README.md) · [Windows](docs/setup/WINDOWS.md) · [from source](docs/setup/SETUP.md)

## Your AI's task board

Task management is the headline use case. Tasks are documents with a lifecycle (`open → in_progress → done`, `blocked`, `cancelled`), dependencies, priorities, labels, and an atomic claim/close contract for concurrent workers (fencing epochs, 300s leases):

```bash
bp task prime --worker a1    # one call: my claims + ready head + events + counts
bp task next agent-1         # atomically claim the next ready task
bp task claim t1 a1 --resources lib/x.ex   # fence files against parallel workers
bp task close t1 agent-1 1   # CAS on the claim epoch
```

Open `/studio` and the same queue is the **Tasks ✅** pane: you set priority/assignee while the agent claims and closes over HTTP (claims and dependencies are read-only — the API owns them). A root task is a goal; subtasks nest via `parent_id`. Guide: [`TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) · [`tasks.md`](docs/cheatsheets/tasks.md).

## Make Barkpark understand your codebase

Point Barkpark at the repo itself and your code becomes browsable, searchable content. **Cody is your Barkpark agent** — it always knows which Barkpark you're pointed at and gets you set up:

```bash
node tooling/cody/cody.mjs preflight   # where am I, and is my codebase fully analyzed?
```

Preflight resolves the host, then verifies your project is scanned. If Barkpark isn't running it tells you exactly how to start one; if the codebase isn't analyzed it points you at the one-command scan:

```bash
node tooling/status/status.mjs --publish   # score every file + publish it into Barkpark
```

**Codebase Intelligence** ([`tooling/`](tooling/README.md)) scores every file across the thirteen quality dimensions above, maps how files relate, and publishes one paper per file into an isolated `codebase` dataset — an interconnected graph you browse in Studio.

Every tool finds your Barkpark through [`barkpark.json`](barkpark.json) — a committed, **secret-free** host map (local + public) with a health probe and automatic local→public fallover, so tools keep working when your local server is down.

## Play around without stacking up mess

One call spins up an isolated **workspace** — owner, a Default project, a production dataset, its own schemas/tasks/papers/media; nothing leaks into your real work:

```bash
bp workspace create Spike
bp -w spike workspace project-create agents-v2
```

## Four ways in

| Surface | What it is |
|---|---|
| **`bp` CLI** | One static binary speaking the whole API — `bp <noun> <verb>`, assembled live from `GET /v1/capabilities`. Same binary as the TUI. |
| **Web Studio** | Multi-pane LiveView desk at `/studio` — drill, filter, edit-with-autosave, publish. Real-time across tabs. |
| **Terminal TUI** | The same desk, keyboard-driven (`barkpark` with no args). |
| **REST API** | Public reads, token-authed writes, Sanity-compatible mutations, SSE change stream. |

Stack: Elixir / Phoenix LiveView · PostgreSQL · Oban · Go (CLI + TUI, one binary) · Caddy. 3300+ mix tests, 89 HTTP integration tests.

## Design philosophy

- **Built for agents.** `bp capabilities -o json` teaches the whole API in one call; JSON defaults when piped; atomic batch writes via `-f`; `-q` receipts; stable exit codes.
- **One schema, multiple surfaces.** A single SchemaDefinition drives the Studio panes, the TUI desk, the REST contract, and the CLI surface.
- **Manifest-driven contract.** The server projects nouns, verbs, and routes into `GET /v1/capabilities`; every client reads the same projection. Default-deny, existence-hiding, keyed on the caller's auth tier.
- **The plugin highway.** Plugins are first-party Elixir modules on the `Barkpark.Plugin` behaviour — schemas, routes, workers, cron, CLI verbs travel from module to manifest to `bp` shell with no client code at any hop. **With all plugins off, Barkpark still works** — the fresh-install invariant is the test of correctness.

Bundled plugins: **Tasks** (the board above) · **Bulldocs** (papers at `/papers/:slug`) · **Media** (asset library) · **OnixEdit** (ONIX 3.0 + Bokbasen) · **Frt** (Godot content).

## Deploy

One command on any Ubuntu 22.04+ box. `deploy.sh` **requires** `DOMAIN` — the public DNS hostname, never an IP (pins `check_origin`):

```bash
DOMAIN=api.barkpark.cloud ssh root@YOUR_VPS_IP "DOMAIN=$DOMAIN bash -s" < deploy.sh
```

Or `bp setup --target deploy`. Updates: `ssh` in, `cd /opt/barkpark && git pull` (hook rebuilds + restarts). Ops: [`docs/ops/PROD_OPS.md`](docs/ops/PROD_OPS.md).

## Documentation

| Doc | What |
|---|---|
| [`INDEX.md`](docs/INDEX.md) | Catalog of every card, contract, and runbook |
| [`TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) | The task system — agent loop, Studio collaboration, goals |
| [`tooling/`](tooling/README.md) · [`cody/`](tooling/cody/README.md) | Codebase Intelligence suite · Cody (code↔paper) + `barkpark.json` |
| [`HANDBOOK.md`](docs/cli/HANDBOOK.md) | Full `bp` CLI manual |
| [`cheatsheets/`](docs/cheatsheets/) | One-pagers: `bp`, TUI keys, tasks, HTTP API, papers |
| [`api-v1.md`](docs/api-v1.md) · [`auth.md`](docs/auth.md) | HTTP contract · tokens and tiers |
| [`plugins.md`](docs/cards/plugins.md) | Build a plugin (contract: `api/lib/barkpark/plugin.ex` moduledoc) |

## License

MIT
