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
**Monday 16 November.** Nothing merged yet today.

**Sunday 15 November.** 51 pull requests merged. The desk, Barkpark's own document editor, got closer to the TanStack Studio: Delete and Unpublish now ask first and list the documents that still point to the one you remove, and every field has a menu that copies and pastes it. The chat hosts, the computers BarkBot's bots work on, can now give each bot its own folder. A silent bug is gone: an edit could be saved into the next document you opened. [The full day](docs/news/2026-11-15.md)
- **Desk:** Delete and Unpublish ask in the desk's own dialog with who refers; an Incoming references panel; Copy field and Paste field; fieldsets fold; an edit is saved only into the document it was made in ([#26379](https://github.com/FRIKKern/barkpark/pull/26379), [#26381](https://github.com/FRIKKern/barkpark/pull/26381), [#26377](https://github.com/FRIKKern/barkpark/pull/26377), [#26448](https://github.com/FRIKKern/barkpark/pull/26448), [#26467](https://github.com/FRIKKern/barkpark/pull/26467), [#26390](https://github.com/FRIKKern/barkpark/pull/26390), [#26482](https://github.com/FRIKKern/barkpark/pull/26482))
- **Chat hosts:** a bot can work in its own folder, and a turn the computer can no longer serve is ended, not handed out; a workspace holds at most 10 live hosts ([#26451](https://github.com/FRIKKern/barkpark/pull/26451), [#26449](https://github.com/FRIKKern/barkpark/pull/26449), [#26484](https://github.com/FRIKKern/barkpark/pull/26484), [#26353](https://github.com/FRIKKern/barkpark/pull/26353), [#26408](https://github.com/FRIKKern/barkpark/pull/26408))
- **Papers, sheets, media:** find and replace in a paper (Cmd+F); export a paper as Markdown or print it to PDF; charts in sheets; tick many files in the media library and delete or file them at once ([#26319](https://github.com/FRIKKern/barkpark/pull/26319), [#26513](https://github.com/FRIKKern/barkpark/pull/26513), [#26446](https://github.com/FRIKKern/barkpark/pull/26446), [#26376](https://github.com/FRIKKern/barkpark/pull/26376))
<!-- news:end -->

Earlier: [weekly editions](CHANGELOG.md)

## Get started

[Run locally](docs/setup/QUICKSTART.md) · [Open Studio](https://api.barkpark.cloud/studio) · [Deploy a server](docs/setup/SELF-HOST.md) · [Connect an agent](docs/setup/AGENT-ONRAMPS.md)

[Documentation](docs/INDEX.md) · [JavaScript docs site](js/docs/README.md) · [Build a plugin](docs/cards/plugins.md) · [Principles](docs/PHILOSOPHY.md)

[Apache-2.0 licensed](LICENSE). Optional [Barkpark Cloud](https://barkpark.cloud) hosting funds development.
