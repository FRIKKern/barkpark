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
**Saturday 21 November.** 47 pull requests merged. A schema author can now give a type a fixed set of documents (fixedDocuments) and run a cross rule once per list item (each); "$today" reads the workspace time zone on create and in every query filter. In the desk, Vision can Listen to a query's changes, Create new has a type search, and undo covers tree codelist picks, Paste and a focused checkbox. A callout's body now survives bp paper pull and push and shows in the reader. [The full day](docs/news/2026-11-21.md)
- **Schemas:** fixedDocuments; a cross rule per list item; "$today" in the workspace time zone; a null over an initial value stays empty ([#28080](https://github.com/FRIKKern/barkpark/pull/28080), [#27930](https://github.com/FRIKKern/barkpark/pull/27930), [#27933](https://github.com/FRIKKern/barkpark/pull/27933), [#28091](https://github.com/FRIKKern/barkpark/pull/28091))
- **Desk:** Listen in Vision; a type search in Create new; undo of codelist picks, Paste and checkboxes; a save that did not land in caution colour ([#27799](https://github.com/FRIKKern/barkpark/pull/27799), [#27813](https://github.com/FRIKKern/barkpark/pull/27813), [#27992](https://github.com/FRIKKern/barkpark/pull/27992), [#27999](https://github.com/FRIKKern/barkpark/pull/27999), [#28127](https://github.com/FRIKKern/barkpark/pull/28127), [#28130](https://github.com/FRIKKern/barkpark/pull/28130))
- **Papers and history:** a callout's body in BPML and the reader; a history restore can name the state it saw ([#28022](https://github.com/FRIKKern/barkpark/pull/28022), [#28045](https://github.com/FRIKKern/barkpark/pull/28045), [#27880](https://github.com/FRIKKern/barkpark/pull/27880))

**Friday 20 November.** 49 pull requests merged. The desk, Barkpark's own document editor, gained a Tasks sidebar, a who-is-here menu, language tabs, and Params and pickers in Vision; Mod+Z now undoes slugs, selects, lists and nested fields. A workspace owner can register a chat host over ssh in one step. Codelists and select lists keep what is stored, and Paper source mode never changes a Paper it cannot carry. [The full day](docs/news/2026-11-20.md)
- **Desk:** a Tasks sidebar; who is here as one menu; language tabs; Params and pickers in Vision; Mod+Z undoes slugs, selects, lists and nested fields ([#27767](https://github.com/FRIKKern/barkpark/pull/27767), [#27884](https://github.com/FRIKKern/barkpark/pull/27884), [#27533](https://github.com/FRIKKern/barkpark/pull/27533), [#27695](https://github.com/FRIKKern/barkpark/pull/27695), [#27728](https://github.com/FRIKKern/barkpark/pull/27728), [#27680](https://github.com/FRIKKern/barkpark/pull/27680))
- **Chat hosts and Papers:** add a host over ssh in one step; a new code for a waiting host; a rebuilt Studio page; source mode never changes a Paper it cannot carry ([#27651](https://github.com/FRIKKern/barkpark/pull/27651), [#27643](https://github.com/FRIKKern/barkpark/pull/27643), [#27665](https://github.com/FRIKKern/barkpark/pull/27665), [#27555](https://github.com/FRIKKern/barkpark/pull/27555))
- **Kept values:** a codelist takes one short code; Paste writes codelists; select lists in objects and rows save as lists; a refused clear stays as stored ([#27955](https://github.com/FRIKKern/barkpark/pull/27955), [#27970](https://github.com/FRIKKern/barkpark/pull/27970), [#27969](https://github.com/FRIKKern/barkpark/pull/27969), [#27958](https://github.com/FRIKKern/barkpark/pull/27958), [#27936](https://github.com/FRIKKern/barkpark/pull/27936))
<!-- news:end -->

Earlier: [weekly editions](CHANGELOG.md)

## Get started

[Run locally](docs/setup/QUICKSTART.md) · [Open Studio](https://api.barkpark.cloud/studio) · [Deploy a server](docs/setup/SELF-HOST.md) · [Connect an agent](docs/setup/AGENT-ONRAMPS.md)

[Documentation](docs/INDEX.md) · [JavaScript docs site](js/docs/README.md) · [Build a plugin](docs/cards/plugins.md) · [Principles](docs/PHILOSOPHY.md)

[Apache-2.0 licensed](LICENSE). Optional [Barkpark Cloud](https://barkpark.cloud) hosting funds development.
