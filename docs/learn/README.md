<!-- doc-tier: human | canonical-for: learn-and-own | budget: 1400tok -->
# Learn Barkpark — and own it

Barkpark is a headless CMS with **one content model** and many surfaces: a Go TUI + `bp`
CLI, a Phoenix HTTP API + LiveView Studio, a JS SDK, and a Next.js web demo. This is the
adoption track — start here, learn the model, then self-host and own it. When you want
reference, the routing table in the repo `CLAUDE.md` points you at the right card.

## Start here

Install the CLI first — full walkthrough in
[../setup/QUICKSTART.md](../setup/QUICKSTART.md):

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp version
```

Then pick the route that matches what you already have. **`--target local` is
destructive: it runs `mix ecto.reset`, which drops and recreates the dev
database.** Use it only on a machine whose dev DB you are willing to lose, and
stop any running dev server first — a live server holds DB connections and
blocks the reset with `object_in_use`.

```bash
bp setup --target local --yes   # DESTRUCTIVE (wipes the dev DB), then serves on :4000
bp                              # launches the TUI
```

**Already have a Barkpark** — your own server, a teammate's, or a hosted one?
`connect` is the non-destructive path: it writes `bp` config only and touches no
database.

```bash
bp setup --target connect --server https://api.example.com --token $TOKEN
bp whoami                       # active server + auth tier
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
- Every document has three **perspectives**: **published** (what readers and the SDK
  fetch), **drafts** (what you edit — Studio, TUI, and `bp tinker` default), and **raw**
  (everything, unfiltered). Publishing copies the draft → published; the draft remains
  until discarded.

The full model — slugs, memberships, scoping rules — lives in
[../contracts/tenancy.md](../contracts/tenancy.md). The task substrate (a goal is a root
task, a phase is a task with children) is built the same way: tasks are just documents.

## A local dev loop

Scaffold a type, fill it with sample data, and poke at it — no Studio needed:

```bash
bp make schema product --out product.json    # scaffold a schema v2 skeleton
$EDITOR product.json                          # fill the blanks, strip the _comment keys
bp schema apply --file product.json           # register the type
bp seed product --count 5 --publish           # fabricate + publish 5 sample documents
bp doc create product --set title=Anvil       # or write one yourself
bp doc query product --limit 5                # read it back through the API
bp tinker                                     # REPL: `query product`, `doc product <id>`
```

`bp make schema` writes a commented skeleton covering every field type, so authoring is
fill-the-blanks instead of reading the contract. **Edit it before you apply it** — the
skeleton emits 15 `_comment` guidance keys and literal placeholders such as
`"codelistId": "<plugin>:<name>"`, and its own first line tells you to strip the comments
before POSTing. `bp seed` generates schema-valid values per field; `--publish` makes them
visible to the published API your app reads (drop it to keep them as drafts).

`bp doc query` is the same read your application will do — `--perspective drafts` shows
unpublished work, and the default published view is what an anonymous reader gets.
`bp tinker` opens an authenticated REPL that defaults to the `drafts` perspective, so
even unpublished drafts show immediately; switch with `perspective published` to see the
public view.

## Self-host and own Barkpark

Barkpark is yours. Self-hosting is first-class — the *same* Barkpark, no features held
back. The stance is spelled out in [../PHILOSOPHY.md](../PHILOSOPHY.md). The path:

| `bp setup --target …` | What it does |
|---|---|
| `connect` | point bp at an existing server (non-destructive) |
| `local` | bring up a dev server on this machine |
| `deploy` | install on a server you own, over SSH |
| `provision` | create a cloud host (Hetzner / Azure), then deploy |

Run it locally, build something, then `bp setup --target deploy` (or `bp go-live` for the
managed path) to take it to a server you own. Your content, schema, server, and source
code stay yours.

## Next: pick the right tool for the job

Each job has one blessed first-party plugin. See the
[plugin catalog](./plugins-catalog.md).
