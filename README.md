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
**Wednesday 18 November.** 54 pull requests merged. In the desk, Barkpark's own document editor, you can now create a post or other content document that is stored only at its first edit, duplicate it, open its history and revert to an old revision, review changes field by field, copy and paste a whole document, and crop an image; two browsers typing in one title keep both people's words. bp got sturdier for self-hosting: export follows references, import recovers from a stalled batch, and token create --dry-run sends nothing. A weak reference no longer blocks a delete. [The full day](docs/news/2026-11-18.md)
- **Desk:** Create new, Duplicate, History with Revert, Review changes, Copy and Paste document, hotspot and crop; two people typing in one title ([#26970](https://github.com/FRIKKern/barkpark/pull/26970), [#26975](https://github.com/FRIKKern/barkpark/pull/26975), [#26966](https://github.com/FRIKKern/barkpark/pull/26966), [#26985](https://github.com/FRIKKern/barkpark/pull/26985), [#27048](https://github.com/FRIKKern/barkpark/pull/27048), [#27053](https://github.com/FRIKKern/barkpark/pull/27053), [#26988](https://github.com/FRIKKern/barkpark/pull/26988))
- **bp:** setup reads the token from stdin; export --follow-refs; import survives a stalled batch; token create --dry-run sends nothing; instance backup fetch ([#27146](https://github.com/FRIKKern/barkpark/pull/27146), [#27155](https://github.com/FRIKKern/barkpark/pull/27155), [#27154](https://github.com/FRIKKern/barkpark/pull/27154), [#27149](https://github.com/FRIKKern/barkpark/pull/27149), [#27156](https://github.com/FRIKKern/barkpark/pull/27156))
- **Fixes:** a weak reference no longer blocks a delete; a scoped-admin refusal names the missing role; a full task title finds the task ([#27251](https://github.com/FRIKKern/barkpark/pull/27251), [#27226](https://github.com/FRIKKern/barkpark/pull/27226), [#27063](https://github.com/FRIKKern/barkpark/pull/27063))

**Tuesday 17 November.** 86 pull requests merged. The desk, Barkpark's own document editor for workspace admins, got a Validation panel that jumps to each problem field and keeps Publish off while an error blocks, bulk Publish and Unpublish for ticked rows, a tags input, and a menu on each item of an object array. A signed-in user with no seat can ask a workspace for one, and its admins approve or deny it, over the API and bp. More than half the day went to the chat API behind BarkBot and Studio chat; among it, a resend under the same Idempotency-Key now runs its turn once. [The full day](docs/news/2026-11-17.md)
- **Desk:** a Validation panel; Select documents, then Publish selected or Unpublish selected; tags you add with Enter; Remove, Copy, Duplicate and Add before or after on each array item ([#26685](https://github.com/FRIKKern/barkpark/pull/26685), [#26719](https://github.com/FRIKKern/barkpark/pull/26719), [#26807](https://github.com/FRIKKern/barkpark/pull/26807), [#26813](https://github.com/FRIKKern/barkpark/pull/26813))
- **Access:** ask for a seat and admins approve or deny; Barkpark Cloud and emailed-link sign-in return to the page that asked ([#26848](https://github.com/FRIKKern/barkpark/pull/26848), [#26732](https://github.com/FRIKKern/barkpark/pull/26732))
- **Retries:** a chat send or a mutate resent under its Idempotency-Key runs once; a reused key with another body is refused; prefs take If-Match and If-None-Match: * ([#26689](https://github.com/FRIKKern/barkpark/pull/26689), [#26894](https://github.com/FRIKKern/barkpark/pull/26894), [#26786](https://github.com/FRIKKern/barkpark/pull/26786), [#26855](https://github.com/FRIKKern/barkpark/pull/26855), [#26861](https://github.com/FRIKKern/barkpark/pull/26861), [#26891](https://github.com/FRIKKern/barkpark/pull/26891))
<!-- news:end -->

Earlier: [weekly editions](CHANGELOG.md)

## Get started

[Run locally](docs/setup/QUICKSTART.md) · [Open Studio](https://api.barkpark.cloud/studio) · [Deploy a server](docs/setup/SELF-HOST.md) · [Connect an agent](docs/setup/AGENT-ONRAMPS.md)

[Documentation](docs/INDEX.md) · [JavaScript docs site](js/docs/README.md) · [Build a plugin](docs/cards/plugins.md) · [Principles](docs/PHILOSOPHY.md)

[Apache-2.0 licensed](LICENSE). Optional [Barkpark Cloud](https://barkpark.cloud) hosting funds development.
