<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

[![Deploy with Barkpark](https://barkpark.cloud/button.svg)](https://barkpark.cloud/new?template=blog-starter)

[Live Studio](https://api.barkpark.cloud/studio) · [Install](#install--connect) · [Deploy](#be-your-own-cloud) · [Barkpark Cloud](https://barkpark.cloud) · [Docs](docs/INDEX.md)

Barkpark manages tasks, Papers, spreadsheets, and media through one content model.
An AI agent can work through the API while you edit the same documents in Studio
or a terminal.

Barkpark is open source software you can run on a laptop, a VPS, or a server at home.
You own your content, schema, server, and source code, and you should never have to
rely on us. [Barkpark Cloud](https://barkpark.cloud) provides one login across your
instances and helps fund continued work on Barkpark. [Read our principles](docs/PHILOSOPHY.md).

## What this makes possible

- Run Barkpark locally with the same Studio and API, including when you are offline.
  Move content between servers with `bp migrate`, or connect your local instance
  through Cloud's auth tunnel.
- Create and edit spreadsheets with formulas in a live grid. Share them by link
  on your local network or over the internet.
- Read the same Paper blocks on the web, in the terminal, in the editor, and in email.
- Define a content type for a project and work with it through Studio, the terminal,
  the CLI, or the API.
- Export a dataset to a file with `bp export`. Archive an instance and restore it
  on another cloud provider.

## Install & connect

On macOS or Linux, install the CLI and choose whether to run locally, deploy a
server, or connect to an existing instance. You can also use the live
[Studio](https://api.barkpark.cloud/studio) without installing the CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup          # choose local, deploy, or connect
```

To install on a server over SSH, use `bp setup --target deploy`.

Windows: `irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex`, then `.\scripts\setup-windows.ps1`.

[Quickstart](docs/setup/QUICKSTART.md) · [Cursor](docs/setup/CURSOR.md) · [Learn Barkpark](docs/learn/README.md) · [From source](docs/setup/SETUP.md)

## Your first schema

A schema defines the fields in a content type. Studio, the terminal UI, the REST
API, and the CLI use that definition:

```bash
bp make schema recipe --out recipe.json   # create a schema to edit
bp schema apply --file recipe.json        # apply the schema
bp seed recipe --count 5 --publish        # publish sample data
bp tinker                                 # open the interactive shell
```

Use `bp doctor` to check your setup. See the [handbook](docs/cli/HANDBOOK.md)
for more commands and examples.

## Working with agents

Agents discover the available commands and routes through `bp capabilities -o json`.
Tasks, claims, and evidence are stored in Barkpark, so work can be shared across
agents and sessions. Claim operations are atomic, and closing a task requires its
claim epoch.

These are separate command examples. Use the task ID, worker, and epoch from your
own claim:

```bash
bp task next agent-1                      # claim the next ready task
bp task claim t1 a1 --resources lib/x.ex  # declare the files you plan to edit
bp task close t1 agent-1 1                # close using the claim's worker and epoch
```

An agent can read the task record after reconnecting. If its claim has lapsed, it
must claim the task again before continuing. Studio shows task updates as they happen.
`bp onramp` generates setup instructions for agent tools including Claude Code,
Cursor, Codex, Windsurf, and Zed. The built-in MCP server also exposes the task
board to MCP clients.

We use this workflow to build Barkpark: agents find work with `bp task ready`,
publish design Papers, and inspect the codebase through [Cody](tooling/README.md).

## Four ways in

| Surface | What it provides |
|---|---|
| `bp` CLI | Commands derived from the server's `GET /v1/capabilities` response. |
| Web Studio | A LiveView interface at `/studio` for browsing, filtering, editing, and publishing content. |
| Terminal TUI | A keyboard-driven interface, opened by running `bp` with no arguments. |
| REST API | Public reads, token-authenticated writes, Sanity-compatible mutations, and server-sent events. |

## How it works

A `SchemaDefinition` describes each content type. Studio, TUI, REST, and CLI use
that definition. The server lists available commands and routes through
`GET /v1/capabilities`, filtered by the caller's authentication tier.

PortableDoc renderers in Elixir, TypeScript, and Go use shared fixtures to check
that the same content renders consistently across surfaces.

Plugins implement the `Barkpark.Plugin` behaviour and can provide schemas, routes,
workers, scheduled jobs, and CLI commands. Barkpark's core also runs with all
plugins disabled.

Barkpark uses Elixir, Phoenix LiveView, PostgreSQL, Oban, Go, and Caddy. Plugins
include Tasks, Bulldocs, Media, OnixEdit, Sheets, Frt, GitHub, Grip, Pulse, Quiz, Scaffy,
and Tickets. The [code analysis tools](tooling/README.md) check the repository and
produce reports for contributors.

## Why we build it this way

You should be able to run Barkpark, keep your content, and change the software
without depending on us. We commit to open source, user control, and a usable
product. [Read our principles](docs/PHILOSOPHY.md).

## Be your own cloud

To deploy on an Ubuntu 22.04+ server, point a DNS A record at it and run `deploy.sh`.
The script installs Barkpark and Caddy, configures HTTPS, and prints your admin token:

```bash
scp deploy.sh root@SERVER_IP:/root/
ssh root@SERVER_IP "DOMAIN=app.example.com BARKPARK_SEED_PROFILE=clean bash /root/deploy.sh"
```

Set `DOMAIN` to a public hostname, not an IP address. See
[`GO-LIVE.md`](docs/setup/GO-LIVE.md) for the full walkthrough.

[Barkpark Cloud](https://barkpark.cloud) can provision servers, deploy with a
blue/green setup, and archive and restore instances across cloud providers. You
can also run the [control plane](cloud/README.md) yourself.

## Documentation

| Documentation | Covers |
|---|---|
| [`GO-LIVE.md`](docs/setup/GO-LIVE.md) · [`TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) | Deploy a public instance · the task system |
| [`HANDBOOK.md`](docs/cli/HANDBOOK.md) · [`cheatsheets/`](docs/cheatsheets/) | Full `bp` manual · quick references |
| [`api-v1.md`](docs/api-v1.md) · [`auth.md`](docs/auth.md) | HTTP contract · tokens and tiers |
| [`plugins.md`](docs/cards/plugins.md) | Build a plugin |

## License

MIT
