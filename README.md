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
**Thursday 26 November.** 53 pull requests merged. In the Studio, browser Back and a link over a held field now ask with the desk's leave dialog, and while that question is open after a Back into another project, nothing is written, reloaded or opened there. A top-level rich text and the rows of an array are now read under the document's lock and by each row's key, so another editor's save or row move is merged or held under the banner, not written over. Creating a workspace now needs a write seat in a workspace that is not suspended, on REST, in the Studio and in the chrome, and two same-slug papers in two projects no longer make a public papers page answer 500. [The full day](docs/news/2026-11-26.md)
- **Leave question in the Studio:** Back, links and presses over a held field ask with the desk's dialog; under it, after a Back into another project, nothing is written, reloaded or opened there ([#28937](https://github.com/FRIKKern/barkpark/pull/28937), [#28953](https://github.com/FRIKKern/barkpark/pull/28953), [#28968](https://github.com/FRIKKern/barkpark/pull/28968), [#28976](https://github.com/FRIKKern/barkpark/pull/28976))
- **Two editors, one document:** a top-level rich text is read under the lock; array rows go by their key; a rejoined page's hold stays until Save or Reload ([#28933](https://github.com/FRIKKern/barkpark/pull/28933), [#29036](https://github.com/FRIKKern/barkpark/pull/29036), [#29040](https://github.com/FRIKKern/barkpark/pull/29040), [#29043](https://github.com/FRIKKern/barkpark/pull/29043))
- **Who may create a workspace:** a write seat in the workspace it acts from, and never from a suspended one, on REST, in the Studio and in the chrome ([#28980](https://github.com/FRIKKern/barkpark/pull/28980), [#28999](https://github.com/FRIKKern/barkpark/pull/28999), [#29014](https://github.com/FRIKKern/barkpark/pull/29014))

**Wednesday 25 November.** 74 pull requests merged, 49 of them on two people editing one document. Two editors who type in different words of one paragraph of a rich text inside an object now both keep their words, with no banner, and a save that lands while another is being written is merged or held under the banner, never written over in silence: in Chrome that loss fell from 4 of 4 Studio runs to 0 of 10. A chat on a registered host, a person's own computer, can now be created, driven and seen only by an owner or admin seat. A javascript: link inside a rich text stored as HTML is now refused on write, and a bundle import strips such an address from a Portable Text link. [The full day](docs/news/2026-11-25.md)
- **Two editors, one document:** different words of one paragraph merge; a save landing under another is merged or held, never written over, also on a rejoin and on Save ([#28781](https://github.com/FRIKKern/barkpark/pull/28781), [#28802](https://github.com/FRIKKern/barkpark/pull/28802), [#28817](https://github.com/FRIKKern/barkpark/pull/28817), [#28792](https://github.com/FRIKKern/barkpark/pull/28792), [#28803](https://github.com/FRIKKern/barkpark/pull/28803), [#28833](https://github.com/FRIKKern/barkpark/pull/28833), [#28830](https://github.com/FRIKKern/barkpark/pull/28830))
- **Chat on a person's computer:** only an owner or admin seat creates, drives, sees or counts a registered-host chat; an answered question keeps its answers ([#28693](https://github.com/FRIKKern/barkpark/pull/28693), [#28844](https://github.com/FRIKKern/barkpark/pull/28844), [#28848](https://github.com/FRIKKern/barkpark/pull/28848), [#28852](https://github.com/FRIKKern/barkpark/pull/28852))
- **Links and stored HTML:** a script link is refused in an HTML rich text on write and stripped from an imported link; stored ids move out of the page's way; a NUL byte is a 422 ([#28695](https://github.com/FRIKKern/barkpark/pull/28695), [#28728](https://github.com/FRIKKern/barkpark/pull/28728), [#28659](https://github.com/FRIKKern/barkpark/pull/28659), [#28712](https://github.com/FRIKKern/barkpark/pull/28712))
<!-- news:end -->

Earlier: [weekly editions](CHANGELOG.md)

## Get started

[Run locally](docs/setup/QUICKSTART.md) · [Open Studio](https://api.barkpark.cloud/studio) · [Deploy a server](docs/setup/SELF-HOST.md) · [Connect an agent](docs/setup/AGENT-ONRAMPS.md)

[Documentation](docs/INDEX.md) · [JavaScript docs site](js/docs/README.md) · [Build a plugin](docs/cards/plugins.md) · [Principles](docs/PHILOSOPHY.md)

[Apache-2.0 licensed](LICENSE). Optional [Barkpark Cloud](https://barkpark.cloud) hosting funds development.
