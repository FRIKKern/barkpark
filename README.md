<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

[![Deploy with Barkpark](https://barkpark.cloud/button.svg)](https://barkpark.cloud/new?template=blog-starter)

**[Live Studio →](https://api.barkpark.cloud/studio)** · **[Install](#install--connect)** · **[Deploy](#be-your-own-cloud)** · **[Barkpark Cloud](https://barkpark.cloud)** · **[Docs](docs/INDEX.md)**

**A lightweight operating system for everything you and your AI make.** One content model —
tasks, papers, sheets, media, anything you can schema — with an AI agent driving the API while
you edit the same documents live in Studio or a terminal.

**Barkpark is yours** — open source you run anywhere: a laptop, a VPS, a box at home. You own
your content, schema, server and source code; you should never have to rely on us. Or use
**[Barkpark Cloud](https://barkpark.cloud)** — the official home: one login across your whole
fleet, and a way to cheer the work on. [The full stance →](docs/PHILOSOPHY.md)

**2.81M lines · 9,366 files · 16,900+ tests · 561 routes · 11 plugins · four runtimes.**

## What this makes possible

- **The internet goes out; your work doesn't.** A full Barkpark runs on your laptop — same
  Studio, same API. Move content between servers with `bp migrate`; Cloud's auth tunnel
  reaches your local box too.
- **An AI builds a spreadsheet; you're both inside it a minute later.** Real formulas, a live
  grid — sharing is a link, on your LAN or across the world.
- **A paper written once reads everywhere.** The same blocks render on the web, in the
  terminal, in the editor, even in email.
- **A whole CMS for a side project, in minutes.** Schema one type and every surface exists —
  a D&D campaign got its own Barkpark while the idea was still warm.
- **Hand someone the whole thing.** `bp export` streams a dataset to a file; instances archive
  and resurrect on a different cloud. Leaving is a feature — which is why staying is safe.

## Install & connect

Two commands on macOS / Linux (the live [Studio](https://api.barkpark.cloud/studio) needs none):

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup          # local · deploy · connect — pick one, it does the rest
```

Own a server? `bp setup --target deploy` installs over SSH.

Windows: `irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex`, then `.\scripts\setup-windows.ps1`.

[Quickstart](docs/setup/QUICKSTART.md) · [Cursor](docs/setup/CURSOR.md) · [Learn & own](docs/learn/README.md) · [From source](docs/setup/SETUP.md)

## Your first schema

Describe the shape of your content once, and every surface — Studio pane, TUI desk, REST
routes, CLI verbs — appears around it:

```bash
bp make schema recipe --out recipe.json   # skeleton — fill the blanks
bp schema apply --file recipe.json        # the type now exists everywhere
bp seed recipe --count 5 --publish        # schema-valid sample data, live
bp tinker                                 # REPL: query it, poke it
```

When you're ready to go further: `bp doctor` checks your setup, and the
[handbook](docs/cli/HANDBOOK.md) walks the rest.

## Working with agents

Barkpark treats an agent as a collaborator with a desk of its own. `bp capabilities -o json`
describes every noun, verb and route in one call, so any harness can learn the system without
docs pasted into context. Work lives on a shared task board with an atomic claim/close
contract, so several agents (and you) can move at once without collisions:

```bash
bp task next agent-1                      # atomically claim the next ready task
bp task claim t1 a1 --resources lib/x.ex  # fence files against parallel workers
bp task close t1 agent-1 1                # CAS on the claim epoch
```

Because the board lives in Barkpark rather than in a session, an agent that disconnects or
crashes picks its work back up, context intact — and everything it does lands visibly in
Studio, in real time. `bp onramp` emits ready-to-paste setup for nine harnesses (Claude Code,
Cursor, Codex, Windsurf, Zed and more), and a built-in MCP server exposes the task board to
any MCP client.

This repository is built this way: agents claim work from `bp task ready`, publish design
papers, and score the codebase into a browsable graph ([Cody](tooling/README.md)).

## Four ways in

| Surface | What it is |
|---|---|
| **`bp` CLI** | One static binary speaking the whole API, assembled live from `GET /v1/capabilities`. |
| **Web Studio** | Multi-pane LiveView desk at `/studio` — drill, filter, autosave, publish, real-time. |
| **Terminal TUI** | The same desk, keyboard-driven (`bp` with no args). |
| **REST API** | Public reads, token-authed writes, Sanity-compatible mutations, SSE stream. |

## How it works

- **One schema, many surfaces.** A single SchemaDefinition drives Studio, TUI, REST, and CLI.
- **Manifest-driven contract.** The server projects nouns, verbs, and routes into
  `GET /v1/capabilities`; every client reads the same projection — default-deny,
  existence-hiding, keyed on auth tier.
- **Proven parity, not promised.** One document renders in Elixir, TypeScript and Go; 62 frozen
  fixtures fail the build if they disagree.
- **The plugin highway.** Plugins ride the `Barkpark.Plugin` behaviour — schemas, routes,
  workers, cron, CLI verbs travel module → manifest → `bp` shell.
  **With all plugins off, Barkpark still works** — an AST gate proves it.

Stack: Elixir / Phoenix LiveView · PostgreSQL · Oban · Go (CLI + TUI, one binary) · Caddy.
Plugins: **Tasks · Bulldocs · Media · OnixEdit · Sheets · Frt · GitHub · Pulse · Quiz · Scaffy ·
Tickets**. It grades itself — [`tooling/`](tooling/README.md) recomputes 14 critics live.

## Why we build it this way

We know the temptation from the inside: the moment greed enters a design, dark patterns
follow — so we took the choice away from ourselves. Open source dismantles the machinery that
makes a "no" profitable. We are locked behind a purpose — greatness, and making software
yours — and we will not hold back on user experience or freedom.
[Conditioned for greatness →](docs/PHILOSOPHY.md)

## Be your own cloud

Any Ubuntu 22.04+ box → HTTPS + CLI login. Point a DNS A record at the box, run `deploy.sh`
(installs Barkpark + Caddy/TLS, prints your admin token):

```bash
scp deploy.sh root@SERVER_IP:/root/
ssh root@SERVER_IP "DOMAIN=app.example.com BARKPARK_SEED_PROFILE=clean bash /root/deploy.sh"
```

`DOMAIN` = public hostname, never an IP. Walkthrough: [`GO-LIVE.md`](docs/setup/GO-LIVE.md).
Prefer it handled? **[Barkpark Cloud](https://barkpark.cloud)** provisions on two clouds, deploys
blue/green, and can archive an instance and resurrect it on the *other* cloud. Or run the
control plane ([`cloud/`](cloud/README.md)) yourself.

## Documentation

| Doc | What |
|---|---|
| [`GO-LIVE.md`](docs/setup/GO-LIVE.md) · [`TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) | Deploy a public instance · the task system |
| [`HANDBOOK.md`](docs/cli/HANDBOOK.md) · [`cheatsheets/`](docs/cheatsheets/) | Full `bp` manual · one-pagers |
| [`api-v1.md`](docs/api-v1.md) · [`auth.md`](docs/auth.md) | HTTP contract · tokens and tiers |
| [`plugins.md`](docs/cards/plugins.md) | Build a plugin |

## License

MIT
