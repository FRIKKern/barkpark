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
**Tuesday 17 November.** 86 pull requests merged. The desk, Barkpark's own document editor, got a Validation panel that jumps to each problem field and keeps Publish off while an error blocks, bulk Publish and Unpublish for ticked rows, a tags input, and a menu on each item of an object array. A signed-in user with no seat can ask a workspace for one, and its admins approve or deny it, over the API and bp. More than half the day made the chat API safer to retry: a resend under the same Idempotency-Key runs its turn once. [The full day](docs/news/2026-11-17.md)
- **Desk:** a Validation panel; Select documents, then Publish selected or Unpublish selected; tags you add with Enter; Remove, Copy, Duplicate and Add before or after on each array item ([#26685](https://github.com/FRIKKern/barkpark/pull/26685), [#26719](https://github.com/FRIKKern/barkpark/pull/26719), [#26807](https://github.com/FRIKKern/barkpark/pull/26807), [#26813](https://github.com/FRIKKern/barkpark/pull/26813))
- **Access:** ask for a seat and admins approve or deny; Barkpark Cloud and emailed-link sign-in return to the page that asked ([#26848](https://github.com/FRIKKern/barkpark/pull/26848), [#26732](https://github.com/FRIKKern/barkpark/pull/26732))
- **Retries:** a chat send or a mutate resent under its Idempotency-Key runs once; a reused key with another body is refused; prefs take If-Match and If-None-Match ([#26689](https://github.com/FRIKKern/barkpark/pull/26689), [#26894](https://github.com/FRIKKern/barkpark/pull/26894), [#26786](https://github.com/FRIKKern/barkpark/pull/26786), [#26855](https://github.com/FRIKKern/barkpark/pull/26855), [#26861](https://github.com/FRIKKern/barkpark/pull/26861), [#26891](https://github.com/FRIKKern/barkpark/pull/26891))

**Monday 16 November.** 17 pull requests merged. Workspace admins got two new pages in Barkpark's built-in Studio: Webhooks (add, test and replay a dataset's webhooks) and Activity (the audit log: who changed what, also over the API and bp audit ls). In the media library, a file now lists the documents that use it. Four fixes tighten who sees what: refused deletes name only documents you can read, and the org-admin page shows only your own workspaces and organisations. The chat API behind BarkBot ends a turn whose message could not be stored, if no computer has started it yet, and a BarkBot page load now reads 0 old messages where it read every one. [The full day](docs/news/2026-11-16.md)
- **New in Studio:** Webhooks for admins: list, add, edit, test and replay, with the signing secret shown once; Activity for admins: filter the audit log by category, actor and date; Used in for media: the documents you can read that use a file, and bp media usage ([#26570](https://github.com/FRIKKern/barkpark/pull/26570), [#26615](https://github.com/FRIKKern/barkpark/pull/26615), [#26535](https://github.com/FRIKKern/barkpark/pull/26535))
- **Who sees what:** a refused media or dataset delete names only documents you can read; org-admin shows only your own workspaces' activity, and organisation settings only for organisations you administer in full, with one line saying so ([#26560](https://github.com/FRIKKern/barkpark/pull/26560), [#26580](https://github.com/FRIKKern/barkpark/pull/26580), [#26637](https://github.com/FRIKKern/barkpark/pull/26637), [#26648](https://github.com/FRIKKern/barkpark/pull/26648), [#26653](https://github.com/FRIKKern/barkpark/pull/26653))
- **Chat:** a turn whose message cannot be stored is ended if no computer has started it; a lost reply after a stored message no longer stores it twice; text holding a NUL character is a 400; a read past the newest message loads no rows ([#26632](https://github.com/FRIKKern/barkpark/pull/26632), [#26659](https://github.com/FRIKKern/barkpark/pull/26659), [#26657](https://github.com/FRIKKern/barkpark/pull/26657), [#26658](https://github.com/FRIKKern/barkpark/pull/26658))
<!-- news:end -->

Earlier: [weekly editions](CHANGELOG.md)

## Get started

[Run locally](docs/setup/QUICKSTART.md) · [Open Studio](https://api.barkpark.cloud/studio) · [Deploy a server](docs/setup/SELF-HOST.md) · [Connect an agent](docs/setup/AGENT-ONRAMPS.md)

[Documentation](docs/INDEX.md) · [JavaScript docs site](js/docs/README.md) · [Build a plugin](docs/cards/plugins.md) · [Principles](docs/PHILOSOPHY.md)

[Apache-2.0 licensed](LICENSE). Optional [Barkpark Cloud](https://barkpark.cloud) hosting funds development.
