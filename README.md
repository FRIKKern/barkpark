<!-- doc-tier: human | canonical-for: project-overview | budget: 1750tok -->
# Barkpark

[![Deploy with Barkpark](https://barkpark.cloud/button.svg)](https://barkpark.cloud/new?template=blog-starter)

What the button does, and how to add it to your own template: [Deploy with Barkpark](docs/setup/DEPLOY-WITH-BARKPARK.md).

Barkpark is an open-source CMS you can run on your computer or a server.
Define your own fields, edit content visually, and publish it through an API.
Build a website or just keep a recipe collection. Use only what you need.

Barkpark syncs between a local instance and a remote one. Several people can share one server while each runs Barkpark on their own machine — like running Sanity on your own computer. When the internet is down, everything still works, and you can pass documents to coworkers, family and friends over your local network.

## What you can do

| Use | What you get |
|---|---|
| Manage content | Custom fields, linked records, drafts, revisions, and a visual editor. |
| Write documents | Papers: shareable proposals, reports, and notes that update live. |
| Work with spreadsheets | Sheets: collaborative tables, formulas, and Excel import/export. |
| Organize media | Upload images and files; manage tags, collections, and rights. |
| Track work | Task boards, dependencies, agent work queues, and support tickets. |
| Search content | Full-text search, filters, facets, and click analytics. |
| Work with AI | Chat with agents, give them tasks, and inspect their changes. |
| Publish websites | Templates, deployments, and custom domains on your instance. |
| Manage servers | Provision, update, archive, and restore your Barkpark instances. |
| Control access | Workspace membership, scoped tokens, sharing rules, and single sign-on. |
| Run specialist tools | Live quizzes and ONIX book-metadata editing and export. |

Use each tool independently or combine them through shared data and access rules.
Work through the browser, terminal UI, CLI, or AI. Review changes and revoke tokens yourself.

## Local or remote

Keep the server, database, and files on your computer. Local work continues when
the internet or a remote server fails. Run remotely for shared access.
Local and remote instances hold separate data; transfers are explicit today.

## News

<!-- news:start -->
**Friday 20 November.** 49 pull requests merged. The desk, Barkpark's own document editor, gained a Tasks sidebar, a who-is-here menu, language tabs, and Params and pickers in Vision; Mod+Z now undoes slugs, selects, lists and nested fields. A workspace owner can register a chat host over ssh in one step. Codelists and select lists keep what is stored, and Paper source mode never changes a Paper it cannot carry. [The full day](docs/news/2026-11-20.md)
- **Desk:** a Tasks sidebar; who is here as one menu; language tabs; Params and pickers in Vision; Mod+Z undoes slugs, selects, lists and nested fields ([#27767](https://github.com/FRIKKern/barkpark/pull/27767), [#27884](https://github.com/FRIKKern/barkpark/pull/27884), [#27533](https://github.com/FRIKKern/barkpark/pull/27533), [#27695](https://github.com/FRIKKern/barkpark/pull/27695), [#27728](https://github.com/FRIKKern/barkpark/pull/27728), [#27680](https://github.com/FRIKKern/barkpark/pull/27680))
- **Chat hosts and Papers:** add a host over ssh in one step; a new code for a waiting host; a rebuilt Studio page; source mode never changes a Paper it cannot carry ([#27651](https://github.com/FRIKKern/barkpark/pull/27651), [#27643](https://github.com/FRIKKern/barkpark/pull/27643), [#27665](https://github.com/FRIKKern/barkpark/pull/27665), [#27555](https://github.com/FRIKKern/barkpark/pull/27555))
- **Kept values:** a codelist takes one short code; Paste writes codelists; select lists in objects and rows save as lists; a refused clear stays as stored ([#27955](https://github.com/FRIKKern/barkpark/pull/27955), [#27970](https://github.com/FRIKKern/barkpark/pull/27970), [#27969](https://github.com/FRIKKern/barkpark/pull/27969), [#27958](https://github.com/FRIKKern/barkpark/pull/27958), [#27936](https://github.com/FRIKKern/barkpark/pull/27936))

**Thursday 19 November.** 31 pull requests merged. The desk, Barkpark's own document editor, gained Vision for running queries, a Perspective picker and a phone menu, a read-only published view, and undo that takes back only your own typing. A member can ask for a higher role, and a token's permissions now cap what an admin seat lets it do. A codelist over a stored value it cannot show now keeps that value until you change that field, in the desk and the old Studio. [The full day](docs/news/2026-11-19.md)
- **Desk:** Vision; a Perspective picker and a phone drawer; the published version read-only; Cmd+Z undoes your own typing; a bad URL blocks Publish ([#27621](https://github.com/FRIKKern/barkpark/pull/27621), [#27492](https://github.com/FRIKKern/barkpark/pull/27492), [#27369](https://github.com/FRIKKern/barkpark/pull/27369), [#27435](https://github.com/FRIKKern/barkpark/pull/27435), [#27443](https://github.com/FRIKKern/barkpark/pull/27443))
- **Access:** ask for a higher role; members list role names; secrets and webhooks need the admin permission; a read-only token cannot write on an admin seat; imports carry no access requests ([#27339](https://github.com/FRIKKern/barkpark/pull/27339), [#27409](https://github.com/FRIKKern/barkpark/pull/27409), [#27297](https://github.com/FRIKKern/barkpark/pull/27297), [#27334](https://github.com/FRIKKern/barkpark/pull/27334), [#27277](https://github.com/FRIKKern/barkpark/pull/27277), [#27448](https://github.com/FRIKKern/barkpark/pull/27448))
- **Kept values:** a codelist over a number, object or list keeps it until that field or row is changed ([#27464](https://github.com/FRIKKern/barkpark/pull/27464), [#27497](https://github.com/FRIKKern/barkpark/pull/27497), [#27482](https://github.com/FRIKKern/barkpark/pull/27482))
<!-- news:end -->

Earlier: [weekly editions](CHANGELOG.md)

## Get started

[Run locally](docs/setup/QUICKSTART.md) · [Open Studio](https://api.barkpark.cloud/studio) · [Deploy a server](docs/setup/SELF-HOST.md) · [Connect an agent](docs/setup/AGENT-ONRAMPS.md)

[Documentation](docs/INDEX.md) · [JavaScript docs site](js/docs/README.md) · [Build a plugin](docs/cards/plugins.md) · [Principles](docs/PHILOSOPHY.md)

[Apache-2.0 licensed](LICENSE). Optional [Barkpark Cloud](https://barkpark.cloud) hosting funds development.
