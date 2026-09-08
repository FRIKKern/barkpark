<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

Barkpark is an open-source platform you can shape around your work. Use one
instance for a single job, or combine applications into a larger system. They
share a core for data, authentication, permissions, and APIs.

You control the server, the data, and the code. Run it on your laptop or a remote
server, and work through a browser, terminal, command line, or AI agent.

[Try the browser app](https://api.barkpark.cloud/studio) · [Set up Barkpark](docs/setup/QUICKSTART.md) · [Documentation](docs/INDEX.md)

## One purpose or a larger system

You can use Barkpark as:

- A media library for organizing images and files.
- A task manager for planning work and keeping track of who is doing it.
- A CMS for defining and editing the content behind a website or catalog.
- A place to write and share documents, called **Papers**.
- A place to work with spreadsheets, called **Sheets**, with cells and formulas.

You can also build email workflows with an agent and a mail service you configure.
These are uses of the platform; you can add your own applications through plugins
and the API.

One installation might only manage photos. Another might hold a publication's
catalog, media, assignments, documents, and budgets. You choose what belongs
together and what deserves its own instance.

The core supplies the common parts. Each application can reuse the data model,
storage, authentication, and access controls. Sharing controls let you choose
who can read or change content and what you make public. The aim is to keep the
system understandable as the work gets more complicated.

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

Inspect document revisions and task evidence to follow an agent's work across
sessions. Revoke its workspace token when it should no longer have access.
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
