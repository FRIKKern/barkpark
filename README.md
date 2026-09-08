<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

Barkpark is an open-source platform for building connected applications on
infrastructure you own. Run and modify the server and control your data. Build on
shared schemas, storage, permissions, and APIs. Work with the same data through a
browser, terminal, CLI, or AI agent.

Vendors save work, but their limits shape what you can build. Barkpark's goal is
fewer separate services and more freedom to change and combine your tools. Run
it on your laptop or server, or pay someone to operate it for you.

[Try Studio](https://api.barkpark.cloud/studio) · [Install](#install--connect) · [Create a recipe](#your-first-schema) · [Host a server](#be-your-own-cloud) · [Docs](docs/INDEX.md)

## Four ways in

| Interface | Use it to |
|---|---|
| Studio | Browse, edit, and publish content in your browser. |
| Terminal UI | Work with content from your keyboard; open it by running `bp`. |
| `bp` CLI | Read and change content from scripts or an agent's tools. |
| REST API | Connect your own applications and integrations. |

## What this makes possible

- Use Barkpark as a CMS: define content types, then edit records visually in
  Studio or through an agent using the API.
- Share Papers, Barkpark's documents, through a browser or terminal on a local
  network or a remote server. Papers also render for email.
- Keep a spreadsheet in Sheets and embed it in a Paper. Updates to the sheet
  refresh the embedded data, so you can share the document without another XLSX
  export.
- Share tasks and their evidence across agent sessions. Claims record who is
  working on each task.
- Work with the data on your local server when offline. Export datasets with
  `bp export` or move content between servers with `bp migrate`.

## Install & connect

You can open the [live Studio](https://api.barkpark.cloud/studio) without installing
anything. To use the CLI or run your own instance, install `bp`.

On macOS or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup
```

The setup wizard can connect to an existing instance, run a local server, or deploy
one over SSH. For a native local server, you need Git, Elixir, and PostgreSQL; the
Docker route is `bp setup --target local --docker` and needs a running Docker
engine. The [Quickstart](docs/setup/QUICKSTART.md) covers prerequisites and each setup route.
Local setup resets the development database, so use a fresh instance for the
example below.

On Windows, install the CLI in PowerShell:

```powershell
irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
```

Then use `bp setup` to connect to an instance. To run a native Windows server,
follow the [Windows guide](docs/setup/WINDOWS.md), which includes cloning the
repository before running its setup script.

Use `bp whoami` to check your active server and access level. Use `bp doctor`
to check your setup. For a local server on the default port, Studio is at
`http://localhost:4000/studio`.

## Your first schema

This example creates a recipe and reads it back. Use a fresh instance or test
project with an admin token: creating a schema requires admin access. Commands
use your active workspace, project, and dataset.

Save this complete schema as `recipe.json`:

```json
{
  "name": "recipe",
  "title": "Recipe",
  "visibility": "public",
  "fields": [
    { "name": "title", "type": "string", "validation": { "required": true } },
    { "name": "minutes", "type": "number" }
  ]
}
```

Apply it, create a draft, then publish it. This example is public content; use
the sample values below.

```bash
bp schema apply --file recipe.json --yes
bp doc create recipe --set _id=recipe-pancakes --set title=Pancakes --set minutes:=15 --yes
bp doc publish recipe recipe-pancakes --yes
bp doc get recipe recipe-pancakes -o json
```

The JSON response includes these fields:

```json
{
  "_id": "recipe-pancakes",
  "_type": "recipe",
  "title": "Pancakes",
  "minutes": 15
}
```

Open the Recipe type in Studio, in the same project and dataset, to edit the
record, or run `bp` to browse it in the terminal. Choose another ID to create
another recipe.

The [CLI handbook](docs/cli/HANDBOOK.md) covers updates, queries, and publishing.

## Working with agents

The goal is full control through CLI, TUI, GUI, or AI, including setup and access
management. An agent should be able to do the work end to end. People should be
able to read the data, inspect changes, and take over at any point.

`bp capabilities -o json` lists commands available to the caller. Generate Codex
setup instructions with:

```bash
bp onramp codex
```

[Agent onramps](docs/setup/AGENT-ONRAMPS.md) cover other tools and MCP clients.
The [task guide](docs/setup/TASK-SYSTEM.md) covers claims, evidence, and closing
work with the current claim epoch. These records make an agent's work inspectable
across sessions. Agents must renew or reclaim their leases.

## Be your own cloud

For an Ubuntu 22.04+ server you can reach over SSH, point a DNS A record at the
server, then run the installed CLI:

```bash
bp setup --target deploy --ssh-host root@SERVER_IP --domain app.example.com
```

Replace `SERVER_IP` and `app.example.com` with your server address and public
hostname. The [deployment guide](docs/setup/GO-LIVE.md) covers the full setup.

[Barkpark Cloud](https://barkpark.cloud) can provision and deploy instances for
you, provide one login across them, and archive and restore instances across
cloud providers. You can also run the [control plane](cloud/README.md) yourself.

[![Deploy with Barkpark](https://barkpark.cloud/button.svg)](https://barkpark.cloud/new?template=blog-starter)

## Why we build it this way

I build Barkpark from everyday problems. Papers began because I was tired of
copying AI progress into messages for coworkers; I wanted to share it over the
local network. Sheets grew from repeatedly exporting XLSX files when we could
work with live data instead.

Each tool should make the next one easier to build. The aim is to spend more time
on an idea and less on choosing vendors and connecting them. You can run,
inspect, and change the software yourself. Barkpark is MIT licensed; using
Barkpark Cloud helps fund it.

Automatic local/remote synchronization remains a goal. Today you can work locally
and transfer content explicitly.
[Read our principles](docs/PHILOSOPHY.md).

## How it works

Schemas describe content types. The server exposes commands through
`GET /v1/capabilities`; clients discover what the caller is allowed to use.
Plugins add schemas, routes, jobs, and commands, and the core runs with all
plugins disabled.

The stack includes Elixir, Phoenix LiveView, PostgreSQL, Oban, Go, and Caddy.
See the [plugin catalog](docs/learn/plugins-catalog.md) and
[code analysis tools](tooling/README.md) for contributor details.

## Documentation

| Guide | Covers |
|---|---|
| [Quickstart](docs/setup/QUICKSTART.md) · [From source](docs/setup/SETUP.md) | Installation and setup |
| [Learn Barkpark](docs/learn/README.md) · [Cheatsheets](docs/cheatsheets/) | Concepts and common commands |
| [HTTP API](docs/api-v1.md) · [Authentication](docs/auth.md) | Integrations and access control |
| [Build a plugin](docs/cards/plugins.md) | Extending Barkpark |

## License

MIT
