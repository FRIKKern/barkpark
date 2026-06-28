<!-- doc-tier: human | canonical-for: learn-and-own | budget: 1400tok -->
# Learn Barkpark — and own it

Barkpark is a headless CMS with **one content model** and many surfaces: a Go TUI + `bp`
CLI, a Phoenix HTTP API + LiveView Studio, a JS SDK, and a Next.js web demo. This is the
adoption track — start here, learn the model, then self-host and own it. When you want
reference, the routing table in the repo `CLAUDE.md` points you at the right card.

## Start here

Four lines from nothing to a running Barkpark — full walkthrough in
[../setup/QUICKSTART.md](../setup/QUICKSTART.md):

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp version
bp setup --target local --yes   # brings up a dev server on this machine
bp                              # launches the TUI
```

## The content model in plain words

Everything you store is a **document**. Documents are shaped by a **schema** and live
inside a tenancy hierarchy:

```
Workspace ──< Project ──< Dataset ──< Documents (typed by a Schema)
```

- **Workspace** is the hard tenant boundary; **Project** sits under one workspace;
  **Dataset** sits under one project (e.g. `production`, `staging`).
- A **schema** names a document `type` (`post`, `page`, `paper`, `sheet`, `book`, …) and
  its fields. The eight legacy seed schemas use simple v1 fields; plugin schemas can add
  richer v2 types (composites, arrays, codelists, localized text).
- Every document has two **perspectives**: a **draft** you edit and a **published**
  version readers and the SDK fetch. Publishing copies draft → published.

The full model — slugs, memberships, scoping rules — lives in
[../contracts/tenancy.md](../contracts/tenancy.md). The task substrate (a goal is a root
task, a phase is a task with children) is built the same way: tasks are just documents.

## A local dev loop

Scaffold a type, fill it with sample data, and poke at it — no Studio needed:

```bash
bp make schema product --out product.json   # scaffold a schema v2 skeleton — fill the blanks
bp schema apply --file product.json          # register the type
bp seed product --count 5                     # fabricate 5 sample documents (as drafts)
bp tinker                                     # REPL: `query product` lists them, `doc product <id>` shows one
```

`bp make schema` writes a commented skeleton covering every field type, so authoring is
fill-the-blanks instead of reading the contract. `bp seed` generates schema-valid values
per field. `bp tinker` opens an authenticated REPL that defaults to the `drafts`
perspective — so the docs you just seeded are visible immediately. Switch with
`perspective published` once you publish them.

## Self-host and own Barkpark

Barkpark is yours. Self-hosting is first-class — the *same* Barkpark, no features held
back. The stance is spelled out in [../PHILOSOPHY.md](../PHILOSOPHY.md). The path:

| `bp setup --target …` | What it does |
|---|---|
| `connect` | point bp at an existing server (non-destructive) |
| `local` | bring up a dev server on this machine |
| `deploy` | install on a server you own, over SSH |
| `provision` | create a cloud host (Hetzner / Azure), then deploy |

Run it locally, build something, then `bp deploy` (or `bp go-live` for the managed path)
to take it to a server you own. Your content, schema, server, and source code stay yours.

## Next: pick the right tool for the job

Each job has one blessed first-party plugin. See the
[plugin catalog](./plugins-catalog.md).
