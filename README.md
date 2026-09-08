<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

Barkpark is an open-source content management system for developers working with
AI agents. You define your content types, and people and agents work on the same
data through a browser, terminal, or API. Run it on your own laptop or server.

For example, an agent can add recipes through the API while you edit them in
Studio, Barkpark's web interface. The same records are available in the terminal;
you do not maintain a separate copy for each interface.

[Try Studio](https://api.barkpark.cloud/studio) · [Install](#install--connect) · [Create a recipe](#your-first-schema) · [Host a server](#be-your-own-cloud) · [Docs](docs/INDEX.md)

## Four ways in

| Interface | Use it to |
|---|---|
| Studio | Browse, edit, and publish content in your browser. |
| Terminal UI | Work with content from your keyboard; open it by running `bp`. |
| `bp` CLI | Read and change content from scripts or an agent's tools. |
| REST API | Connect your own applications and integrations. |

## What this makes possible

- Define content types for a website, catalog, or project. Their fields become
  available in Studio, the terminal UI, and the API.
- Keep tasks and their evidence on a shared board so agents can hand work between
  sessions. Claims record who is working on each task.
- Write documents called Papers using blocks that render in the browser, terminal,
  editor, and email. Spreadsheets provide formulas and an editable grid.
- Work against a local server when offline. Export datasets with `bp export` or
  move content between servers with `bp migrate`.

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
record. Run `bp` to browse it in the terminal. Both interfaces work with the
recipe you just created. The example uses a fixed ID; choose another ID to create
another recipe.

The [CLI handbook](docs/cli/HANDBOOK.md) covers updates, queries, and publishing.

## Working with agents

Give your agent access to the same instance. `bp capabilities -o json` describes
the commands available to its credentials. To generate Codex setup instructions:

```bash
bp onramp codex
```

[Agent onramps](docs/setup/AGENT-ONRAMPS.md) also cover Claude Code, Cursor, and
other tools, including MCP clients. The [task guide](docs/setup/TASK-SYSTEM.md)
shows a complete workflow for claiming work, recording evidence, and closing a
task with the current claim epoch. Task records remain available after a session
ends; the agent must renew or reclaim its lease as the guide describes.

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

You should be able to keep your content, run your own server, and change the
software without depending on us. Barkpark is MIT licensed. Using Barkpark Cloud
helps fund continued development; self-hosting remains an option.
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
