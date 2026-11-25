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
**Monday 23 November.** 11 pull requests merged, six of them on BPML, the text form of a Paper that bp paper pull prints. A pull now prints every level of a nested list with its item ids, a push stores every level, and an item keeps what BPML cannot spell through an edit. Each push records the Paper before and after it, in its own transaction. In the desk, leaving a document with a field held unsaved now asks first, and a legacy Paper's HTML is cleaned by a real HTML parser. [The full day](docs/news/2026-11-23.md)
- **Nested lists in BPML:** every level and item id printed and pushed; older list shapes take an edit; a pull counts and names the items a push carries back ([#28384](https://github.com/FRIKKern/barkpark/pull/28384), [#28438](https://github.com/FRIKKern/barkpark/pull/28438), [#28488](https://github.com/FRIKKern/barkpark/pull/28488), [#28464](https://github.com/FRIKKern/barkpark/pull/28464))
- **Push history:** a push records the Paper before and after it, in one transaction; a read-only report of list children and callout bodies a Paper lost ([#28414](https://github.com/FRIKKern/barkpark/pull/28414), [#28398](https://github.com/FRIKKern/barkpark/pull/28398))
- **Desk and reader:** leaving a document with a held field asks first; a legacy Paper's HTML is cleaned by an HTML parser ([#28408](https://github.com/FRIKKern/barkpark/pull/28408), [#28404](https://github.com/FRIKKern/barkpark/pull/28404))

**Sunday 22 November.** 43 pull requests merged. Two people editing one document in the desk now lose fewer words: another editor's save conflicts only where it rewrote a field you changed, the banner names those fields, and both people's words are kept inside an object's text and rich text. Rich text keeps an indent, a renumber and a block's own stored fields, and a javascript:, data: or vbscript: link is drawn as words and refused on write. A BPML push now refuses to change what its pull did not show, and a Studio history restore is refused when the document has moved on. [The full day](docs/news/2026-11-22.md)
- **Two editors:** a conflict only where the other save rewrote your field, named in the banner; both people's words kept in object text and rich text; titles follow the other editor ([#28176](https://github.com/FRIKKern/barkpark/pull/28176), [#28302](https://github.com/FRIKKern/barkpark/pull/28302), [#28331](https://github.com/FRIKKern/barkpark/pull/28331), [#28349](https://github.com/FRIKKern/barkpark/pull/28349), [#28322](https://github.com/FRIKKern/barkpark/pull/28322), [#28363](https://github.com/FRIKKern/barkpark/pull/28363))
- **Rich text and links:** an indent or renumber is stored; a block keeps its stored fields; a javascript:, data: or vbscript: link is drawn as words and refused on write ([#28354](https://github.com/FRIKKern/barkpark/pull/28354), [#28360](https://github.com/FRIKKern/barkpark/pull/28360), [#28371](https://github.com/FRIKKern/barkpark/pull/28371), [#28393](https://github.com/FRIKKern/barkpark/pull/28393))
- **Papers and history:** a BPML push refuses changes to what its pull did not show and records the Paper as it stood before; a Studio restore names the state it saw ([#27556](https://github.com/FRIKKern/barkpark/pull/27556), [#28381](https://github.com/FRIKKern/barkpark/pull/28381), [#28096](https://github.com/FRIKKern/barkpark/pull/28096))
<!-- news:end -->

Earlier: [weekly editions](CHANGELOG.md)

## Get started

[Run locally](docs/setup/QUICKSTART.md) · [Open Studio](https://api.barkpark.cloud/studio) · [Deploy a server](docs/setup/SELF-HOST.md) · [Connect an agent](docs/setup/AGENT-ONRAMPS.md)

[Documentation](docs/INDEX.md) · [JavaScript docs site](js/docs/README.md) · [Build a plugin](docs/cards/plugins.md) · [Principles](docs/PHILOSOPHY.md)

[Apache-2.0 licensed](LICENSE). Optional [Barkpark Cloud](https://barkpark.cloud) hosting funds development.
