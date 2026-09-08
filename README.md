<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

Barkpark is an open-source platform for building tools that work together. You
control the server, the data, and the code. Run it on your laptop or a remote
server, and work through a browser, terminal, command line, or AI agent.

It comes with tools for documents, spreadsheets, structured data, and shared
tasks. They use a common core for storage, schemas, permissions, and APIs. You can
build your own applications on that foundation, with fewer separate services to
choose and connect.

[Try the browser app](https://api.barkpark.cloud/studio) · [Set up Barkpark](docs/setup/QUICKSTART.md) · [Documentation](docs/INDEX.md)

## Start with familiar tools

Write a project update with text, tables, and images, then share it for coworkers
to read in a browser or terminal. Barkpark calls these documents **Papers**. You
can host them on a local network or a remote server.

Work on a budget in a spreadsheet with cells, formulas, and tabs. These are
**Sheets**. A Sheet lives in Barkpark and can be embedded in a Paper. Save changes
to the budget, and the figures embedded in your project update refresh. You can
share the report without exporting another XLSX file.

An agent can update that spreadsheet through the API while you review it in the
browser. The document and its data stay connected. This is the reason for the
shared core: each tool can become part of another workflow.

You can also define your own data types, such as products in a catalog or recipes
for a website, and edit their records visually or through an agent. This is
Barkpark's content management side. The [recipe example below](#create-your-first-record)
shows how a new data type becomes usable.

## Choose how you work

| Use | For |
|---|---|
| Studio, the browser app | Editing and publishing content visually. |
| The terminal interface (`bp`) | Browsing content in an interactive terminal app. |
| The `bp` command line | Running individual commands and scripts. |
| An AI agent | Using its tools to read and change content. |

The goal is full control from whichever interface you prefer. An agent should be
able to operate the whole system, including setup and access management. People
should be able to read the data, understand changes, and take over.

Today, you can inspect document revisions and revoke workspace tokens. A shared
task board records claims and evidence so you can follow work across agent
sessions. These controls help you see what happened behind a finished page.
See [agent setup](docs/setup/AGENT-ONRAMPS.md), the [task workflow](docs/setup/TASK-SYSTEM.md),
and [access control](docs/auth.md).

## Run Barkpark

The [live Studio](https://api.barkpark.cloud/studio) lets you look around without
installing anything. To connect to an instance or run your own, install the `bp`
command line tool. On macOS or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup
```

The wizard can connect to a server, create a local instance, or deploy over SSH.
Native local setup requires Git, Elixir, and PostgreSQL. For Docker, run
`bp setup --target local --docker` with a running Docker engine. Local setup
resets the development database; use a fresh instance for this walkthrough.

The [Quickstart](docs/setup/QUICKSTART.md) covers prerequisites and setup routes.
Use the [Windows guide](docs/setup/WINDOWS.md) for Windows installation, or the
[deployment guide](docs/setup/GO-LIVE.md) to host a public server.

Run `bp whoami` to check the active server and access level, and `bp doctor` to
check your setup. A local instance normally opens Studio at
`http://localhost:4000/studio`.

## Create your first record

This example defines a recipe, creates one, and reads it back. Use a fresh
instance or test project with an admin token, since creating a schema requires
admin access. Commands use your active workspace, project, and dataset.

A schema names the fields your records can contain. Save this as `recipe.json`:

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

Apply the schema, create a draft, and publish it. This example is public content;
use the sample values below.

```bash
bp schema apply --file recipe.json --yes
bp doc create recipe --set _id=recipe-pancakes --set title=Pancakes --set minutes:=15 --yes
bp doc publish recipe recipe-pancakes --yes
bp doc get recipe recipe-pancakes -o json
```

The response includes:

```json
{
  "_id": "recipe-pancakes",
  "_type": "recipe",
  "title": "Pancakes",
  "minutes": 15
}
```

Open Recipe in Studio, in the same project and dataset, or run `bp` to browse it
in the terminal. You are working with the record you just created. Choose another
ID to create another recipe. The [CLI handbook](docs/cli/HANDBOOK.md) covers
queries, updates, and publishing.

## Why I build it

I build Barkpark from problems I run into at work. Papers started because I was
tired of copying AI progress into messages for coworkers. Sheets came from
repeatedly exporting spreadsheets when we could work with live data instead.
Each tool should make the next idea easier to build.

Vendors can save you time and effort. They also bring limits on what you can
change and how products connect. Barkpark aims to make more of those choices
yours: use a service where it helps, run things yourself where that fits, and
keep the ability to inspect and change the software.

You can work with data on a local instance without internet access and explicitly
move content between servers. Keeping local and remote instances automatically
synchronized through outages is a goal; current transfer tools do not provide
that guarantee.

Barkpark is [MIT licensed](LICENSE). [Barkpark Cloud](https://barkpark.cloud) can
operate instances for you and helps fund development. Its
[control plane](cloud/README.md) is also open source. Content features belong in
the open core, and self-hosting must remain a complete option.
[Read the principles](docs/PHILOSOPHY.md) or [build a plugin](docs/cards/plugins.md).
